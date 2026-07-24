--!strict
--[[
	PartyService
	------------
	Табло отряда: рассылает клиентам состояние союзников (HP/мана/книга).

	Broadcasts a compact roster of every player in the match so each client can
	draw the party frames. Health comes from the Humanoid, mana from
	SpellCastingService (which owns it) and the equipped book from the player's
	profile — the client never computes these itself.

	The roster is pushed on a fixed low-frequency tick rather than every frame:
	party frames only need to feel live, and a wave of 40 enemies is already
	competing for bandwidth. A snapshot is also pushed immediately whenever the
	roster's shape changes (join/leave/respawn) so frames never lag a join.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Remotes = require(Shared.Remotes)
local SpellbookModule = require(Shared.SpellbookModule)

local PlayerDataService = require(script.Parent.PlayerDataService)
local SpellCastingService = require(script.Parent.SpellCastingService)

local PartyService = {}

-- How often the roster is re-sent. 5 Hz is smooth enough for health bars.
local BROADCAST_INTERVAL = 0.2

export type PartyMember = {
	UserId: number,
	Name: string,
	Health: number,
	MaxHealth: number,
	Mana: number,
	MaxMana: number,
	BookId: string,
	Element: string,
	Alive: boolean,
}

local function snapshot(): { PartyMember }
	local members: { PartyMember } = {}

	for _, player in Players:GetPlayers() do
		local profile = PlayerDataService.get(player)
		local bookId = profile and profile.SelectedBook or "Fire"
		local book = SpellbookModule.getBook(bookId)

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local mana, maxMana = SpellCastingService.getMana(player)

		table.insert(members, {
			UserId = player.UserId,
			Name = player.DisplayName ~= "" and player.DisplayName or player.Name,
			Health = humanoid and math.ceil(humanoid.Health) or 0,
			MaxHealth = humanoid and humanoid.MaxHealth or 100,
			Mana = math.floor(mana),
			MaxMana = maxMana,
			BookId = bookId,
			Element = book and book.Element or "Fire",
			Alive = humanoid ~= nil and humanoid.Health > 0,
		})
	end

	-- Stable order so party frames don't reshuffle between ticks.
	table.sort(members, function(a, b)
		return a.UserId < b.UserId
	end)
	return members
end

--[[ Sends the current roster to every client. ]]
function PartyService.broadcast()
	Remotes.event(Remotes.Names.PartyStateChanged):FireAllClients({ Members = snapshot() })
end

function PartyService.Init() end

function PartyService.Start()
	-- Immediate push on roster changes so a new party member appears at once.
	local function onPlayer(player: Player)
		task.defer(PartyService.broadcast)
		player.CharacterAdded:Connect(function()
			task.wait(0.5) -- let the server apply configured max health first
			PartyService.broadcast()
		end)
	end
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(function()
		task.defer(PartyService.broadcast)
	end)

	task.spawn(function()
		while true do
			task.wait(BROADCAST_INTERVAL)
			-- Solo players still get the push; the client hides the panel itself.
			PartyService.broadcast()
		end
	end)
end

return PartyService
