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
	BossId: string?, -- selects the BossController behaviour set
	-- Unique gimmick that makes the enemy more than a bag of HP. One of:
	-- "PoisonDeath" | "Explode" | "FrostBite" | "Phase" | "DirectionalShield".
	Gimmick: string?,
	GimmickData: { [string]: any }?,
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

	SkeletonArcher = {
		Id = "SkeletonArcher",
		Name = "Skeleton Archer",
		Archetype = "Ranged",
		MaxHealth = 40,
		WalkSpeed = 12,
		ContactDamage = 12,
		AttackCooldown = 2.2,
		AttackRange = 38,
		GoldReward = 8,
		XpReward = 16,
		BodyColor = Color3.fromRGB(210, 205, 180),
		BodySize = Vector3.new(2, 3, 1),
	},

	-- Ядовитый слизень: при смерти оставляет лужу яда (DoT-зона на полу).
	PoisonSlime = {
		Id = "PoisonSlime",
		Name = "Poison Slime",
		Archetype = "Runner",
		MaxHealth = 50,
		WalkSpeed = 10,
		ContactDamage = 8,
		AttackCooldown = 1,
		AttackRange = 0,
		GoldReward = 8,
		XpReward = 16,
		BodyColor = Color3.fromRGB(110, 190, 70),
		BodySize = Vector3.new(2.4, 2, 2.4),
		Gimmick = "PoisonDeath",
		GimmickData = { PuddleRadius = 8, PuddleDamage = 6, PuddleDuration = 6 },
	},

	-- Взрывной гоблин: при смерти или контакте с базой взрывается (AoE).
	BombGoblin = {
		Id = "BombGoblin",
		Name = "Bomb Goblin",
		Archetype = "Fast",
		MaxHealth = 30,
		WalkSpeed = 20,
		ContactDamage = 10,
		AttackCooldown = 1,
		AttackRange = 0,
		GoldReward = 9,
		XpReward = 18,
		BodyColor = Color3.fromRGB(200, 120, 40),
		BodySize = Vector3.new(1.8, 2.4, 1.2),
		Gimmick = "Explode",
		GimmickData = { ExplosionRadius = 12, ExplosionDamage = 35 },
	},

	-- Морозный волк: при попадании по игроку накладывает замедление.
	FrostWolf = {
		Id = "FrostWolf",
		Name = "Frost Wolf",
		Archetype = "Fast",
		MaxHealth = 45,
		WalkSpeed = 21,
		ContactDamage = 12,
		AttackCooldown = 1.2,
		AttackRange = 0,
		GoldReward = 10,
		XpReward = 20,
		BodyColor = Color3.fromRGB(150, 200, 235),
		BodySize = Vector3.new(2.6, 2, 1.2),
		Gimmick = "FrostBite",
		GimmickData = { SlowPower = 0.45, SlowDuration = 2.5 },
	},

	-- Тень: периодически становится неуязвимой и телепортируется.
	ShadowWraith = {
		Id = "ShadowWraith",
		Name = "Shadow Wraith",
		Archetype = "Runner",
		MaxHealth = 70,
		WalkSpeed = 15,
		ContactDamage = 16,
		AttackCooldown = 1.2,
		AttackRange = 0,
		GoldReward = 14,
		XpReward = 28,
		BodyColor = Color3.fromRGB(80, 60, 110),
		BodySize = Vector3.new(2, 3.4, 1),
		Gimmick = "Phase",
		GimmickData = { BlinkStuds = 18 },
	},

	-- Щитоносец: держит щит спереди; бить нужно со спины.
	ShieldedBrute = {
		Id = "ShieldedBrute",
		Name = "Shielded Brute",
		Archetype = "Tank",
		MaxHealth = 180,
		WalkSpeed = 10,
		ContactDamage = 22,
		AttackCooldown = 1.6,
		AttackRange = 0,
		GoldReward = 16,
		XpReward = 34,
		BodyColor = Color3.fromRGB(130, 120, 140),
		BodySize = Vector3.new(3, 4.5, 1.8),
		Gimmick = "DirectionalShield",
	},

	-- Boss adds -----------------------------------------------------------
	FireElemental = {
		Id = "FireElemental",
		Name = "Fire Elemental",
		Archetype = "Fast",
		MaxHealth = 40,
		WalkSpeed = 19,
		ContactDamage = 12,
		AttackCooldown = 1,
		AttackRange = 0,
		GoldReward = 4,
		XpReward = 8,
		BodyColor = Color3.fromRGB(255, 120, 50),
		BodySize = Vector3.new(1.6, 2.4, 1.6),
	},

	ShadowCopy = {
		Id = "ShadowCopy",
		Name = "Shadow Copy",
		Archetype = "Runner",
		MaxHealth = 45,
		WalkSpeed = 15,
		ContactDamage = 12,
		AttackCooldown = 1.1,
		AttackRange = 0,
		GoldReward = 3,
		XpReward = 6,
		BodyColor = Color3.fromRGB(60, 55, 80),
		BodySize = Vector3.new(1.9, 3, 0.9),
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
		BossId = "Generic",
	},

	-- Огненный Голем (Wave 5 boss): 3 фазы — огненные волны, призыв
	-- элементалей, берсерк с огненной аурой.
	FireGolem = {
		Id = "FireGolem",
		Name = "Fire Golem",
		Archetype = "Boss",
		MaxHealth = 1800,
		WalkSpeed = 10,
		ContactDamage = 42,
		AttackCooldown = 1.5,
		AttackRange = 6,
		GoldReward = 150,
		XpReward = 300,
		BodyColor = Color3.fromRGB(200, 80, 40),
		BodySize = Vector3.new(5, 7.5, 3),
		IsBoss = true,
		BossPhases = 3,
		BossId = "FireGolem",
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
		BossId = "Generic",
	},

	-- Лич-некромант (финальный босс): 3 фазы — призыв скелетов и тьма,
	-- зоны запрета каста, воскрешение врагов как теневых копий.
	Lich = {
		Id = "Lich",
		Name = "Lich",
		Archetype = "Boss",
		MaxHealth = 3600,
		WalkSpeed = 9,
		ContactDamage = 50,
		AttackCooldown = 2,
		AttackRange = 42,
		GoldReward = 350,
		XpReward = 700,
		BodyColor = Color3.fromRGB(110, 80, 160),
		BodySize = Vector3.new(5, 8.5, 3),
		IsBoss = true,
		BossPhases = 3,
		BossId = "Lich",
	},
}

EnemyDefinitions.Enemies = Enemies

function EnemyDefinitions.get(id: string): EnemyDef?
	return Enemies[id]
end

return EnemyDefinitions
