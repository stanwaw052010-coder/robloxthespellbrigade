--!strict
--[[
	CosmeticsService
	----------------
	Внешний вид персонажа: роба по классу, книга в руке, головной убор и аура.

	Builds every character prop procedurally from primitives and welds it to the
	avatar, so the game needs no uploaded meshes or Accessory assets:

	  • Robe + mantle — tinted by the equipped spellbook's element, so you can
	    read a teammate's class across the arena (§6.1).
	  • Spellbook prop — a "hero prop" held in the off hand, glowing in the
	    element colour.
	  • Hat — hood / wizard hat / circlet / crown, bought with Essence.
	  • Aura — a ParticleEmitter cosmetic, also bought with Essence.

	Props are additive: the player's own avatar is never recoloured or stripped,
	so purchased Roblox items still show. Everything lives under one folder in
	the character, rebuilt wholesale whenever the look changes.

	Purchases are validated here (server-authoritative); the client only ever
	asks to unlock or equip by id.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local CosmeticsCatalogue = require(Shared.CosmeticsCatalogue)
local Remotes = require(Shared.Remotes)
local SpellbookModule = require(Shared.SpellbookModule)

local EconomyService = require(script.Parent.EconomyService)
local PlayerDataService = require(script.Parent.PlayerDataService)

local CosmeticsService = {}

local FOLDER_NAME = "MagicBrigadeCosmetics"
local VALID_KINDS = { Aura = true, Hat = true }

-- Rig helpers -----------------------------------------------------------------

--[[ Finds a limb by its R15 name, falling back to the R6 equivalent, so the
     props weld correctly whichever rig the player is using. ]]
local function findLimb(character: Model, r15Name: string, r6Name: string): BasePart?
	local part = character:FindFirstChild(r15Name) or character:FindFirstChild(r6Name)
	return part and part:IsA("BasePart") and part or nil
end

--[[ Creates a cosmetic part welded to `anchor` at a local offset.

     A WeldConstraint captures the relative offset at the moment it is created,
     so the part is fully placed — position, rotation and shape — BEFORE the
     weld exists. Callers must not move the part afterwards.

     Cosmetic parts are massless and non-colliding so they never disturb
     movement or block raycasts.

     @param offset CFrame -- local to `anchor`, rotation included
     @param shape  Enum.PartType? -- defaults to Block
]]
local function attachPart(
	parent: Instance,
	anchor: BasePart,
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	material: Enum.Material,
	shape: Enum.PartType?
): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Shape = shape or Enum.PartType.Block
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Anchored = false
	part.CFrame = anchor.CFrame * offset
	part.Parent = parent

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = part
	weld.Parent = part

	return part
end

-- Cylinder primitives are built along their X axis; this stands them upright.
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

-- Prop builders ---------------------------------------------------------------

local function buildRobe(folder: Folder, character: Model, color: Color3)
	local torso = findLimb(character, "LowerTorso", "Torso")
	if not torso then
		return
	end

	-- Skirt of the robe: a wide cylinder hanging below the torso.
	local skirt = attachPart(
		folder,
		torso,
		"Robe",
		Vector3.new(2.4, 2.6, 2.6),
		CFrame.new(0, -1.1, 0) * UPRIGHT,
		color,
		Enum.Material.Fabric,
		Enum.PartType.Cylinder
	)
	skirt.Transparency = 0.05

	local upper = findLimb(character, "UpperTorso", "Torso")
	if upper then
		-- Shoulder mantle, slightly brighter than the robe for contrast.
		attachPart(
			folder,
			upper,
			"Mantle",
			Vector3.new(2.5, 0.5, 1.4),
			CFrame.new(0, 0.75, 0),
			color:Lerp(Color3.new(1, 1, 1), 0.25),
			Enum.Material.Fabric
		)
	end
end

local function buildSpellbook(folder: Folder, character: Model, color: Color3)
	local hand = findLimb(character, "LeftHand", "Left Arm")
	if not hand then
		return
	end

	local offset = CFrame.new(0, -0.6, -0.4) * CFrame.Angles(math.rad(-20), 0, 0)
	local book = attachPart(
		folder,
		hand,
		"Spellbook",
		Vector3.new(1.1, 0.28, 0.9),
		offset,
		Color3.fromRGB(48, 36, 30),
		Enum.Material.Wood
	)

	-- Glowing pages: the element colour is the readable class tell.
	local pages = attachPart(
		folder,
		book,
		"Pages",
		Vector3.new(1.0, 0.12, 0.8),
		CFrame.new(0, 0.14, 0),
		color,
		Enum.Material.Neon
	)

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 8
	light.Brightness = 1.5
	light.Parent = pages
end

local function buildHat(folder: Folder, character: Model, hat: CosmeticsCatalogue.HatEntry, elementColor: Color3)
	if hat.Shape == "None" then
		return
	end
	local head = findLimb(character, "Head", "Head")
	if not head then
		return
	end

	if hat.Shape == "Hood" then
		-- A hood reads as the robe continuing over the head, so it takes the
		-- element tint rather than the catalogue colour.
		local hood = attachPart(
			folder,
			head,
			"Hood",
			Vector3.new(1.5, 1.3, 1.5),
			CFrame.new(0, 0.25, 0.1),
			elementColor,
			Enum.Material.Fabric,
			Enum.PartType.Ball
		)
		hood.Transparency = 0.05
	elseif hat.Shape == "Wizard" then
		attachPart(
			folder,
			head,
			"HatBrim",
			Vector3.new(0.16, 2.2, 2.2),
			CFrame.new(0, 0.6, 0) * UPRIGHT,
			hat.Color,
			Enum.Material.Fabric,
			Enum.PartType.Cylinder
		)
		attachPart(
			folder,
			head,
			"HatCone",
			Vector3.new(1.8, 1.2, 1.2),
			CFrame.new(0, 1.5, 0) * UPRIGHT,
			hat.Color,
			Enum.Material.Fabric,
			Enum.PartType.Cylinder
		)
	elseif hat.Shape == "Circlet" then
		attachPart(
			folder,
			head,
			"Circlet",
			Vector3.new(0.18, 1.35, 1.35),
			CFrame.new(0, 0.55, 0) * UPRIGHT,
			hat.Color,
			Enum.Material.Metal,
			Enum.PartType.Cylinder
		)
	elseif hat.Shape == "Crown" then
		attachPart(
			folder,
			head,
			"CrownBand",
			Vector3.new(0.35, 1.4, 1.4),
			CFrame.new(0, 0.7, 0) * UPRIGHT,
			hat.Color,
			Enum.Material.Metal,
			Enum.PartType.Cylinder
		)
		-- Five points around the band, glowing in the caster's element.
		for i = 1, 5 do
			local angle = (i - 1) * (math.pi * 2 / 5)
			attachPart(
				folder,
				head,
				"CrownPoint" .. i,
				Vector3.new(0.16, 0.5, 0.16),
				CFrame.new(math.cos(angle) * 0.6, 1.05, math.sin(angle) * 0.6),
				elementColor,
				Enum.Material.Neon
			)
		end
	end
end

local function buildAura(folder: Folder, character: Model, aura: CosmeticsCatalogue.AuraEntry)
	if aura.Rate <= 0 then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	-- The emitter needs a host that lives in the cosmetics folder so clearing
	-- the folder tears the aura down with it.
	local host = attachPart(
		folder,
		root,
		"AuraHost",
		Vector3.new(0.2, 0.2, 0.2),
		CFrame.new(0, -1.4, 0),
		aura.Color,
		Enum.Material.Neon
	)
	host.Transparency = 1

	local attachment = Instance.new("Attachment")
	attachment.Parent = host

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(aura.Color, aura.SecondaryColor)
	emitter.LightEmission = 0.7
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.7, 1.3)
	emitter.Rate = aura.Rate
	emitter.Speed = NumberRange.new(1.5, 3)
	emitter.SpreadAngle = Vector2.new(25, 25)
	emitter.Acceleration = Vector3.new(0, 4, 0)
	emitter.Parent = attachment
end

-- Application -----------------------------------------------------------------

--[[ Rebuilds every prop on a character from the player's current profile.
     Safe to call repeatedly — the old folder is destroyed first. ]]
function CosmeticsService.apply(player: Player)
	local character = player.Character
	if not character or not character.Parent then
		return
	end
	local profile = PlayerDataService.get(player)
	if not profile then
		return
	end

	local existing = character:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end

	local book = SpellbookModule.getBook(profile.SelectedBook)
	local elementColor = CosmeticsCatalogue.colorForElement(book and book.Element or "")

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = character

	local hatId = profile.Cosmetics.Hat or "None"
	local auraId = profile.Cosmetics.Aura or "None"
	local hat = CosmeticsCatalogue.Hats[hatId] or CosmeticsCatalogue.Hats.None
	local aura = CosmeticsCatalogue.Auras[auraId] or CosmeticsCatalogue.Auras.None

	-- Each builder is independent; one failing rig lookup must not cost the
	-- player the rest of their look.
	local builders = {
		function()
			buildRobe(folder, character, elementColor)
		end,
		function()
			buildSpellbook(folder, character, elementColor)
		end,
		function()
			buildHat(folder, character, hat, elementColor)
		end,
		function()
			buildAura(folder, character, aura)
		end,
	}
	for _, build in builders do
		local ok: boolean, err: any = pcall(build)
		if not ok then
			warn("[CosmeticsService] prop build failed: " .. tostring(err))
		end
	end
end

-- Purchase / equip ------------------------------------------------------------

--[[ True if the player may equip this cosmetic (free items are always owned). ]]
local function owns(profile: any, kind: string, id: string): boolean
	local entry = CosmeticsCatalogue.get(kind, id)
	if not entry then
		return false
	end
	if entry.Cost <= 0 then
		return true
	end
	return profile.UnlockedCosmetics[kind .. ":" .. id] == true
end

local function handleRequest(player: Player, payload: any)
	if type(payload) ~= "table" or type(payload.Kind) ~= "string" or type(payload.Id) ~= "string" then
		return { Ok = false, Message = "Некорректный запрос" }
	end
	if not VALID_KINDS[payload.Kind] then
		return { Ok = false, Message = "Неизвестный тип косметики" }
	end

	local entry = CosmeticsCatalogue.get(payload.Kind, payload.Id)
	if not entry then
		return { Ok = false, Message = "Такой косметики нет" }
	end

	local profile = PlayerDataService.get(player)
	if not profile then
		return { Ok = false, Message = "Профиль не загружен" }
	end

	if payload.Action == "unlock" then
		if owns(profile, payload.Kind, payload.Id) then
			return { Ok = false, Message = "Уже разблокировано" }
		end
		if not EconomyService.trySpendEssence(player, entry.Cost) then
			return { Ok = false, Message = "Недостаточно эссенции" }
		end
		PlayerDataService.unlockCosmetic(player, payload.Kind, payload.Id)
		return { Ok = true, Message = ("Разблокировано: %s"):format(entry.Name) }
	end

	-- equip
	if not owns(profile, payload.Kind, payload.Id) then
		return { Ok = false, Message = "Сначала разблокируйте" }
	end
	PlayerDataService.setCosmetic(player, payload.Kind, payload.Id)
	return { Ok = true, Message = ("Надето: %s"):format(entry.Name) }
end

-- Lifecycle -------------------------------------------------------------------

function CosmeticsService.Init() end

function CosmeticsService.Start()
	local function hookPlayer(player: Player)
		player.CharacterAppearanceLoaded:Connect(function()
			-- Wait for the avatar's own parts to settle before welding onto them.
			task.wait(0.2)
			CosmeticsService.apply(player)
		end)
		if player.Character then
			task.defer(CosmeticsService.apply, player)
		end
	end
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)

	-- Rebuild when the equipped book or a cosmetic changes.
	PlayerDataService.AppearanceChanged:Connect(function(player: Player)
		CosmeticsService.apply(player)
	end)
	-- Profiles can load after the character spawns; catch that ordering too.
	PlayerDataService.ProfileLoaded:Connect(function(player: Player)
		CosmeticsService.apply(player)
	end)

	Remotes.func(Remotes.Names.CosmeticRequest).OnServerInvoke = function(player: Player, payload: any)
		return handleRequest(player, payload)
	end
end

return CosmeticsService
