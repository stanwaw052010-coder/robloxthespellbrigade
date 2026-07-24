--!strict
--[[
	UpgradeCatalogue
	----------------
	Общий каталог внутриматчевых апгрейдов (данные для сервера и клиента).

	Shared data for in-match upgrades so the server (UpgradeService, which owns
	validation and spending) and the client (HUD shop, which renders the
	buttons) read from a single source. Data only — no behaviour.
]]

local UpgradeCatalogue = {}

export type UpgradeEntry = {
	Id: string,
	Field: string, -- which multiplier on the player's UpgradeState this touches
	PerLevel: number, -- delta applied per purchased level
	BaseCost: number, -- gold cost basis (scales with current level)
	MaxLevel: number,
	Label: string,
}

-- Ordered list keeps the shop layout stable.
UpgradeCatalogue.Order = { "Damage", "Cooldown", "Radius", "Mana" }

UpgradeCatalogue.Entries = {
	Damage = { Id = "Damage", Field = "DamageMult", PerLevel = 0.15, BaseCost = 60, MaxLevel = 8, Label = "Урон +15%" },
	Cooldown = { Id = "Cooldown", Field = "CooldownMult", PerLevel = -0.07, BaseCost = 80, MaxLevel = 6, Label = "Кулдаун -7%" },
	Radius = { Id = "Radius", Field = "RadiusMult", PerLevel = 0.12, BaseCost = 70, MaxLevel = 5, Label = "Радиус +12%" },
	Mana = { Id = "Mana", Field = "ManaCostMult", PerLevel = -0.08, BaseCost = 50, MaxLevel = 5, Label = "Мана -8%" },
} :: { [string]: UpgradeEntry }

--[[ Gold cost to buy the NEXT level given the current level. ]]
function UpgradeCatalogue.costFor(upgradeId: string, currentLevel: number): number
	local entry = UpgradeCatalogue.Entries[upgradeId]
	if not entry then
		return math.huge
	end
	return math.floor(entry.BaseCost * (1 + currentLevel * 0.6))
end

-- Per-spell upgrade trees (дерево прокачки заклинаний) -------------------------
--[[
	Every spell gets a small tree of three stacking stat nodes plus, for a
	curated set of spells, one "signature" node that changes how the spell
	behaves (e.g. Fireball detonating a second time). Stat nodes multiply on top
	of the global shop multipliers; signature nodes are read by name in
	SpellCastingService.

	Node kinds:
	  "Potency"   → damage multiplier for this spell only
	  "Haste"     → cooldown multiplier for this spell only
	  "Amplify"   → area-of-effect multiplier for this spell only
	  "Signature" → unique mechanic, MaxLevel 1, resolved by Id in the caster
]]

export type SpellNode = {
	Id: string, -- unique within the spell's tree
	Kind: string, -- Potency | Haste | Amplify | Signature
	PerLevel: number, -- delta applied per level (unused for Signature)
	MaxLevel: number,
	BaseCost: number,
	Label: string,
	Description: string,
}

-- The three stat nodes every spell shares. Cloned per spell so a designer can
-- override the numbers for an individual spell without touching the others.
local function statNodes(costScale: number): { SpellNode }
	return {
		{
			Id = "Potency",
			Kind = "Potency",
			PerLevel = 0.12,
			MaxLevel = 5,
			BaseCost = math.floor(45 * costScale),
			Label = "Мощь +12%",
			Description = "Увеличивает урон/лечение этого заклинания.",
		},
		{
			Id = "Haste",
			Kind = "Haste",
			PerLevel = -0.08,
			MaxLevel = 4,
			BaseCost = math.floor(55 * costScale),
			Label = "Скорость -8% КД",
			Description = "Сокращает кулдаун этого заклинания.",
		},
		{
			Id = "Amplify",
			Kind = "Amplify",
			PerLevel = 0.10,
			MaxLevel = 4,
			BaseCost = math.floor(50 * costScale),
			Label = "Радиус +10%",
			Description = "Расширяет зону поражения этого заклинания.",
		},
	}
end

-- Signature nodes: spellId → the one mechanic-changing node it can buy.
-- The Id is what SpellCastingService branches on, so keep these stable.
local SIGNATURES: { [string]: SpellNode } = {
	Fire_Fireball = {
		Id = "EchoBlast",
		Kind = "Signature",
		PerLevel = 0,
		MaxLevel = 1,
		BaseCost = 260,
		Label = "⭐ Двойной взрыв",
		Description = "Fireball взрывается второй раз через 0.6 сек (60% урона).",
	},
	Fire_Meteor = {
		Id = "Cataclysm",
		Kind = "Signature",
		PerLevel = 0,
		MaxLevel = 1,
		BaseCost = 340,
		Label = "⭐ Катаклизм",
		Description = "Метеоритный шторм бьёт трижды с задержкой.",
	},
	Ice_Nova = {
		Id = "Shatter",
		Kind = "Signature",
		PerLevel = 0,
		MaxLevel = 1,
		BaseCost = 250,
		Label = "⭐ Раскол",
		Description = "Замороженные враги получают от этого каста +60% урона.",
	},
	Light_Chain = {
		Id = "Overload",
		Kind = "Signature",
		PerLevel = 0,
		MaxLevel = 1,
		BaseCost = 270,
		Label = "⭐ Перегрузка",
		Description = "+3 перескока молнии и меньшее затухание урона.",
	},
	Earth_Wall = {
		Id = "GreatWall",
		Kind = "Signature",
		PerLevel = 0,
		MaxLevel = 1,
		BaseCost = 220,
		Label = "⭐ Великая стена",
		Description = "Ставит три стены в ряд, и они держатся вдвое дольше.",
	},
	Heal_Mend = {
		Id = "Overflow",
		Kind = "Signature",
		PerLevel = 0,
		MaxLevel = 1,
		BaseCost = 240,
		Label = "⭐ Перелив",
		Description = "Избыточное лечение превращается в щит союзнику.",
	},
	Necro_Raise = {
		Id = "Legion",
		Kind = "Signature",
		PerLevel = 0,
		MaxLevel = 1,
		BaseCost = 250,
		Label = "⭐ Легион",
		Description = "Призывает на 2 скелета больше.",
	},
}

--[[ Returns the ordered node list for a spell (stat nodes + signature if any).
     Built lazily and cached so the client and server share identical data. ]]
local treeCache: { [string]: { SpellNode } } = {}

function UpgradeCatalogue.treeFor(spellId: string, isUltimate: boolean?): { SpellNode }
	local cached = treeCache[spellId]
	if cached then
		return cached
	end
	-- Ultimates cost more per node; they scale the whole match.
	local nodes = statNodes(isUltimate and 1.8 or 1)
	local signature = SIGNATURES[spellId]
	if signature then
		table.insert(nodes, signature)
	end
	table.freeze(nodes)
	treeCache[spellId] = nodes
	return nodes
end

--[[ Finds a single node in a spell's tree by id, or nil. ]]
function UpgradeCatalogue.nodeFor(spellId: string, nodeId: string, isUltimate: boolean?): SpellNode?
	for _, node in UpgradeCatalogue.treeFor(spellId, isUltimate) do
		if node.Id == nodeId then
			return node
		end
	end
	return nil
end

--[[ Gold cost to buy the NEXT level of a spell node. ]]
function UpgradeCatalogue.spellNodeCost(node: SpellNode, currentLevel: number): number
	return math.floor(node.BaseCost * (1 + currentLevel * 0.75))
end

return UpgradeCatalogue
