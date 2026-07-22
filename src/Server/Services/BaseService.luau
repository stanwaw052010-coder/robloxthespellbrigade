--!strict
--[[
	BaseService
	-----------
	Объект-цель (портал), здоровье базы, арена и точки спавна.

	Owns the objective the party defends: the portal/core and its health. It
	also builds a simple playable arena procedurally (floor, portal, spawn pads,
	player spawn) so the game is runnable the moment you sync it — no external
	map assets required. Swap the generated arena for a designed map later.
]]

local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage").Shared
local GameConfig = require(Shared.GameConfig)
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)

local BaseService = {}

BaseService.BaseDestroyed = Signal.new() -- fires once when base health hits 0
BaseService.BaseDamaged = Signal.new() -- (newHealth, maxHealth)

local ARENA_RADIUS = 120
local SPAWN_POINT_COUNT = 8

local health = GameConfig.Base.MaxHealth
local destroyed = false
local portal: BasePart? = nil
local spawnPoints: { Vector3 } = {}
local arenaFolder: Folder? = nil

local function broadcast()
	Remotes.event(Remotes.Names.BaseHealthChanged):FireAllClients({
		Health = health,
		MaxHealth = GameConfig.Base.MaxHealth,
	})
end

-- Arena construction ----------------------------------------------------------

local function buildArena()
	local folder = Instance.new("Folder")
	folder.Name = "Arena"

	-- NOTE: the ground floor and the player SpawnLocation are STATIC instances
	-- declared in default.project.json so they exist from the very first frame
	-- (before any script runs). That guarantees players never spawn into the
	-- void while this arena is being built. Here we only add the gameplay props.

	-- Central portal (the objective).
	local portalPart = Instance.new("Part")
	portalPart.Name = "Portal"
	portalPart.Anchored = true
	portalPart.Shape = Enum.PartType.Cylinder
	portalPart.Size = Vector3.new(2, 16, 16)
	portalPart.CFrame = CFrame.new(0, 8, 0) * CFrame.Angles(0, 0, math.rad(90))
	portalPart.Material = Enum.Material.Neon
	portalPart.Color = Color3.fromRGB(120, 180, 255)
	portalPart.Transparency = 0.2
	portalPart.CanCollide = false
	portalPart.Parent = folder

	local light = Instance.new("PointLight")
	light.Range = 40
	light.Brightness = 3
	light.Color = portalPart.Color
	light.Parent = portalPart

	-- A base under the portal for pathfinding to aim at and enemies to hit.
	local core = Instance.new("Part")
	core.Name = "Core"
	core.Anchored = true
	core.Size = Vector3.new(10, 4, 10)
	core.Position = Vector3.new(0, 2, 0)
	core.Material = Enum.Material.Slate
	core.Color = Color3.fromRGB(90, 90, 110)
	core.Parent = folder

	-- Enemy spawn pads evenly around the perimeter.
	for i = 1, SPAWN_POINT_COUNT do
		local angle = (i - 1) * (2 * math.pi / SPAWN_POINT_COUNT)
		local pos = Vector3.new(math.cos(angle) * ARENA_RADIUS, 1, math.sin(angle) * ARENA_RADIUS)
		spawnPoints[i] = pos

		local pad = Instance.new("Part")
		pad.Name = "SpawnPad_" .. i
		pad.Anchored = true
		pad.Size = Vector3.new(10, 0.4, 10)
		pad.Position = pos - Vector3.new(0, 0.8, 0)
		pad.Material = Enum.Material.Neon
		pad.Color = Color3.fromRGB(180, 70, 70)
		pad.Transparency = 0.4
		pad.CanCollide = false
		pad.Parent = folder
	end

	folder.Parent = Workspace
	arenaFolder = folder
	portal = portalPart
end

-- Public API ------------------------------------------------------------------

function BaseService.getPortalPosition(): Vector3
	return portal and portal.Position or Vector3.new(0, 2, 0)
end

function BaseService.getSpawnPoints(): { Vector3 }
	return spawnPoints
end

--[[ Returns a random enemy spawn position. ]]
function BaseService.randomSpawnPoint(): Vector3
	if #spawnPoints == 0 then
		return Vector3.new(0, 1, ARENA_RADIUS)
	end
	return spawnPoints[math.random(1, #spawnPoints)]
end

function BaseService.getHealth(): number
	return health
end

function BaseService.isDestroyed(): boolean
	return destroyed
end

--[[ Enemies call this when they reach the portal. ]]
function BaseService.damageBase(amount: number)
	if destroyed or amount <= 0 then
		return
	end
	health = math.max(0, health - amount)
	broadcast()
	BaseService.BaseDamaged:Fire(health, GameConfig.Base.MaxHealth)
	if health <= 0 then
		destroyed = true
		BaseService.BaseDestroyed:Fire()
	end
end

function BaseService.repairBase(amount: number)
	if destroyed then
		return
	end
	health = math.min(GameConfig.Base.MaxHealth, health + amount)
	broadcast()
end

--[[ Full reset for a new match. ]]
function BaseService.reset()
	health = GameConfig.Base.MaxHealth
	destroyed = false
	broadcast()
end

-- Lifecycle -------------------------------------------------------------------

function BaseService.Init()
	buildArena()
end

function BaseService.Start()
	broadcast()
end

return BaseService
