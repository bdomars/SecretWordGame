-- GUI helpers for screens built in code, styled after the Secret Word storyboard.
--
-- Coordinates are in storyboard pixels: a 390x844 phone frame, origin top-left,
-- y growing downwards (like the design files). The GUI itself is 2x that
-- (780x1688, see game.project), which keeps rounded corners and text crisp.
--
-- Every function takes the gui script's `self`, which holds the current screen's
-- nodes; ui.clear() removes them all. Must be called from a gui_script.

local M = {}

M.W, M.H = 390, 844
M.PAD = 24 -- side padding
M.CONTENT_W = M.W - 2 * M.PAD
local S = 2 -- storyboard px -> GUI units

local function hex(h)
	return vmath.vector4(tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255, 1)
end
M.hex = hex

-- Palette (from the storyboard)
M.BG = hex("17161F")
M.SURFACE = hex("23212E")
M.SURFACE_SELECTED = hex("2E2A22")
M.LINE = hex("34313F")
M.LINE_STRONG = hex("4A4657")
M.MUTED = hex("6B6677")
M.TEXT = hex("F4F1EA")
M.DIM = hex("A8A3B3")
M.ACCENT = hex("F2B53A")
M.ON_ACCENT = hex("1A1400")
M.DANGER = hex("F07457")
M.ON_DANGER = hex("2A0D06")
M.GOOD = hex("8FD19E")

-- Player colors, indexed by the color number the host assigns (1..8): fill + text on it
M.PLAYER_COLORS = {
	{ fill = hex("F2B53A"), ink = hex("1A1400") },
	{ fill = hex("6FB7E8"), ink = hex("0B1A26") },
	{ fill = hex("8FD19E"), ink = hex("0D2113") },
	{ fill = hex("F07457"), ink = hex("2A0D06") },
	{ fill = hex("C9A2F0"), ink = hex("1F0E30") },
	{ fill = hex("E8D36F"), ink = hex("231E05") },
	{ fill = hex("F29BC5"), ink = hex("2B0A1C") },
	{ fill = hex("6FD6C8"), ink = hex("062622") },
}

function M.player_color(index)
	return M.PLAYER_COLORS[index] or { fill = M.DIM, ink = M.BG }
end

local FONT_BASE = { heading = 64, body = 40, bold = 40 } -- sizes in fonts/*.font

local function pos(x, y)
	return vmath.vector3(x * S, (M.H - y) * S, 0)
end

---------------------------------------------------------------------------
-- Screen nodes
---------------------------------------------------------------------------

function M.init(self)
	self.nodes, self.buttons, self.holds, self.timers = {}, {}, {}, {}
end

function M.clear(self)
	for _, n in ipairs(self.nodes) do
		gui.delete_node(n)
	end
	self.nodes, self.buttons, self.holds, self.timers = {}, {}, {}, {}
end

local function track(self, n)
	self.nodes[#self.nodes + 1] = n
	return n
end

-- Rounded rectangle, top-left at (x, y).
-- opts: color, radius (storyboard px: 4 8 12 14 16 18 24 28), outline (draw only the border)
function M.rect(self, x, y, w, h, opts)
	opts = opts or {}
	local n = gui.new_box_node(pos(x + w / 2, y + h / 2), vmath.vector3(w * S, h * S, 0))
	gui.set_color(n, opts.color or M.SURFACE)
	local r = opts.radius or 0
	if r > 0 then
		local tr = r * S -- texture corner radius in GUI units
		gui.set_texture(n, "ui")
		gui.play_flipbook(n, (opts.outline and "outline" or "round") .. tr)
		gui.set_slice9(n, vmath.vector4(tr + 1, tr + 1, tr + 1, tr + 1))
	end
	return track(self, n)
end

-- Filled circle (or ring) centered at (cx, cy)
function M.circle(self, cx, cy, d, color, ring)
	local n = gui.new_box_node(pos(cx, cy), vmath.vector3(d * S, d * S, 0))
	gui.set_color(n, color)
	gui.set_texture(n, "ui")
	gui.play_flipbook(n, ring and "ring" or "circle")
	return track(self, n)
end

-- Text. x is the left edge / center / right edge depending on `align`;
-- y is the vertical center of the text, or its top edge with opts.top.
-- opts: font ("body" | "bold" | "heading"), size (px), color, align ("left" | "center" | "right"),
--       width (wrap at this many px), top
function M.label(self, str, x, y, opts)
	opts = opts or {}
	local font = opts.font or "body"
	local scale = (opts.size or 15) * S / FONT_BASE[font]
	local n = gui.new_text_node(pos(x, y), str)
	gui.set_font(n, font)
	gui.set_scale(n, vmath.vector3(scale, scale, 1))
	gui.set_color(n, opts.color or M.TEXT)

	local align = opts.align or "left"
	local pivots = opts.top
		and { left = gui.PIVOT_NW, center = gui.PIVOT_N, right = gui.PIVOT_NE }
		or { left = gui.PIVOT_W, center = gui.PIVOT_CENTER, right = gui.PIVOT_E }
	gui.set_pivot(n, pivots[align])

	if opts.width then
		gui.set_line_break(n, true)
		gui.set_size(n, vmath.vector3(opts.width * S / scale, 0, 0))
	end
	return track(self, n)
end

-- Width in GUI units of a text node's text, including its scale
local function node_text_width(n)
	local metrics = resource.get_text_metrics(gui.get_font_resource(gui.get_font(n)), gui.get_text(n))
	return metrics.width * gui.get_scale(n).x
end

-- Width of a text node in storyboard px
function M.text_width(n)
	return node_text_width(n) / S
end

-- Button, top-left at (x, y). opts:
--   style: "primary" (amber), "secondary" (outlined), "danger", "tile" (surface card)
--   enabled (default true), size, font, text_color
function M.button(self, label, x, y, w, h, on_click, opts)
	opts = opts or {}
	local enabled = opts.enabled ~= false
	local style = opts.style or "primary"
	local fill, ink, radius = M.ACCENT, M.ON_ACCENT, 16
	if style == "secondary" then
		fill, ink = M.LINE_STRONG, M.TEXT
	elseif style == "danger" then
		fill, ink = M.DANGER, M.ON_DANGER
	elseif style == "tile" then
		fill, ink, radius = M.SURFACE, M.TEXT, 14
	end
	if not enabled then
		fill, ink = M.LINE, M.MUTED
	end

	local box = M.rect(self, x, y, w, h, { color = fill, radius = radius, outline = style == "secondary" and enabled })
	if label and label ~= "" then
		M.label(self, label, x + w / 2, y + h / 2, {
			font = opts.font or "bold", size = opts.size or 18, align = "center", color = opts.text_color or ink,
		})
	end
	if enabled and on_click then
		self.buttons[#self.buttons + 1] = { node = box, on_click = on_click }
	end
	return box
end

-- Small text-only button (e.g. "Leave" in the top bar), right-aligned at x
function M.link(self, label, x, y, on_click)
	local n = M.label(self, label, x, y, { font = "bold", size = 14, color = M.DIM, align = "right" })
	-- A generous invisible hit area: text alone is too small to tap reliably
	local w = M.text_width(n) + 24
	local hit = gui.new_box_node(pos(x - w / 2 + 12, y), vmath.vector3(w * S, 44 * S, 0))
	gui.set_color(hit, vmath.vector4(0, 0, 0, 0))
	track(self, hit)
	self.buttons[#self.buttons + 1] = { node = hit, on_click = on_click }
end

-- Colored circle with the player's initial
function M.avatar(self, cx, cy, d, color_index, name)
	local c = M.player_color(color_index)
	M.circle(self, cx, cy, d, c.fill)
	local initial = (name or "?"):match("^[%z\1-\127\194-\244][\128-\191]*") or "?"
	M.label(self, initial:upper(), cx, cy, { font = "bold", size = d * 0.45, color = c.ink, align = "center" })
end

-- Progress bar, fraction 0..1
function M.bar(self, x, y, w, fraction, color, h)
	h = h or 8
	local r = h >= 16 and 8 or 4
	M.rect(self, x, y, w, h, { color = M.LINE, radius = r })
	local fw = math.max(0, math.min(1, fraction)) * w
	if fw >= h then
		M.rect(self, x, y, fw, h, { color = color or M.ACCENT, radius = r })
	end
end

-- Make any node tappable
function M.on_tap(self, node, on_click)
	self.buttons[#self.buttons + 1] = { node = node, on_click = on_click }
end

-- Press-and-hold area: on_change(true) on press, on_change(false) on release.
-- Callbacks should only change state and re-render, never touch nodes directly
-- (the screen may have been rebuilt while the finger was down).
function M.hold_area(self, node, on_change)
	self.holds[#self.holds + 1] = { node = node, on_change = on_change }
end

---------------------------------------------------------------------------
-- Timers
---------------------------------------------------------------------------

local function format_time(seconds)
	seconds = math.max(0, math.ceil(seconds))
	return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

-- Countdown text; ui.update() keeps it ticking. Same args as ui.label.
function M.countdown(self, ends_in, x, y, opts)
	local n = M.label(self, format_time(ends_in or 0), x, y, opts)
	self.timers[#self.timers + 1] = { node = n, ends_at = socket.gettime() + (ends_in or 0) }
	return n
end

-- Circular countdown ring centered at (cx, cy): drains from full as time runs out
function M.ring(self, cx, cy, d, thickness, ends_in, total, color)
	local function pie(fill_color)
		local n = gui.new_pie_node(pos(cx, cy), vmath.vector3(d * S, d * S, 0))
		gui.set_inner_radius(n, (d / 2 - thickness) * S)
		gui.set_perimeter_vertices(n, 96)
		gui.set_color(n, fill_color)
		return track(self, n)
	end
	pie(M.LINE)
	local progress = pie(color or M.ACCENT)
	-- Start at 12 o'clock instead of 3 o'clock
	if gui.set_euler then
		gui.set_euler(progress, vmath.vector3(0, 0, 90))
	else
		gui.set_rotation(progress, vmath.vector3(0, 0, 90))
	end
	self.timers[#self.timers + 1] = { pie = progress, ends_at = socket.gettime() + (ends_in or 0), total = total }
end

function M.update(self)
	local now = socket.gettime()
	for _, t in ipairs(self.timers) do
		local left = t.ends_at - now
		if t.pie then
			gui.set_fill_angle(t.pie, 360 * math.max(0, math.min(1, left / t.total)))
		else
			gui.set_text(t.node, format_time(left))
		end
	end
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

-- Routes a touch action to buttons and hold areas. Returns true if consumed.
function M.on_input(self, action)
	if action.pressed then
		for _, b in ipairs(self.buttons) do
			if gui.pick_node(b.node, action.x, action.y) then
				b.on_click()
				return true
			end
		end
		for _, h in ipairs(self.holds) do
			if gui.pick_node(h.node, action.x, action.y) then
				self.active_hold = h
				h.on_change(true)
				return true
			end
		end
	elseif action.released and self.active_hold then
		local h = self.active_hold
		self.active_hold = nil
		h.on_change(false)
		return true
	end
	return false
end

---------------------------------------------------------------------------
-- Overlays: toasts and the connection banner. They live outside self.nodes so
-- they survive screen redraws.
---------------------------------------------------------------------------

local TOAST_Y = 690 -- newest toast (center, px from top); older ones move up
local TOAST_SPACING = 46
local TOAST_LIFETIME = 3.0

local function overlay_text(str, size, color)
	local n = gui.new_text_node(vmath.vector3(0, 0, 0), str)
	gui.set_font(n, "bold")
	local scale = size * S / FONT_BASE.bold
	gui.set_scale(n, vmath.vector3(scale, scale, 1))
	gui.set_color(n, color)
	return n
end

function M.init_overlays(self)
	self.toasts = {}
	self.banner = gui.new_box_node(pos(M.W / 2, 22), vmath.vector3(M.W * S, 44 * S, 0))
	gui.set_color(self.banner, M.ACCENT)
	local label = overlay_text("Connection unstable - waiting for host...", 14, M.ON_ACCENT)
	gui.set_parent(label, self.banner)
	gui.set_enabled(self.banner, false)
end

function M.set_banner(self, visible)
	gui.set_enabled(self.banner, visible)
end

-- Nodes created later draw on top, so move overlays up again after a redraw.
function M.raise_overlays(self)
	for _, t in ipairs(self.toasts) do
		gui.move_above(t.node, nil)
	end
	gui.move_above(self.banner, nil)
end

function M.toast(self, message, color)
	for _, t in ipairs(self.toasts) do
		t.y = t.y - TOAST_SPACING
		gui.animate(t.node, "position.y", (M.H - t.y) * S, gui.EASING_OUTQUAD, 0.15)
	end

	local label = overlay_text(message, 14, color or M.TEXT)
	local w = node_text_width(label) + 48 * S
	local bg = gui.new_box_node(pos(M.W / 2, TOAST_Y), vmath.vector3(w, 36 * S, 0))
	gui.set_color(bg, M.SURFACE)
	gui.set_texture(bg, "ui")
	gui.play_flipbook(bg, "round36")
	gui.set_slice9(bg, vmath.vector4(37, 37, 37, 37))
	gui.set_parent(label, bg)
	gui.set_inherit_alpha(label, true)

	local entry = { node = bg, y = TOAST_Y }
	self.toasts[#self.toasts + 1] = entry
	gui.animate(bg, "color.w", 0, gui.EASING_INQUAD, 0.5, TOAST_LIFETIME, function()
		gui.delete_node(bg)
		for i, t in ipairs(self.toasts) do
			if t == entry then
				table.remove(self.toasts, i)
				break
			end
		end
	end)
end

return M
