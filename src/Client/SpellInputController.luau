--!strict
--[[
	SpellInputController
	--------------------
	Ввод заклинаний: клавиатура (ЛКМ / Q / E / R) и мобильные кнопки.

	Maps input to the equipped spell slots and fires a CastSpell request with
	an aim point. Cross-platform: ContextActionService binds both the keyboard
	key and an auto-generated on-screen button for touch. Client-side cooldown
	prediction keeps the HUD responsive; the server remains authoritative and
	will simply drop any request that's early / out of mana / out of range.
]]

local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)

local ClientState = require(script.Parent.ClientState)

local SpellInputController = {}

SpellInputController.SpellCast = Signal.new() -- (slot, spell) for HUD feedback

local player = Players.LocalPlayer

-- Slot -> input binding. Basic on the mouse, actives on Q/E, ultimate on R.
local SLOTS = {
	{ Slot = "Basic", Action = "MB_CastBasic", Input = Enum.UserInputType.MouseButton1 },
	{ Slot = "Q", Action = "MB_CastQ", Input = Enum.KeyCode.Q },
	{ Slot = "E", Action = "MB_CastE", Input = Enum.KeyCode.E },
	{ Slot = "Ultimate", Action = "MB_CastUlt", Input = Enum.KeyCode.R },
}

-- Local cooldown prediction: cooldownUntil[spellId] = os.clock()
local cooldownUntil: { [string]: number } = {}
local basicHeld = false

-- Aim resolution --------------------------------------------------------------

local function getCharacterRoot(): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--[[ World point the player is aiming at. Raycasts from the camera through the
     cursor; falls back to the nearest enemy (mobile auto-aim) or forward. ]]
local function getAimPosition(): Vector3
	local root = getCharacterRoot()
	local origin = root and root.Position or Vector3.zero

	local camera = Workspace.CurrentCamera
	if not camera then
		return origin + (root and root.CFrame.LookVector * 30 or Vector3.new(0, 0, -30))
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	if player.Character then
		params.FilterDescendantsInstances = { player.Character }
	end
	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * 500, params)
	if result then
		return result.Position
	end

	-- No surface under the cursor: auto-aim at the nearest visible enemy.
	local enemies = Workspace:FindFirstChild("Enemies")
	if enemies then
		local best: Vector3? = nil
		local bestDist = math.huge
		for _, model in enemies:GetChildren() do
			if model:IsA("Model") then
				local part = model:FindFirstChild("HumanoidRootPart") :: BasePart?
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				if part and humanoid and humanoid.Health > 0 then
					local d = (part.Position - origin).Magnitude
					if d < bestDist then
						bestDist = d
						best = part.Position
					end
				end
			end
		end
		if best then
			return best
		end
	end

	-- Fallback: a point in front of the character.
	return origin + (root and root.CFrame.LookVector * 30 or Vector3.new(0, 0, -30))
end

-- Casting ---------------------------------------------------------------------

function SpellInputController.getCooldownFraction(slot: string): number
	local spell = ClientState.getSpellForSlot(slot)
	if not spell then
		return 0
	end
	local until_ = cooldownUntil[spell.Id]
	if not until_ then
		return 0
	end
	local remaining = until_ - os.clock()
	if remaining <= 0 then
		return 0
	end
	return math.clamp(remaining / ClientState.getEffectiveCooldown(spell), 0, 1)
end

local function castSlot(slot: string)
	local spell = ClientState.getSpellForSlot(slot)
	if not spell then
		return
	end

	-- Client-side cooldown gate (prediction; server re-checks).
	local until_ = cooldownUntil[spell.Id]
	if until_ and os.clock() < until_ then
		return
	end

	local root = getCharacterRoot()
	if not root then
		return
	end

	-- Local mana prediction to avoid firing an obviously-doomed request.
	if ClientState.Mana < spell.ManaCost then
		return
	end

	cooldownUntil[spell.Id] = os.clock() + ClientState.getEffectiveCooldown(spell)

	Remotes.event(Remotes.Names.CastSpell):FireServer({
		SpellId = spell.Id,
		AimPosition = getAimPosition(),
	})

	SpellInputController.SpellCast:Fire(slot, spell)
end

-- Input binding ---------------------------------------------------------------

local function onAction(actionName: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	-- Find the slot for this action.
	local slot: string? = nil
	for _, entry in SLOTS do
		if entry.Action == actionName then
			slot = entry.Slot
			break
		end
	end
	if not slot then
		return Enum.ContextActionResult.Pass
	end

	if slot == "Basic" then
		if inputState == Enum.UserInputState.Begin then
			basicHeld = true
			castSlot("Basic")
		elseif inputState == Enum.UserInputState.End then
			basicHeld = false
		end
	elseif inputState == Enum.UserInputState.Begin then
		castSlot(slot)
	end
	return Enum.ContextActionResult.Sink
end

function SpellInputController.Init() end

function SpellInputController.Start()
	for _, entry in SLOTS do
		-- createTouchButton = true auto-generates a mobile button per slot.
		ContextActionService:BindAction(entry.Action, onAction, true, entry.Input)
		ContextActionService:SetTitle(entry.Action, entry.Slot == "Basic" and "🔥" or entry.Slot)
	end

	-- Auto-repeat the basic attack while the mouse/touch is held.
	RunService.Heartbeat:Connect(function()
		if basicHeld then
			castSlot("Basic")
		end
	end)
end

return SpellInputController
