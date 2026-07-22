--!strict
--[[
	GameConfig
	----------
	Единая точка правды для глобальных числовых констант игры.
	Central source of truth for global tuning constants shared by the
	server and client. Keep gameplay balance numbers here so designers can
	tweak them in one place.
]]

local GameConfig = {}

-- Party / match sizing --------------------------------------------------------
GameConfig.MaxPartySize = 8
GameConfig.MinPlayersToStart = 1

-- Player defaults -------------------------------------------------------------
GameConfig.Player = {
	MaxHealth = 100,
	MaxMana = 100,
	ManaRegenPerSecond = 8,
	BaseWalkSpeed = 16,
	RespawnTime = 6, -- seconds; downed players revive between waves
}

-- The objective the enemies attack (portal / village core) --------------------
GameConfig.Base = {
	MaxHealth = 1000,
	-- How much health an enemy removes when it reaches the base and self-destructs.
	ContactDamageFallback = 20,
}

-- Wave pacing -----------------------------------------------------------------
GameConfig.Wave = {
	IntermissionSeconds = 20, -- shop / repair window between waves
	FirstWaveGraceSeconds = 8, -- time before wave 1 starts
	MiniBossEvery = 5,
	BossEvery = 10,
	-- Per-wave stat multipliers used when auto-generating waves beyond the
	-- hand-authored table in WaveDefinitions.
	HealthScalePerWave = 0.12, -- +12% enemy HP per wave
	DamageScalePerWave = 0.08, -- +8% enemy damage per wave
	CountScalePerWave = 0.10, -- +10% enemy count per wave
}

-- Economy ---------------------------------------------------------------------
GameConfig.Economy = {
	GoldPerKillBase = 5,
	GoldWaveClearBonus = 25, -- multiplied by wave number
	EssencePerMatchClear = 10,
	-- Player XP curve: xp needed for level N = Base * (N ^ Exp)
	XpCurveBase = 100,
	XpCurveExp = 1.5,
	XpPerKill = 12,
}

-- Anti-exploit / networking ---------------------------------------------------
GameConfig.Security = {
	-- Max cast requests accepted from a single client per second before we
	-- start dropping them (protects against remote spamming).
	MaxCastsPerSecond = 12,
	-- Allowed slack (studs) added to a spell's Range when validating that the
	-- client's aim point is reachable. Accounts for latency / lag compensation.
	RangeTolerance = 8,
}

-- Status effect identifiers (shared so client VFX and server logic agree) ------
GameConfig.StatusEffects = {
	Burn = "Burn", -- fire damage over time
	Poison = "Poison", -- nature/slime damage over time (from puddles)
	Freeze = "Freeze", -- hard crowd control (cannot move)
	Slow = "Slow", -- movement speed reduction
	Stun = "Stun", -- brief hard stop from an attack
	Weaken = "Weaken", -- deals-less-damage debuff
	Shield = "Shield", -- absorbs incoming damage
	Invulnerable = "Invulnerable", -- ignores all incoming damage (Shadow Wraith)
}

-- Boss / special-attack telegraphing --------------------------------------------
GameConfig.Combat = {
	-- How long a red danger zone shows on the floor before the attack lands.
	TelegraphSeconds = 1.3,
	-- Frontal cone (degrees, half-angle) a directional shield blocks from.
	ShieldBlockHalfAngle = 70,
	-- Shadow Wraith invulnerability cadence.
	WraithVulnerableWindow = 2.5,
	WraithInvulnerableWindow = 3.5,
}

table.freeze(GameConfig.Player)
table.freeze(GameConfig.Base)
table.freeze(GameConfig.Wave)
table.freeze(GameConfig.Economy)
table.freeze(GameConfig.Security)
table.freeze(GameConfig.StatusEffects)
table.freeze(GameConfig.Combat)
table.freeze(GameConfig)

return GameConfig
