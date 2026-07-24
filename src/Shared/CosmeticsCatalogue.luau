--!strict
--[[
	CosmeticsCatalogue
	------------------
	Каталог косметики: ауры и головные уборы, а также цвета роб по стихиям.

	Data only. Two layers:

	  1. Class looks — a robe / mantle / spellbook prop tinted by the equipped
	     book's element. Free and automatic: your class always reads at a glance.
	  2. Unlockables — auras and hats bought with Essence (the meta currency),
	     persisted on the profile and equipped from the lobby panel.

	Everything is built from primitives at runtime (see CosmeticsService), so no
	uploaded meshes or textures are required. Swap `Shape`/colour fields for real
	Accessory asset ids when you have them.
]]

local CosmeticsCatalogue = {}

export type AuraEntry = {
	Id: string,
	Name: string,
	Color: Color3,
	SecondaryColor: Color3,
	Cost: number, -- essence; 0 = owned by everyone
	Rate: number, -- particles per second
	Description: string,
}

export type HatEntry = {
	Id: string,
	Name: string,
	Shape: string, -- "Hood" | "Wizard" | "Circlet" | "Crown"
	Color: Color3,
	Cost: number,
	Description: string,
}

-- Robe / mantle tint per spellbook element. Keyed by Spellbook.Element.
CosmeticsCatalogue.ElementColors = {
	Fire = Color3.fromRGB(178, 58, 32),
	Ice = Color3.fromRGB(84, 150, 196),
	Earth = Color3.fromRGB(122, 96, 62),
	Lightning = Color3.fromRGB(196, 176, 62),
	Holy = Color3.fromRGB(214, 196, 140),
	Shadow = Color3.fromRGB(86, 56, 118),
} :: { [string]: Color3 }

CosmeticsCatalogue.DefaultElementColor = Color3.fromRGB(120, 120, 150)

-- Auras -----------------------------------------------------------------------

CosmeticsCatalogue.AuraOrder = { "None", "Ember", "Frost", "Storm", "Verdant", "Radiant", "Void" }

CosmeticsCatalogue.Auras = {
	None = {
		Id = "None",
		Name = "Без ауры",
		Color = Color3.fromRGB(255, 255, 255),
		SecondaryColor = Color3.fromRGB(255, 255, 255),
		Cost = 0,
		Rate = 0,
		Description = "Ничего лишнего.",
	},
	Ember = {
		Id = "Ember",
		Name = "Тлеющие угли",
		Color = Color3.fromRGB(255, 140, 50),
		SecondaryColor = Color3.fromRGB(255, 60, 20),
		Cost = 0,
		Rate = 14,
		Description = "Искры, поднимающиеся от земли.",
	},
	Frost = {
		Id = "Frost",
		Name = "Иней",
		Color = Color3.fromRGB(180, 235, 255),
		SecondaryColor = Color3.fromRGB(110, 190, 255),
		Cost = 120,
		Rate = 12,
		Description = "Кристаллы льда, кружащие вокруг вас.",
	},
	Storm = {
		Id = "Storm",
		Name = "Гроза",
		Color = Color3.fromRGB(240, 240, 160),
		SecondaryColor = Color3.fromRGB(150, 180, 255),
		Cost = 160,
		Rate = 18,
		Description = "Потрескивающие разряды статики.",
	},
	Verdant = {
		Id = "Verdant",
		Name = "Цветение",
		Color = Color3.fromRGB(150, 240, 150),
		SecondaryColor = Color3.fromRGB(90, 190, 120),
		Cost = 160,
		Rate = 10,
		Description = "Живые споры и лепестки.",
	},
	Radiant = {
		Id = "Radiant",
		Name = "Сияние",
		Color = Color3.fromRGB(255, 245, 200),
		SecondaryColor = Color3.fromRGB(255, 215, 120),
		Cost = 240,
		Rate = 16,
		Description = "Золотой свет, льющийся вверх.",
	},
	Void = {
		Id = "Void",
		Name = "Пустота",
		Color = Color3.fromRGB(150, 90, 220),
		SecondaryColor = Color3.fromRGB(40, 20, 60),
		Cost = 320,
		Rate = 20,
		Description = "Тёмный дым и обрывки душ.",
	},
} :: { [string]: AuraEntry }

-- Hats ------------------------------------------------------------------------

CosmeticsCatalogue.HatOrder = { "None", "Hood", "Wizard", "Circlet", "Crown" }

CosmeticsCatalogue.Hats = {
	None = {
		Id = "None",
		Name = "Без головного убора",
		Shape = "None",
		Color = Color3.fromRGB(255, 255, 255),
		Cost = 0,
		Description = "Открытая голова.",
	},
	Hood = {
		Id = "Hood",
		Name = "Капюшон",
		Shape = "Hood",
		Color = Color3.fromRGB(60, 58, 72),
		Cost = 0,
		Description = "Простой капюшон под цвет робы.",
	},
	Wizard = {
		Id = "Wizard",
		Name = "Шляпа мага",
		Shape = "Wizard",
		Color = Color3.fromRGB(70, 60, 120),
		Cost = 140,
		Description = "Классический остроконечный колпак.",
	},
	Circlet = {
		Id = "Circlet",
		Name = "Обруч архимага",
		Shape = "Circlet",
		Color = Color3.fromRGB(220, 200, 130),
		Cost = 220,
		Description = "Тонкий золотой обруч.",
	},
	Crown = {
		Id = "Crown",
		Name = "Корона стихий",
		Shape = "Crown",
		Color = Color3.fromRGB(240, 220, 160),
		Cost = 400,
		Description = "Корона, светящаяся цветом вашей книги.",
	},
} :: { [string]: HatEntry }

-- Lookup ----------------------------------------------------------------------

--[[ Returns the catalogue entry for a cosmetic, or nil.
     @param kind "Aura" | "Hat" ]]
function CosmeticsCatalogue.get(kind: string, id: string): any?
	if kind == "Aura" then
		return CosmeticsCatalogue.Auras[id]
	elseif kind == "Hat" then
		return CosmeticsCatalogue.Hats[id]
	end
	return nil
end

--[[ Ordered ids for a cosmetic kind (drives the lobby list). ]]
function CosmeticsCatalogue.order(kind: string): { string }
	if kind == "Aura" then
		return CosmeticsCatalogue.AuraOrder
	elseif kind == "Hat" then
		return CosmeticsCatalogue.HatOrder
	end
	return {}
end

--[[ Robe tint for a spellbook element. ]]
function CosmeticsCatalogue.colorForElement(element: string): Color3
	return CosmeticsCatalogue.ElementColors[element] or CosmeticsCatalogue.DefaultElementColor
end

return CosmeticsCatalogue
