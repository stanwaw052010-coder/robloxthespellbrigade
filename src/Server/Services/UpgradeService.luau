--!strict
--[[
	UpgradeService
	--------------
	Внутриматчевые апгрейды заклинаний (покупка за голд между волнами).

	Server-authoritative in-match upgrades, in two layers:

	  1. Global stat modifiers (damage, cooldown, radius, mana) that apply to
	     every spell the player casts.
	  2. Per-spell trees ("дерево прокачки") — three stacking stat nodes per
	     spell plus, for curated spells, a signature node that changes the
	     spell's behaviour (e.g. Fireball detonating twice).

	SpellCastingService reads both at cast time. Escalating gold cost per level;
	everything resets when a match starts.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Remotes = require(Shared.Remotes)
local SpellbookModule = require(Shared.SpellbookModule)
local UpgradeCatalogue = require(Shared.UpgradeCatalogue)

local EconomyService = require(script.Parent.EconomyService)
local PlayerDataService = require(script.Parent.PlayerDataService)

export type UpgradeState = {
	DamageMult: number,
	CooldownMult: number,
	RadiusMult: number,
	ManaCostMult: number,
	Levels: { [string]: number },
	-- SpellLevels[spellId][nodeId] = purchased levels
	SpellLevels: { [string]: { [string]: number } },
}

--[[ Per-spell multipliers combined from that spell's tree. `Signatures` is a
     set of purchased signature node ids, branched on by the caster. ]]
export type SpellMods = {
	DamageMult: number,
	CooldownMult: number,
	RadiusMult: number,
	Signatures: { [string]: boolean },
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
		SpellLevels = {},
	}
end

-- Neutral per-spell mods, returned when a spell has no purchased nodes.
local NEUTRAL_SPELL_MODS: SpellMods = table.freeze({
	DamageMult = 1,
	CooldownMult = 1,
	RadiusMult = 1,
	Signatures = table.freeze({}),
})

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

--[[ True when the spell occupies the Ultimate slot (drives node pricing). ]]
local function isUltimate(spellId: string): boolean
	local spell = SpellbookModule.getSpellById(spellId)
	return spell ~= nil and spell.Slot == "Ultimate"
end

--[[ Pushes the player's purchased upgrade levels (global + per-spell) so the
     shop can render current levels and next costs, and so the HUD's local
     cooldown prediction matches the cooldowns the server actually applies.
     Levels only — the client never gets to decide what they are worth. ]]
local function pushSpellTree(player: Player)
	local state = states[player]
	if not state then
		return
	end
	Remotes.event(Remotes.Names.SpellTreeChanged):FireClient(player, {
		SpellLevels = state.SpellLevels,
		GlobalLevels = state.Levels,
	})
end

function UpgradeService.reset(player: Player)
	states[player] = newState()
	pushSpellTree(player)
end

function UpgradeService.resetAll()
	for player in states do
		states[player] = newState()
		pushSpellTree(player)
	end
end

--[[ Combined multipliers for one spell from its own tree. Returns a shared
     frozen neutral table when nothing has been bought (the common case), so
     casting stays allocation-free. ]]
function UpgradeService.getSpellMods(player: Player, spellId: string): SpellMods
	local state = states[player]
	local levels = state and state.SpellLevels[spellId]
	if not levels then
		return NEUTRAL_SPELL_MODS
	end

	local mods: SpellMods = { DamageMult = 1, CooldownMult = 1, RadiusMult = 1, Signatures = {} }
	local ult = isUltimate(spellId)
	for nodeId, level in levels do
		local node = UpgradeCatalogue.nodeFor(spellId, nodeId, ult)
		if not node or level <= 0 then
			continue
		end
		if node.Kind == "Potency" then
			mods.DamageMult += node.PerLevel * level
		elseif node.Kind == "Haste" then
			mods.CooldownMult += node.PerLevel * level
		elseif node.Kind == "Amplify" then
			mods.RadiusMult += node.PerLevel * level
		elseif node.Kind == "Signature" then
			mods.Signatures[nodeId] = true
		end
	end
	-- Never let stacked haste drive a cooldown to zero or negative.
	mods.CooldownMult = math.max(0.25, mods.CooldownMult)
	return mods
end

--[[ Purchased level of a single spell node (0 if none). ]]
function UpgradeService.getSpellNodeLevel(player: Player, spellId: string, nodeId: string): number
	local state = states[player]
	local levels = state and state.SpellLevels[spellId]
	return (levels and levels[nodeId]) or 0
end

--[[ Attempts to buy one level of a per-spell node. Returns (ok, message).
     The spell must belong to the player's equipped book — you cannot pre-buy
     upgrades for a class you are not playing. ]]
function UpgradeService.purchaseSpellNode(player: Player, spellId: string, nodeId: string): (boolean, string)
	local spell = SpellbookModule.getSpellById(spellId)
	if not spell then
		return false, "Неизвестное заклинание"
	end

	local profile = PlayerDataService.get(player)
	if not profile then
		return false, "Профиль не загружен"
	end
	if not SpellbookModule.bookHasSpell(profile.SelectedBook, spellId) then
		return false, "Это заклинание не из вашей книги"
	end

	local ult = spell.Slot == "Ultimate"
	local node = UpgradeCatalogue.nodeFor(spellId, nodeId, ult)
	if not node then
		return false, "Неизвестный узел прокачки"
	end

	local state = UpgradeService.getState(player)
	local levels = state.SpellLevels[spellId]
	if not levels then
		levels = {}
		state.SpellLevels[spellId] = levels
	end

	local level = levels[nodeId] or 0
	if level >= node.MaxLevel then
		return false, "Максимальный уровень"
	end

	local cost = UpgradeCatalogue.spellNodeCost(node, level)
	if not EconomyService.trySpendGold(player, cost) then
		return false, "Недостаточно золота"
	end

	levels[nodeId] = level + 1
	pushSpellTree(player)
	return true, ("%s — %s (ур. %d)"):format(spell.Name, node.Label, level + 1)
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
	local multipliers = state :: any
	local field = entry.Field
	multipliers[field] = multipliers[field] + entry.PerLevel
	pushSpellTree(player)
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

	-- Per-spell tree nodes.
	local nodeRemote = Remotes.func(Remotes.Names.PurchaseSpellNode)
	nodeRemote.OnServerInvoke = function(player: Player, payload: any)
		if type(payload) ~= "table" or type(payload.SpellId) ~= "string" or type(payload.NodeId) ~= "string" then
			return { Ok = false, Message = "Некорректный запрос" }
		end
		local ok, message = UpgradeService.purchaseSpellNode(player, payload.SpellId, payload.NodeId)
		return { Ok = ok, Message = message }
	end
end

return UpgradeService
