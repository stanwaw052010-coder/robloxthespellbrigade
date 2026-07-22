--!strict
--[[
	EconomyService
	--------------
	Прогрессия и валюты: голд за убийства/волны, опыт, уровни, эссенция за матч.

	Turns combat outcomes into currency and progression. It listens to
	DamageService.EnemyDied (never trusts the client) to award gold/XP, handles
	level-ups against the XP curve in GameConfig, and pays out essence at the
	end of a match. Spending (upgrades, book unlocks) also lives here.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local GameConfig = require(Shared.GameConfig)
local Remotes = require(Shared.Remotes)

local PlayerDataService = require(script.Parent.PlayerDataService)
local DamageService = require(script.Parent.DamageService)

local EconomyService = {}

-- XP needed to advance FROM the given level to the next one.
local function xpForLevel(level: number): number
	local eco = GameConfig.Economy
	return math.floor(eco.XpCurveBase * (level ^ eco.XpCurveExp))
end

EconomyService.xpForLevel = xpForLevel

local function notify(player: Player, text: string, kind: string?)
	Remotes.event(Remotes.Names.Notify):FireClient(player, { Text = text, Kind = kind or "info" })
end

--[[ Grants XP and resolves any level-ups (can chain multiple levels). ]]
function EconomyService.grantXp(player: Player, amount: number)
	local profile = PlayerDataService.get(player)
	if not profile then
		return
	end
	profile.Xp += amount

	local leveled = false
	while profile.Xp >= xpForLevel(profile.Level) do
		profile.Xp -= xpForLevel(profile.Level)
		profile.Level += 1
		leveled = true
	end
	if leveled then
		notify(player, ("Уровень %d!"):format(profile.Level), "levelup")
	end
	PlayerDataService.pushStats(player)
end

--[[ Grants gold to a single player. ]]
function EconomyService.grantGold(player: Player, amount: number)
	PlayerDataService.increment(player, "Gold", amount)
end

--[[ Splits a reward equally across all alive players (e.g. wave-clear bonus).
     Kill rewards go to the killer only. ]]
function EconomyService.grantGoldToAll(amount: number)
	local Players = game:GetService("Players")
	for _, player in Players:GetPlayers() do
		if PlayerDataService.get(player) then
			EconomyService.grantGold(player, amount)
		end
	end
end

--[[ Attempts to spend gold. Returns true on success. ]]
function EconomyService.trySpendGold(player: Player, amount: number): boolean
	local profile = PlayerDataService.get(player)
	if not profile or profile.Gold < amount then
		return false
	end
	PlayerDataService.increment(player, "Gold", -amount)
	return true
end

--[[ Attempts to spend essence (meta currency). Returns true on success. ]]
function EconomyService.trySpendEssence(player: Player, amount: number): boolean
	local profile = PlayerDataService.get(player)
	if not profile or profile.Essence < amount then
		return false
	end
	PlayerDataService.increment(player, "Essence", -amount)
	return true
end

--[[ Pays out end-of-match essence and records stats. ]]
function EconomyService.payMatchReward(player: Player, wavesCleared: number)
	local profile = PlayerDataService.get(player)
	if not profile then
		return
	end
	local essence = GameConfig.Economy.EssencePerMatchClear + math.floor(wavesCleared * 1.5)
	PlayerDataService.increment(player, "Essence", essence)
	PlayerDataService.addStat(player, "MatchesPlayed", 1)
	if wavesCleared > profile.Stats.BestWave then
		profile.Stats.BestWave = wavesCleared
	end
	notify(player, ("Матч завершён! +%d эссенции"):format(essence), "reward")
end

-- Lifecycle -------------------------------------------------------------------

function EconomyService.Init()
	-- nothing to pre-build
end

function EconomyService.Start()
	-- Award the killer for every enemy that dies. Server-authoritative: the
	-- reward comes from the enemy definition, never from client input.
	DamageService.EnemyDied:Connect(function(def, killer)
		if not killer then
			return
		end
		if not PlayerDataService.get(killer) then
			return
		end
		local gold = def.GoldReward + GameConfig.Economy.GoldPerKillBase
		EconomyService.grantGold(killer, gold)
		EconomyService.grantXp(killer, def.XpReward + GameConfig.Economy.XpPerKill)
		PlayerDataService.addStat(killer, "Kills", 1)
	end)

	-- Track cumulative damage / healing stats.
	DamageService.DamageDealt:Connect(function(player, amount)
		if not player or not PlayerDataService.get(player) then
			return
		end
		if amount >= 0 then
			PlayerDataService.addStat(player, "DamageDealt", math.floor(amount))
		else
			PlayerDataService.addStat(player, "Healing", math.floor(-amount))
		end
	end)
end

return EconomyService
