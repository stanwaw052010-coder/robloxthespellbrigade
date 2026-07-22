--!strict
--[[
	WaveDefinitions
	---------------
	Таблица волн + генератор бесконечных волн со scaling'ом.

	Hand-authored waves for the early game, plus a procedural generator for
	"endless" waves beyond the table. Every 5th wave adds a mini-boss and every
	10th a full boss (see GameConfig.Wave). WaveManager consumes `build(n)`.
]]

local GameConfig = require(script.Parent.GameConfig)

export type WaveSpec = {
	WaveNumber: number,
	-- Enemy id -> how many to spawn this wave
	Composition: { [string]: number },
	SpawnDelay: number, -- seconds between spawns
	Boss: string?, -- boss enemy id, if any
	HealthMultiplier: number,
	DamageMultiplier: number,
	Reward: number, -- bonus gold for clearing the wave
}

local WaveDefinitions = {}

-- Hand-authored opening waves (readable, tuned by feel) -----------------------
local Authored: { [number]: { Composition: { [string]: number }, SpawnDelay: number, Boss: string? } } = {
	[1] = { Composition = { Goblin = 10 }, SpawnDelay = 1.5 },
	[2] = { Composition = { Goblin = 12, Skeleton = 4 }, SpawnDelay = 1.3 },
	[3] = { Composition = { Goblin = 10, Skeleton = 8, Imp = 4 }, SpawnDelay = 1.2 },
	[4] = { Composition = { Skeleton = 12, Imp = 8, DarkArcher = 2 }, SpawnDelay = 1.1 },
	[5] = { Composition = { Goblin = 14, Skeleton = 6 }, SpawnDelay = 1.0, Boss = "OrcChieftain" },
	[6] = { Composition = { Imp = 14, Skeleton = 8, DarkArcher = 3 }, SpawnDelay = 1.0 },
	[7] = { Composition = { Skeleton = 14, Ogre = 2, DarkArcher = 4 }, SpawnDelay = 0.95 },
	[8] = { Composition = { Imp = 18, Ogre = 2, DarkArcher = 5 }, SpawnDelay = 0.9 },
	[9] = { Composition = { Skeleton = 16, Ogre = 3, Imp = 10, DarkArcher = 5 }, SpawnDelay = 0.85 },
	[10] = { Composition = { Skeleton = 12, Ogre = 3, Imp = 12 }, SpawnDelay = 0.85, Boss = "LichKing" },
}

-- Pool used to seed the composition of procedurally generated waves.
local ENDLESS_POOL = { "Goblin", "Skeleton", "Imp", "Ogre", "DarkArcher" }

local function totalCount(comp: { [string]: number }): number
	local n = 0
	for _, c in comp do
		n += c
	end
	return n
end

--[[
	Builds the full spec for wave `n` (n >= 1). Applies difficulty scaling from
	GameConfig on top of either the authored composition or a generated one.
]]
function WaveDefinitions.build(n: number): WaveSpec
	assert(n >= 1, "wave number must be >= 1")
	local cfg = GameConfig.Wave

	local composition: { [string]: number }
	local spawnDelay: number
	local boss: string? = nil

	local authored = Authored[n]
	if authored then
		-- Copy so callers can't mutate the source table.
		composition = table.clone(authored.Composition)
		spawnDelay = authored.SpawnDelay
		boss = authored.Boss
	else
		-- Procedural wave: scale total count with wave number and spread it
		-- across a slice of the pool that widens as waves progress.
		local baseCount = 14 + math.floor((n - 1) * 1.6)
		baseCount = math.floor(baseCount * (1 + cfg.CountScalePerWave * (n - 10)))
		baseCount = math.max(baseCount, 12)

		local variety = math.clamp(2 + math.floor(n / 4), 2, #ENDLESS_POOL)
		composition = {}
		for i = 1, variety do
			local enemyId = ENDLESS_POOL[((i - 1) % #ENDLESS_POOL) + 1]
			composition[enemyId] = (composition[enemyId] or 0) + math.max(1, math.floor(baseCount / variety))
		end
		spawnDelay = math.max(0.45, 1.5 - n * 0.03)

		-- Bosses on the configured cadence.
		if n % cfg.BossEvery == 0 then
			boss = (n % 20 == 0) and "LichKing" or "OrcChieftain"
		elseif n % cfg.MiniBossEvery == 0 then
			boss = "Ogre" -- a beefier "mini-boss" stand-in
		end
	end

	local healthMult = 1 + cfg.HealthScalePerWave * (n - 1)
	local damageMult = 1 + cfg.DamageScalePerWave * (n - 1)
	local reward = GameConfig.Economy.GoldWaveClearBonus * n

	return {
		WaveNumber = n,
		Composition = composition,
		SpawnDelay = spawnDelay,
		Boss = boss,
		HealthMultiplier = healthMult,
		DamageMultiplier = damageMult,
		Reward = reward,
	}
end

--[[ Convenience: number of regular (non-boss) enemies a wave will spawn. ]]
function WaveDefinitions.enemyCount(spec: WaveSpec): number
	return totalCount(spec.Composition) + (spec.Boss and 1 or 0)
end

return WaveDefinitions
