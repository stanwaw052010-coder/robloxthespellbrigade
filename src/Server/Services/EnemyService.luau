--!strict
--[[
	EnemyService
	------------
	Спавн врагов, ИИ (Pathfinding, состояния), контактный урон, миньоны.

	Spawns enemies as procedurally-built rigs (no external assets needed),
	registers them with DamageService, and drives their AI: path toward the
	portal, deal contact damage on arrival, ranged enemies fire from distance,
	bosses have phases. Also spawns player-summoned minions that hunt enemies.

	Exposes spatial queries (enemies in radius / nearest) used by
	SpellCastingService for area spells and targeting.
]]

local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local GameConfig = require(Shared.GameConfig)
local Signal = require(Shared.Signal)
local EnemyDefinitions = require(Shared.EnemyDefinitions)

local DamageService = require(script.Parent.DamageService)
local BaseService = require(script.Parent.BaseService)

type EnemyRuntime = {
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Def: any,
	IsMinion: boolean,
	Owner: Player?,
	DamageMultiplier: number,
	Alive: boolean,
	LastAttack: number,
	Phase: number,
	StuckSince: number,
	Path: Path?,
	Waypoints: { PathWaypoint },
	WaypointIndex: number,
}

local EnemyService = {}

EnemyService.EnemyRemoved = Signal.new() -- (model, wasKilledByPlayer, isMinion)

local enemiesFolder: Folder
local runtimes: { [Model]: EnemyRuntime } = {}
local aliveWaveEnemies = 0 -- excludes minions

-- Rig construction ------------------------------------------------------------

local function buildHealthbar(model: Model, humanoid: Humanoid, def: any)
	local head = model:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Healthbar"
	billboard.Size = UDim2.fromOffset(60, 8)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, def.BodySize.Y * 0.6 + 1.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	bg.BorderSizePixel = 0
	bg.Parent = billboard

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = def.IsBoss and Color3.fromRGB(200, 60, 200) or Color3.fromRGB(220, 60, 60)
	fill.BorderSizePixel = 0
	fill.Parent = bg

	humanoid.HealthChanged:Connect(function(h)
		fill.Size = UDim2.fromScale(math.clamp(h / humanoid.MaxHealth, 0, 1), 1)
	end)
end

--[[ Builds a simple humanoid rig from primitives so we need no imported assets. ]]
local function buildRig(def: any, position: Vector3): (Model, Humanoid, BasePart)
	local model = Instance.new("Model")
	model.Name = def.Id

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = def.BodySize
	root.Color = def.BodyColor
	root.Material = Enum.Material.SmoothPlastic
	root.Position = position + Vector3.new(0, def.BodySize.Y / 2, 0)
	root.Parent = model

	-- A small "head" gives us a mount point for the healthbar and some character.
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(def.BodySize.X * 0.7, def.BodySize.X * 0.7, def.BodySize.X * 0.7)
	head.Color = def.BodyColor:Lerp(Color3.new(1, 1, 1), 0.25)
	head.Material = Enum.Material.SmoothPlastic
	head.CanCollide = false
	-- Position BEFORE welding so the constraint captures the correct offset.
	head.Position = root.Position + Vector3.new(0, def.BodySize.Y / 2 + head.Size.Y / 2, 0)
	head.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = head
	weld.Parent = head

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = def.MaxHealth
	humanoid.Health = def.MaxHealth
	humanoid.WalkSpeed = def.WalkSpeed
	humanoid.DisplayName = def.Name
	-- Prevent ragdoll physics from flinging the simple rig around on death.
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model

	model.PrimaryPart = root
	return model, humanoid, root
end

-- Target selection & movement -------------------------------------------------

local function nearestPlayerRoot(position: Vector3, maxRange: number): (BasePart?, number)
	local best: BasePart? = nil
	local bestDist = maxRange
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local d = (root.Position - position).Magnitude
			if d < bestDist then
				best = root
				bestDist = d
			end
		end
	end
	return best, bestDist
end

local function computePath(rt: EnemyRuntime, goal: Vector3)
	local path = PathfindingService:CreatePath({
		AgentRadius = math.max(rt.Def.BodySize.X, rt.Def.BodySize.Z) / 2 + 1,
		AgentHeight = rt.Def.BodySize.Y,
		AgentCanJump = false,
		WaypointSpacing = 6,
	})
	local ok = pcall(function()
		path:ComputeAsync(rt.Root.Position, goal)
	end)
	if ok and path.Status == Enum.PathStatus.Success then
		rt.Path = path
		rt.Waypoints = path:GetWaypoints()
		rt.WaypointIndex = 2 -- skip the first (current position)
	else
		rt.Path = nil
		rt.Waypoints = {}
	end
end

local function moveToward(rt: EnemyRuntime, goal: Vector3)
	local humanoid = rt.Humanoid
	-- Follow a precomputed path if we have one; otherwise head straight for the
	-- goal. Straight-line is fine in the open arena; pathing handles walls.
	if rt.Waypoints and #rt.Waypoints >= rt.WaypointIndex then
		local wp = rt.Waypoints[rt.WaypointIndex]
		humanoid:MoveTo(wp.Position)
		if (rt.Root.Position - wp.Position).Magnitude < 4 then
			rt.WaypointIndex += 1
		end
	else
		humanoid:MoveTo(goal)
	end
end

-- Attacks ---------------------------------------------------------------------

local function meleeContact(rt: EnemyRuntime)
	-- Deal contact damage to the base and self-destruct (runners/fast), or keep
	-- pounding it (tanks/bosses). Also hits any player standing on the core.
	local now = os.clock()
	if now - rt.LastAttack < rt.Def.AttackCooldown then
		return
	end
	rt.LastAttack = now
	local contactDamage = (rt.Model:GetAttribute("ContactDamage") :: number?) or rt.Def.ContactDamage

	BaseService.damageBase(contactDamage)

	local archetype = rt.Def.Archetype
	if archetype == "Runner" or archetype == "Fast" then
		-- Kamikaze: remove after one hit.
		EnemyService._removeEnemy(rt.Model, false)
	end
end

local function rangedAttack(rt: EnemyRuntime, targetRoot: BasePart)
	local now = os.clock()
	if now - rt.LastAttack < rt.Def.AttackCooldown then
		return
	end
	rt.LastAttack = now
	local contactDamage = (rt.Model:GetAttribute("ContactDamage") :: number?) or rt.Def.ContactDamage
	local targetHumanoid = targetRoot.Parent and targetRoot.Parent:FindFirstChildOfClass("Humanoid")
	if targetHumanoid then
		DamageService.applyDamage(targetHumanoid, contactDamage, rt.Model)
	end
	-- Broadcast a projectile VFX so clients can render it.
	local Remotes = require(Shared.Remotes)
	Remotes.event(Remotes.Names.PlayVFX):FireAllClients({
		Vfx = "EnemyProjectile",
		Origin = rt.Root.Position,
		Target = targetRoot.Position,
	})
end

-- Boss phase transitions (speed / damage ramp as health drops).
local function updateBossPhase(rt: EnemyRuntime)
	if not rt.Def.IsBoss then
		return
	end
	local frac = rt.Humanoid.Health / rt.Humanoid.MaxHealth
	local phases = rt.Def.BossPhases or 1
	local phase = phases - math.floor(frac * phases)
	phase = math.clamp(phase, 1, phases)
	if phase > rt.Phase then
		rt.Phase = phase
		rt.Humanoid.WalkSpeed = rt.Def.WalkSpeed * (1 + 0.15 * (phase - 1))
		local Remotes = require(Shared.Remotes)
		Remotes.event(Remotes.Names.Notify):FireAllClients({
			Text = ("%s: фаза %d!"):format(rt.Def.Name, phase),
			Kind = "boss",
		})
	end
end

-- AI loops --------------------------------------------------------------------

local function runEnemyAI(rt: EnemyRuntime)
	local portalPos = BaseService.getPortalPosition()
	local repathAt = 0

	while rt.Alive and rt.Humanoid.Health > 0 and not BaseService.isDestroyed() do
		local root = rt.Root
		local pos = root.Position

		updateBossPhase(rt)

		if DamageService.isFrozen(rt.Humanoid) then
			task.wait(0.2)
			continue
		end

		if rt.Def.Archetype == "Ranged" then
			-- Prefer a player in range, otherwise close on the portal.
			local playerRoot, playerDist = nearestPlayerRoot(pos, rt.Def.AttackRange)
			local distToPortal = (pos - portalPos).Magnitude
			if playerRoot and playerDist <= rt.Def.AttackRange then
				rt.Humanoid:MoveTo(pos) -- hold position
				rangedAttack(rt, playerRoot)
			elseif distToPortal <= rt.Def.AttackRange then
				rt.Humanoid:MoveTo(pos)
				-- Fire at the core.
				BaseService.damageBase((rt.Model:GetAttribute("ContactDamage") :: number?) or rt.Def.ContactDamage)
				rt.LastAttack = os.clock()
				task.wait(rt.Def.AttackCooldown)
			else
				moveToward(rt, portalPos)
			end
		else
			-- Melee archetypes home on the portal.
			local distToPortal = (pos - portalPos).Magnitude
			if distToPortal <= (rt.Def.AttackRange > 0 and rt.Def.AttackRange or 7) then
				meleeContact(rt)
			else
				-- Occasionally repath to route around walls / when stuck.
				local now = os.clock()
				if now >= repathAt then
					computePath(rt, portalPos)
					repathAt = now + 2
				end
				moveToward(rt, portalPos)
			end
		end

		task.wait(0.25)
	end
end

local function runMinionAI(rt: EnemyRuntime)
	while rt.Alive and rt.Humanoid.Health > 0 do
		local pos = rt.Root.Position
		local target = EnemyService.getNearestEnemy(pos, 80)
		if target then
			local targetRoot = target:FindFirstChild("HumanoidRootPart") :: BasePart?
			local targetHumanoid = target:FindFirstChildOfClass("Humanoid")
			if targetRoot and targetHumanoid then
				local dist = (targetRoot.Position - pos).Magnitude
				if dist <= 6 then
					local now = os.clock()
					if now - rt.LastAttack >= rt.Def.AttackCooldown then
						rt.LastAttack = now
						DamageService.applyDamage(targetHumanoid, rt.Def.ContactDamage, rt.Owner)
					end
				else
					rt.Humanoid:MoveTo(targetRoot.Position)
				end
			end
		else
			-- Idle near owner.
			local owner = rt.Owner
			local ownerRoot = owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if ownerRoot then
				rt.Humanoid:MoveTo(ownerRoot.Position)
			end
		end
		task.wait(0.3)
	end
end

-- Spawning & removal ----------------------------------------------------------

--[[ Spawns a regular wave enemy. Returns the model. ]]
function EnemyService.spawnEnemy(enemyId: string, healthMultiplier: number, damageMultiplier: number): Model?
	local def = EnemyDefinitions.get(enemyId)
	if not def then
		warn("[EnemyService] unknown enemy id: " .. tostring(enemyId))
		return nil
	end

	local spawnPos = BaseService.randomSpawnPoint()
	local model, humanoid, root = buildRig(def, spawnPos)
	model.Parent = enemiesFolder

	DamageService.registerEnemy(model, def, healthMultiplier, damageMultiplier)
	buildHealthbar(model, humanoid, def)

	local rt: EnemyRuntime = {
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Def = def,
		IsMinion = false,
		Owner = nil,
		DamageMultiplier = damageMultiplier,
		Alive = true,
		LastAttack = 0,
		Phase = 1,
		StuckSince = 0,
		Path = nil,
		Waypoints = {},
		WaypointIndex = 1,
	}
	runtimes[model] = rt
	aliveWaveEnemies += 1

	-- Removal on death (killed by a player).
	humanoid.Died:Connect(function()
		EnemyService._removeEnemy(model, true)
	end)

	task.spawn(runEnemyAI, rt)
	return model
end

--[[ Spawns a player-summoned minion near the owner. ]]
function EnemyService.spawnMinion(defId: string, owner: Player, position: Vector3): Model?
	local def = EnemyDefinitions.get(defId)
	if not def then
		return nil
	end
	local model, humanoid, root = buildRig(def, position)
	model.Parent = enemiesFolder

	DamageService.registerMinion(model, def, owner)
	buildHealthbar(model, humanoid, def)

	local rt: EnemyRuntime = {
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Def = def,
		IsMinion = true,
		Owner = owner,
		DamageMultiplier = 1,
		Alive = true,
		LastAttack = 0,
		Phase = 1,
		StuckSince = 0,
		Path = nil,
		Waypoints = {},
		WaypointIndex = 1,
	}
	runtimes[model] = rt

	humanoid.Died:Connect(function()
		EnemyService._removeEnemy(model, false)
	end)

	-- Minions are temporary.
	task.delay(20, function()
		if runtimes[model] then
			EnemyService._removeEnemy(model, false)
		end
	end)

	task.spawn(runMinionAI, rt)
	return model
end

function EnemyService._removeEnemy(model: Model, killedByPlayer: boolean)
	local rt = runtimes[model]
	if not rt or not rt.Alive then
		return
	end
	rt.Alive = false
	runtimes[model] = nil

	local wasMinion = rt.IsMinion
	if not wasMinion then
		aliveWaveEnemies = math.max(0, aliveWaveEnemies - 1)
	end

	-- Release the DamageService combatant entry (covers self-destruct / despawn
	-- cases where the Humanoid never fired Died).
	DamageService.unregister(rt.Humanoid)

	EnemyService.EnemyRemoved:Fire(model, killedByPlayer, wasMinion)

	-- Brief death fade then cleanup.
	task.delay(killedByPlayer and 0.6 or 0, function()
		if model and model.Parent then
			model:Destroy()
		end
	end)
end

-- Queries ---------------------------------------------------------------------

--[[ All alive, non-minion enemy models within `radius` of `position`. ]]
function EnemyService.getEnemiesInRadius(position: Vector3, radius: number): { Model }
	local result = {}
	for model, rt in runtimes do
		if rt.Alive and not rt.IsMinion and rt.Humanoid.Health > 0 then
			if (rt.Root.Position - position).Magnitude <= radius then
				table.insert(result, model)
			end
		end
	end
	return result
end

--[[ Nearest alive enemy model within maxRange, or nil. ]]
function EnemyService.getNearestEnemy(position: Vector3, maxRange: number): Model?
	local best: Model? = nil
	local bestDist = maxRange
	for model, rt in runtimes do
		if rt.Alive and not rt.IsMinion and rt.Humanoid.Health > 0 then
			local d = (rt.Root.Position - position).Magnitude
			if d < bestDist then
				best = model
				bestDist = d
			end
		end
	end
	return best
end

function EnemyService.getAliveWaveEnemyCount(): number
	return aliveWaveEnemies
end

--[[ Wipes every enemy and minion (used on match reset / defeat). ]]
function EnemyService.clearAll()
	for model, rt in runtimes do
		rt.Alive = false
		if model.Parent then
			model:Destroy()
		end
	end
	table.clear(runtimes)
	aliveWaveEnemies = 0
end

-- Lifecycle -------------------------------------------------------------------

function EnemyService.Init()
	enemiesFolder = Instance.new("Folder")
	enemiesFolder.Name = "Enemies"
	enemiesFolder.Parent = Workspace
end

function EnemyService.Start()
	-- nothing; spawning is driven by WaveManager / SpellCastingService
end

return EnemyService
