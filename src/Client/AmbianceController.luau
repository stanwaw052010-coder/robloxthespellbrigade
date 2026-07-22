--!strict
--[[
	AmbianceController
	------------------
	Освещение и пост-обработка в стиле тёмного фэнтези (раздел 6.1).

	Sets up the "stylized dark fantasy" look on the client: Future lighting for
	real-time shadows + bloom, a bluish night ambient, atmosphere for depth, and
	post-processing (Bloom, ColorCorrection, DepthOfField). Depth of field is
	softened in the lobby/intermission and switched OFF during combat so it never
	interferes with aiming (per the design doc).
]]

local Lighting = game:GetService("Lighting")

local Shared = game:GetService("ReplicatedStorage").Shared
local Remotes = require(Shared.Remotes)

local AmbianceController = {}

local dof: DepthOfFieldEffect

local function ensure(className: string, name: string): Instance
	local existing = Lighting:FindFirstChild(name)
	if existing then
		return existing
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = Lighting
	return inst
end

function AmbianceController.Init()
	-- Core lighting: Future tech gives us shadows + glow for spell VFX.
	Lighting.Technology = Enum.Technology.Future
	Lighting.Brightness = 2
	Lighting.ClockTime = 18.5 -- dusk
	Lighting.GeographicLatitude = 20
	Lighting.Ambient = Color3.fromRGB(60, 66, 90)
	Lighting.OutdoorAmbient = Color3.fromRGB(70, 78, 105)
	Lighting.EnvironmentDiffuseScale = 0.5
	Lighting.EnvironmentSpecularScale = 0.4
	Lighting.ShadowSoftness = 0.5
	Lighting.FogEnd = 900

	-- Atmosphere for depth and a moody haze.
	local atmosphere = ensure("Atmosphere", "Atmosphere") :: Atmosphere
	atmosphere.Density = 0.32
	atmosphere.Offset = 0.1
	atmosphere.Haze = 1.6
	atmosphere.Glare = 0.2
	atmosphere.Color = Color3.fromRGB(190, 195, 215)
	atmosphere.Decay = Color3.fromRGB(80, 90, 120)

	-- Post-processing.
	local bloom = ensure("BloomEffect", "MagicBloom") :: BloomEffect
	bloom.Intensity = 1.1
	bloom.Size = 24
	bloom.Threshold = 1.1

	local cc = ensure("ColorCorrectionEffect", "MagicColorCorrection") :: ColorCorrectionEffect
	cc.Brightness = 0.02
	cc.Contrast = 0.12
	cc.Saturation = 0.18
	cc.TintColor = Color3.fromRGB(240, 240, 255)

	dof = ensure("DepthOfFieldEffect", "MagicDOF") :: DepthOfFieldEffect
	dof.FarIntensity = 0.15
	dof.FocusDistance = 30
	dof.InFocusRadius = 60
	dof.NearIntensity = 0
	dof.Enabled = true
end

function AmbianceController.Start()
	-- Turn depth of field off during active combat so aiming stays crisp.
	Remotes.event(Remotes.Names.WaveStateChanged).OnClientEvent:Connect(function(data)
		if not dof then
			return
		end
		dof.Enabled = data.Phase ~= "Active"
	end)
end

return AmbianceController
