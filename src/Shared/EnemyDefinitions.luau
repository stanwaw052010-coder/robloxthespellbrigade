--!strict
--[[
	EnemyDefinitions
	----------------
	Статы и поведение каждого типа врага. Только данные — логику ИИ и спавна
	держит EnemyService на сервере.

	Data-only definitions for every enemy archetype. `Archetype` tells the AI
	how the enemy behaves; the service reads these numbers when it spawns a
	model. Colours/sizes let us build placeholder rigs procedurally without any
	external .rbxm assets, so the game runs the moment you sync it.

	Archetypes:
		"Runner" - runs straight to the base, melee on contact
		"Fast"   - low HP, high speed swarmer
		"Tank"   - high HP, slow, hits hard
		"Ranged" - stops at range and fires projectiles at players/base
		"Boss"   - unique, high HP, phase-based (handled specially)
		"Minion" - player-summoned ally (Necromancy); attacks enemies
]]

export type EnemyDef = {
	Id: string,
	Name: string,
	Archetype: string,
	MaxHealth: number,
	WalkSpeed: number,
	ContactDamage: number, -- melee / self-destruct damage
	AttackCooldown: number,
	AttackRange: number, -- studs; 0 means "on contact"
	GoldReward: number,
	XpReward: number,
	-- Placeholder rig appearance
	BodyColor: Color3,
	BodySize: Vector3,
	IsBoss: boolean?,
	BossPhases: number?,
}

local EnemyDefinitions = {}

local Enemies: { [string]: EnemyDef } = {
	Goblin = {
		Id = "Goblin",
		Name = "Goblin",
		Archetype = "Runner",
		MaxHealth = 40,
		WalkSpeed = 14,
		ContactDamage = 8,
		AttackCooldown = 1,
		AttackRange = 0,
		GoldReward = 5,
		XpReward = 12,
		BodyColor = Color3.fromRGB(86, 145, 74),
		BodySize = Vector3.new(2, 3, 1),
	},

	Skeleton = {
		Id = "Skeleton",
		Name = "Skeleton",
		Archetype = "Runner",
		MaxHealth = 55,
		WalkSpeed = 13,
		ContactDamage = 10,
		AttackCooldown = 1.1,
		AttackRange = 0,
		GoldReward = 6,
		XpReward = 14,
		BodyColor = Color3.fromRGB(220, 220, 210),
		BodySize = Vector3.new(2, 3, 1),
	},

	Imp = {
		Id = "Imp",
		Name = "Imp",
		Archetype = "Fast",
		MaxHealth = 22,
		WalkSpeed = 22,
		ContactDamage = 6,
		AttackCooldown = 0.8,
		AttackRange = 0,
		GoldReward = 5,
		XpReward = 10,
		BodyColor = Color3.fromRGB(180, 60, 60),
		BodySize = Vector3.new(1.4, 2, 0.9),
	},

	Ogre = {
		Id = "Ogre",
		Name = "Ogre",
		Archetype = "Tank",
		MaxHealth = 220,
		WalkSpeed = 9,
		ContactDamage = 25,
		AttackCooldown = 1.6,
		AttackRange = 0,
		GoldReward = 15,
		XpReward = 35,
		BodyColor = Color3.fromRGB(120, 110, 90),
		BodySize = Vector3.new(3.5, 5, 2),
	},

	DarkArcher = {
		Id = "DarkArcher",
		Name = "Dark Archer",
		Archetype = "Ranged",
		MaxHealth = 45,
		WalkSpeed = 12,
		ContactDamage = 14, -- projectile damage
		AttackCooldown = 2,
		AttackRange = 35,
		GoldReward = 9,
		XpReward = 18,
		BodyColor = Color3.fromRGB(60, 40, 90),
		BodySize = Vector3.new(2, 3, 1),
	},

	-- Player-summoned ally (Necromancy). Same data shape, Archetype = Minion.
	SkeletonMinion = {
		Id = "SkeletonMinion",
		Name = "Skeleton Minion",
		Archetype = "Minion",
		MaxHealth = 60,
		WalkSpeed = 16,
		ContactDamage = 12,
		AttackCooldown = 1,
		AttackRange = 0,
		GoldReward = 0,
		XpReward = 0,
		BodyColor = Color3.fromRGB(150, 200, 180),
		BodySize = Vector3.new(1.8, 2.8, 0.9),
	},

	-- Bosses -------------------------------------------------------------
	OrcChieftain = {
		Id = "OrcChieftain",
		Name = "Orc Chieftain",
		Archetype = "Boss",
		MaxHealth = 1500,
		WalkSpeed = 11,
		ContactDamage = 40,
		AttackCooldown = 1.4,
		AttackRange = 6,
		GoldReward = 120,
		XpReward = 250,
		BodyColor = Color3.fromRGB(70, 120, 60),
		BodySize = Vector3.new(5, 7, 3),
		IsBoss = true,
		BossPhases = 2,
	},

	LichKing = {
		Id = "LichKing",
		Name = "Lich King",
		Archetype = "Boss",
		MaxHealth = 3200,
		WalkSpeed = 10,
		ContactDamage = 55,
		AttackCooldown = 1.8,
		AttackRange = 40,
		GoldReward = 300,
		XpReward = 600,
		BodyColor = Color3.fromRGB(90, 70, 140),
		BodySize = Vector3.new(5, 8, 3),
		IsBoss = true,
		BossPhases = 3,
	},
}

EnemyDefinitions.Enemies = Enemies

function EnemyDefinitions.get(id: string): EnemyDef?
	return Enemies[id]
end

return EnemyDefinitions
