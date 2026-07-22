--!strict
--[[
	BossController
	--------------
	Фазы боссов и уникальные механики: телеграфы атак, призыв помощников,
	берсерк-аура, зоны запрета каста, воскрешение.

	Drives multi-phase boss behaviour on top of the normal movement AI from
	EnemyService. Listens to Humanoid.HealthChanged to switch phases by HP%, and
	runs a per-boss ability loop. Attacks are TELEGRAPHED — a red danger disc
	appears on the floor ~1.3s before the hit lands so players can dodge.

	Cross-service note: EnemyService requires this module, so we require
	EnemyService / BaseService LAZILY inside functions to avoid a load-time
	cycle.
]]

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local GameConfig = require(Shared.GameConfig)
local Remotes = require(Shared.Remotes)

local DamageService = require(script.Parent.DamageService)

local BossController = {}

local telegraphsFolder: Folder?

-- No-cast zones the Lich places. Queried by SpellCastingService.
type Zone = { Pos: Vector3, Radius: number, ExpireAt: number }
local noCastZones: { Zone } = {}

-- Lazy requires (avoid the EnemyService <-> BossController load cycle) ---------
local function enemyService()
	return require(script.Parent.EnemyService)
end
local function baseService()
	return require(script.Parent.BaseService)
end

-- Helpers ---------------------------------------------------------------------

local function getFolder(): Folder
	if telegraphsFolder then
		return telegraphsFolder
	end
	local f = Instance.new("Folder")
	f.Name = "Telegraphs"
	f.Parent = Workspace
	telegraphsFolder = f
	return f
end

local function nearestPlayerRoot(pos: Vector3, maxRange: number): (BasePart?, number)
	local best: BasePart? = nil
	local bestDist = maxRange
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and hum.Health > 0 then
			local d = (root.Position - pos).Magnitude
			if d < bestDist then
				best = root
				bestDist = d
			end
		end
	end
	return best, bestDist
end

local function damagePlayersInRadius(center: Vector3, radius: number, damage: number, source: any, effect: string?, effPower: number?, effDur: number?)
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and hum.Health > 0 and (root.Position - center).Magnitude <= radius then
			DamageService.applyDamage(hum, damage, source)
			if effect then
				DamageService.applyEffect(hum, effect, effPower or 0, effDur or 0, source)
			end
		end
	end
end

--[[ Shows a red danger disc, then invokes `onLand(center)` after the telegraph
     window. `center` is captured at telegraph time. ]]
local function telegraph(center: Vector3, radius: number, onLand: (Vector3) -> ())
	local disc = Instance.new("Part")
	disc.Name = "Telegraph"
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanQuery = false
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(0.4, radius * 2, radius * 2)
	disc.CFrame = CFrame.new(center + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
	disc.Material = Enum.Material.Neon
	disc.Color = Color3.fromRGB(220, 40, 40)
	disc.Transparency = 0.55
	disc.Parent = getFolder()

	local delaySeconds = GameConfig.Combat.TelegraphSeconds
	task.delay(delaySeconds, function()
		if disc.Parent then
			disc:Destroy()
		end
		onLand(center)
	end)
end
BossController.telegraph = telegraph

-- No-cast zone API ------------------------------------------------------------

local function addNoCastZone(center: Vector3, radius: number, duration: number)
	table.insert(noCastZones, { Pos = center, Radius = radius, ExpireAt = os.clock() + duration })

	-- Visual marker.
	local marker = Instance.new("Part")
	marker.Name = "NoCastZone"
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.Shape = Enum.PartType.Cylinder
	marker.Size = Vector3.new(0.4, radius * 2, radius * 2)
	marker.CFrame = CFrame.new(center + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	marker.Material = Enum.Material.Neon
	marker.Color = Color3.fromRGB(120, 60, 160)
	marker.Transparency = 0.6
	marker.Parent = getFolder()
	task.delay(duration, function()
		if marker.Parent then
			marker:Destroy()
		end
	end)
end

--[[ True if a position is inside any active no-cast zone. ]]
function BossController.isInNoCastZone(pos: Vector3): boolean
	local now = os.clock()
	for _, zone in noCastZones do
		if now < zone.ExpireAt and (pos - zone.Pos).Magnitude <= zone.Radius then
			return true
		end
	end
	return false
end

local function pruneZones()
	local now = os.clock()
	for i = #noCastZones, 1, -1 do
		if now >= noCastZones[i].ExpireAt then
			table.remove(noCastZones, i)
		end
	end
end

-- Phase computation -----------------------------------------------------------

local function currentPhase(humanoid: Humanoid, phases: number): number
	local frac = humanoid.Health / math.max(1, humanoid.MaxHealth)
	local phase = phases - math.floor(frac * phases)
	return math.clamp(phase, 1, phases)
end

local function announce(text: string)
	Remotes.event(Remotes.Names.Notify):FireAllClients({ Text = text, Kind = "boss" })
end

-- Boss ability sets -----------------------------------------------------------

-- Fire Golem: fire waves (all phases), summon elementals (P2+), berserk aura (P3).
local function runFireGolem(rt: any)
	local humanoid = rt.Humanoid
	local root = rt.Root
	local nextWave = os.clock() + 6
	local nextSummon = 0
	local phase = 1

	while rt.Alive and humanoid.Health > 0 do
		local now = os.clock()
		local newPhase = currentPhase(humanoid, 3)
		if newPhase > phase then
			phase = newPhase
			if phase == 2 then
				announce("Огненный Голем призывает элементалей!")
			elseif phase == 3 then
				announce("Огненный Голем впадает в БЕРСЕРК!")
				humanoid.WalkSpeed = rt.Def.WalkSpeed * 1.35
			end
		end

		-- Fire wave: telegraphed ground AoE centred on the boss.
		if now >= nextWave then
			nextWave = now + (phase == 3 and 6 or 9)
			local center = root.Position
			telegraph(center, 16, function(c)
				damagePlayersInRadius(c, 16, 30, rt.Model)
				Remotes.event(Remotes.Names.PlayVFX):FireAllClients({
					Vfx = "MeteorStorm", Target = c, Radius = 16,
				})
			end)
		end

		-- Summon fire elementals in phase 2+.
		if phase >= 2 and now >= nextSummon then
			nextSummon = now + 12
			local count = phase == 3 and 4 or 3
			for i = 1, count do
				local ang = (i / count) * math.pi * 2
				local pos = root.Position + Vector3.new(math.cos(ang) * 8, 0, math.sin(ang) * 8)
				enemyService().spawnEnemy("FireElemental", 1, 1, pos)
			end
		end

		-- Phase 3 berserk aura: DoT to anyone standing close.
		if phase == 3 then
			damagePlayersInRadius(root.Position, 13, 8, rt.Model, GameConfig.StatusEffects.Burn, 4, 2)
		end

		task.wait(0.5)
	end
end

-- Lich: summon skeletons (P1), no-cast zones (P2), resurrect shadows (P3),
-- plus a dark bolt at the nearest player on all phases.
local function runLich(rt: any)
	local humanoid = rt.Humanoid
	local root = rt.Root
	local nextSummon = os.clock() + 5
	local nextBolt = os.clock() + 3
	local nextZone = 0
	local nextRes = 0
	local phase = 1

	while rt.Alive and humanoid.Health > 0 do
		local now = os.clock()
		local newPhase = currentPhase(humanoid, 3)
		if newPhase > phase then
			phase = newPhase
			if phase == 2 then
				announce("Лич запечатывает магию — зоны запрета каста!")
			elseif phase == 3 then
				announce("Лич воскрешает павших!")
			end
		end

		-- Dark bolt at the nearest player (ranged attack).
		if now >= nextBolt then
			nextBolt = now + 3
			local targetRoot = nearestPlayerRoot(root.Position, rt.Def.AttackRange)
			if targetRoot then
				local hum = targetRoot.Parent and targetRoot.Parent:FindFirstChildOfClass("Humanoid")
				if hum then
					DamageService.applyDamage(hum, 22, rt.Model)
				end
				Remotes.event(Remotes.Names.PlayVFX):FireAllClients({
					Vfx = "ShadowBolt", Origin = root.Position, Target = targetRoot.Position,
				})
			end
		end

		-- Phase 1+: summon skeletons in waves.
		if now >= nextSummon then
			nextSummon = now + 8
			local ids = { "Skeleton", "SkeletonArcher", "Skeleton" }
			for i, id in ids do
				local ang = (i / #ids) * math.pi * 2
				local pos = root.Position + Vector3.new(math.cos(ang) * 7, 0, math.sin(ang) * 7)
				enemyService().spawnEnemy(id, 1, 1, pos)
			end
		end

		-- Phase 2+: place no-cast zones on players.
		if phase >= 2 and now >= nextZone then
			nextZone = now + 11
			for _ = 1, 2 do
				local targetRoot = nearestPlayerRoot(root.Position, 200)
				local center = targetRoot and targetRoot.Position or root.Position
				addNoCastZone(center, 12, 8)
			end
		end

		-- Phase 3: resurrect fallen as shadow copies.
		if phase == 3 and now >= nextRes then
			nextRes = now + 9
			for i = 1, 3 do
				local ang = (i / 3) * math.pi * 2
				local pos = root.Position + Vector3.new(math.cos(ang) * 9, 0, math.sin(ang) * 9)
				enemyService().spawnEnemy("ShadowCopy", 1, 1, pos)
			end
		end

		task.wait(0.5)
	end
end

-- Generic boss: a simple telegraphed slam every few seconds (Orc / Lich King).
local function runGeneric(rt: any)
	local humanoid = rt.Humanoid
	local root = rt.Root
	local nextSlam = os.clock() + 5
	while rt.Alive and humanoid.Health > 0 do
		if os.clock() >= nextSlam then
			nextSlam = os.clock() + 7
			local targetRoot = nearestPlayerRoot(root.Position, 40)
			local center = targetRoot and targetRoot.Position or root.Position
			telegraph(center, 12, function(c)
				damagePlayersInRadius(c, 12, 28, rt.Model, GameConfig.StatusEffects.Stun, 1, 1)
			end)
		end
		task.wait(0.5)
	end
end

-- Attach ----------------------------------------------------------------------

--[[ Called by EnemyService when a boss rig spawns. Starts its ability loop. ]]
function BossController.attach(rt: any)
	local bossId = rt.Def.BossId or "Generic"
	local runner
	if bossId == "FireGolem" then
		runner = runFireGolem
	elseif bossId == "Lich" then
		runner = runLich
	else
		runner = runGeneric
	end
	task.spawn(runner, rt)
end

-- Lifecycle -------------------------------------------------------------------

function BossController.Init()
	getFolder()
end

function BossController.Start()
	-- Periodically prune expired no-cast zones.
	task.spawn(function()
		while true do
			task.wait(2)
			pruneZones()
		end
	end)
end

return BossController
