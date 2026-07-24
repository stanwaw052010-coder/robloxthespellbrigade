--!strict
--[[
	PlayerDataService
	-----------------
	Сохранение прогресса игрока (голд, эссенция, опыт, разблокировки).

	Owns per-player persistent profiles. Uses a session-cache pattern (load on
	join, autosave on an interval, flush on leave/close) backed by DataStore.
	If DataStore access is unavailable (e.g. Studio without API access enabled)
	it degrades gracefully to a session-only profile so the game still runs.

	This is a lightweight stand-in for ProfileService/DataStore2; swap in the
	real library for production-grade session locking.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local GameConfig = require(Shared.GameConfig)
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)

export type Profile = {
	Gold: number, -- soft currency, in-match
	Essence: number, -- meta currency, persists
	Xp: number,
	Level: number,
	SelectedBook: string,
	UnlockedBooks: { [string]: boolean },
	-- Equipped cosmetics, keyed by kind ("Aura" | "Hat").
	Cosmetics: { [string]: string },
	-- Purchased cosmetics, keyed "<kind>:<id>". Free entries are never stored.
	UnlockedCosmetics: { [string]: boolean },
	Stats: {
		Kills: number,
		DamageDealt: number,
		Healing: number,
		MatchesPlayed: number,
		BestWave: number,
	},
}

local DATASTORE_NAME = "MagicBrigade_PlayerData_v1"
local AUTOSAVE_INTERVAL = 120 -- seconds

local PlayerDataService = {}
PlayerDataService.ProfileLoaded = Signal.new() -- fires (player, profile)
-- Fires (player) whenever something that changes how the character LOOKS was
-- saved: equipped book (robe tint / spellbook prop) or an equipped cosmetic.
-- CosmeticsService listens so it can rebuild the character's props.
PlayerDataService.AppearanceChanged = Signal.new()

local store: DataStore? = nil
local profiles: { [Player]: Profile } = {}
local loading: { [Player]: boolean } = {}

local function defaultProfile(): Profile
	return {
		Gold = 0,
		Essence = 0,
		Xp = 0,
		Level = 1,
		SelectedBook = "Fire", -- starter book (free)
		UnlockedBooks = { Fire = true },
		Cosmetics = { Aura = "Ember", Hat = "Hood" }, -- free starter set
		UnlockedCosmetics = {},
		Stats = {
			Kills = 0,
			DamageDealt = 0,
			Healing = 0,
			MatchesPlayed = 0,
			BestWave = 0,
		},
	}
end

-- Merge a loaded (possibly older/partial) profile onto the current default so
-- new fields are always present.
local function reconcile(loaded: any): Profile
	local base = defaultProfile()
	if type(loaded) ~= "table" then
		return base
	end
	for key, value in loaded do
		base[key] = value
	end
	-- Deep-reconcile nested Stats table.
	local stats = defaultProfile().Stats
	if type(loaded.Stats) == "table" then
		for key in stats do
			if loaded.Stats[key] ~= nil then
				stats[key] = loaded.Stats[key]
			end
		end
	end
	base.Stats = stats
	if type(base.UnlockedBooks) ~= "table" then
		base.UnlockedBooks = { Fire = true }
	end
	if type(base.Cosmetics) ~= "table" then
		base.Cosmetics = { Aura = "Ember", Hat = "Hood" }
	end
	if type(base.UnlockedCosmetics) ~= "table" then
		base.UnlockedCosmetics = {}
	end
	return base
end

local function keyFor(player: Player): string
	return "player_" .. player.UserId
end

-- Networking: push a lightweight stats snapshot to the owning client.
local function pushStats(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	Remotes.event(Remotes.Names.PlayerStatsChanged):FireClient(player, {
		Gold = profile.Gold,
		Essence = profile.Essence,
		Xp = profile.Xp,
		Level = profile.Level,
		SelectedBook = profile.SelectedBook,
		UnlockedBooks = profile.UnlockedBooks,
		Cosmetics = profile.Cosmetics,
		UnlockedCosmetics = profile.UnlockedCosmetics,
	})
end
PlayerDataService.pushStats = pushStats

local function loadProfile(player: Player)
	loading[player] = true

	local data: any = nil
	if store then
		local ok, result = pcall(function()
			return (store :: DataStore):GetAsync(keyFor(player))
		end)
		if ok then
			data = result
		else
			warn(("[PlayerDataService] load failed for %s: %s"):format(player.Name, tostring(result)))
		end
	end

	-- Player may have left while we awaited the DataStore.
	if not player.Parent then
		loading[player] = nil
		return
	end

	local profile = reconcile(data)
	profiles[player] = profile
	loading[player] = nil

	PlayerDataService.ProfileLoaded:Fire(player, profile)
	pushStats(player)
end

local function saveProfile(player: Player)
	local profile = profiles[player]
	if not profile or not store then
		return
	end
	local ok, err = pcall(function()
		(store :: DataStore):UpdateAsync(keyFor(player), function()
			return profile
		end)
	end)
	if not ok then
		warn(("[PlayerDataService] save failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

-- Public API ------------------------------------------------------------------

--[[ Returns the profile for a player, or nil if not yet loaded / left. ]]
function PlayerDataService.get(player: Player): Profile?
	return profiles[player]
end

--[[ Blocks (yields) until the player's profile is available or they leave. ]]
function PlayerDataService.waitFor(player: Player, timeout: number?): Profile?
	local deadline = os.clock() + (timeout or 15)
	while not profiles[player] and player.Parent and os.clock() < deadline do
		task.wait(0.1)
	end
	return profiles[player]
end

--[[ Mutates a numeric field and re-syncs the client. Safe for gold/essence/xp.
     Returns the new value. ]]
function PlayerDataService.increment(player: Player, field: string, delta: number): number?
	local profile = profiles[player]
	if not profile then
		return nil
	end
	local current = (profile :: any)[field]
	if type(current) ~= "number" then
		return nil
	end
	local newValue = current + delta
	local fields = profile :: any
	fields[field] = newValue
	pushStats(player)
	return newValue
end

function PlayerDataService.setSelectedBook(player: Player, bookId: string): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	if not profile.UnlockedBooks[bookId] then
		return false
	end
	profile.SelectedBook = bookId
	pushStats(player)
	PlayerDataService.AppearanceChanged:Fire(player)
	return true
end

function PlayerDataService.unlockBook(player: Player, bookId: string)
	local profile = profiles[player]
	if not profile then
		return
	end
	profile.UnlockedBooks[bookId] = true
	pushStats(player)
end

--[[ Equips a cosmetic. `kind` is "Aura" | "Hat". Ownership is validated by
     CosmeticsService before this is called. ]]
function PlayerDataService.setCosmetic(player: Player, kind: string, id: string)
	local profile = profiles[player]
	if not profile then
		return
	end
	profile.Cosmetics[kind] = id
	pushStats(player)
	PlayerDataService.AppearanceChanged:Fire(player)
end

--[[ Records a purchased cosmetic under the flat "<kind>:<id>" key. ]]
function PlayerDataService.unlockCosmetic(player: Player, kind: string, id: string)
	local profile = profiles[player]
	if not profile then
		return
	end
	profile.UnlockedCosmetics[kind .. ":" .. id] = true
	pushStats(player)
end

function PlayerDataService.addStat(player: Player, field: string, delta: number)
	local profile = profiles[player]
	if not profile then
		return
	end
	local stats = profile.Stats :: any
	local current = stats[field]
	if type(current) == "number" then
		stats[field] = current + delta
	end
end

-- Lifecycle -------------------------------------------------------------------

function PlayerDataService.Init()
	-- Probe DataStore availability once. In Studio without API access, or in a
	-- disconnected environment, GetDataStore itself can throw.
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok then
		store = result
	else
		store = nil
		warn("[PlayerDataService] DataStore unavailable; running session-only. " .. tostring(result))
	end
end

function PlayerDataService.Start()
	Players.PlayerAdded:Connect(loadProfile)
	Players.PlayerRemoving:Connect(function(player)
		saveProfile(player)
		profiles[player] = nil
		loading[player] = nil
	end)

	-- Cover players already present (Studio Play Solo, script reload).
	for _, player in Players:GetPlayers() do
		if not profiles[player] and not loading[player] then
			task.spawn(loadProfile, player)
		end
	end

	-- Periodic autosave.
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for player in profiles do
				saveProfile(player)
			end
		end
	end)

	-- Best-effort flush on server shutdown.
	game:BindToClose(function()
		if RunService:IsStudio() then
			return
		end
		for player in profiles do
			task.spawn(saveProfile, player)
		end
		task.wait(3)
	end)
end

return PlayerDataService
