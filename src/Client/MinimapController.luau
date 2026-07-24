--!strict
--[[
	MinimapController
	-----------------
	Миникарта: портал, союзники, враги и боссы (§6).

	A north-up radar in the top-right corner. Everything it draws is already
	replicated to the client — enemy models in Workspace.Enemies, other players'
	characters, the arena portal — so no extra networking is needed and nothing
	here is authoritative.

	Blips are pooled and reused between frames, and the whole thing refreshes at
	a fixed 12 Hz rather than every frame: a radar dot moving in 80 ms steps
	looks identical and costs a fraction of the work during a 40-enemy wave.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local UIKit = require(script.Parent.UIKit)

local MinimapController = {}

local localPlayer = Players.LocalPlayer

local MAP_SIZE = 168 -- pixels
local WORLD_RADIUS = 140 -- studs mapped to the map's half-width
local REFRESH_INTERVAL = 1 / 12
local MAX_BLIPS = 60 -- cap so a huge wave can't stall the UI

local COLORS = {
	Enemy = Color3.fromRGB(235, 80, 80),
	Boss = Color3.fromRGB(255, 120, 240),
	Minion = Color3.fromRGB(150, 235, 170),
	Ally = Color3.fromRGB(110, 175, 255),
	Player = Color3.fromRGB(255, 255, 255),
	Portal = Color3.fromRGB(120, 200, 255),
}

local root: Frame
local canvas: Frame
local blips: { Frame } = {}
local blipCount = 0

-- Blip pool -------------------------------------------------------------------

local function acquireBlip(): Frame
	blipCount += 1
	local blip = blips[blipCount]
	if not blip then
		blip = UIKit.frame({
			Parent = canvas,
			Color = COLORS.Enemy,
			Radius = 4,
			Size = UDim2.fromOffset(6, 6),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 3,
		})
		blips[blipCount] = blip
	end
	blip.Visible = true
	return blip
end

--[[ Hides every blip the current frame did not claim. ]]
local function releaseUnused()
	for i = blipCount + 1, #blips do
		blips[i].Visible = false
	end
end

--[[ Maps a world position to a pixel offset from the map centre, or nil when
     the point is outside the radar's range. ]]
local function project(center: Vector3, position: Vector3): (number?, number?)
	local dx = position.X - center.X
	local dz = position.Z - center.Z
	local scale = (MAP_SIZE / 2) / WORLD_RADIUS
	local px, py = dx * scale, dz * scale
	-- Circular clip: the map is round, so corners would show things that are
	-- further away than things it hides.
	if (px * px + py * py) > (MAP_SIZE / 2) ^ 2 then
		return nil, nil
	end
	return px, py
end

local function placeBlip(center: Vector3, position: Vector3, size: number, color: Color3)
	if blipCount >= MAX_BLIPS then
		return
	end
	local px, py = project(center, position)
	if not px or not py then
		return
	end
	local blip = acquireBlip()
	blip.Size = UDim2.fromOffset(size, size)
	blip.BackgroundColor3 = color
	blip.Position = UDim2.new(0.5, px, 0.5, py)
end

-- Refresh ---------------------------------------------------------------------

local function refresh()
	local character = localPlayer.Character
	local playerRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not playerRoot then
		root.Visible = false
		return
	end
	root.Visible = true

	-- The map follows the player, so their blip is always dead centre.
	local center = playerRoot.Position
	blipCount = 0

	-- Portal / objective.
	local arena = Workspace:FindFirstChild("Arena")
	local portal = arena and arena:FindFirstChild("Portal") :: BasePart?
	if portal then
		placeBlip(center, portal.Position, 12, COLORS.Portal)
	end

	-- Enemies, bosses and friendly summons.
	local enemies = Workspace:FindFirstChild("Enemies")
	if enemies then
		for _, model in enemies:GetChildren() do
			if not model:IsA("Model") then
				continue
			end
			local part = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not part then
				continue
			end
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health <= 0 then
				continue
			end

			if model:GetAttribute("IsBoss") then
				placeBlip(center, part.Position, 11, COLORS.Boss)
			elseif model:GetAttribute("IsMinion") then
				placeBlip(center, part.Position, 5, COLORS.Minion)
			else
				placeBlip(center, part.Position, 6, COLORS.Enemy)
			end
		end
	end

	-- Allies.
	for _, player in Players:GetPlayers() do
		if player == localPlayer then
			continue
		end
		local otherChar = player.Character
		local otherRoot = otherChar and otherChar:FindFirstChild("HumanoidRootPart") :: BasePart?
		if otherRoot then
			placeBlip(center, otherRoot.Position, 8, COLORS.Ally)
		end
	end

	-- The local player last so their marker sits on top.
	placeBlip(center, center, 9, COLORS.Player)

	releaseUnused()
end

-- Lifecycle -------------------------------------------------------------------

function MinimapController.mount(parent: Instance)
	root = UIKit.frame({
		Parent = parent,
		Color = UIKit.Colors.Panel,
		Transparency = 0.2,
		Size = UDim2.fromOffset(MAP_SIZE, MAP_SIZE),
		Position = UDim2.new(1, -12, 0, 12),
		AnchorPoint = Vector2.new(1, 0),
	})
	-- Round map: a circular corner radius on a square frame.
	UIKit.corner(root, MAP_SIZE // 2)
	UIKit.stroke(root, UIKit.Colors.PanelLight, 2)

	canvas = UIKit.frame({
		Parent = root,
		Transparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
	})
	-- Blips are positioned in pixels from the centre, so the canvas must clip
	-- anything that slips past the circular range check.
	canvas.ClipsDescendants = true

	-- Faint cross-hair so the radar reads as a map, not a random dot field.
	UIKit.frame({
		Parent = canvas,
		Color = UIKit.Colors.PanelLight,
		Transparency = 0.5,
		Size = UDim2.new(1, 0, 0, 1),
		Position = UDim2.fromScale(0, 0.5),
		ZIndex = 2,
	})
	UIKit.frame({
		Parent = canvas,
		Color = UIKit.Colors.PanelLight,
		Transparency = 0.5,
		Size = UDim2.new(0, 1, 1, 0),
		Position = UDim2.fromScale(0.5, 0),
		ZIndex = 2,
	})
end

function MinimapController.Init() end

function MinimapController.Start()
	local accumulated = 0
	RunService.RenderStepped:Connect(function(dt)
		accumulated += dt
		if accumulated < REFRESH_INTERVAL then
			return
		end
		accumulated = 0
		local ok: boolean, err: any = pcall(refresh)
		if not ok then
			warn("[MinimapController] refresh failed: " .. tostring(err))
		end
	end)
end

return MinimapController
