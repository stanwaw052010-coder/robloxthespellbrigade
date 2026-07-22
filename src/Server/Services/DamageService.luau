--!strict
--[[
	DamageService
	-------------
	ЕДИНАЯ и ЕДИНСТВЕННАЯ точка расчёта урона, лечения и статус-эффектов.
	Всё считается на сервере — клиенту никогда не доверяем.

	The one and only place damage, healing and status effects are resolved.
	Everything here is server-authoritative. Spells, enemy attacks and
	damage-over-time all funnel through `applyDamage` so crit, shields,
	weaken debuffs and death rewards are handled consistently.

	Combatants (players, enemies, minions) are registered so the service knows
	each one's max health, base walk speed and current statuses.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local GameConfig = require(Shared.GameConfig)
local Signal = require(Shared.Signal)
local FX = GameConfig.StatusEffects

type StatusState = {
	ExpireAt: number,
	Power: number,
	Source: any,
	NextTick: number?, -- for DoT
}

type Combatant = {
	Model: Model,
	Humanoid: Humanoid,
	MaxHealth: number,
	IsEnemy: boolean,
	IsMinion: boolean,
	Def: any, -- EnemyDef for enemies, nil for players
	OwnerPlayer: Player?, -- for minions
	Shield: number,
	BaseWalkSpeed: number,
	Statuses: { [string]: StatusState },
	LastAttacker: Player?, -- for kill attribution
	Dead: boolean,
	Connections: { RBXScriptConnection },
}

local DamageService = {}

-- Signals other services subscribe to.
DamageService.EnemyDied = Signal.new() -- (enemyDef, killerPlayer?, model)
DamageService.DamageDealt = Signal.new() -- (sourcePlayer?, amount, targetModel)

local combatants: { [Humanoid]: Combatant } = {}

-- Helpers ---------------------------------------------------------------------

local function resolvePlayer(source: any): Player?
	if typeof(source) == "Instance" then
		if source:IsA("Player") then
			return source
		end
		local character = source:FindFirstAncestorOfClass("Model")
		if character then
			return Players:GetPlayerFromCharacter(character)
		end
	end
	return nil
end

local function getCombatantFromHumanoid(humanoid: Humanoid): Combatant?
	return combatants[humanoid]
end

--[[ Recompute a combatant's WalkSpeed from its base and any active movement
     debuffs (Freeze fully stops; Slow scales). ]]
local function recomputeWalkSpeed(c: Combatant)
	local humanoid = c.Humanoid
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local factor = 1
	local freeze = c.Statuses[FX.Freeze]
	if freeze then
		factor = 0
	end
	local slow = c.Statuses[FX.Slow]
	if slow then
		factor = math.min(factor, 1 - math.clamp(slow.Power, 0, 0.95))
	end
	humanoid.WalkSpeed = c.BaseWalkSpeed * factor
end

-- Registration ----------------------------------------------------------------

local function register(model: Model, humanoid: Humanoid, opts: {
	IsEnemy: boolean,
	IsMinion: boolean?,
	Def: any?,
	OwnerPlayer: Player?,
}): Combatant
	-- Clean up any prior registration for this humanoid.
	if combatants[humanoid] then
		DamageService.unregister(humanoid)
	end

	local c: Combatant = {
		Model = model,
		Humanoid = humanoid,
		MaxHealth = humanoid.MaxHealth,
		IsEnemy = opts.IsEnemy,
		IsMinion = opts.IsMinion or false,
		Def = opts.Def,
		OwnerPlayer = opts.OwnerPlayer,
		Shield = 0,
		BaseWalkSpeed = humanoid.WalkSpeed,
		Statuses = {},
		LastAttacker = nil,
		Dead = false,
		Connections = {},
	}
	combatants[humanoid] = c

	table.insert(c.Connections, humanoid.Died:Connect(function()
		DamageService._onDied(c)
	end))

	return c
end

function DamageService.registerEnemy(model: Model, def: any, healthMultiplier: number, damageMultiplier: number)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local scaledHealth = math.floor(def.MaxHealth * healthMultiplier)
	humanoid.MaxHealth = scaledHealth
	humanoid.Health = scaledHealth
	humanoid.WalkSpeed = def.WalkSpeed

	local isMinion = def.Archetype == "Minion"
	local c = register(model, humanoid, {
		IsEnemy = not isMinion,
		IsMinion = isMinion,
		Def = def,
	})
	-- Store the scaled contact damage on the combatant for EnemyService to read.
	c.MaxHealth = scaledHealth
	model:SetAttribute("ContactDamage", math.floor(def.ContactDamage * damageMultiplier))
	model:SetAttribute("MaxHealth", scaledHealth)
end

function DamageService.registerMinion(model: Model, def: any, owner: Player)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	humanoid.MaxHealth = def.MaxHealth
	humanoid.Health = def.MaxHealth
	humanoid.WalkSpeed = def.WalkSpeed
	register(model, humanoid, { IsEnemy = false, IsMinion = true, Def = def, OwnerPlayer = owner })
	model:SetAttribute("ContactDamage", def.ContactDamage)
end

function DamageService.registerPlayerCharacter(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	register(character, humanoid, { IsEnemy = false, IsMinion = false })
end

function DamageService.unregister(humanoid: Humanoid)
	local c = combatants[humanoid]
	if not c then
		return
	end
	for _, conn in c.Connections do
		conn:Disconnect()
	end
	combatants[humanoid] = nil
end

-- Death handling --------------------------------------------------------------

function DamageService._onDied(c: Combatant)
	if c.Dead then
		return
	end
	c.Dead = true

	if c.IsEnemy and c.Def and not c.IsMinion then
		DamageService.EnemyDied:Fire(c.Def, c.LastAttacker, c.Model)
	end

	-- Defer unregister so any in-flight logic can still read state this frame.
	task.defer(function()
		DamageService.unregister(c.Humanoid)
	end)
end

-- Core: damage & healing ------------------------------------------------------

export type DamageOptions = {
	CritChance: number?,
	Effect: string?,
	EffectPower: number?,
	EffectDuration: number?,
	IsDoT: boolean?,
	IgnoreShield: boolean?,
}

--[[
	Applies `amount` of damage (or healing if negative) to a target humanoid.
	@param target Humanoid | Model | BasePart-with-humanoid
	@param amount number  -- positive = damage, negative = heal
	@param source any     -- Player, enemy model, or nil
	@param options DamageOptions?
	@return number actualAmount applied (post crit/shield/weaken), or 0
]]
function DamageService.applyDamage(target: any, amount: number, source: any?, options: DamageOptions?): number
	local humanoid: Humanoid? = nil
	if typeof(target) == "Instance" then
		if target:IsA("Humanoid") then
			humanoid = target
		elseif target:IsA("Model") then
			humanoid = target:FindFirstChildOfClass("Humanoid")
		end
	end
	if not humanoid or humanoid.Health <= 0 then
		return 0
	end

	options = options or {}
	local c = combatants[humanoid]

	-- Healing path -----------------------------------------------------------
	if amount < 0 then
		local healAmount = -amount
		local newHealth = math.min(humanoid.MaxHealth, humanoid.Health + healAmount)
		local applied = newHealth - humanoid.Health
		humanoid.Health = newHealth
		local healer = resolvePlayer(source)
		if healer and applied > 0 then
			DamageService.DamageDealt:Fire(healer, -applied, if c then c.Model else nil)
		end
		return applied
	end

	-- Damage path ------------------------------------------------------------
	local finalAmount = amount

	-- Outgoing "Weaken" debuff on the attacker reduces their damage.
	local attackerPlayer = resolvePlayer(source)
	if typeof(source) == "Instance" then
		local srcModel = source:IsA("Model") and source or source:FindFirstAncestorOfClass("Model")
		local srcHumanoid = srcModel and srcModel:FindFirstChildOfClass("Humanoid")
		if srcHumanoid then
			local srcC = combatants[srcHumanoid]
			if srcC then
				local weaken = srcC.Statuses[FX.Weaken]
				if weaken then
					finalAmount *= (1 - math.clamp(weaken.Power, 0, 0.9))
				end
			end
		end
	end

	-- Critical strike.
	local critChance = options.CritChance or 0
	if critChance > 0 and math.random() < critChance then
		finalAmount *= 2
	end

	finalAmount = math.floor(finalAmount + 0.5)
	if finalAmount <= 0 then
		return 0
	end

	-- Shield absorption.
	if c and c.Shield > 0 and not options.IgnoreShield then
		local absorbed = math.min(c.Shield, finalAmount)
		c.Shield -= absorbed
		finalAmount -= absorbed
	end

	if finalAmount <= 0 then
		return 0
	end

	-- Attribute kills to the last player who damaged the target.
	if c and attackerPlayer then
		c.LastAttacker = attackerPlayer
	end

	humanoid:TakeDamage(finalAmount)

	-- Attribute the damage to the caster for stats (DoT counts too).
	if attackerPlayer then
		DamageService.DamageDealt:Fire(attackerPlayer, finalAmount, if c then c.Model else nil)
	end

	-- Apply an on-hit status effect if requested.
	if options.Effect and options.EffectDuration and options.EffectDuration > 0 then
		DamageService.applyEffect(humanoid, options.Effect, options.EffectPower or 0, options.EffectDuration, source)
	end

	return finalAmount
end

--[[ Applies a status effect to a target humanoid. ]]
function DamageService.applyEffect(target: any, effectType: string, power: number, duration: number, source: any?)
	local humanoid: Humanoid? = nil
	if typeof(target) == "Instance" then
		if target:IsA("Humanoid") then
			humanoid = target
		elseif target:IsA("Model") then
			humanoid = target:FindFirstChildOfClass("Humanoid")
		end
	end
	if not humanoid then
		return
	end
	local c = combatants[humanoid]
	if not c or c.Dead then
		return
	end

	local now = os.clock()

	if effectType == FX.Shield then
		c.Shield += power
		-- Shield persists for `duration`, then whatever remains expires.
		c.Statuses[FX.Shield] = { ExpireAt = now + duration, Power = power, Source = source }
		return
	end

	local state: StatusState = {
		ExpireAt = now + duration,
		Power = power,
		Source = source,
	}
	if effectType == FX.Burn then
		state.NextTick = now + 1
	end
	c.Statuses[effectType] = state

	if effectType == FX.Freeze or effectType == FX.Slow then
		recomputeWalkSpeed(c)
	end
end

-- Queries used by other services ---------------------------------------------

--[[ Damage multiplier an attacker currently deals (accounts for Weaken). ]]
function DamageService.getDamageDealtMultiplier(humanoid: Humanoid): number
	local c = combatants[humanoid]
	if not c then
		return 1
	end
	local weaken = c.Statuses[FX.Weaken]
	if weaken then
		return 1 - math.clamp(weaken.Power, 0, 0.9)
	end
	return 1
end

function DamageService.isFrozen(humanoid: Humanoid): boolean
	local c = combatants[humanoid]
	return c ~= nil and c.Statuses[FX.Freeze] ~= nil
end

function DamageService.getCombatantCount(): number
	local n = 0
	for _ in combatants do
		n += 1
	end
	return n
end

-- Status tick loop ------------------------------------------------------------

local function tick()
	local now = os.clock()
	for humanoid, c in combatants do
		if c.Dead or humanoid.Health <= 0 then
			continue
		end
		local movementDirty = false
		for effectType, state in c.Statuses do
			-- Burn deals damage each second.
			if effectType == FX.Burn and state.NextTick and now >= state.NextTick then
				state.NextTick = now + 1
				DamageService.applyDamage(humanoid, state.Power, state.Source, { IsDoT = true })
			end
			-- Expiry.
			if now >= state.ExpireAt then
				c.Statuses[effectType] = nil
				if effectType == FX.Shield then
					c.Shield = 0
				elseif effectType == FX.Freeze or effectType == FX.Slow then
					movementDirty = true
				end
			end
		end
		if movementDirty then
			recomputeWalkSpeed(c)
		end
	end
end

-- Lifecycle -------------------------------------------------------------------

function DamageService.Init()
	-- nothing to pre-build
end

function DamageService.Start()
	-- Register player characters so they can be healed / shielded / damaged.
	local function hookPlayer(player: Player)
		local function onCharacter(character: Model)
			-- Wait a frame for the Humanoid to exist.
			local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
			if humanoid then
				DamageService.registerPlayerCharacter(player, character)
			end
		end
		player.CharacterAdded:Connect(onCharacter)
		if player.Character then
			onCharacter(player.Character)
		end
	end
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)

	RunService.Heartbeat:Connect(tick)
end

return DamageService
