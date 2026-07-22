--!strict
--[[
	EnemyEffectsModule
	------------------
	Таблица статус-эффектов (метаданные): цвет, тип, поведение.

	Shared catalogue describing each status effect referenced in the design doc
	(Burn, Poison, Freeze, Stun, Invulnerable, Shielded, ...). Data only — the
	actual application/ticking lives in DamageService (the StatusEffectService
	role). Both server logic and client VFX read colours/labels from here so
	they stay in sync.
]]

local GameConfig = require(script.Parent.GameConfig)
local FX = GameConfig.StatusEffects

export type EffectMeta = {
	Id: string,
	Kind: string, -- "DoT" | "Movement" | "Buff" | "State"
	Color: Color3, -- tint used for particles / UI
	Label: string,
	Hostile: boolean, -- true = debuff on enemies/players, false = ally buff
	TickInterval: number?, -- for DoT effects, seconds between ticks
}

local EnemyEffectsModule = {}

local Effects: { [string]: EffectMeta } = {
	[FX.Burn] = {
		Id = FX.Burn,
		Kind = "DoT",
		Color = Color3.fromRGB(255, 110, 40),
		Label = "Горение",
		Hostile = true,
		TickInterval = 1,
	},
	[FX.Poison] = {
		Id = FX.Poison,
		Kind = "DoT",
		Color = Color3.fromRGB(120, 210, 70),
		Label = "Отравление",
		Hostile = true,
		TickInterval = 1,
	},
	[FX.Freeze] = {
		Id = FX.Freeze,
		Kind = "Movement",
		Color = Color3.fromRGB(150, 220, 255),
		Label = "Заморозка",
		Hostile = true,
	},
	[FX.Slow] = {
		Id = FX.Slow,
		Kind = "Movement",
		Color = Color3.fromRGB(140, 200, 240),
		Label = "Замедление",
		Hostile = true,
	},
	[FX.Stun] = {
		Id = FX.Stun,
		Kind = "Movement",
		Color = Color3.fromRGB(240, 230, 120),
		Label = "Оглушение",
		Hostile = true,
	},
	[FX.Weaken] = {
		Id = FX.Weaken,
		Kind = "State",
		Color = Color3.fromRGB(150, 90, 200),
		Label = "Ослабление",
		Hostile = true,
	},
	[FX.Shield] = {
		Id = FX.Shield,
		Kind = "Buff",
		Color = Color3.fromRGB(255, 230, 150),
		Label = "Щит",
		Hostile = false,
	},
	[FX.Invulnerable] = {
		Id = FX.Invulnerable,
		Kind = "State",
		Color = Color3.fromRGB(90, 90, 110),
		Label = "Неуязвимость",
		Hostile = false,
	},
}

EnemyEffectsModule.Effects = Effects

function EnemyEffectsModule.get(effectId: string): EffectMeta?
	return Effects[effectId]
end

function EnemyEffectsModule.colorFor(effectId: string): Color3
	local meta = Effects[effectId]
	return meta and meta.Color or Color3.fromRGB(220, 220, 220)
end

return EnemyEffectsModule
