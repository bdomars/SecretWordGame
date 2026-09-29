-- Secret Word screens, laid out after the storyboard (390x844 px, see ui/ui.lua).
-- Each renders one "view" from the host (see secret_word.lua) and sends player input
-- back with net.act(). Clients hold no game state beyond the latest view, plus a
-- little local UI state (peeking at the card, the vote being picked, scores toggle).

local ui = require "ui.ui"
local net = require "net.lobby_net"

local M = {}

local PAD, CW = ui.PAD, ui.CONTENT_W
local CX = ui.W / 2
local BOTTOM_Y, BUTTON_H = 756, 56 -- the primary button sits at the bottom of every screen

local PHASE_LABELS = {
	card = "YOUR CARD", clues = "CLUES", discuss = "DISCUSS", vote = "VOTE",
	guess = "CAUGHT", result = "RESULT",
}

local function find(v, id)
	for _, p in ipairs(v.players) do
		if p.id == id then
			return p
		end
	end
	return { id = id, name = "?", color = 0, score = 0 }
end

local function name(v, id)
	return find(v, id).name
end

local function top_bar(self, v, color)
	local label = v.phase == "final" and "GAME OVER"
		or ("ROUND %d OF %d · %s"):format(v.round, v.rounds, PHASE_LABELS[v.phase])
	ui.label(self, label, PAD, 64, { font = "bold", size = 13, color = color or ui.ACCENT })
	ui.link(self, "Leave", ui.W - PAD, 64, self.leave)
end

local function waiting(self, text)
	ui.label(self, text or "Waiting for the others…", CX, BOTTOM_Y + BUTTON_H / 2, { size = 15, color = ui.DIM, align = "center" })
end

local function row_with_count(self, y, left, right)
	ui.label(self, left, PAD, y, { size = 14, color = ui.DIM })
	ui.label(self, right, ui.W - PAD, y, { size = 14, color = ui.DIM, align = "right" })
end

-- Holding `node` shows your card (sets self.peeking and re-renders)
local function peekable(self, node)
	ui.hold_area(self, node, function(on)
		self.peeking = on
		M.render(self, self.view)
	end)
end

-- Your card's content inside a colored block (used when peeking mid-round)
local function card_contents(self, v, top, h)
	local fill = v.impostor and ui.DANGER or ui.ACCENT
	local ink = v.impostor and ui.ON_DANGER or ui.ON_ACCENT
	local node = ui.rect(self, PAD, top, CW, h, { color = fill, radius = 24 })
	local mid = top + h / 2
	ui.label(self, "CATEGORY · " .. v.category:upper(), CX, mid - 36, { font = "bold", size = 14, color = ink, align = "center" })
	if v.impostor then
		ui.label(self, "You're the impostor", CX, mid + 14, { font = "heading", size = 30, color = ink, align = "center" })
	else
		ui.label(self, v.word, CX, mid + 14, { font = "heading", size = 44, color = ink, align = "center", max_width = CW - 40 })
	end
	return node
end

---------------------------------------------------------------------------
-- Phases
---------------------------------------------------------------------------

local render = {}

function render.card(self, v)
	top_bar(self, v)
	local reveal = self.peeking
	local title = not reveal and "Shield your screen" or (v.impostor and "Keep a straight face" or "You know the word")
	ui.label(self, title, PAD, 108, { font = "heading", size = 32 })

	local top, h = 144, 460
	local mid = top + h / 2
	local card
	if reveal then
		self.seen_round = v.round
		local fill = v.impostor and ui.DANGER or ui.ACCENT
		local ink = v.impostor and ui.ON_DANGER or ui.ON_ACCENT
		card = ui.rect(self, PAD, top, CW, h, { color = fill, radius = 28 })
		ui.label(self, "CATEGORY · " .. v.category:upper(), CX, mid - 100, { font = "bold", size = 14, color = ink, align = "center" })
		if v.impostor then
			local heading = ui.label(self, "You're the impostor", CX, mid - 70, { font = "heading", size = 44, color = ink, align = "center", width = 290, top = true })
			ui.label(self, "You don't know the word. Listen to the clues and blend in.", CX, mid - 70 + ui.text_height(heading) + 16,
				{ size = 15, color = ink, align = "center", width = 250, top = true })
		else
			ui.label(self, v.word, CX, mid - 20, { font = "heading", size = 60, color = ink, align = "center", max_width = CW - 40 })
			ui.label(self, "Give clues that prove you know it, without handing it to the impostor.", CX, mid + 40, { size = 15, color = ink, align = "center", width = 250, top = true })
		end
	else
		card = ui.rect(self, PAD, top, CW, h, { color = ui.SURFACE, radius = 28 })
		ui.rect(self, PAD, top, CW, h, { color = ui.LINE, radius = 28, outline = true })
		ui.circle(self, CX, mid - 50, 120, ui.ACCENT, true)
		ui.circle(self, CX, mid - 50, 36, ui.ACCENT)
		ui.label(self, "Hold to reveal", CX, mid + 40, { font = "bold", size = 22, align = "center" })
		ui.label(self, "Let go and the card hides again.", CX, mid + 72, { size = 15, color = ui.DIM, align = "center" })
	end
	peekable(self, card)

	row_with_count(self, 640, "Players ready", ("%d of %d"):format(v.ready_count, v.total))
	ui.bar(self, PAD, 660, CW, v.ready_count / v.total, ui.GOOD)

	if v.ready then
		waiting(self)
	else
		-- Only after you've actually looked at the card
		ui.button(self, "I've seen my card", PAD, BOTTOM_Y, CW, BUTTON_H, function() net.act({ a = "seen" }) end,
			{ style = "secondary", enabled = self.seen_round == v.round })
	end
end

function render.clues(self, v)
	top_bar(self, v)
	local me = net.my_id()
	local speaker = v.order[v.current]
	local my_turn = speaker == me

	local card
	if self.peeking then
		card = card_contents(self, v, 96, 176)
	else
		local ink = my_turn and ui.ON_ACCENT or ui.TEXT
		card = ui.rect(self, PAD, 96, CW, 176, { color = my_turn and ui.ACCENT or ui.SURFACE, radius = 24 })
		ui.label(self, my_turn and "YOUR TURN" or (name(v, speaker):upper() .. " IS UP"), CX, 124, { font = "bold", size = 14, color = ink, align = "center" })
		ui.countdown(self, v.ends_in, CX, 184, { font = "heading", size = 64, color = ink, align = "center" })
		ui.label(self, my_turn and "Say one word out loud" or "Listen closely", CX, 244, { size = 16, color = my_turn and ink or ui.DIM, align = "center" })
	end
	peekable(self, card)
	ui.label(self, "Hold the card to peek at your word", CX, 290, { size = 12, color = ui.MUTED, align = "center" })

	ui.label(self, "Speaking order", PAD, 322, { font = "bold", size = 15 })
	for i, id in ipairs(v.order) do
		local y = 340 + (i - 1) * 46
		local p = find(v, id)
		local now, done = i == v.current, i < v.current
		if now then
			ui.rect(self, PAD, y, CW, 40, { color = ui.SURFACE_SELECTED, radius = 12 })
			ui.rect(self, PAD, y, CW, 40, { color = ui.ACCENT, radius = 12, outline = true })
			ui.circle(self, PAD + 20, y + 20, 10, ui.ACCENT)
		else
			ui.rect(self, PAD, y, CW, 40, { color = ui.SURFACE, radius = 12 })
			if done then
				ui.circle(self, PAD + 20, y + 20, 10, ui.GOOD)
			end
		end
		local label = p.name .. (id == me and " (you)" or "")
		local faded = done or not p.connected
		ui.label(self, label, PAD + 40, y + 20, { font = now and "bold" or "body", size = 15, color = faded and ui.DIM or ui.TEXT })
		local status = not p.connected and "left" or (now and "now" or (done and "done" or ""))
		ui.label(self, status, ui.W - PAD - 14, y + 20, { size = 13, color = now and ui.ACCENT or ui.DIM, align = "right" })
	end

	if my_turn then
		ui.button(self, "Done, next player", PAD, BOTTOM_Y, CW, BUTTON_H, function()
			net.act({ a = "done", turn = v.current })
		end)
	end
end

function render.discuss(self, v)
	top_bar(self, v)
	local ring_y = 290
	if self.peeking then
		card_contents(self, v, ring_y - 90, 180)
	else
		ui.ring(self, CX, ring_y, 250, 10, v.ends_in, v.total_time or v.ends_in or 1)
		ui.countdown(self, v.ends_in, CX, ring_y, { font = "heading", size = 72, align = "center" })
	end
	local hit = ui.rect(self, CX - 125, ring_y - 125, 250, 250, { color = vmath.vector4(0, 0, 0, 0) })
	peekable(self, hit)
	ui.label(self, "Hold the timer to peek at your word", CX, ring_y + 145, { size = 12, color = ui.MUTED, align = "center" })

	ui.label(self, "Phones down.\nWho's faking it?", CX, 470, { font = "heading", size = 36, align = "center", width = CW, top = true })
	ui.label(self, "Argue it out in the room. Voting opens when the timer ends.", CX, 568, { size = 16, color = ui.DIM, align = "center", width = 280, top = true })

	ui.label(self, ("%d of %d ready to vote early"):format(v.ready_count, v.total), CX, 722, { size = 14, color = ui.DIM, align = "center" })
	if v.ready then
		waiting(self)
	else
		ui.button(self, "I'm ready to vote", PAD, BOTTOM_Y, CW, BUTTON_H, function() net.act({ a = "ready" }) end, { style = "secondary" })
	end
end

function render.vote(self, v)
	top_bar(self, v)
	local me = net.my_id()
	ui.label(self, "Who's the impostor?", PAD, 106, { font = "heading", size = 34 })
	ui.label(self, "Votes stay secret until everyone's in.", PAD, 142, { size = 15, color = ui.DIM })
	ui.countdown(self, v.ends_in, ui.W - PAD, 142, { font = "bold", size = 15, color = ui.ACCENT, align = "right" })

	if v.my_vote then
		local p = find(v, v.my_vote)
		ui.rect(self, PAD, 180, CW, 300, { color = ui.SURFACE, radius = 24 })
		ui.label(self, "You voted for", CX, 228, { size = 15, color = ui.DIM, align = "center" })
		ui.avatar(self, CX, 300, 80, p.color, p.name)
		ui.label(self, p.name, CX, 376, { font = "heading", size = 30, align = "center", max_width = CW - 40 })
		ui.label(self, "Waiting for the others…", CX, 424, { size = 15, color = ui.DIM, align = "center" })
	else
		local tile_w, tile_h, gap = (CW - 12) / 2, 104, 12
		local i = 0
		for _, p in ipairs(v.players) do
			if p.id ~= me and p.connected then
				local x = PAD + (i % 2) * (tile_w + gap)
				local y = 176 + math.floor(i / 2) * (tile_h + gap)
				local picked = self.vote_pick == p.id
				local tile = ui.rect(self, x, y, tile_w, tile_h, { color = picked and ui.SURFACE_SELECTED or ui.SURFACE, radius = 18 })
				ui.rect(self, x, y, tile_w, tile_h, { color = picked and ui.ACCENT or ui.LINE, radius = 18, outline = true })
				ui.avatar(self, x + tile_w / 2, y + 40, 40, p.color, p.name)
				ui.label(self, p.name, x + tile_w / 2, y + 80, { font = "bold", size = 16, align = "center", max_width = tile_w - 16 })
				ui.on_tap(self, tile, function()
					self.vote_pick = p.id
					M.render(self, self.view)
				end)
				i = i + 1
			end
		end
	end

	row_with_count(self, 670, "Votes in", ("%d of %d"):format(v.votes_in, v.total))
	ui.bar(self, PAD, 690, CW, v.votes_in / v.total)

	if not v.my_vote then
		if self.vote_pick then
			ui.button(self, "Lock in vote for " .. name(v, self.vote_pick), PAD, BOTTOM_Y, CW, BUTTON_H, function()
				net.act({ a = "vote", target = self.vote_pick })
			end)
		else
			ui.button(self, "Pick a player", PAD, BOTTOM_Y, CW, BUTTON_H, nil, { enabled = false })
		end
	end
end

-- Horizontal vote bars (name | bar with count), rows from `top`
local function vote_bars(self, v, rows, top, row_gap, show_from)
	local max = 1
	for _, r in ipairs(rows) do
		max = math.max(max, r.count)
	end
	local y = top
	for _, r in ipairs(rows) do
		local is_imp = r.id == v.impostor_id
		ui.label(self, name(v, r.id), PAD, y + 13, { font = "bold", size = 15, max_width = 70 })
		local w = math.max(44, 200 * r.count / max)
		local fill = is_imp and ui.DANGER or (r.id == v.accused and ui.MUTED or ui.LINE_STRONG)
		ui.rect(self, PAD + 76, y, w, 26, { color = fill, radius = 8 })
		ui.label(self, tostring(r.count), PAD + 86, y + 13, { font = "bold", size = 14, color = is_imp and ui.ON_DANGER or ui.TEXT })
		if is_imp and v.phase == "result" then
			ui.label(self, "impostor", PAD + 84 + w, y + 13, { size = 12, color = ui.DANGER })
		end
		if show_from and r.from then
			ui.label(self, "from " .. r.from, PAD + 76, y + 40, { size = 13, color = ui.DIM })
			y = y + 52
		else
			y = y + row_gap
		end
	end
	return y
end

function render.guess(self, v)
	top_bar(self, v, ui.DANGER)
	local me = net.my_id()
	local rows = {}
	for i, t in ipairs(v.tally) do
		if i <= 4 then
			rows[#rows + 1] = { id = t.id, count = t.count }
		end
	end
	vote_bars(self, v, rows, 92, 34)

	if me == v.impostor_id then
		local card_top = 248
		local card = ui.rect(self, PAD, card_top, CW, 130, { color = ui.SURFACE, radius = 24 })
		local outline = ui.rect(self, PAD, card_top, CW, 130, { color = ui.DANGER, radius = 24, outline = true })
		local heading = ui.label(self, "They got you.\nPick the word to steal it.", PAD + 20, card_top + 18, { font = "heading", size = 26, width = 300, top = true })
		local info_y = card_top + 18 + ui.text_height(heading) + 16
		ui.label(self, "CATEGORY · " .. v.category:upper(), PAD + 20, info_y, { font = "bold", size = 13, color = ui.DIM })
		ui.countdown(self, v.ends_in, ui.W - PAD - 20, info_y, { font = "bold", size = 15, color = ui.ACCENT, align = "right" })
		local card_h = info_y + 22 - card_top
		ui.set_rect(card, PAD, card_top, CW, card_h)
		ui.set_rect(outline, PAD, card_top, CW, card_h)
		local choices_top = card_top + card_h + 22

		local tile_w = (CW - 12) / 2
		for i, word in ipairs(v.choices or {}) do
			local x = PAD + ((i - 1) % 2) * (tile_w + 12)
			local y = choices_top + math.floor((i - 1) / 2) * 68
			ui.button(self, word, x, y, tile_w, 56, function() net.act({ a = "guess", word = word }) end,
				{ style = "tile", size = 16 })
		end
	else
		local imp = find(v, v.impostor_id)
		ui.avatar(self, CX, 360, 88, imp.color, imp.name)
		local heading = ui.label(self, imp.name .. " was caught", CX, 440, { font = "heading", size = 30, align = "center", width = CW, top = true })
		ui.label(self, "Waiting for their last guess at the word…", CX, 440 + ui.text_height(heading) + 12,
			{ size = 15, color = ui.DIM, align = "center", width = 300, top = true })
		ui.countdown(self, v.ends_in, CX, 570, { font = "heading", size = 48, color = ui.ACCENT, align = "center" })
	end
end

-- overline, title, detail, players_won (true/false, nil when cancelled)
local function outcome_text(v)
	local imp, word = name(v, v.impostor_id), v.word
	if v.outcome == "caught" then
		local detail = v.guess and ("%s was the impostor and guessed “%s”."):format(imp, v.guess)
			or ("%s was the impostor and didn't guess in time."):format(imp)
		return "PLAYERS WIN", "The word was " .. word, detail, true
	elseif v.outcome == "guessed" then
		return "IMPOSTOR STEALS IT", imp .. " guessed it", ("%s was caught but named the word: %s."):format(imp, word), false
	elseif v.outcome == "framed" then
		return "IMPOSTOR ESCAPES · WRONG PERSON", name(v, v.accused) .. " was innocent",
			("%s was the impostor all along. The word was %s."):format(imp, word), false
	elseif v.outcome == "tie" then
		return "IMPOSTOR ESCAPES · TIED VOTE", imp .. " slipped away", ("The vote was tied. The word was %s."):format(word), false
	end
	return "ROUND CANCELLED", "The impostor left", ("%s left the game. The word was %s."):format(imp, word), nil
end

local function standings(v)
	local list = {}
	for _, p in ipairs(v.players) do
		list[#list + 1] = p
	end
	table.sort(list, function(a, b) return a.score > b.score or (a.score == b.score and a.id < b.id) end)
	return list
end

-- Score rows: rank, avatar, name, this round's points (optional), total
local function score_rows(self, v, top, points, highlight_top)
	local list = standings(v)
	for i, p in ipairs(list) do
		local y = top + (i - 1) * 52
		local winner = highlight_top and p.score == list[1].score
		ui.rect(self, PAD, y, CW, 44, { color = ui.SURFACE, radius = 12 })
		if winner then
			ui.rect(self, PAD, y, CW, 44, { color = ui.ACCENT, radius = 12, outline = true })
		end
		ui.label(self, tostring(i), PAD + 16, y + 22, { size = 14, color = ui.DIM })
		ui.avatar(self, PAD + 50, y + 22, 28, p.color, p.name)
		ui.label(self, p.name, PAD + 74, y + 22, { font = "bold", size = 15, color = p.connected and ui.TEXT or ui.DIM, max_width = CW - 160 })
		if points then
			local gained = points[p.id]
			ui.label(self, gained and ("+" .. gained) or "+0", ui.W - PAD - 56, y + 22, { size = 14, color = gained and ui.GOOD or ui.DIM, align = "right" })
		end
		ui.label(self, tostring(p.score), ui.W - PAD - 14, y + 22, { font = "bold", size = 17, align = "right" })
	end
end

function render.result(self, v)
	local overline, title, detail, players_won = outcome_text(v)
	local fill = players_won == true and ui.ACCENT or (players_won == false and ui.DANGER or ui.SURFACE)
	local ink = players_won == true and ui.ON_ACCENT or (players_won == false and ui.ON_DANGER or ui.TEXT)
	top_bar(self, v, players_won == false and ui.DANGER or ui.ACCENT)

	-- The banner grows with its text: a long word can wrap the title onto two lines
	local banner_top = 92
	local banner = ui.rect(self, PAD, banner_top, CW, 156, { color = fill, radius = 24 })
	ui.label(self, overline, PAD + 22, banner_top + 26, { font = "bold", size = 13, color = ink })
	local title_top = banner_top + 42
	local title_node = ui.label(self, title, PAD + 22, title_top, { font = "heading", size = 28, color = ink, width = CW - 44, top = true })
	local detail_top = title_top + ui.text_height(title_node) + 8
	local detail_node = ui.label(self, detail, PAD + 22, detail_top, { size = 15, color = ink, width = CW - 44, top = true })
	local banner_bottom = detail_top + ui.text_height(detail_node) + 22
	ui.set_rect(banner, PAD, banner_top, CW, banner_bottom - banner_top)

	local section_y = banner_bottom + 34 -- the section heading below the banner
	local points = {}
	for _, d in ipairs(v.deltas) do
		points[d.id] = d.points
	end

	if self.show_scores then
		ui.label(self, "Scores", PAD, section_y, { font = "bold", size = 15 })
		ui.label(self, "this round  ·  total", ui.W - PAD, section_y, { size = 13, color = ui.DIM, align = "right" })
		score_rows(self, v, section_y + 18, points)
	else
		ui.label(self, "How you voted", PAD, section_y, { font = "bold", size = 15 })
		-- Group votes by who they were for
		local groups, by_target = {}, {}
		for _, vote in ipairs(v.votes) do
			local g = by_target[vote.target]
			if not g then
				g = { id = vote.target, count = 0, voters = {} }
				by_target[vote.target] = g
				groups[#groups + 1] = g
			end
			g.count = g.count + 1
			g.voters[#g.voters + 1] = name(v, vote.voter)
		end
		table.sort(groups, function(a, b) return a.count > b.count end)
		for _, g in ipairs(groups) do
			g.from = table.concat(g.voters, ", ")
		end
		local y
		if #groups == 0 then
			ui.label(self, "Nobody voted.", PAD, section_y + 32, { size = 14, color = ui.DIM })
			y = section_y + 58
		else
			y = vote_bars(self, v, groups, section_y + 20, 34, true)
		end

		-- Who scored this round
		local parts = {}
		for _, p in ipairs(standings(v)) do
			if points[p.id] then
				parts[#parts + 1] = ("%s +%d"):format(p.name, points[p.id])
			end
		end
		local summary = #parts > 0 and ("Points: " .. table.concat(parts, " · ")) or "No points this round."
		ui.label(self, summary, PAD, y + 4, { size = 13, color = ui.DIM, width = CW, top = true })
	end

	local toggle_label = self.show_scores and "Votes" or "Scores"
	local function toggle()
		self.show_scores = not self.show_scores
		M.render(self, self.view)
	end
	if net.is_host() then
		ui.button(self, toggle_label, PAD, BOTTOM_Y, 110, BUTTON_H, toggle, { style = "secondary", size = 16 })
		ui.button(self, v.last_round and "Final scores" or "Next round", PAD + 120, BOTTOM_Y, CW - 120, BUTTON_H,
			function() net.act({ a = "next" }) end)
	else
		ui.label(self, "Waiting for the host to continue…", CX, BOTTOM_Y - 20, { size = 13, color = ui.DIM, align = "center" })
		ui.button(self, toggle_label, PAD, BOTTOM_Y, CW, BUTTON_H, toggle, { style = "secondary" })
	end
end

function render.final(self, v)
	top_bar(self, v)
	local list = standings(v)
	local winners = {}
	for _, p in ipairs(list) do
		if p.score == list[1].score then
			winners[#winners + 1] = p.name
		end
	end
	local title = table.concat(winners, " & ") .. (#winners == 1 and " wins!" or " win!")
	-- A shared win ("Christopher & Anna win!") can take two lines; the rest follows the title
	local title_node = ui.label(self, title, PAD, 90, { font = "heading", size = 40, width = CW, top = true })
	local subtitle_y = 90 + ui.text_height(title_node) + 16
	ui.label(self, v.reason or ("After %d rounds"):format(v.round), PAD, subtitle_y, { size = 15, color = ui.DIM })
	score_rows(self, v, subtitle_y + 28, nil, true)

	if net.is_host() then
		ui.button(self, "Back to lobby", PAD, BOTTOM_Y, CW, BUTTON_H, function() net.end_game() end)
	else
		waiting(self, "Waiting for the host…")
	end
end

---------------------------------------------------------------------------

-- Render the latest view. Local UI state resets whenever the phase changes.
function M.render(self, v)
	local key = v.phase .. ":" .. v.round .. ":" .. tostring(v.current)
	if key ~= self.view_key then
		self.view_key = key
		self.vote_pick = nil
		self.peeking = false
		self.show_scores = false
		self.active_hold = nil
	end
	self.view = v
	self.screen = "game"
	ui.clear(self)
	render[v.phase](self, v)
end

return M
