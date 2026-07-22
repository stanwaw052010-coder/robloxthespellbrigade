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

return UpgradeCatalogue
