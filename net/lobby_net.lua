-- Local-network lobby (no internet required).
--
-- One device hosts: a TCP server for game messages plus a UDP responder for discovery.
-- Other devices find hosts by sending a small UDP probe to every address in their
-- own /24 subnet (works on iOS without the multicast entitlement, and on Android
-- where broadcast is often filtered), then join over TCP.
--
-- Messages are newline-delimited JSON. Call M.update() every frame.

-- The global `socket` is only LuaSocket's C core; helpers like socket.bind live here.
local socket = require "builtins.scripts.socket"

local M = {}

M.TCP_PORT = 47800
M.DISCOVERY_PORT = 47801
M.MAX_PLAYERS = 8
M.NUM_COLORS = 8 -- colors are indices 1..NUM_COLORS; the UI decides what they look like

local PROTOCOL = "LTG2"
local PROBE = PROTOCOL .. "?"
local HEARTBEAT_INTERVAL = 1.0
local WARN_AFTER = 2.5 -- silence before a client reports an unstable connection
local TIMEOUT = 5.0 -- silence before a peer is considered gone
local SCAN_INTERVAL = 1.0
local HOST_FORGET_AFTER = 3.5

local mode = nil -- nil | "host" | "scan" | "client"
local my_name = "Player"
local listener = function() end

-- host state
local server
local discovery
local peers = {} -- list of connections; joined ones have .id, .name and .color
local next_id = 2
local started = false
local host_color = 1

-- scan state
local scanner
local found = {} -- ip -> { ip, port, name, players, seen }
local scan_timer = 0

-- client state
local conn
local my_id
local connection_unstable = false

local heartbeat_timer = 0

local function now()
	return socket.gettime()
end

local function emit(event, data)
	listener(event, data)
end

---------------------------------------------------------------------------
-- Connection helpers (non-blocking TCP with line framing)
---------------------------------------------------------------------------

local function new_conn(sock)
	sock:settimeout(0)
	sock:setoption("tcp-nodelay", true)
	return { sock = sock, inbuf = "", outbuf = "", last_recv = now() }
end

local function queue(c, msg)
	c.outbuf = c.outbuf .. json.encode(msg) .. "\n"
end

-- Returns false if the connection is dead.
local function flush(c)
	if c.outbuf == "" then
		return true
	end
	local sent, err, last = c.sock:send(c.outbuf)
	sent = sent or last
	if sent and sent > 0 then
		c.outbuf = c.outbuf:sub(sent + 1)
	end
	return err == nil or err == "timeout"
end

-- Returns (messages, closed). Messages that arrived just before a close are still returned,
-- so a final "bye" isn't lost.
local function read(c)
	local closed = false
	while true do
		local data, err, partial = c.sock:receive(4096)
		local chunk = data or partial
		if chunk and #chunk > 0 then
			c.inbuf = c.inbuf .. chunk
			c.last_recv = now()
		end
		if err == "timeout" then
			break
		elseif err then
			closed = true
			break
		end
	end

	local msgs = {}
	while true do
		local nl = c.inbuf:find("\n", 1, true)
		if not nl then
			break
		end
		local line = c.inbuf:sub(1, nl - 1)
		c.inbuf = c.inbuf:sub(nl + 1)
		local ok, msg = pcall(json.decode, line)
		if ok and type(msg) == "table" and msg.t then
			msgs[#msgs + 1] = msg
		end
	end
	return msgs, closed
end

local function close(c)
	if c and c.sock then
		c.sock:close()
		c.sock = nil
	end
end

---------------------------------------------------------------------------
-- Local addresses
---------------------------------------------------------------------------

local function is_private(ip)
	if ip:match("^10%.") or ip:match("^192%.168%.") then
		return true
	end
	local b = tonumber(ip:match("^172%.(%d+)%."))
	return b ~= nil and b >= 16 and b <= 31
end

-- Mobile-data and VPN interfaces can also have 10.x addresses; never scan those.
local function is_cellular_or_vpn(name)
	name = name or ""
	return name:match("^rmnet") or name:match("^v4%-rmnet") or name:match("^ccmni") or name:match("^pdp_ip")
		or name:match("^clat") or name:match("^tun") or name:match("^utun") or name:match("^ipsec")
end

-- Private IPv4 addresses of this device (Wi-Fi, hotspot, LAN).
function M.local_ips()
	local ips = {}
	for _, a in ipairs(sys.get_ifaddrs()) do
		if a.family == "ipv4" and a.up and a.address and is_private(a.address) and not is_cellular_or_vpn(a.name) then
			ips[#ips + 1] = a.address
		end
	end
	return ips
end

---------------------------------------------------------------------------
-- Host
---------------------------------------------------------------------------

local function player_list()
	local list = { { id = 1, name = my_name, color = host_color, host = true } }
	for _, c in ipairs(peers) do
		if c.id then
			list[#list + 1] = { id = c.id, name = c.name, color = c.color }
		end
	end
	return list
end

-- owner is a peer connection, or "host" for the host itself
local function color_taken(color, owner)
	if owner ~= "host" and host_color == color then
		return true
	end
	for _, c in ipairs(peers) do
		if c.id and c ~= owner and c.color == color then
			return true
		end
	end
	return false
end

-- First free color after `current` (wrapping). next_free_color(0, owner) gives the lowest free one.
local function next_free_color(current, owner)
	for step = 1, M.NUM_COLORS do
		local color = (current + step - 1) % M.NUM_COLORS + 1
		if not color_taken(color, owner) then
			return color
		end
	end
	return current
end

local function make_tap(id, name, color, x, y)
	return { t = "tap", id = id, name = name, color = color, x = math.floor(x), y = math.floor(y) }
end

local function broadcast(msg)
	for _, c in ipairs(peers) do
		if c.id then
			queue(c, msg)
		end
	end
end

local function lobby_changed()
	local list = player_list()
	broadcast({ t = "lobby", players = list })
	emit("lobby", list)
end

local function host_handle(c, msg)
	if msg.t == "hello" then
		if msg.proto ~= PROTOCOL then
			queue(c, { t = "reject", reason = "Version mismatch" })
			c.close_after_flush = true
		elseif started then
			queue(c, { t = "reject", reason = "Game already started" })
			c.close_after_flush = true
		elseif #player_list() >= M.MAX_PLAYERS then
			queue(c, { t = "reject", reason = "Lobby is full" })
			c.close_after_flush = true
		else
			c.id = next_id
			c.name = tostring(msg.name or ("Player " .. next_id))
			c.color = next_free_color(0, c)
			next_id = next_id + 1
			queue(c, { t = "welcome", id = c.id })
			lobby_changed()
		end
	elseif msg.t == "color" and c.id and not started then
		c.color = next_free_color(c.color, c)
		lobby_changed()
	elseif msg.t == "tap" and c.id and tonumber(msg.x) and tonumber(msg.y) then
		local tap = make_tap(c.id, c.name, c.color, tonumber(msg.x), tonumber(msg.y))
		broadcast(tap)
		emit("tap", tap)
	elseif msg.t == "bye" then
		c.said_bye = true
	end
end

-- Why a peer should be dropped, or nil if it's fine.
local function drop_reason(c, closed)
	if c.said_bye then
		return "left"
	elseif closed or not flush(c) then
		return "disconnected"
	elseif now() - c.last_recv >= TIMEOUT then
		return "lost connection"
	elseif c.close_after_flush and c.outbuf == "" then
		return "rejected"
	end
end

local function host_update(dt)
	-- Accept new connections
	while true do
		local sock = server:accept()
		if not sock then
			break
		end
		peers[#peers + 1] = new_conn(sock)
	end

	-- Answer discovery probes
	while true do
		local data, ip, port = discovery:receivefrom()
		if not data then
			break
		end
		if data == PROBE and not started then
			local reply = json.encode({ proto = PROTOCOL, name = my_name, port = M.TCP_PORT, players = #player_list(), max = M.MAX_PLAYERS })
			discovery:sendto(reply, ip, port)
		end
	end

	heartbeat_timer = heartbeat_timer + dt
	local send_heartbeat = heartbeat_timer >= HEARTBEAT_INTERVAL
	if send_heartbeat then
		heartbeat_timer = 0
	end

	-- Service peers
	local gone = {}
	for i = #peers, 1, -1 do
		local c = peers[i]
		local msgs, closed = read(c)
		for _, msg in ipairs(msgs) do
			host_handle(c, msg)
		end
		if send_heartbeat and not closed then
			queue(c, { t = "ping" })
		end
		local reason = drop_reason(c, closed)
		if reason then
			close(c)
			table.remove(peers, i)
			if c.id then
				gone[#gone + 1] = { t = "left", id = c.id, name = c.name, color = c.color, reason = reason }
			end
		end
	end

	-- Tell everyone who left and why, then send the updated player list
	for _, info in ipairs(gone) do
		broadcast(info)
		emit("player_left", info)
	end
	if #gone > 0 then
		lobby_changed()
	end
end

function M.host(name)
	M.stop()
	my_name = name

	local s, err = socket.bind("0.0.0.0", M.TCP_PORT)
	if not s then
		return false, "Could not open TCP port " .. M.TCP_PORT .. ": " .. tostring(err)
	end
	s:settimeout(0)

	local u = socket.udp()
	u:settimeout(0)
	local ok, uerr = u:setsockname("0.0.0.0", M.DISCOVERY_PORT)
	if not ok then
		s:close()
		u:close()
		return false, "Could not open UDP port " .. M.DISCOVERY_PORT .. ": " .. tostring(uerr)
	end

	server, discovery = s, u
	peers, next_id, started, heartbeat_timer, host_color = {}, 2, false, 0, 1
	mode = "host"
	lobby_changed()
	return true
end

function M.start_game()
	if mode ~= "host" or started then
		return
	end
	started = true
	broadcast({ t = "start" })
	emit("start")
end

---------------------------------------------------------------------------
-- Scan (discovery client)
---------------------------------------------------------------------------

local function send_probes()
	local targets = { "127.0.0.1" } -- finds a host running on the same machine
	for _, ip in ipairs(M.local_ips()) do
		local prefix = ip:match("^(%d+%.%d+%.%d+)%.")
		for i = 1, 254 do
			targets[#targets + 1] = prefix .. "." .. i
		end
	end
	for _, ip in ipairs(targets) do
		scanner:sendto(PROBE, ip, M.DISCOVERY_PORT) -- errors (unreachable etc.) are ignored
	end
	-- Broadcast as a bonus; often filtered on phones, so we don't rely on it.
	scanner:sendto(PROBE, "255.255.255.255", M.DISCOVERY_PORT)
end

local function scan_update(dt)
	scan_timer = scan_timer - dt
	local changed = false

	if scan_timer <= 0 then
		scan_timer = SCAN_INTERVAL
		send_probes()
		for ip, h in pairs(found) do
			if now() - h.seen > HOST_FORGET_AFTER then
				found[ip] = nil
				changed = true
			end
		end
	end

	while true do
		local data, ip = scanner:receivefrom()
		if not data then
			break
		end
		local ok, info = pcall(json.decode, data)
		if ok and type(info) == "table" and info.proto == PROTOCOL then
			if not found[ip] or found[ip].players ~= info.players then
				changed = true
			end
			found[ip] = { ip = ip, port = info.port, name = info.name, players = info.players, max = info.max, seen = now() }
		end
	end

	if changed then
		local list = {}
		for _, h in pairs(found) do
			list[#list + 1] = h
		end
		table.sort(list, function(a, b) return a.ip < b.ip end)
		emit("hosts", list)
	end
end

function M.scan()
	M.stop()
	scanner = socket.udp()
	scanner:settimeout(0)
	scanner:setsockname("0.0.0.0", 0)
	scanner:setoption("broadcast", true)
	found, scan_timer = {}, 0
	mode = "scan"
end

---------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------

-- Close the connection without saying bye, then report why.
local function client_lost(reason)
	close(conn)
	M.stop()
	emit("disconnected", reason)
end

local function client_update(dt)
	local msgs, closed = read(conn)

	for _, msg in ipairs(msgs) do
		if msg.t == "welcome" then
			my_id = msg.id
			emit("welcome", my_id)
		elseif msg.t == "lobby" then
			emit("lobby", msg.players)
		elseif msg.t == "start" then
			emit("start")
		elseif msg.t == "tap" then
			emit("tap", msg)
		elseif msg.t == "left" then
			emit("player_left", msg)
		elseif msg.t == "reject" then
			return client_lost(msg.reason or "Rejected by host")
		elseif msg.t == "bye" then
			return client_lost("Host ended the game")
		end
	end

	if closed then
		return client_lost("Lost connection to host")
	end

	heartbeat_timer = heartbeat_timer + dt
	if heartbeat_timer >= HEARTBEAT_INTERVAL then
		heartbeat_timer = 0
		queue(conn, { t = "ping" })
	end
	if not flush(conn) then
		return client_lost("Lost connection to host")
	end

	-- Silence detection: warn first, give up after TIMEOUT
	local silence = now() - conn.last_recv
	if silence > TIMEOUT then
		return client_lost("Host not responding")
	end
	local unstable = silence > WARN_AFTER
	if unstable ~= connection_unstable then
		connection_unstable = unstable
		emit("connection", { stable = not unstable })
	end
end

function M.join(ip, port, name)
	M.stop()
	my_name = name
	local sock = socket.tcp()
	-- Blocking connect with a short timeout keeps this simple; on a LAN it takes milliseconds.
	sock:settimeout(1.5)
	local ok, err = sock:connect(ip, port or M.TCP_PORT)
	if not ok then
		sock:close()
		return false, "Could not connect to " .. ip .. ": " .. tostring(err)
	end
	conn = new_conn(sock)
	my_id, heartbeat_timer, connection_unstable = nil, 0, false
	mode = "client"
	queue(conn, { t = "hello", proto = PROTOCOL, name = name })
	return true
end

---------------------------------------------------------------------------
-- Shared
---------------------------------------------------------------------------

-- In-game tap at (x, y) in the project's logical coordinates (640x1136).
-- Goes through the host, which relays it to everyone (including the sender).
function M.tap(x, y)
	if mode == "host" then
		local tap = make_tap(1, my_name, host_color, x, y)
		broadcast(tap)
		emit("tap", tap)
	elseif mode == "client" then
		queue(conn, { t = "tap", x = math.floor(x), y = math.floor(y) })
	end
end

-- Lobby only: switch to the next free color.
function M.change_color()
	if mode == "host" and not started then
		host_color = next_free_color(host_color, "host")
		lobby_changed()
	elseif mode == "client" then
		queue(conn, { t = "color" })
	end
end

function M.my_id()
	if mode == "host" then
		return 1
	end
	return my_id
end

function M.is_host()
	return mode == "host"
end

-- listener(event, data). Events:
--   "hosts"        list of found hosts (while scanning)
--   "welcome"      my player id (client)
--   "lobby"        player list { id, name, color, host }
--   "start"        host started the game
--   "tap"          { id, name, color, x, y }
--   "player_left"  { id, name, color, reason } reason: "left" | "lost connection" | "disconnected"
--   "connection"   { stable = bool } client only; silence from host > WARN_AFTER, or recovered
--   "disconnected" reason string; we are no longer in a game
function M.set_listener(fn)
	listener = fn or function() end
end

function M.update(dt)
	if mode == "host" then
		host_update(dt)
	elseif mode == "scan" then
		scan_update(dt)
	elseif mode == "client" then
		client_update(dt)
	end
end

-- Leave whatever we're doing. Connections that are still open get a "bye" first,
-- so others see "left" immediately instead of waiting for a timeout.
function M.stop()
	for _, c in ipairs(peers) do
		if c.sock and c.id then
			queue(c, { t = "bye" })
			flush(c)
		end
		close(c)
	end
	if conn and conn.sock then
		queue(conn, { t = "bye" })
		flush(conn)
	end
	peers = {}
	close(conn)
	conn = nil
	if server then server:close() end
	if discovery then discovery:close() end
	if scanner then scanner:close() end
	server, discovery, scanner = nil, nil, nil
	found = {}
	mode = nil
end

return M
