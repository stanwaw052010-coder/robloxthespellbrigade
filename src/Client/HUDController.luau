--!strict
--[[
	HUDController
	-------------
	HUD и игровой UI: HP/мана, панель скиллов, счётчик волны, магазин, итоги.

	Owns the always-on interface: vitals, the skill bar with radial cooldowns,
	wave/base status, and the two modals it drives — the between-waves upgrade
	shop and the end-of-match results screen. The lobby (books, cosmetics,
	party), the party frames and the minimap live in their own controllers and
	are mounted into this ScreenGui.

	Everything is built programmatically from UIKit, so the game runs the moment
	you sync it with no imported UI assets.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Remotes = require(Shared.Remotes)
local SpellbookModule = require(Shared.SpellbookModule)
local UpgradeCatalogue = require(Shared.UpgradeCatalogue)

local ClientState = require(script.Parent.ClientState)
local LobbyPanelController = require(script.Parent.LobbyPanelController)
local MinimapController = require(script.Parent.MinimapController)
local PartyFrameController = require(script.Parent.PartyFrameController)
local SpellInputController = require(script.Parent.SpellInputController)
local Toast = require(script.Parent.Toast)
local UIKit = require(script.Parent.UIKit)

local HUDController = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local COLORS = UIKit.Colors

-- Root widgets ----------------------------------------------------------------

local gui: ScreenGui
local hpFill: Frame, manaFill: Frame, hpText: TextLabel, manaText: TextLabel
local goldText: TextLabel, essenceText: TextLabel, levelText: TextLabel
local waveText: TextLabel, enemyText: TextLabel, baseFill: Frame, baseText: TextLabel, countdownText: TextLabel
local skillSlots: { [string]: { Button: TextButton, Overlay: Frame, CdText: TextLabel, NameText: TextLabel, Stroke: UIStroke } } = {}
local shopPanel: Frame
local shopContent: ScrollingFrame
local shopTabBar: Frame
local resultsPanel: Frame

local SLOT_ORDER = { "Basic", "Q", "E", "Ultimate" }
local SLOT_KEYS = { Basic = "ЛКМ", Q = "Q", E = "E", Ultimate = "R" }

-- The shop tab currently shown: "Global" or a spell id.
local shopTab = "Global"

-- Top status (wave / base) ----------------------------------------------------

local function buildTopStatus(parent: Instance)
	local holder = UIKit.frame({
		Parent = parent,
		Color = COLORS.Panel,
		Transparency = 0.15,
		Radius = 10,
		Size = UDim2.fromOffset(320, 74),
		Position = UDim2.new(0.5, 0, 0, 12),
		AnchorPoint = Vector2.new(0.5, 0),
	})

	waveText = UIKit.text({
		Parent = holder,
		Text = "Волна 0",
		Font = Enum.Font.GothamBold,
		TextSize = 22,
		Size = UDim2.new(0.6, 0, 0, 26),
		Position = UDim2.fromOffset(12, 6),
		XAlign = Enum.TextXAlignment.Left,
	})
	enemyText = UIKit.text({
		Parent = holder,
		Text = "Врагов: 0",
		TextColor = COLORS.Dim,
		TextSize = 15,
		Size = UDim2.new(0.6, 0, 0, 18),
		Position = UDim2.fromOffset(12, 32),
		XAlign = Enum.TextXAlignment.Left,
	})
	countdownText = UIKit.text({
		Parent = holder,
		Text = "",
		TextColor = COLORS.Accent,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		Size = UDim2.new(0.4, -12, 0, 18),
		Position = UDim2.new(0.6, 0, 0, 8),
		XAlign = Enum.TextXAlignment.Right,
	})

	local bg
	bg, baseFill = UIKit.bar({
		Parent = holder,
		FillColor = Color3.fromRGB(120, 200, 255),
		Size = UDim2.new(1, -24, 0, 14),
		Position = UDim2.new(0, 12, 1, -20),
	})
	baseText = UIKit.text({
		Parent = bg,
		Text = "База 1000/1000",
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		ZIndex = 3,
	})
end

-- Currency (top-left) ---------------------------------------------------------

local function buildCurrency(parent: Instance)
	local holder = UIKit.frame({
		Parent = parent,
		Color = COLORS.Panel,
		Transparency = 0.15,
		Radius = 10,
		Size = UDim2.fromOffset(180, 78),
		Position = UDim2.fromOffset(12, 12),
	})
	levelText = UIKit.text({
		Parent = holder,
		Text = "Ур. 1",
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.fromOffset(12, 6),
		XAlign = Enum.TextXAlignment.Left,
	})
	goldText = UIKit.text({
		Parent = holder,
		Text = "💰 0",
		TextColor = COLORS.Gold,
		TextSize = 16,
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.fromOffset(12, 28),
		XAlign = Enum.TextXAlignment.Left,
	})
	essenceText = UIKit.text({
		Parent = holder,
		Text = "🔮 0",
		TextColor = COLORS.Essence,
		TextSize = 16,
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.fromOffset(12, 50),
		XAlign = Enum.TextXAlignment.Left,
	})
end

-- Vitals (bottom-left) --------------------------------------------------------

local function buildVitals(parent: Instance)
	local holder = UIKit.frame({
		Parent = parent,
		Color = COLORS.Panel,
		Transparency = 0.15,
		Radius = 10,
		Size = UDim2.fromOffset(240, 72),
		Position = UDim2.new(0, 12, 1, -12),
		AnchorPoint = Vector2.new(0, 1),
	})

	local function bar(y: number, color: Color3): (Frame, TextLabel)
		local bg, fill = UIKit.bar({
			Parent = holder,
			FillColor = color,
			Radius = 8,
			Size = UDim2.new(1, -24, 0, 22),
			Position = UDim2.new(0, 12, 0, y),
		})
		local label = UIKit.text({ Parent = bg, Text = "", TextSize = 13, Font = Enum.Font.GothamBold, ZIndex = 3 })
		return fill, label
	end

	hpFill, hpText = bar(12, COLORS.Health)
	manaFill, manaText = bar(40, COLORS.Mana)
end

-- Skill bar (bottom-centre) ---------------------------------------------------

local function buildSkillBar(parent: Instance)
	local holder = UIKit.frame({
		Parent = parent,
		Transparency = 1,
		Size = UDim2.fromOffset(4 * 76 + 3 * 10, 92),
		Position = UDim2.new(0.5, 0, 1, -12),
		AnchorPoint = Vector2.new(0.5, 1),
	})
	local list = UIKit.list(holder, 10)
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom

	for i, slot in SLOT_ORDER do
		local cell = UIKit.frame({ Parent = holder, Transparency = 1, Size = UDim2.fromOffset(76, 92) })
		cell.LayoutOrder = i

		local nameText = UIKit.text({
			Parent = cell,
			Text = slot,
			TextColor = COLORS.Dim,
			TextSize = 12,
			Size = UDim2.new(1, 0, 0, 14),
		})

		local button = UIKit.button({
			Parent = cell,
			Color = COLORS.PanelLight,
			Text = "",
			Size = UDim2.fromOffset(72, 72),
			Position = UDim2.fromOffset(2, 18),
			Radius = 12,
		})

		-- Element-coloured frame around the icon (recoloured when book changes).
		local stroke = UIKit.stroke(button, COLORS.Accent, 2.5)

		UIKit.text({
			Parent = button,
			Text = SLOT_KEYS[slot] or slot,
			Font = Enum.Font.GothamBold,
			TextColor = COLORS.Accent,
			TextSize = 14,
			Size = UDim2.new(1, 0, 0, 16),
			Position = UDim2.new(0, 0, 0, 4),
			ZIndex = 3,
		})

		-- Cooldown overlay fills from the bottom up as cooldown elapses.
		local overlay = UIKit.frame({
			Parent = button,
			Color = Color3.fromRGB(10, 10, 14),
			Transparency = 0.35,
			Radius = 12,
			Size = UDim2.fromScale(1, 0),
			Position = UDim2.fromScale(0, 1),
			AnchorPoint = Vector2.new(0, 1),
			ZIndex = 2,
		})
		local cdText = UIKit.text({
			Parent = button,
			Text = "",
			Font = Enum.Font.GothamBold,
			TextSize = 18,
			ZIndex = 4,
		})

		skillSlots[slot] = { Button = button, Overlay = overlay, CdText = cdText, NameText = nameText, Stroke = stroke }
	end
end

--[[ Recolours the skill-icon frames to the equipped book's element. ]]
local function updateSkillFrames()
	local book = SpellbookModule.getBook(ClientState.SelectedBook)
	local color = UIKit.elementColor(book and book.Element)
	for _, refs in skillSlots do
		refs.Stroke.Color = color
	end
end

-- Shop (between waves) --------------------------------------------------------

local renderShop -- forward declaration; tab buttons re-render it

--[[ One purchasable row: label, level pips and a gold-priced buy button. ]]
local function shopRow(order: number, label: string, description: string, level: number, maxLevel: number, cost: number?, onBuy: () -> ())
	local row = UIKit.frame({
		Parent = shopContent,
		Color = COLORS.PanelLight,
		Radius = 10,
		Size = UDim2.new(1, 0, 0, 62),
	})
	row.LayoutOrder = order

	UIKit.text({
		Parent = row,
		Text = label,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		Size = UDim2.new(1, -140, 0, 20),
		Position = UDim2.fromOffset(14, 8),
		XAlign = Enum.TextXAlignment.Left,
	})
	UIKit.text({
		Parent = row,
		Text = description,
		TextColor = COLORS.Dim,
		TextSize = 12,
		Wrapped = true,
		Size = UDim2.new(1, -140, 0, 30),
		Position = UDim2.fromOffset(14, 28),
		XAlign = Enum.TextXAlignment.Left,
		YAlign = Enum.TextYAlignment.Top,
	})

	-- Level pips make "3 of 5 bought" readable at a glance.
	local pips = UIKit.frame({
		Parent = row,
		Transparency = 1,
		Size = UDim2.fromOffset(maxLevel * 12, 8),
		Position = UDim2.new(1, -124, 0, 12),
		AnchorPoint = Vector2.new(1, 0),
	})
	local pipLayout = UIKit.list(pips, 3)
	pipLayout.FillDirection = Enum.FillDirection.Horizontal
	for i = 1, maxLevel do
		local pip = UIKit.frame({
			Parent = pips,
			Color = i <= level and COLORS.Gold or COLORS.Panel,
			Radius = 3,
			Size = UDim2.fromOffset(9, 8),
		})
		pip.LayoutOrder = i
	end

	local maxed = level >= maxLevel
	local button = UIKit.button({
		Parent = row,
		Color = maxed and COLORS.Panel or COLORS.Accent,
		Text = maxed and "МАКС" or ("%d 💰"):format(cost or 0),
		TextSize = 14,
		Size = UDim2.fromOffset(104, 40),
		Position = UDim2.new(1, -12, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Radius = 8,
	})
	if not maxed then
		button.Activated:Connect(onBuy)
	end
end

local function renderGlobalShop()
	for i, id in UpgradeCatalogue.Order do
		local entry = UpgradeCatalogue.Entries[id]
		local level = ClientState.GlobalLevels[id] or 0
		shopRow(
			i,
			entry.Label,
			"Действует на все заклинания книги.",
			level,
			entry.MaxLevel,
			UpgradeCatalogue.costFor(id, level),
			function()
				local ok, result = pcall(function()
					return Remotes.func(Remotes.Names.PurchaseUpgrade):InvokeServer(id)
				end)
				if ok and type(result) == "table" then
					Toast.push(result.Message or "", result.Ok and "reward" or "warn")
				end
				renderShop()
			end
		)
	end
end

local function renderSpellShop(spellId: string)
	local spell = SpellbookModule.getSpellById(spellId)
	if not spell then
		return
	end
	local isUltimate = spell.Slot == "Ultimate"

	for i, node in UpgradeCatalogue.treeFor(spellId, isUltimate) do
		local level = ClientState.getSpellNodeLevel(spellId, node.Id)
		shopRow(
			i,
			node.Label,
			node.Description,
			level,
			node.MaxLevel,
			UpgradeCatalogue.spellNodeCost(node, level),
			function()
				local ok, result = pcall(function()
					return Remotes.func(Remotes.Names.PurchaseSpellNode):InvokeServer({
						SpellId = spellId,
						NodeId = node.Id,
					})
				end)
				if ok and type(result) == "table" then
					Toast.push(result.Message or "", result.Ok and "reward" or "warn")
				end
				renderShop()
			end
		)
	end
end

--[[ Rebuilds the tab strip (Общие + one tab per equipped spell) and the rows
     for whichever tab is active. ]]
function renderShop()
	if not shopPanel.Visible then
		return
	end

	for _, child in shopTabBar:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	for _, child in shopContent:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	local spells = ClientState.getEquippedSpells()

	-- A book change can leave the active tab pointing at a spell we no longer
	-- have; fall back to the global tab in that case.
	if shopTab ~= "Global" then
		local stillEquipped = false
		for _, spell in spells do
			if spell.Id == shopTab then
				stillEquipped = true
				break
			end
		end
		if not stillEquipped then
			shopTab = "Global"
		end
	end

	local function addTab(id: string, label: string, order: number)
		local button = UIKit.button({
			Parent = shopTabBar,
			Color = shopTab == id and COLORS.Accent or COLORS.PanelLight,
			Text = label,
			TextSize = 12,
			Size = UDim2.fromOffset(96, 32),
			Radius = 8,
		})
		button.LayoutOrder = order
		button.Activated:Connect(function()
			shopTab = id
			renderShop()
		end)
	end

	addTab("Global", "Общие", 0)
	for i, spell in spells do
		addTab(spell.Id, spell.Name, i)
	end

	if shopTab == "Global" then
		renderGlobalShop()
	else
		renderSpellShop(shopTab)
	end
end

local function buildShop(parent: Instance)
	shopPanel = UIKit.frame({
		Parent = parent,
		Color = COLORS.Panel,
		Transparency = 0.03,
		Radius = 14,
		Size = UDim2.fromOffset(520, 400),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 8,
	})

	UIKit.text({
		Parent = shopPanel,
		Text = "🛒 Магазин апгрейдов",
		Font = Enum.Font.GothamBold,
		TextSize = 20,
		Size = UDim2.new(1, -60, 0, 28),
		Position = UDim2.fromOffset(16, 12),
		XAlign = Enum.TextXAlignment.Left,
		ZIndex = 9,
	})

	local close = UIKit.button({
		Parent = shopPanel,
		Color = COLORS.PanelLight,
		Text = "✕",
		TextSize = 16,
		Size = UDim2.fromOffset(32, 32),
		Position = UDim2.new(1, -12, 0, 12),
		AnchorPoint = Vector2.new(1, 0),
		Radius = 8,
		ZIndex = 10,
	})
	close.Activated:Connect(function()
		shopPanel.Visible = false
	end)

	shopTabBar = UIKit.frame({
		Parent = shopPanel,
		Transparency = 1,
		Size = UDim2.new(1, -32, 0, 32),
		Position = UDim2.fromOffset(16, 46),
		ZIndex = 9,
	})
	local tabLayout = UIKit.list(shopTabBar, 6)
	tabLayout.FillDirection = Enum.FillDirection.Horizontal

	shopContent = UIKit.scroll({
		Parent = shopPanel,
		Size = UDim2.new(1, -32, 1, -96),
		Position = UDim2.fromOffset(16, 86),
		ZIndex = 9,
	})
	UIKit.list(shopContent, 8)
end

-- Results ---------------------------------------------------------------------

local function buildResults(parent: Instance)
	resultsPanel = UIKit.frame({
		Parent = parent,
		Color = COLORS.Panel,
		Transparency = 0.02,
		Radius = 16,
		Size = UDim2.fromOffset(420, 320),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 12,
	})
end

function HUDController.showResults(data: { [string]: any })
	for _, child in resultsPanel:GetChildren() do
		if not child:IsA("UICorner") then
			child:Destroy()
		end
	end
	UIKit.text({
		Parent = resultsPanel,
		Text = "Матч окончен",
		Font = Enum.Font.GothamBold,
		TextSize = 26,
		Size = UDim2.new(1, 0, 0, 44),
		Position = UDim2.fromOffset(0, 16),
		ZIndex = 13,
	})
	local rows = {
		{ "Волн пройдено", tostring(data.WavesCleared or 0) },
		{ "Убийств", tostring(data.Kills or 0) },
		{ "Нанесено урона", tostring(data.Damage or 0) },
		{ "Исцелено", tostring(data.Healing or 0) },
	}
	for i, row in rows do
		UIKit.text({
			Parent = resultsPanel,
			Text = row[1],
			TextColor = COLORS.Dim,
			TextSize = 16,
			Size = UDim2.new(0.5, -20, 0, 30),
			Position = UDim2.fromOffset(24, 60 + (i - 1) * 36),
			XAlign = Enum.TextXAlignment.Left,
			ZIndex = 13,
		})
		UIKit.text({
			Parent = resultsPanel,
			Text = row[2],
			Font = Enum.Font.GothamBold,
			TextSize = 18,
			Size = UDim2.new(0.5, -20, 0, 30),
			Position = UDim2.new(0.5, 0, 0, 60 + (i - 1) * 36),
			XAlign = Enum.TextXAlignment.Right,
			ZIndex = 13,
		})
	end
	local close = UIKit.button({
		Parent = resultsPanel,
		Text = "Продолжить",
		Size = UDim2.fromOffset(180, 44),
		Position = UDim2.new(0.5, 0, 1, -20),
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = 13,
	})
	close.Activated:Connect(function()
		resultsPanel.Visible = false
	end)
	resultsPanel.Visible = true
end

-- Update loops ----------------------------------------------------------------

local lastHealth = -1

local function updateVitals()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local frac = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
		hpFill.Size = UDim2.fromScale(frac, 1)
		hpText.Text = ("%d / %d"):format(math.ceil(humanoid.Health), humanoid.MaxHealth)

		-- Damage flash: briefly whiten the HP bar when health drops (§6.1).
		if lastHealth >= 0 and humanoid.Health < lastHealth - 0.5 then
			hpFill.BackgroundColor3 = Color3.fromRGB(255, 235, 235)
			TweenService:Create(hpFill, TweenInfo.new(0.35), { BackgroundColor3 = COLORS.Health }):Play()
		end
		lastHealth = humanoid.Health
	end
	local manaFrac = math.clamp(ClientState.Mana / ClientState.MaxMana, 0, 1)
	manaFill.Size = UDim2.fromScale(manaFrac, 1)
	manaText.Text = ("%d / %d"):format(math.floor(ClientState.Mana), ClientState.MaxMana)
end

local function updateCooldowns()
	for slot, refs in skillSlots do
		local spell = ClientState.getSpellForSlot(slot)
		refs.NameText.Text = spell and spell.Name or slot
		local frac = SpellInputController.getCooldownFraction(slot)
		refs.Overlay.Size = UDim2.fromScale(1, frac)
		if frac > 0 and spell then
			local remaining = frac * ClientState.getEffectiveCooldown(spell)
			refs.CdText.Text = remaining >= 1 and tostring(math.ceil(remaining)) or ("%.1f"):format(remaining)
		else
			refs.CdText.Text = ""
		end
		-- Dim the slot if not enough mana.
		if spell and ClientState.Mana < spell.ManaCost then
			refs.Button.BackgroundColor3 = Color3.fromRGB(60, 40, 40)
		else
			refs.Button.BackgroundColor3 = COLORS.PanelLight
		end
	end
end

local function updateCurrency()
	goldText.Text = "💰 " .. tostring(ClientState.Gold)
	essenceText.Text = "🔮 " .. tostring(ClientState.Essence)
	levelText.Text = "Ур. " .. tostring(ClientState.Level)
end

-- Remote wiring ---------------------------------------------------------------

local function wireRemotes()
	Remotes.event(Remotes.Names.WaveStateChanged).OnClientEvent:Connect(function(data)
		waveText.Text = data.IsBossWave and ("👑 Волна " .. data.Wave) or ("Волна " .. tostring(data.Wave))
		enemyText.Text = "Врагов: " .. tostring(data.EnemiesRemaining or 0)
		if data.Phase == "Intermission" and data.Countdown then
			countdownText.Text = "⏳ " .. tostring(data.Countdown) .. "с"
		else
			countdownText.Text = data.Phase == "Active" and "⚔ Бой" or ""
		end

		-- The shop opens for the intermission and closes when the wave starts.
		-- Players can dismiss it early; it reopens next intermission.
		if data.Phase == "Intermission" then
			if not shopPanel.Visible then
				shopPanel.Visible = true
				renderShop()
			end
		else
			shopPanel.Visible = false
		end

		-- Between matches, the lobby is the natural thing to be looking at.
		if data.Phase == "Idle" or data.Phase == "Ended" then
			LobbyPanelController.setVisible(true)
		elseif data.Phase == "Active" then
			LobbyPanelController.setVisible(false)
		end
	end)

	Remotes.event(Remotes.Names.BaseHealthChanged).OnClientEvent:Connect(function(data)
		local frac = math.clamp(data.Health / data.MaxHealth, 0, 1)
		baseFill.Size = UDim2.fromScale(frac, 1)
		baseFill.BackgroundColor3 = frac > 0.3 and Color3.fromRGB(120, 200, 255) or COLORS.Danger
		baseText.Text = ("База %d/%d"):format(data.Health, data.MaxHealth)
	end)

	Remotes.event(Remotes.Names.PlayerStatsChanged).OnClientEvent:Connect(function(payload)
		ClientState.merge(payload)
		updateCurrency()
		updateSkillFrames()
	end)

	Remotes.event(Remotes.Names.Notify).OnClientEvent:Connect(function(data)
		Toast.push(data.Text or "", data.Kind)
	end)

	Remotes.event(Remotes.Names.MatchEnded).OnClientEvent:Connect(function(data)
		HUDController.showResults(data)
	end)

	-- Purchased levels arriving from the server change every price in the shop.
	ClientState.UpgradesChanged:Connect(renderShop)
end

-- Lifecycle -------------------------------------------------------------------

function HUDController.Init()
	gui = Instance.new("ScreenGui")
	gui.Name = "MagicBrigadeHUD"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	buildTopStatus(gui)
	buildCurrency(gui)
	buildVitals(gui)
	buildSkillBar(gui)
	buildShop(gui)
	buildResults(gui)

	-- Panels owned by their own controllers, mounted into the same ScreenGui.
	MinimapController.mount(gui)
	PartyFrameController.mount(gui)
	LobbyPanelController.mount(gui)
	-- Toasts stack below the minimap so the two never overlap.
	Toast.mount(gui, 192)

	local toggle = UIKit.button({
		Parent = gui,
		Text = "📖 Лобби",
		Color = COLORS.PanelLight,
		Size = UDim2.fromOffset(110, 34),
		Position = UDim2.fromOffset(200, 12),
		Radius = 8,
	})
	toggle.Activated:Connect(LobbyPanelController.toggle)
end

function HUDController.Start()
	wireRemotes()
	updateCurrency()
	updateSkillFrames()
	RunService.RenderStepped:Connect(function()
		updateVitals()
		updateCooldowns()
	end)
end

return HUDController
