-- Screen gallery (debug builds only): steps through every screen with sample data in
-- the real engine, so layouts can be reviewed without setting up a multiplayer game.
--
-- Open it from the "Screens" link on the menu. Prev/Next in the top bar or the arrow
-- keys switch screens; tap the title or press Esc to exit.
--
-- The screens are the real ones. To draw host/client variants without a network,
-- net.is_host and net.my_id are temporarily replaced while the gallery is open.
-- Buttons on the sample screens are disabled so nothing is sent or saved.

local ui = require "ui.ui"
local net = require "net.lobby_net"

local M = {}

local BAR_H = 44

function M.enabled()
	local info = sys.get_engine_info()
	return info and info.is_debug
end

---------------------------------------------------------------------------
-- Sample data: 8 players, long names, non-ASCII letters, one player who left
---------------------------------------------------------------------------

local PLAYERS = {
	{ id = 1, name = "Anna", color = 1, score = 7, host = true },
	{ id = 2, name = "Christopher", color = 2, score = 5 },
	{ id = 3, name = "Åsa-Märta", color = 3, score = 5 },
	{ id = 4, name = "Mikko", color = 4, score = 3 },
	{ id = 5, name = "Leena", color = 5, score = 2 },
	{ id = 6, name = "Jussi", color = 6, score = 2 },
	{ id = 7, name = "Olli", color = 7, score = 1, connected = false },
	{ id = 8, name = "Sara", color = 8, score = 0 },
}

local function players(count)
	local list = {}
	for i = 1, count or #PLAYERS do
		local p = PLAYERS[i]
		list[i] = { id = p.id, name = p.name, color = p.color, score = p.score, host = p.host, connected = p.connected ~= false }
	end
	return list
end

local CHOICES = { "Remote control", "Vacuum cleaner", "Alarm clock", "Toothbrush", "Doormat", "Kettle", "Umbrella", "Candle" }

-- A game view as the host would send it; `extra` overrides/adds fields
local function view(phase, extra)
	local v = {
		phase = phase, round = 2, rounds = 3, category = "Things at home",
		players = players(), word = "Remote control", impostor = false, ends_in = 18, total_time = 30,
	}
	for k, value in pairs(extra or {}) do
		v[k] = value
	end
	return v
end

local ORDER = { 2, 3, 1, 4, 5, 6, 7, 8 }
local VOTES = {
	{ voter = 1, target = 4 }, { voter = 2, target = 4 }, { voter = 3, target = 4 },
	{ voter = 4, target = 2 }, { voter = 5, target = 3 }, { voter = 6, target = 4 }, { voter = 8, target = 2 },
}
local SCATTERED_VOTES = {
	{ voter = 1, target = 2 }, { voter = 2, target = 3 }, { voter = 3, target = 4 },
	{ voter = 4, target = 5 }, { voter = 5, target = 6 }, { voter = 6, target = 8 }, { voter = 8, target = 1 },
}

local function result(outcome, extra)
	local v = view("result", {
		outcome = outcome, impostor_id = 4, accused = 4, votes = VOTES, word = "Remote control",
		deltas = { { id = 1, points = 1 }, { id = 2, points = 1 }, { id = 3, points = 1 }, { id = 6, points = 1 } },
		impostor = nil, ends_in = nil,
	})
	for k, value in pairs(extra or {}) do
		v[k] = value
	end
	return v
end

-- Each page: title, what to show, plus who "you" are (me) and whether you host
local PAGES = {
	{ title = "Menu", menu = {} },
	{ title = "Menu · editing a long name", menu = { editing = "Christopher" } },
	{ title = "Menu · connection error", menu = { message = "Could not connect to 192.168.1.23: connection refused" } },

	{ title = "Join · searching", scan = {} },
	{ title = "Join · hosts found", scan = {
		{ ip = "192.168.1.10", port = 47800, name = "Anna", players = 3, max = 8 },
		{ ip = "192.168.1.11", port = 47800, name = "Christopher", players = 7, max = 8 },
		{ ip = "192.168.1.12", port = 47800, name = "Åsa-Märta", players = 1, max = 8 },
	} },

	{ title = "Lobby · host, needs players", lobby = { count = 2 }, host = true, me = 1 },
	{ title = "Lobby · host, full lobby", lobby = { count = 8 }, host = true, me = 1 },
	{ title = "Lobby · client", lobby = { count = 5, settings = { rounds = 6, clue_time = 15, discuss_time = 300 } }, me = 3 },
	{ title = "Lobby · popup: rounds", lobby = { count = 5, popup = "rounds" }, host = true, me = 1 },
	{ title = "Lobby · popup: time per clue", lobby = { count = 5, popup = "clue_time" }, host = true, me = 1 },
	{ title = "Lobby · popup: discussion", lobby = { count = 5, popup = "discuss_time" }, host = true, me = 1 },

	{ title = "Card · hidden", game = view("card", { ready = false, ready_count = 3, total = 7 }), me = 1 },
	{ title = "Card · player (hold)", game = view("card", { ready = false, ready_count = 3, total = 7 }), me = 1, peeking = true },
	{ title = "Card · impostor (hold)", game = view("card", { impostor = true, word = nil, ready = false, ready_count = 3, total = 7 }), me = 4, peeking = true },
	{ title = "Card · waiting for others", game = view("card", { ready = true, ready_count = 6, total = 7 }), me = 1 },

	{ title = "Clues · your turn", game = view("clues", { order = ORDER, current = 3 }), me = 1, host = true },
	{ title = "Clues · someone else's turn", game = view("clues", { order = ORDER, current = 5 }), me = 1 },
	{ title = "Clues · peeking", game = view("clues", { order = ORDER, current = 5 }), me = 1, peeking = true },
	{ title = "Clues · toasts + unstable banner", game = view("clues", { order = ORDER, current = 2 }), me = 1, overlays = true },

	{ title = "Discuss", game = view("discuss", { ends_in = 102, total_time = 120, ready = false, ready_count = 3, total = 7 }), me = 1 },
	{ title = "Discuss · ready", game = view("discuss", { ends_in = 45, total_time = 120, ready = true, ready_count = 6, total = 7 }), me = 1 },
	{ title = "Discuss · impostor peeking", game = view("discuss", { impostor = true, word = nil, ends_in = 80, total_time = 120, ready = false, ready_count = 0, total = 7 }), me = 4, peeking = true },

	{ title = "Vote · choosing", game = view("vote", { ends_in = 42, votes_in = 2, total = 7 }), me = 1 },
	{ title = "Vote · picked", game = view("vote", { ends_in = 42, votes_in = 2, total = 7 }), me = 1, vote_pick = 2 },
	{ title = "Vote · voted", game = view("vote", { ends_in = 30, votes_in = 5, total = 7, my_vote = 3 }), me = 1 },

	{ title = "Guess · impostor chooses", game = view("guess", {
		impostor = true, word = nil, impostor_id = 4, ends_in = 14, choices = CHOICES,
		tally = { { id = 4, count = 4 }, { id = 2, count = 2 }, { id = 3, count = 1 } },
	}), me = 4 },
	{ title = "Guess · others wait", game = view("guess", {
		impostor_id = 4, ends_in = 14, tally = { { id = 4, count = 4 }, { id = 2, count = 2 }, { id = 3, count = 1 } },
	}), me = 1 },

	{ title = "Result · caught, wrong guess", game = result("caught", { guess = "Vacuum cleaner" }), me = 1, host = true },
	{ title = "Result · caught, no guess", game = result("caught"), me = 1, host = true },
	{ title = "Result · impostor guessed", game = result("guessed", { guess = "Remote control" }), me = 1, host = true },
	{ title = "Result · innocent accused", game = result("framed", { accused = 2, votes = {
		{ voter = 1, target = 2 }, { voter = 3, target = 2 }, { voter = 4, target = 2 }, { voter = 5, target = 2 },
		{ voter = 2, target = 4 }, { voter = 6, target = 3 }, { voter = 8, target = 5 },
	}, deltas = { { id = 4, points = 3 }, { id = 2, points = 1 } } }), me = 1, host = true },
	{ title = "Result · tie, every vote different", game = result("tie", { accused = nil, votes = SCATTERED_VOTES,
		deltas = { { id = 4, points = 2 }, { id = 3, points = 1 } } }), me = 1, host = true },
	{ title = "Result · cancelled (impostor left)", game = result("void", { deltas = {} }), me = 1, host = true },
	{ title = "Result · scores", game = result("caught", { guess = "Kettle", last_round = true }), me = 1, host = true, show_scores = true },
	{ title = "Result · as a client", game = result("caught", { guess = "Kettle" }), me = 3 },

	{ title = "Final · one winner", game = view("final", { round = 3 }), me = 1, host = true },
	{ title = "Final · shared win, as a client", game = view("final", { round = 3, players = (function()
		local list = players()
		list[2].score = 7
		return list
	end)() }), me = 2 },
	{ title = "Final · ended early", game = view("final", { round = 2, reason = "Not enough players left" }), me = 1, host = true },
}

---------------------------------------------------------------------------
-- Controller
---------------------------------------------------------------------------

local real_is_host, real_my_id

local function draw_bar(self, page, issue_count)
	local g = self.gallery
	ui.rect(self, 0, 0, ui.W, BAR_H, { color = vmath.vector4(0, 0, 0, 0.85) })
	ui.label(self, "Prev", 14, BAR_H / 2, { font = "bold", size = 14, color = ui.ACCENT })
	ui.label(self, "Next", ui.W - 14, BAR_H / 2, { font = "bold", size = 14, color = ui.ACCENT, align = "right" })
	ui.label(self, page.title, ui.W / 2, 15, { font = "bold", size = 12, align = "center", max_width = ui.W - 190 })
	local status = issue_count > 0
		and ("%d of %d · %d layout issue%s · tap to exit"):format(g.index, #PAGES, issue_count, issue_count == 1 and "" or "s")
		or ("%d of %d · layout ok · tap to exit"):format(g.index, #PAGES)
	ui.label(self, status, ui.W / 2, 31, { size = 10, color = issue_count > 0 and ui.DANGER or ui.DIM, align = "center" })

	-- Tap zones; they replace every button on the sample screen (holds still work)
	local prev = ui.rect(self, 0, 0, 90, BAR_H, { color = vmath.vector4(0, 0, 0, 0) })
	local exit = ui.rect(self, 90, 0, ui.W - 180, BAR_H, { color = vmath.vector4(0, 0, 0, 0) })
	local next = ui.rect(self, ui.W - 90, 0, 90, BAR_H, { color = vmath.vector4(0, 0, 0, 0) })
	self.buttons = {
		{ node = prev, on_click = function() M.go(self, -1) end },
		{ node = next, on_click = function() M.go(self, 1) end },
		{ node = exit, on_click = function() M.stop(self) end },
	}
end

local function show(self)
	local g = self.gallery
	local page = PAGES[g.index]
	local ctx = g.ctx

	net.is_host = function() return page.host == true end
	net.my_id = function() return page.me end
	ui.set_banner(self, false)
	self.editing = false

	if page.menu then
		self.draft, self.marked = page.menu.editing or "", ""
		self.editing = page.menu.editing ~= nil
		ctx.menu(self, page.menu.message)
		self.editing = false -- drawn as editing, but don't grab keyboard input
		-- show_menu calls net.stop(), which is harmless here; restore the fakes afterwards
		net.is_host = function() return page.host == true end
		net.my_id = function() return page.me end
	elseif page.scan then
		ctx.scan(self, page.scan)
	elseif page.lobby then
		self.players = players(page.lobby.count)
		self.settings = page.lobby.settings
		self.popup = page.lobby.popup
		ctx.lobby(self)
		self.popup = nil
	elseif page.game then
		self.view_key = nil
		ctx.render(self, page.game) -- resets local state (peeking, picks)
		if page.peeking or page.vote_pick or page.show_scores then
			self.peeking = page.peeking == true
			self.vote_pick = page.vote_pick
			self.show_scores = page.show_scores == true
			ctx.render(self, page.game)
		end
		if page.overlays then
			ui.toast(self, "Olli lost connection", ui.player_color(7).fill)
			ui.toast(self, "Christopher left", ui.player_color(2).fill)
			ui.set_banner(self, true)
		end
	end
	self.screen = "gallery"

	-- Check the page's text with the real fonts: overlaps and text running off screen
	local issues = ui.layout_issues(self)
	ui.show_layout_issues(self, issues)
	for _, issue in ipairs(issues) do
		print(("[gallery] %s: %s"):format(page.title, issue.text))
	end
	g.issues = issues

	draw_bar(self, page, #issues)
	ui.raise_overlays(self)
end

-- Command-line layout check: a debug build started with SECRET_WORD_LAYOUT_CHECK set in
-- the environment checks every page with the real fonts, reports and exits (exit code 1
-- if any page has layout issues). Set it to a file path to also get the report as a file.
function M.wants_auto_check()
	return M.enabled() and os.getenv("SECRET_WORD_LAYOUT_CHECK") ~= nil
end

local function finish_auto_check(report)
	local count = 0
	for _, page in ipairs(report) do
		count = count + #page.issues
	end
	local lines = { ("%d pages checked, %d with issues, %d issues in total"):format(#PAGES, #report, count) }
	for _, page in ipairs(report) do
		for _, issue in ipairs(page.issues) do
			lines[#lines + 1] = ("%s: %s"):format(page.title, issue.text)
		end
	end
	for _, line in ipairs(lines) do
		print("[layout-check] " .. line)
	end
	local path = os.getenv("SECRET_WORD_LAYOUT_CHECK")
	if path ~= "1" then
		local file = io.open(path, "w")
		if file then
			file:write(table.concat(lines, "\n"), "\n")
			file:close()
		end
	end
	sys.exit(count > 0 and 1 or 0)
end

-- Call once per frame until it returns true. One page per frame: deleted GUI nodes are
-- only freed at the end of a frame, so all pages at once would run out of nodes.
function M.auto_check_step(self, ctx)
	if not self.gallery then
		M.start(self, ctx) -- shows page 1
		self.gallery.report = {}
	else
		M.go(self, 1)
	end
	local g = self.gallery
	if #g.issues > 0 then
		g.report[#g.report + 1] = { title = PAGES[g.index].title, issues = g.issues }
	end
	if g.index == #PAGES then
		finish_auto_check(g.report)
		return true
	end
	return false
end

-- ctx: the screens to draw with: { menu = fn(self, message), scan = fn(self, hosts),
--      lobby = fn(self), render = fn(self, view), exit = fn(self) }
function M.start(self, ctx)
	real_is_host, real_my_id = net.is_host, net.my_id
	self.gallery = { index = 1, ctx = ctx }
	show(self)
end

function M.go(self, step)
	local g = self.gallery
	g.index = (g.index - 1 + step) % #PAGES + 1
	show(self)
end

function M.stop(self)
	local ctx = self.gallery.ctx
	self.gallery = nil
	net.is_host, net.my_id = real_is_host, real_my_id
	ui.set_banner(self, false)
	self.players, self.settings, self.view_key = {}, nil, nil
	ctx.exit(self)
end

function M.active(self)
	return self.gallery ~= nil
end

local LEFT, RIGHT, ESCAPE, BACK = hash("left"), hash("right"), hash("escape"), hash("back")

-- Keyboard shortcuts; returns true if consumed
function M.on_input(self, action_id, action)
	if not action.pressed then
		return false
	end
	if action_id == LEFT then
		M.go(self, -1)
	elseif action_id == RIGHT then
		M.go(self, 1)
	elseif action_id == ESCAPE or action_id == BACK then
		M.stop(self)
	else
		return false
	end
	return true
end

M.PAGES = PAGES

return M
