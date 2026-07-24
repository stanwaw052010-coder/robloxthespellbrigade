--!strict
--[[
	SpellCastingService
	-------------------
	Обработка заклинаний с ПОЛНОЙ серверной валидацией.

	The client only ever *requests* a cast (spell id + aim point). This service
	is the authority: it validates the spell is equipped, off cooldown, mana is
	available and the aim point is within range (with a small latency
	tolerance), then resolves the effect through DamageService / EnemyService.
	Mana is tracked and regenerated here (server-owned).

	Never trust the client for damage, cooldowns, mana or targets.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage").Shared
local GameConfig = require(Shared.GameConfig)
local Remotes = require(Shared.Remotes)
local SpellbookModule = require(Shared.SpellbookModule)
local FX = GameConfig.StatusEffects

local DamageService = require(script.Parent.DamageService)
local EnemyService = require(script.Parent.EnemyService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local UpgradeService = require(script.Parent.UpgradeService)
local AntiExploit = require(script.Parent.AntiExploit)
local BossController = require(script.Parent.BossController)

local SpellCastingService = {}

type ManaState = { Mana: number, Max: number }

local manaState: { [Player]: ManaState } = {}
-- cooldowns[player][spellId] = os.clock() expiry
local cooldowns: { [Player]: { [string]: number } } = {}

-- Mana ------------------------------------------------------------------------

local function ensureMana(player: Player): ManaState
	local state = manaState[player]
	if not state then
		state = { Mana = GameConfig.Player.MaxMana, Max = GameConfig.Player.MaxMana }
		manaState[player] = state
	end
	return state
end

local function pushMana(player: Player)
	local state = manaState[player]
	if not state then
		return
	end
	-- Partial PlayerStatsChanged payload; the client merges it into HUD state.
	Remotes.event(Remotes.Names.PlayerStatsChanged):FireClient(player, {
		Mana = math.floor(state.Mana),
		MaxMana = state.Max,
	})
end

-- Validation ------------------------------------------------------------------

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Effect resolution -----------------------------------------------------------

local function broadcastVFX(caster: Player, spell: any, origin: Vector3, impact: Vector3, radius: number)
	Remotes.event(Remotes.Names.PlayVFX):FireAllClients({
		Vfx = spell.VFX,
		SpellId = spell.Id,
		Caster = caster,
		Origin = origin,
		Target = impact,
		Radius = radius,
	})
end

--[[ Builds the DamageService options for a HOSTILE cast. Shield is never
     applied to enemies — only genuine debuffs (Burn/Freeze/Slow/Weaken) pass
     through here. Ally shields are handled separately in applyFriendlyArea. ]]
local function hostileOptions(spell: any)
	local effect = (spell.Effect ~= FX.Shield) and spell.Effect or nil
	return {
		CritChance = spell.CritChance,
		Effect = effect,
		EffectPower = effect and spell.EffectPower or nil,
		EffectDuration = effect and spell.EffectDuration or nil,
	}
end

--[[ Damages every enemy in a radius. `frozenBonus` (Shatter signature) is an
     extra multiplier applied only to targets currently frozen. ]]
local function applyEnemyArea(impact: Vector3, radius: number, spell: any, damage: number, source: Player, frozenBonus: number?)
	local opts = hostileOptions(spell)
	for _, model in EnemyService.getEnemiesInRadius(impact, radius) do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local dealt = damage
			if frozenBonus and DamageService.isFrozen(humanoid) then
				dealt *= frozenBonus
			end
			DamageService.applyDamage(humanoid, dealt, source, opts)
		end
	end
end

local function applySingleTarget(impact: Vector3, spell: any, damage: number, source: Player): Model?
	-- Find the enemy nearest the aim point within a forgiving hit radius.
	local target = EnemyService.getNearestEnemy(impact, 8)
	if target then
		local humanoid = target:FindFirstChildOfClass("Humanoid")
		if humanoid then
			DamageService.applyDamage(humanoid, damage, source, hostileOptions(spell))
		end
	end
	return target
end

--[[ Chains to nearby enemies with falloff (used by projectile spells that carry
     an AreaOfEffect, e.g. Chain Lightning). The Overload signature raises
     `jumps` and softens `falloff`. ]]
local function applyChain(
	firstHit: Model?,
	impact: Vector3,
	radius: number,
	spell: any,
	damage: number,
	source: Player,
	jumps: number,
	falloff: number
)
	if not firstHit then
		return
	end
	local origin = firstHit:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not origin then
		return
	end
	local hit = { [firstHit] = true }
	local jumpDamage = damage
	local from = origin.Position
	for _ = 1, jumps do
		jumpDamage *= falloff
		local candidates = EnemyService.getEnemiesInRadius(from, radius)
		local next: Model? = nil
		local bestDist = math.huge
		for _, model in candidates do
			if not hit[model] then
				local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root then
					local d = (root.Position - from).Magnitude
					if d < bestDist then
						bestDist = d
						next = model
					end
				end
			end
		end
		if not next then
			break
		end
		hit[next] = true
		local humanoid = next:FindFirstChildOfClass("Humanoid")
		if humanoid then
			DamageService.applyDamage(humanoid, jumpDamage, source, { CritChance = spell.CritChance })
		end
		local nroot = next:FindFirstChild("HumanoidRootPart") :: BasePart?
		from = nroot and nroot.Position or from
	end
end

--[[ Heals and/or shields allied players within radius. `healAmount` is negative
     to heal (0 for none); `shieldPower` > 0 grants a shield.
     `overflowShield` (Overflow signature) converts healing wasted on a
     full-health ally into a temporary shield instead. ]]
local function applyFriendlyArea(
	impact: Vector3,
	radius: number,
	healAmount: number,
	shieldPower: number,
	shieldDuration: number,
	source: Player,
	overflowShield: boolean?
)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 and (root.Position - impact).Magnitude <= radius then
			if healAmount < 0 then
				-- applyDamage returns how much healing actually landed; the rest
				-- would otherwise be wasted on an already-full ally.
				local applied = DamageService.applyDamage(humanoid, healAmount, source) -- negative = heal
				if overflowShield then
					local wasted = -healAmount - applied
					if wasted > 0 then
						DamageService.applyEffect(humanoid, FX.Shield, wasted, 8, source)
					end
				end
			end
			if shieldPower > 0 then
				DamageService.applyEffect(humanoid, FX.Shield, shieldPower, shieldDuration, source)
			end
		end
	end
end

local WALL_SIZE = Vector3.new(14, 8, 2) -- width, height, thickness

--[[ The flat direction the caster aimed, used to face walls across the lane. ]]
local function castDirection(origin: Vector3, impact: Vector3): Vector3
	local flat = Vector3.new(impact.X - origin.X, 0, impact.Z - origin.Z)
	if flat.Magnitude < 0.1 then
		return Vector3.new(0, 0, 1)
	end
	return flat.Unit
end

--[[ Raises one stone wall broadside to `direction`, so its 14-stud width blocks
     the lane the caster aimed down rather than sitting at a random angle. ]]
local function spawnWall(position: Vector3, direction: Vector3, duration: number)
	local base = position + Vector3.new(0, WALL_SIZE.Y / 2, 0)

	local wall = Instance.new("Part")
	wall.Name = "StoneWall"
	wall.Anchored = true
	wall.Size = WALL_SIZE
	-- lookAt puts the part's thin Z axis along the cast, leaving the width
	-- perpendicular to it.
	wall.CFrame = CFrame.lookAt(base, base + direction)
	wall.Material = Enum.Material.Rock
	wall.Color = Color3.fromRGB(110, 105, 95)
	wall.Parent = Workspace:FindFirstChild("Enemies") or Workspace
	task.delay(duration, function()
		if wall and wall.Parent then
			wall:Destroy()
		end
	end)
end

--[[ Great Wall signature: three segments side by side across the cast lane.
     All three share one direction so the segments meet flush instead of
     fanning apart. ]]
local function spawnWallLine(impact: Vector3, direction: Vector3, duration: number)
	-- Sideways step of exactly one wall width, so the segments join up.
	local side = direction:Cross(Vector3.yAxis) * WALL_SIZE.X
	for i = -1, 1 do
		spawnWall(impact + side * i, direction, duration)
	end
end

--[[ Executes a validated spell.
     @param mods      global upgrade multipliers (shop)
     @param spellMods this spell's own tree multipliers + signature nodes ]]
local function executeSpell(
	player: Player,
	spell: any,
	root: BasePart,
	aim: Vector3,
	mods: UpgradeService.UpgradeState,
	spellMods: UpgradeService.SpellMods
)
	local origin = root.Position
	local sig = spellMods.Signatures

	-- Damage upgrades boost healing too (both live on Spell.Damage, healing
	-- being negative), so scale by magnitude rather than sign.
	local damageMult = mods.DamageMult * spellMods.DamageMult
	local damage = spell.Damage * damageMult
	local radius = spell.AreaOfEffect * mods.RadiusMult * spellMods.RadiusMult

	local impact: Vector3
	if spell.CastType == "Self" or spell.CastType == "Summon" then
		impact = origin
	else
		impact = aim
	end

	broadcastVFX(player, spell, origin, impact, radius)

	if spell.CastType == "Summon" and spell.SummonId then
		-- Legion: two extra skeletons per cast.
		local count = (spell.SummonCount or 1) + (sig.Legion and 2 or 0)
		for i = 1, count do
			local angle = (i / count) * math.pi * 2
			local offset = Vector3.new(math.cos(angle) * 4, 0, math.sin(angle) * 4)
			EnemyService.spawnMinion(spell.SummonId, player, origin + offset)
		end
		return
	end

	-- Pure-utility wall (no damage, no effect, targeted): spawn an obstacle.
	if spell.Damage == 0 and not spell.Effect and spell.CastType == "AreaTarget" then
		local direction = castDirection(origin, impact)
		if sig.GreatWall then
			spawnWallLine(impact, direction, 16)
		else
			spawnWall(impact, direction, 8)
		end
		return
	end

	-- Friendly effects (heal and/or ally shield) always land on allies, even
	-- when the same spell also damages enemies (e.g. an ultimate that shields
	-- the party AND hits foes).
	local hasShield = spell.Effect == FX.Shield
	if spell.Damage < 0 or hasShield then
		applyFriendlyArea(
			impact,
			math.max(radius, 8),
			spell.Damage < 0 and damage or 0,
			hasShield and (spell.EffectPower or 0) or 0,
			spell.EffectDuration or 0,
			player,
			sig.Overflow
		)
	end

	-- Hostile damage: any positive-damage spell, or a pure-CC debuff spell.
	local isHostile = spell.Damage > 0 or (spell.Effect ~= nil and spell.Effect ~= FX.Shield)
	if not isHostile then
		return
	end

	-- Shatter: this cast punishes anything already frozen.
	local frozenBonus = sig.Shatter and 1.6 or nil

	if radius > 0 and spell.CastType ~= "Projectile" then
		applyEnemyArea(impact, radius, spell, damage, player, frozenBonus)

		-- Echo Blast / Cataclysm: repeat the detonation on a delay. Each echo
		-- re-queries the arena, so it catches enemies that walked in after the
		-- first hit. Guarded by the player still being in the match.
		local echoes = (sig.EchoBlast and 1 or 0) + (sig.Cataclysm and 2 or 0)
		for i = 1, echoes do
			task.delay(0.6 * i, function()
				if not player.Parent then
					return
				end
				broadcastVFX(player, spell, impact, impact, radius)
				applyEnemyArea(impact, radius, spell, damage * 0.6, player, frozenBonus)
			end)
		end
	elseif spell.CastType == "Projectile" then
		local firstHit = applySingleTarget(impact, spell, damage, player)
		if radius > 0 then
			-- Projectile + AoE => chaining behaviour. Overload adds jumps and
			-- softens the per-jump falloff.
			local jumps = sig.Overload and 6 or 3
			local falloff = sig.Overload and 0.85 or 0.7
			applyChain(firstHit, impact, radius, spell, damage, player, jumps, falloff)
		end
	else
		applySingleTarget(impact, spell, damage, player)
	end
end

-- Request handler -------------------------------------------------------------

local function onCastRequest(player: Player, payload: any)
	-- 1. Rate limit raw traffic.
	if not AntiExploit.allow(player, "CastSpell") then
		return
	end
	-- 2. Shape validation.
	if type(payload) ~= "table" or type(payload.SpellId) ~= "string" then
		return
	end
	local aim = payload.AimPosition
	if aim ~= nil and typeof(aim) ~= "Vector3" then
		return
	end

	-- 3. Spell must exist and be in the player's equipped book.
	local profile = PlayerDataService.get(player)
	if not profile then
		return
	end
	local spell = SpellbookModule.getSpellById(payload.SpellId)
	if not spell then
		return
	end
	if not SpellbookModule.bookHasSpell(profile.SelectedBook, spell.Id) then
		return -- trying to cast a spell from a book they don't have equipped
	end

	-- 4. Caster must be alive with a character.
	local root = getCharacterRoot(player)
	if not root then
		return
	end

	-- 4b. The Lich's no-cast zones seal magic: reject casts made from inside one.
	if BossController.isInNoCastZone(root.Position) then
		Remotes.event(Remotes.Names.Notify):FireClient(player, { Text = "Магия запечатана в этой зоне!", Kind = "warn" })
		return
	end

	local mods = UpgradeService.getState(player)
	local spellMods = UpgradeService.getSpellMods(player, spell.Id)

	-- 5. Cooldown (server-side, upgrade-adjusted).
	local now = os.clock()
	local playerCds = cooldowns[player]
	if not playerCds then
		playerCds = {}
		cooldowns[player] = playerCds
	end
	if playerCds[spell.Id] and now < playerCds[spell.Id] then
		return -- still on cooldown; silently drop
	end

	-- 6. Mana.
	local mana = ensureMana(player)
	local manaCost = spell.ManaCost * mods.ManaCostMult
	if mana.Mana < manaCost then
		Remotes.event(Remotes.Names.Notify):FireClient(player, { Text = "Недостаточно маны", Kind = "warn" })
		return
	end

	-- 7. Range validation for targeted/projectile casts.
	if spell.CastType ~= "Self" and spell.Range > 0 then
		local aimPos = aim or root.Position
		local dist = (aimPos - root.Position).Magnitude
		if dist > spell.Range + GameConfig.Security.RangeTolerance then
			-- Clamp the aim to max range rather than reject, so lag doesn't feel
			-- punishing, but never let it exceed the tolerance-checked bound.
			return
		end
	end

	-- All checks passed: commit cost + cooldown, then resolve.
	mana.Mana -= manaCost
	pushMana(player)
	playerCds[spell.Id] = now + spell.Cooldown * mods.CooldownMult * spellMods.CooldownMult

	local aimPos = aim or root.Position
	local ok, err = pcall(executeSpell, player, spell, root, aimPos, mods, spellMods)
	if not ok then
		warn("[SpellCastingService] executeSpell error: " .. tostring(err))
	end
end

-- Regeneration loop -----------------------------------------------------------

local function regenLoop()
	local accum = 0
	RunService.Heartbeat:Connect(function(dt)
		accum += dt
		if accum < 0.25 then
			return
		end
		local step = accum
		accum = 0
		for player, state in manaState do
			if state.Mana < state.Max then
				state.Mana = math.min(state.Max, state.Mana + GameConfig.Player.ManaRegenPerSecond * step)
				pushMana(player)
			end
		end
	end)
end

-- Lifecycle -------------------------------------------------------------------

--[[ Current and maximum mana for a player. Read by PartyService for the party
     frames; mana itself stays owned by this service. ]]
function SpellCastingService.getMana(player: Player): (number, number)
	local state = manaState[player]
	if not state then
		return 0, GameConfig.Player.MaxMana
	end
	return state.Mana, state.Max
end

function SpellCastingService.resetMana(player: Player)
	local state = ensureMana(player)
	state.Mana = state.Max
	pushMana(player)
	cooldowns[player] = {}
end

function SpellCastingService.Init() end

function SpellCastingService.Start()
	local function hookPlayer(player: Player)
		ensureMana(player)
		player.CharacterAdded:Connect(function()
			-- Refill mana on (re)spawn.
			task.wait(0.5)
			SpellCastingService.resetMana(player)
		end)
		pushMana(player)
	end
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	Players.PlayerRemoving:Connect(function(player)
		manaState[player] = nil
		cooldowns[player] = nil
	end)

	Remotes.event(Remotes.Names.CastSpell).OnServerEvent:Connect(onCastRequest)

	regenLoop()
end

return SpellCastingService
