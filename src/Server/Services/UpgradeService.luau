--!strict
--[[
	UpgradeService
	--------------
	Внутриматчевые апгрейды заклинаний (покупка за голд между волнами).

	Server-authoritative in-match upgrades. To keep the economy readable these
	are player-global stat modifiers (damage, cooldown, radius, mana) rather
	than a per-spell tree — SpellCastingService reads the resulting multipliers
	at cast time. Escalating gold cost per level. Reset when a match starts.

	This intentionally models the *shape* of the "дерево прокачки" from the
	design doc; extend `Catalogue` with per-spell nodes when content is ready.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Remotes = require(Shared.Remotes)
local UpgradeCatalogue = require(Shared.UpgradeCatalogue)

local EconomyService = require(script.Parent.EconomyService)

export type UpgradeState = {
	DamageMult: number,
	CooldownMult: number,
	RadiusMult: number,
	ManaCostMult: number,
	Levels: { [string]: number },
}

local UpgradeService = {}

-- Data lives in the shared catalogue so the client shop and this validator
-- agree on labels, per-level deltas, costs and caps.
local Catalogue = UpgradeCatalogue.Entries
UpgradeService.Catalogue = Catalogue

local states: { [Player]: UpgradeState } = {}

local function newState(): UpgradeState
	return {
		DamageMult = 1,
		CooldownMult = 1,
		RadiusMult = 1,
		ManaCostMult = 1,
		Levels = {},
	}
end

local costFor = UpgradeCatalogue.costFor
UpgradeService.costFor = costFor

--[[ Returns (creating if needed) the multiplier state for a player. ]]
function UpgradeService.getState(player: Player): UpgradeState
	local state = states[player]
	if not state then
		state = newState()
		states[player] = state
	end
	return state
end

function UpgradeService.reset(player: Player)
	states[player] = newState()
end

function UpgradeService.resetAll()
	for player in states do
		states[player] = newState()
	end
end

--[[ Attempts to buy one level of an upgrade. Returns (ok, message). ]]
function UpgradeService.purchase(player: Player, upgradeId: string): (boolean, string)
	local entry = Catalogue[upgradeId]
	if not entry then
		return false, "Неизвестный апгрейд"
	end
	local state = UpgradeService.getState(player)
	local level = state.Levels[upgradeId] or 0
	if level >= entry.MaxLevel then
		return false, "Максимальный уровень"
	end

	local cost = costFor(upgradeId, level)
	if not EconomyService.trySpendGold(player, cost) then
		return false, "Недостаточно золота"
	end

	state.Levels[upgradeId] = level + 1
	local field = entry.Field
	;(state :: any)[field] = (state :: any)[field] + entry.PerLevel
	return true, ("%s (ур. %d)"):format(entry.Label, level + 1)
end

function UpgradeService.Init() end

function UpgradeService.Start()
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)

	-- Handle purchase requests over a RemoteFunction (validated server-side).
	local remote = Remotes.func(Remotes.Names.PurchaseUpgrade)
	remote.OnServerInvoke = function(player: Player, upgradeId: any)
		if type(upgradeId) ~= "string" then
			return { Ok = false, Message = "Некорректный запрос" }
		end
		local ok, message = UpgradeService.purchase(player, upgradeId)
		return { Ok = ok, Message = message }
	end
end

return UpgradeService
