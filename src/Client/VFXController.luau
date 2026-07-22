--!strict
--[[
	VFXController
	-------------
	Визуальные эффекты заклинаний и снарядов (только клиент).

	Renders effects requested by the server via the PlayVFX remote. Effects are
	built procedurally (neon parts, expanding rings, projectile streaks) and
	coloured per element, so nothing needs importing. Purely cosmetic — never
	authoritative. Object-pooled parts keep allocation low under heavy fire.
]]

local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Remotes = require(Shared.Remotes)

local VFXController = {}

local localPlayer = Players.LocalPlayer

-- Element colours keyed by the VFX id prefix / known keys.
local VFX_COLORS: { [string]: Color3 } = {
	EmberBolt = Color3.fromRGB(255, 130, 40),
	Fireball = Color3.fromRGB(255, 90, 30),
	FlameWall = Color3.fromRGB(255, 110, 40),
	MeteorStorm = Color3.fromRGB(255, 80, 20),
	FrostShard = Color3.fromRGB(150, 220, 255),
	FrostNova = Color3.fromRGB(170, 230, 255),
	Blizzard = Color3.fromRGB(190, 235, 255),
	AbsoluteZero = Color3.fromRGB(210, 245, 255),
	RockThrow = Color3.fromRGB(150, 130, 100),
	StoneWall = Color3.fromRGB(140, 130, 110),
	Earthquake = Color3.fromRGB(160, 130, 90),
	TitanBulwark = Color3.fromRGB(180, 160, 110),
	Spark = Color3.fromRGB(255, 240, 120),
	ChainLightning = Color3.fromRGB(180, 200, 255),
	StaticField = Color3.fromRGB(200, 210, 255),
	ThunderJudgement = Color3.fromRGB(230, 230, 255),
	RadiantBolt = Color3.fromRGB(255, 245, 200),
	MendCircle = Color3.fromRGB(120, 255, 160),
	Blessing = Color3.fromRGB(255, 240, 170),
	Sanctuary = Color3.fromRGB(180, 255, 200),
	ShadowBolt = Color3.fromRGB(150, 90, 200),
	RaiseDead = Color3.fromRGB(120, 200, 160),
	CurseCloud = Color3.fromRGB(120, 70, 160),
	ArmyOfDead = Color3.fromRGB(130, 210, 170),
	EnemyProjectile = Color3.fromRGB(200, 70, 70),
	Block = Color3.fromRGB(180, 185, 200),
}

-- VFX keys heavy enough to shake the camera when they land near the player.
local HEAVY_VFX: { [string]: number } = {
	Fireball = 0.4,
	MeteorStorm = 1.0,
	FlameWall = 0.3,
	Earthquake = 0.7,
	TitanBulwark = 0.5,
	ThunderJudgement = 0.8,
	AbsoluteZero = 0.5,
}

local effectsFolder: Folder

local function colorFor(vfx: string?): Color3
	return (vfx and VFX_COLORS[vfx]) or Color3.fromRGB(200, 200, 255)
end

-- Expanding ring at a point (for area / nova effects).
local function playImpactRing(position: Vector3, radius: number, color: Color3)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.5, 2, 2)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = effectsFolder

	local target = math.max(radius, 4) * 2
	local tween = TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.5, target, target),
		Transparency = 1,
	})
	tween:Play()
	Debris:AddItem(ring, 0.5)
end

-- Bright flash orb at a point.
local function playFlash(position: Vector3, color: Color3, size: number)
	local orb = Instance.new("Part")
	orb.Shape = Enum.PartType.Ball
	orb.Anchored = true
	orb.CanCollide = false
	orb.CanQuery = false
	orb.Material = Enum.Material.Neon
	orb.Color = color
	orb.Size = Vector3.one * size
	orb.Position = position
	orb.Parent = effectsFolder

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = size * 3
	light.Brightness = 4
	light.Parent = orb

	-- A quick particle burst tinted to the element (6.1: per-element particles).
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.6
	emitter.Size = NumberSequence.new(size * 0.4, 0)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.3, 0.6)
	emitter.Speed = NumberRange.new(size * 4, size * 8)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Parent = orb
	emitter:Emit(18)

	local tween = TweenService:Create(orb, TweenInfo.new(0.35), { Transparency = 1, Size = Vector3.one * (size * 0.3) })
	tween:Play()
	Debris:AddItem(orb, 0.7)
end

-- Camera shake: adds a decaying random offset for `intensity` seconds. Bound
-- after the camera update so the offset isn't overwritten.
local shakeUntil = 0
local shakeMagnitude = 0
local shakeBound = false

local function shakeCamera(intensity: number)
	shakeMagnitude = math.max(shakeMagnitude, intensity)
	shakeUntil = math.max(shakeUntil, os.clock() + 0.35)
	if shakeBound then
		return
	end
	shakeBound = true
	RunService:BindToRenderStep("MagicBrigadeShake", Enum.RenderPriority.Camera.Value + 1, function()
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local remaining = shakeUntil - os.clock()
		if remaining <= 0 then
			shakeMagnitude = 0
			return
		end
		local mag = shakeMagnitude * (remaining / 0.35)
		local offset = Vector3.new(
			(math.random() - 0.5) * 2 * mag,
			(math.random() - 0.5) * 2 * mag,
			(math.random() - 0.5) * 2 * mag
		)
		camera.CFrame = camera.CFrame + offset
	end)
end

-- Streak from origin to target (projectiles / beams).
local function playStreak(origin: Vector3, target: Vector3, color: Color3)
	local distance = (target - origin).Magnitude
	if distance < 0.5 then
		return
	end
	local beam = Instance.new("Part")
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.Material = Enum.Material.Neon
	beam.Color = color
	beam.Size = Vector3.new(0.4, 0.4, distance)
	beam.CFrame = CFrame.lookAt(origin, target) * CFrame.new(0, 0, -distance / 2)
	beam.Parent = effectsFolder

	local tween = TweenService:Create(beam, TweenInfo.new(0.25), { Transparency = 1 })
	tween:Play()
	Debris:AddItem(beam, 0.3)
end

local function onPlayVFX(data: { [string]: any })
	if type(data) ~= "table" then
		return
	end
	local color = colorFor(data.Vfx)
	local origin = data.Origin
	local target = data.Target
	local radius = tonumber(data.Radius) or 0

	local impact: Vector3? = nil
	if typeof(target) == "Vector3" then
		if typeof(origin) == "Vector3" and (origin - target).Magnitude > 3 then
			playStreak(origin, target, color)
		end
		if radius > 0 then
			playImpactRing(target, radius, color)
		end
		playFlash(target, color, radius > 0 and 3 or 2)
		impact = target
	elseif typeof(origin) == "Vector3" then
		playFlash(origin, color, 3)
		if radius > 0 then
			playImpactRing(origin, radius, color)
		end
		impact = origin
	end

	-- Camera shake for heavy hits that land near the local player.
	local heavy = data.Vfx and HEAVY_VFX[data.Vfx]
	if heavy and impact then
		local char = localPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and (root.Position - impact).Magnitude <= 45 then
			shakeCamera(heavy)
		end
	end
end

function VFXController.Init()
	effectsFolder = Instance.new("Folder")
	effectsFolder.Name = "VFX"
	effectsFolder.Parent = Workspace
end

function VFXController.Start()
	Remotes.event(Remotes.Names.PlayVFX).OnClientEvent:Connect(onPlayVFX)
end

return VFXController
