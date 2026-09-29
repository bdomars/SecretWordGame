-- Categories and secret words. Add categories freely; each needs at least
-- `guess_choices` words (see secret_word.lua) so the last guess has enough options.

local M = {}

M.CATEGORIES = {
	{ name = "Animals", words = {
		"Penguin", "Giraffe", "Octopus", "Kangaroo", "Owl", "Crocodile", "Hedgehog", "Dolphin",
		"Elephant", "Squirrel", "Flamingo", "Wolf", "Tortoise", "Bat", "Seal",
	} },
	{ name = "Food", words = {
		"Pizza", "Sushi", "Pancake", "Taco", "Popcorn", "Lasagna", "Croissant", "Burrito",
		"Porridge", "Ice cream", "Salmon", "Curry", "Waffle", "Dumpling", "Omelette",
	} },
	{ name = "Places", words = {
		"Lighthouse", "Airport", "Library", "Hospital", "Sauna", "Beach", "Castle", "Cinema",
		"Museum", "Prison", "Zoo", "Church", "Gym", "Farm", "Submarine",
	} },
	{ name = "Jobs", words = {
		"Firefighter", "Dentist", "Pilot", "Chef", "Plumber", "Astronaut", "Teacher", "Farmer",
		"Lawyer", "Magician", "Barber", "Detective", "Lifeguard", "Nurse", "Architect",
	} },
	{ name = "Things at home", words = {
		"Toaster", "Umbrella", "Pillow", "Mirror", "Candle", "Vacuum cleaner", "Remote control",
		"Toothbrush", "Fridge", "Doormat", "Alarm clock", "Bathtub", "Curtain", "Kettle", "Ladder",
	} },
	{ name = "Sports", words = {
		"Ice hockey", "Tennis", "Golf", "Surfing", "Boxing", "Skiing", "Fencing", "Bowling",
		"Archery", "Rowing", "Karate", "Volleyball", "Darts", "Climbing", "Curling",
	} },
}

local function shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end
M.shuffle = shuffle

-- Random category and a word not in `used` (a set of words already played).
function M.pick(used)
	local cat = M.CATEGORIES[math.random(#M.CATEGORIES)]
	local fresh = {}
	for _, w in ipairs(cat.words) do
		if not used[w] then
			fresh[#fresh + 1] = w
		end
	end
	if #fresh == 0 then
		fresh = cat.words
	end
	return cat.name, fresh[math.random(#fresh)]
end

-- `n` options for the impostor's last guess: the secret word plus others from its category.
function M.choices(category, word, n)
	local others = {}
	for _, cat in ipairs(M.CATEGORIES) do
		if cat.name == category then
			for _, w in ipairs(cat.words) do
				if w ~= word then
					others[#others + 1] = w
				end
			end
		end
	end
	shuffle(others)
	local list = { word }
	for i = 1, math.min(n - 1, #others) do
		list[#list + 1] = others[i]
	end
	return shuffle(list)
end

return M
