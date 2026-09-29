-- Secret Word: host-side game rules. Runs only on the host; knows nothing about
-- networking or UI. Players send actions (on_action), and after every change the game
-- sends each player a "view": a snapshot of only what that player is allowed to see.
--
-- Phases: card -> clues -> discuss -> vote -> [guess] -> result -> (next round | final)

local words = require "game.words"

local M = {}

local HOST_ID = 1

M.MIN_PLAYERS = 3

M.SETTINGS = {
	rounds = 3,
	clue_time = 30,     -- seconds per clue
	discuss_time = 120,
	vote_time = 60,     -- missing votes at timeout count as abstentions
	guess_time = 20,    -- the caught impostor's last guess
	guess_choices = 8,  -- words to pick from when guessing
}

M.SCORING = {
	correct_vote = 1,     -- every player who voted for the impostor, whatever the outcome
	impostor_tie = 2,     -- tied vote, impostor escapes
	impostor_framed = 3,  -- an innocent player got the most votes
	impostor_guessed = 2, -- caught, but guessed the word
}

local Game = {}
Game.__index = Game

-- players: lobby list { id, name, color }; send(player_id, view)
function M.new(players, send, settings)
	local g = setmetatable({}, Game)
	g.settings = settings or M.SETTINGS
	g.send = send
	g.players = {}
	for _, p in ipairs(players) do
		g.players[#g.players + 1] = { id = p.id, name = p.name, color = p.color, score = 0, connected = true }
	end
	g.round = 0
	g.used = {}
	g:start_round()
	return g
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function Game:player(id)
	for _, p in ipairs(self.players) do
		if p.id == id then
			return p
		end
	end
end

function Game:is_active(id)
	local p = self:player(id)
	return p ~= nil and p.connected
end

function Game:active()
	local list = {}
	for _, p in ipairs(self.players) do
		if p.connected then
			list[#list + 1] = p
		end
	end
	return list
end

-- set: player id -> anything
function Game:count_in(set)
	local n = 0
	for _, p in ipairs(self:active()) do
		if set[p.id] then
			n = n + 1
		end
	end
	return n
end

function Game:all_in(set)
	return self:count_in(set) == #self:active()
end

function Game:set_phase(phase, timer)
	self.phase = phase
	self.timer = timer
	self.timer_total = timer
end

-- Votes per player, most first: { { id, count } }
function Game:tally()
	local counts = {}
	for _, target in pairs(self.votes) do
		counts[target] = (counts[target] or 0) + 1
	end
	local list = {}
	for id, n in pairs(counts) do
		list[#list + 1] = { id = id, count = n }
	end
	table.sort(list, function(a, b) return a.count > b.count or (a.count == b.count and a.id < b.id) end)
	return list
end

---------------------------------------------------------------------------
-- Phases
---------------------------------------------------------------------------

function Game:start_round()
	self.round = self.round + 1
	self.category, self.word = words.pick(self.used)
	self.used[self.word] = true
	local active = self:active()
	self.impostor = active[math.random(#active)].id
	self.ready = {}
	self.votes = {}
	self.deltas = {}
	self.guess, self.accused, self.outcome, self.choices = nil, nil, nil, nil
	self:set_phase("card")
	self:publish()
end

function Game:start_clues()
	local order = {}
	for _, p in ipairs(self:active()) do
		order[#order + 1] = p.id
	end
	words.shuffle(order)
	-- The impostor never goes first: they'd have nothing to go on
	if order[1] == self.impostor and #order > 1 then
		local j = math.random(2, #order)
		order[1], order[j] = order[j], order[1]
	end
	self.order = order
	self.current = 0
	self:next_speaker()
end

-- Next connected speaker, or on to the discussion when everyone has spoken.
function Game:next_speaker()
	repeat
		self.current = self.current + 1
	until self.current > #self.order or self:is_active(self.order[self.current])

	if self.current > #self.order then
		self.ready = {}
		self:set_phase("discuss", self.settings.discuss_time)
	else
		self:set_phase("clues", self.settings.clue_time)
	end
	self:publish()
end

function Game:start_vote()
	self.votes = {}
	self:set_phase("vote", self.settings.vote_time)
	self:publish()
end

function Game:resolve_votes()
	local tally = self:tally()
	local top = tally[1]
	local unique = top ~= nil and (tally[2] == nil or tally[2].count < top.count)
	if not unique then
		self:finish("tie") -- includes nobody voting at all
	elseif top.id == self.impostor then
		self.accused = top.id
		self.choices = words.choices(self.category, self.word, self.settings.guess_choices)
		self:set_phase("guess", self.settings.guess_time)
		self:publish()
	else
		self.accused = top.id
		self:finish("framed")
	end
end

-- outcome: "caught" (players win) | "guessed" | "framed" | "tie" | "void" (impostor left)
function Game:finish(outcome)
	local S = M.SCORING
	self.outcome = outcome
	self.deltas = {}
	local function add(id, points)
		self.deltas[id] = (self.deltas[id] or 0) + points
	end

	if outcome ~= "void" then
		for voter, target in pairs(self.votes) do
			if target == self.impostor then
				add(voter, S.correct_vote)
			end
		end
		if outcome == "tie" then
			add(self.impostor, S.impostor_tie)
		elseif outcome == "framed" then
			add(self.impostor, S.impostor_framed)
		elseif outcome == "guessed" then
			add(self.impostor, S.impostor_guessed)
		end
	end

	for id, points in pairs(self.deltas) do
		local p = self:player(id)
		if p then
			p.score = p.score + points
		end
	end
	self:set_phase("result")
	self:publish()
end

function Game:end_game(reason)
	self.reason = reason
	self:set_phase("final")
	self:publish()
end

---------------------------------------------------------------------------
-- Input from the network / host
---------------------------------------------------------------------------

function Game:on_action(from, data)
	if not self:is_active(from) or type(data) ~= "table" then
		return
	end
	local a, phase = data.a, self.phase

	if phase == "card" and a == "seen" then
		self.ready[from] = true
		if self:all_in(self.ready) then self:start_clues() else self:publish() end

	elseif phase == "clues" and a == "done" then
		-- The speaker ends their own turn; the host may skip someone. `turn` stops a
		-- double tap (or speaker + host at once) from skipping two players.
		local speaker = self.order[self.current]
		if data.turn == self.current and (from == speaker or from == HOST_ID) then
			self:next_speaker()
		end

	elseif phase == "discuss" and a == "ready" then
		self.ready[from] = true
		if self:all_in(self.ready) then self:start_vote() else self:publish() end

	elseif phase == "vote" and a == "vote" then
		local target = tonumber(data.target)
		if not self.votes[from] and target ~= from and self:is_active(target) then
			self.votes[from] = target
			if self:all_in(self.votes) then self:resolve_votes() else self:publish() end
		end

	elseif phase == "guess" and a == "guess" and from == self.impostor then
		self.guess = tostring(data.word or "")
		self:finish(self.guess:lower() == self.word:lower() and "guessed" or "caught")

	elseif phase == "result" and a == "next" and from == HOST_ID then
		if self.round >= self.settings.rounds then
			self:end_game()
		else
			self:start_round()
		end
	end
end

function Game:on_player_left(id)
	local p = self:player(id)
	if not p or not p.connected then
		return
	end
	p.connected = false
	local phase = self.phase

	if phase == "final" or phase == "result" then
		return self:publish()
	elseif #self:active() < M.MIN_PLAYERS then
		return self:end_game("Not enough players left")
	elseif id == self.impostor then
		return self:finish("void")
	end

	if phase == "card" and self:all_in(self.ready) then
		return self:start_clues()
	elseif phase == "clues" and self.order[self.current] == id then
		return self:next_speaker()
	elseif phase == "discuss" and self:all_in(self.ready) then
		return self:start_vote()
	elseif phase == "vote" then
		self.votes[id] = nil
		if self:all_in(self.votes) then
			return self:resolve_votes()
		end
	end
	self:publish()
end

function Game:update(dt)
	if not self.timer then
		return
	end
	self.timer = self.timer - dt
	if self.timer > 0 then
		return
	end
	self.timer = nil

	local phase = self.phase
	if phase == "clues" then
		self:next_speaker()
	elseif phase == "discuss" then
		self:start_vote()
	elseif phase == "vote" then
		self:resolve_votes()
	elseif phase == "guess" then
		self:finish("caught") -- no guess in time
	end
end

---------------------------------------------------------------------------
-- Views
---------------------------------------------------------------------------

function Game:view_for(p)
	local me, phase = p.id, self.phase
	local players = {}
	for _, q in ipairs(self.players) do
		players[#players + 1] = { id = q.id, name = q.name, color = q.color, score = q.score, connected = q.connected }
	end
	local v = {
		phase = phase,
		round = self.round,
		rounds = self.settings.rounds,
		category = self.category,
		players = players,
		ends_in = self.timer and math.max(0, self.timer) or nil,
		total_time = self.timer_total,
	}

	-- Your card stays available until the result; the impostor never receives the word
	if phase ~= "result" and phase ~= "final" then
		v.impostor = me == self.impostor
		if not v.impostor then
			v.word = self.word
		end
	end

	if phase == "card" or phase == "discuss" then
		v.ready = self.ready[me] == true
		v.ready_count = self:count_in(self.ready)
		v.total = #self:active()
	elseif phase == "clues" then
		v.order = self.order
		v.current = self.current
	elseif phase == "vote" then
		v.my_vote = self.votes[me]
		v.votes_in = self:count_in(self.votes)
		v.total = #self:active()
	elseif phase == "guess" then
		v.impostor_id = self.impostor
		v.tally = self:tally()
		if me == self.impostor then
			v.choices = self.choices
		end
	elseif phase == "result" then
		v.outcome = self.outcome
		v.impostor_id = self.impostor
		v.word = self.word
		v.accused = self.accused
		v.guess = self.guess
		v.last_round = self.round >= self.settings.rounds
		v.votes = {}
		for voter, target in pairs(self.votes) do
			v.votes[#v.votes + 1] = { voter = voter, target = target }
		end
		table.sort(v.votes, function(a, b) return a.voter < b.voter end)
		v.deltas = {}
		for id, points in pairs(self.deltas) do
			v.deltas[#v.deltas + 1] = { id = id, points = points }
		end
	elseif phase == "final" then
		v.reason = self.reason
	end
	return v
end

function Game:publish()
	for _, p in ipairs(self.players) do
		if p.connected then
			self.send(p.id, self:view_for(p))
		end
	end
end

return M
