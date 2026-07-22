--!strict
--[[
	SpellbookModule
	---------------
	Каталог книг заклинаний. Каждая книга — это класс со своим набором
	заклинаний (базовая атака, активные скиллы, ультимейт).

	Catalogue of every spellbook (class). Each spell is a plain data table so
	that both the server (which owns damage/cooldown logic) and the client
	(which owns input hints and VFX) read from the SAME definition. Never put
	behaviour here — only data. Behaviour lives in the services.

	Spell shape:
	{
		Id            = string,   -- unique across ALL books
		Name          = string,
		Slot          = "Basic" | "Q" | "E" | "R" | "Ultimate",
		Damage        = number,   -- per hit (0 for pure-utility spells)
		Cooldown      = number,   -- seconds
		ManaCost      = number,
		Range         = number,   -- studs; how far the cast can reach
		AreaOfEffect  = number,   -- studs radius; 0 = single target / projectile
		CastType      = "Projectile" | "AreaTarget" | "Cone" | "Self" | "Summon",
		Effect        = string?,  -- GameConfig.StatusEffects key
		EffectPower   = number?,  -- e.g. DoT per tick, slow %, shield amount
		EffectDuration= number?,  -- seconds
		CritChance    = number?,  -- 0..1
		VFX           = string,   -- key the client VFXController understands
		SoundId       = string?,  -- rbxassetid://...
		Animation     = string?,  -- rbxassetid://...
		Description   = string,
	}
]]

local GameConfig = require(script.Parent.GameConfig)
local FX = GameConfig.StatusEffects

export type Spell = {
	Id: string,
	Name: string,
	Slot: string,
	Damage: number,
	Cooldown: number,
	ManaCost: number,
	Range: number,
	AreaOfEffect: number,
	CastType: string,
	Effect: string?,
	EffectPower: number?,
	EffectDuration: number?,
	CritChance: number?,
	SummonId: string?,
	SummonCount: number?,
	VFX: string,
	SoundId: string?,
	Animation: string?,
	Description: string,
}

export type Spellbook = {
	Id: string,
	Name: string,
	Element: string,
	Role: string,
	UnlockCost: number, -- essence cost in the lobby; 0 = free/starter
	Description: string,
	Spells: { Spell },
}

local SpellbookModule = {}

-- NOTE: asset ids are placeholders ("rbxassetid://0"); swap for real uploads.
local PLACEHOLDER = "rbxassetid://0"

local Books: { [string]: Spellbook } = {
	--------------------------------------------------------------------------
	Fire = {
		Id = "Fire",
		Name = "Книга Огня",
		Element = "Fire",
		Role = "AoE Damage / DoT",
		UnlockCost = 0,
		Description = "Урон по площади, поджиг целей и растекающееся пламя.",
		Spells = {
			{
				Id = "Fire_Ember",
				Name = "Ember Bolt",
				Slot = "Basic",
				Damage = 12,
				Cooldown = 0.6,
				ManaCost = 0,
				Range = 45,
				AreaOfEffect = 0,
				CastType = "Projectile",
				CritChance = 0.1,
				VFX = "EmberBolt",
				Description = "Быстрый огненный снаряд без затрат маны.",
			},
			{
				Id = "Fire_Fireball",
				Name = "Fireball",
				Slot = "Q",
				Damage = 25,
				Cooldown = 3,
				ManaCost = 15,
				Range = 40,
				AreaOfEffect = 6,
				CastType = "AreaTarget",
				Effect = FX.Burn,
				EffectPower = 5,
				EffectDuration = 4,
				CritChance = 0.15,
				VFX = "Fireball",
				Description = "Взрыв по площади, поджигающий врагов (DoT).",
			},
			{
				Id = "Fire_FlameWall",
				Name = "Flame Wall",
				Slot = "E",
				Damage = 8,
				Cooldown = 9,
				ManaCost = 30,
				Range = 25,
				AreaOfEffect = 10,
				CastType = "AreaTarget",
				Effect = FX.Burn,
				EffectPower = 6,
				EffectDuration = 5,
				VFX = "FlameWall",
				Description = "Стена огня, наносящая урон проходящим врагам.",
			},
			{
				Id = "Fire_Meteor",
				Name = "Meteor Storm",
				Slot = "Ultimate",
				Damage = 90,
				Cooldown = 45,
				ManaCost = 70,
				Range = 60,
				AreaOfEffect = 18,
				CastType = "AreaTarget",
				Effect = FX.Burn,
				EffectPower = 10,
				EffectDuration = 6,
				CritChance = 0.25,
				VFX = "MeteorStorm",
				Description = "Град метеоров, опустошающий большую зону.",
			},
		},
	},

	--------------------------------------------------------------------------
	Ice = {
		Id = "Ice",
		Name = "Книга Льда",
		Element = "Ice",
		Role = "Crowd Control",
		UnlockCost = 150,
		Description = "Заморозка, замедление и контроль толпы.",
		Spells = {
			{
				Id = "Ice_Shard",
				Name = "Frost Shard",
				Slot = "Basic",
				Damage = 10,
				Cooldown = 0.55,
				ManaCost = 0,
				Range = 45,
				AreaOfEffect = 0,
				CastType = "Projectile",
				Effect = FX.Slow,
				EffectPower = 0.2,
				EffectDuration = 1.5,
				VFX = "FrostShard",
				Description = "Ледяной осколок, слегка замедляющий цель.",
			},
			{
				Id = "Ice_Nova",
				Name = "Frost Nova",
				Slot = "Q",
				Damage = 18,
				Cooldown = 6,
				ManaCost = 25,
				Range = 0,
				AreaOfEffect = 14,
				CastType = "Self",
				Effect = FX.Freeze,
				EffectPower = 1,
				EffectDuration = 2.5,
				VFX = "FrostNova",
				Description = "Взрыв холода вокруг вас, замораживает врагов рядом.",
			},
			{
				Id = "Ice_Blizzard",
				Name = "Blizzard",
				Slot = "E",
				Damage = 14,
				Cooldown = 11,
				ManaCost = 40,
				Range = 40,
				AreaOfEffect = 16,
				CastType = "AreaTarget",
				Effect = FX.Slow,
				EffectPower = 0.5,
				EffectDuration = 5,
				VFX = "Blizzard",
				Description = "Метель, наносящая урон и сильно замедляющая зону.",
			},
			{
				Id = "Ice_Absolute",
				Name = "Absolute Zero",
				Slot = "Ultimate",
				Damage = 60,
				Cooldown = 50,
				ManaCost = 75,
				Range = 55,
				AreaOfEffect = 22,
				CastType = "AreaTarget",
				Effect = FX.Freeze,
				EffectPower = 1,
				EffectDuration = 4,
				VFX = "AbsoluteZero",
				Description = "Замораживает всех врагов в огромной зоне.",
			},
		},
	},

	--------------------------------------------------------------------------
	Earth = {
		Id = "Earth",
		Name = "Книга Земли",
		Element = "Earth",
		Role = "Tank / Control",
		UnlockCost = 150,
		Description = "Стены, ловушки и защита базы.",
		Spells = {
			{
				Id = "Earth_Rock",
				Name = "Rock Throw",
				Slot = "Basic",
				Damage = 14,
				Cooldown = 0.7,
				ManaCost = 0,
				Range = 40,
				AreaOfEffect = 0,
				CastType = "Projectile",
				VFX = "RockThrow",
				Description = "Тяжёлый камень с хорошим уроном.",
			},
			{
				Id = "Earth_Wall",
				Name = "Stone Wall",
				Slot = "Q",
				Damage = 0,
				Cooldown = 8,
				ManaCost = 25,
				Range = 20,
				AreaOfEffect = 8,
				CastType = "AreaTarget",
				VFX = "StoneWall",
				Description = "Каменная стена, блокирующая путь врагам.",
			},
			{
				Id = "Earth_Quake",
				Name = "Earthquake",
				Slot = "E",
				Damage = 22,
				Cooldown = 10,
				ManaCost = 35,
				Range = 0,
				AreaOfEffect = 16,
				CastType = "Self",
				Effect = FX.Slow,
				EffectPower = 0.4,
				EffectDuration = 3,
				VFX = "Earthquake",
				Description = "Землетрясение вокруг вас, урон и замедление.",
			},
			{
				Id = "Earth_Titan",
				Name = "Titan's Bulwark",
				Slot = "Ultimate",
				Damage = 40,
				Cooldown = 55,
				ManaCost = 60,
				Range = 0,
				AreaOfEffect = 20,
				CastType = "Self",
				Effect = FX.Shield,
				EffectPower = 150,
				EffectDuration = 10,
				VFX = "TitanBulwark",
				Description = "Даёт щит всему отряду рядом и оглушает врагов.",
			},
		},
	},

	--------------------------------------------------------------------------
	Lightning = {
		Id = "Lightning",
		Name = "Книга Молнии",
		Element = "Lightning",
		Role = "Burst / Crit",
		UnlockCost = 200,
		Description = "Цепной урон и высокий шанс критического удара.",
		Spells = {
			{
				Id = "Light_Spark",
				Name = "Spark",
				Slot = "Basic",
				Damage = 9,
				Cooldown = 0.4,
				ManaCost = 0,
				Range = 50,
				AreaOfEffect = 0,
				CastType = "Projectile",
				CritChance = 0.25,
				VFX = "Spark",
				Description = "Быстрая искра с высоким шансом крита.",
			},
			{
				Id = "Light_Chain",
				Name = "Chain Lightning",
				Slot = "Q",
				Damage = 20,
				Cooldown = 4,
				ManaCost = 20,
				Range = 45,
				AreaOfEffect = 8, -- chain jump radius
				CastType = "Projectile",
				CritChance = 0.2,
				VFX = "ChainLightning",
				Description = "Молния, перескакивающая между ближними врагами.",
			},
			{
				Id = "Light_Storm",
				Name = "Static Field",
				Slot = "E",
				Damage = 12,
				Cooldown = 9,
				ManaCost = 35,
				Range = 35,
				AreaOfEffect = 12,
				CastType = "AreaTarget",
				Effect = FX.Slow,
				EffectPower = 0.3,
				EffectDuration = 4,
				VFX = "StaticField",
				Description = "Статическое поле, бьющее током всех внутри.",
			},
			{
				Id = "Light_Judgement",
				Name = "Thunder Judgement",
				Slot = "Ultimate",
				Damage = 110,
				Cooldown = 48,
				ManaCost = 70,
				Range = 60,
				AreaOfEffect = 14,
				CastType = "AreaTarget",
				CritChance = 0.4,
				VFX = "ThunderJudgement",
				Description = "Разряд с небес, огромный урон и крит по зоне.",
			},
		},
	},

	--------------------------------------------------------------------------
	Healing = {
		Id = "Healing",
		Name = "Книга Исцеления",
		Element = "Holy",
		Role = "Support",
		UnlockCost = 200,
		Description = "Лечение отряда, баффы и защита союзников.",
		Spells = {
			{
				Id = "Heal_Bolt",
				Name = "Radiant Bolt",
				Slot = "Basic",
				Damage = 8,
				Cooldown = 0.6,
				ManaCost = 0,
				Range = 45,
				AreaOfEffect = 0,
				CastType = "Projectile",
				VFX = "RadiantBolt",
				Description = "Луч света, наносящий небольшой урон.",
			},
			{
				Id = "Heal_Mend",
				Name = "Mend",
				Slot = "Q",
				Damage = -35, -- negative damage = healing (handled by DamageService)
				Cooldown = 5,
				ManaCost = 25,
				Range = 40,
				AreaOfEffect = 10,
				CastType = "AreaTarget",
				VFX = "MendCircle",
				Description = "Исцеляет союзников в зоне.",
			},
			{
				Id = "Heal_Blessing",
				Name = "Blessing",
				Slot = "E",
				Damage = 0,
				Cooldown = 14,
				ManaCost = 40,
				Range = 30,
				AreaOfEffect = 14,
				CastType = "AreaTarget",
				Effect = FX.Shield,
				EffectPower = 60,
				EffectDuration = 8,
				VFX = "Blessing",
				Description = "Накладывает защитный щит на союзников рядом.",
			},
			{
				Id = "Heal_Sanctuary",
				Name = "Sanctuary",
				Slot = "Ultimate",
				Damage = -80,
				Cooldown = 60,
				ManaCost = 80,
				Range = 0,
				AreaOfEffect = 24,
				CastType = "Self",
				Effect = FX.Shield,
				EffectPower = 100,
				EffectDuration = 10,
				VFX = "Sanctuary",
				Description = "Массовое лечение и щит для всего отряда.",
			},
		},
	},

	--------------------------------------------------------------------------
	Necromancy = {
		Id = "Necromancy",
		Name = "Книга Некромантии",
		Element = "Shadow",
		Role = "Summoner / Debuff",
		UnlockCost = 250,
		Description = "Призыв миньонов и ослабление врагов.",
		Spells = {
			{
				Id = "Necro_Bolt",
				Name = "Shadow Bolt",
				Slot = "Basic",
				Damage = 11,
				Cooldown = 0.6,
				ManaCost = 0,
				Range = 45,
				AreaOfEffect = 0,
				CastType = "Projectile",
				Effect = FX.Weaken,
				EffectPower = 0.15,
				EffectDuration = 3,
				VFX = "ShadowBolt",
				Description = "Тёмный снаряд, ослабляющий врага.",
			},
			{
				Id = "Necro_Raise",
				Name = "Raise Skeleton",
				Slot = "Q",
				Damage = 0,
				Cooldown = 12,
				ManaCost = 35,
				Range = 20,
				AreaOfEffect = 0,
				CastType = "Summon",
				SummonId = "SkeletonMinion",
				SummonCount = 2,
				VFX = "RaiseDead",
				Description = "Призывает скелетов, атакующих врагов.",
			},
			{
				Id = "Necro_Curse",
				Name = "Curse of Weakness",
				Slot = "E",
				Damage = 6,
				Cooldown = 8,
				ManaCost = 30,
				Range = 40,
				AreaOfEffect = 12,
				CastType = "AreaTarget",
				Effect = FX.Weaken,
				EffectPower = 0.35,
				EffectDuration = 6,
				VFX = "CurseCloud",
				Description = "Проклятие зоны: враги наносят меньше урона.",
			},
			{
				Id = "Necro_Army",
				Name = "Army of the Dead",
				Slot = "Ultimate",
				Damage = 0,
				Cooldown = 65,
				ManaCost = 80,
				Range = 25,
				AreaOfEffect = 0,
				CastType = "Summon",
				SummonId = "SkeletonMinion",
				SummonCount = 6,
				VFX = "ArmyOfDead",
				Description = "Поднимает целую армию скелетов на 20 секунд.",
			},
		},
	},
}

-- Public API ------------------------------------------------------------------

SpellbookModule.Books = Books

--[[ Returns the spellbook data table for an id, or nil. ]]
function SpellbookModule.getBook(bookId: string): Spellbook?
	return Books[bookId]
end

--[[ Returns a flat lookup of every spell keyed by Spell.Id. Built lazily. ]]
local spellIndex: { [string]: Spell }? = nil
function SpellbookModule.getSpellById(spellId: string): Spell?
	if not spellIndex then
		local index: { [string]: Spell } = {}
		for _, book in Books do
			for _, spell in book.Spells do
				assert(index[spell.Id] == nil, "Duplicate spell id: " .. spell.Id)
				index[spell.Id] = spell
			end
		end
		spellIndex = index
	end
	return (spellIndex :: { [string]: Spell })[spellId]
end

--[[ True if `spellId` belongs to `bookId`. Used by the server to reject casts
     of spells the player has not equipped. ]]
function SpellbookModule.bookHasSpell(bookId: string, spellId: string): boolean
	local book = Books[bookId]
	if not book then
		return false
	end
	for _, spell in book.Spells do
		if spell.Id == spellId then
			return true
		end
	end
	return false
end

--[[ Ordered list of book ids for lobby menus. ]]
function SpellbookModule.getBookIds(): { string }
	local ids = {}
	for id in Books do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

return SpellbookModule
