--!strict
--[[
	HUDController
	-------------
	HUD и весь игровой UI: HP/мана, панель скиллов с кулдаунами, счётчик волны,
	здоровье базы, уведомления, магазин апгрейдов, выбор книги, экран итогов.

	Builds the entire interface programmatically (no imported UI assets) so it
	runs the moment you sync. Reads local Humanoid health, ClientState (mana /
	currency / equipped book) and the wave/base/notify remotes. The shop appears
	during intermissions; the book selector when idle; results at match end.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Remotes = require(Shared.Remotes)
local SpellbookModule = require(Shared.SpellbookModule)
local UpgradeCatalogue = require(Shared.UpgradeCatalogue)

local ClientState = require(script.Parent.ClientState)
local SpellInputController = require(script.Parent.SpellInputController)

local HUDController = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Palette ---------------------------------------------------------------------
local COLORS = {
	Panel = Color3.fromRGB(24, 26, 38),
	PanelLight = Color3.fromRGB(38, 41, 58),
	Accent = Color3.fromRGB(120, 150, 255),
	Health = Color3.fromRGB(220, 70, 70),
	Mana = Color3.fromRGB(70, 130, 240),
	Gold = Color3.fromRGB(240, 200, 90),
	Essence = Color3.fromRGB(160, 110, 240),
	Text = Color3.fromRGB(240, 240, 245),
	Dim = Color3.fromRGB(160, 165, 180),
	Danger = Color3.fromRGB(230, 80, 80),
}

-- UI factory helpers ----------------------------------------------------------

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function makeFrame(props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = props.Color or COLORS.Panel
	f.BackgroundTransparency = props.Transparency or 0
	f.BorderSizePixel = 0
	f.Size = props.Size or UDim2.fromOffset(100, 100)
	f.Position = props.Position or UDim2.fromScale(0, 0)
	f.AnchorPoint = props.AnchorPoint or Vector2.zero
	f.Visible = props.Visible ~= false
	if props.Parent then
		f.Parent = props.Parent
	end
	if props.Radius then
		corner(f, props.Radius)
	end
	return f
end

local function makeText(props: { [string]: any }): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = props.Font or Enum.Font.GothamMedium
	t.Text = props.Text or ""
	t.TextColor3 = props.TextColor or COLORS.Text
	t.TextScaled = props.TextScaled or false
	t.TextSize = props.TextSize or 16
	t.TextXAlignment = props.XAlign or Enum.TextXAlignment.Center
	t.Size = props.Size or UDim2.fromScale(1, 1)
	t.Position = props.Position or UDim2.fromScale(0, 0)
	t.AnchorPoint = props.AnchorPoint or Vector2.zero
	if props.Parent then
		t.Parent = props.Parent
	end
	return t
end

local function makeButton(props: { [string]: any }): TextButton
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = props.Color or COLORS.Accent
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.GothamBold
	b.Text = props.Text or ""
	b.TextColor3 = props.TextColor or COLORS.Text
	b.TextSize = props.TextSize or 15
	b.Size = props.Size or UDim2.fromOffset(160, 40)
	b.Position = props.Position or UDim2.fromScale(0, 0)
	b.AnchorPoint = props.AnchorPoint or Vector2.zero
	if props.Parent then
		b.Parent = props.Parent
	end
	corner(b, props.Radius or 8)
	return b
end

-- Root ------------------------------------------------------------------------

local gui: ScreenGui
local hpFill: Frame, manaFill: Frame, hpText: TextLabel, manaText: TextLabel
local goldText: TextLabel, essenceText: TextLabel, levelText: TextLabel
local waveText: TextLabel, enemyText: TextLabel, baseFill: Frame, baseText: TextLabel, countdownText: TextLabel
local skillSlots: { [string]: { Button: TextButton, Overlay: Frame, CdText: TextLabel, NameText: TextLabel } } = {}
local notifyHolder: Frame
local shopPanel: Frame
local bookPanel: Frame
local resultsPanel: Frame

local SLOT_ORDER = { "Basic", "Q", "E", "Ultimate" }
local SLOT_KEYS = { Basic = "ЛКМ", Q = "Q", E = "E", Ultimate = "R" }

-- Build: top status (wave / base) --------------------------------------------

local function buildTopStatus(parent: Instance)
	local holder = makeFrame({
		Parent = parent,
		Color = COLORS.Panel,
		Transparency = 0.15,
		Radius = 10,
		Size = UDim2.fromOffset(320, 74),
		Position = UDim2.new(0.5, 0, 0, 12),
		AnchorPoint = Vector2.new(0.5, 0),
	})

	waveText = makeText({
		Parent = holder,
		Text = "Волна 0",
		Font = Enum.Font.GothamBold,
		TextSize = 22,
		Size = UDim2.new(0.6, 0, 0, 26),
		Position = UDim2.fromOffset(12, 6),
		XAlign = Enum.TextXAlignment.Left,
	})
	enemyText = makeText({
		Parent = holder,
		Text = "Врагов: 0",
		TextColor = COLORS.Dim,
		TextSize = 15,
		Size = UDim2.new(0.6, 0, 0, 18),
		Position = UDim2.fromOffset(12, 32),
		XAlign = Enum.TextXAlignment.Left,
	})
	countdownText = makeText({
		Parent = holder,
		Text = "",
		TextColor = COLORS.Accent,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		Size = UDim2.new(0.4, -12, 0, 18),
		Position = UDim2.new(0.6, 0, 0, 8),
		XAlign = Enum.TextXAlignment.Right,
	})

	-- Base health bar.
	local barBg = makeFrame({
		Parent = holder,
		Color = COLORS.PanelLight,
		Radius = 6,
		Size = UDim2.new(1, -24, 0, 14),
		Position = UDim2.new(0, 12, 1, -20),
	})
	baseFill = makeFrame({
		Parent = barBg,
		Color = Color3.fromRGB(120, 200, 255),
		Radius = 6,
		Size = UDim2.fromScale(1, 1),
	})
	baseText = makeText({
		Parent = barBg,
		Text = "База 1000/1000",
		TextSize = 12,
		Font = Enum.Font.GothamBold,
	})
end

-- Build: currency (top-left) --------------------------------------------------

local function buildCurrency(parent: Instance)
	local holder = makeFrame({
		Parent = parent,
		Color = COLORS.Panel,
		Transparency = 0.15,
		Radius = 10,
		Size = UDim2.fromOffset(180, 78),
		Position = UDim2.fromOffset(12, 12),
	})
	levelText = makeText({
		Parent = holder,
		Text = "Ур. 1",
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.fromOffset(12, 6),
		XAlign = Enum.TextXAlignment.Left,
	})
	goldText = makeText({
		Parent = holder,
		Text = "💰 0",
		TextColor = COLORS.Gold,
		TextSize = 16,
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.fromOffset(12, 28),
		XAlign = Enum.TextXAlignment.Left,
	})
	essenceText = makeText({
		Parent = holder,
		Text = "🔮 0",
		TextColor = COLORS.Essence,
		TextSize = 16,
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.fromOffset(12, 50),
		XAlign = Enum.TextXAlignment.Left,
	})
end

-- Build: HP / mana (bottom-left) ---------------------------------------------

local function buildVitals(parent: Instance)
	local holder = makeFrame({
		Parent = parent,
		Color = COLORS.Panel,
		Transparency = 0.15,
		Radius = 10,
		Size = UDim2.fromOffset(240, 72),
		Position = UDim2.new(0, 12, 1, -12),
		AnchorPoint = Vector2.new(0, 1),
	})

	local function bar(y: number, color: Color3): (Frame, TextLabel)
		local bg = makeFrame({
			Parent = holder,
			Color = COLORS.PanelLight,
			Radius = 8,
			Size = UDim2.new(1, -24, 0, 22),
			Position = UDim2.new(0, 12, 0, y),
		})
		local fill = makeFrame({ Parent = bg, Color = color, Radius = 8, Size = UDim2.fromScale(1, 1) })
		local label = makeText({ Parent = bg, Text = "", TextSize = 13, Font = Enum.Font.GothamBold })
		return fill, label
	end

	hpFill, hpText = bar(12, COLORS.Health)
	manaFill, manaText = bar(40, COLORS.Mana)
end

-- Build: skill bar (bottom-center) -------------------------------------------

local function buildSkillBar(parent: Instance)
	local holder = makeFrame({
		Parent = parent,
		Transparency = 1,
		Size = UDim2.fromOffset(4 * 76 + 3 * 10, 92),
		Position = UDim2.new(0.5, 0, 1, -12),
		AnchorPoint = Vector2.new(0.5, 1),
	})
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.Padding = UDim.new(0, 10)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.Parent = holder

	for _, slot in SLOT_ORDER do
		local cell = makeFrame({ Parent = holder, Transparency = 1, Size = UDim2.fromOffset(76, 92) })

		local nameText = makeText({
			Parent = cell,
			Text = slot,
			TextColor = COLORS.Dim,
			TextSize = 12,
			Size = UDim2.new(1, 0, 0, 14),
			Position = UDim2.fromOffset(0, 0),
		})

		local button = makeButton({
			Parent = cell,
			Color = COLORS.PanelLight,
			Text = "",
			Size = UDim2.fromOffset(72, 72),
			Position = UDim2.fromOffset(2, 18),
			Radius = 12,
		})

		makeText({
			Parent = button,
			Text = SLOT_KEYS[slot] or slot,
			Font = Enum.Font.GothamBold,
			TextColor = COLORS.Accent,
			TextSize = 14,
			Size = UDim2.new(1, 0, 0, 16),
			Position = UDim2.new(0, 0, 0, 4),
		})

		-- Cooldown overlay fills from the bottom up as cooldown elapses.
		local overlay = makeFrame({
			Parent = button,
			Color = Color3.fromRGB(10, 10, 14),
			Transparency = 0.35,
			Radius = 12,
			Size = UDim2.fromScale(1, 0),
			Position = UDim2.fromScale(0, 1),
			AnchorPoint = Vector2.new(0, 1),
		})
		local cdText = makeText({
			Parent = button,
			Text = "",
			Font = Enum.Font.GothamBold,
			TextSize = 18,
			Size = UDim2.fromScale(1, 1),
		})

		skillSlots[slot] = { Button = button, Overlay = overlay, CdText = cdText, NameText = nameText }
	end
end

-- Build: notifications --------------------------------------------------------

local function buildNotifications(parent: Instance)
	notifyHolder = makeFrame({
		Parent = parent,
		Transparency = 1,
		Size = UDim2.fromOffset(300, 260),
		Position = UDim2.new(1, -12, 0, 100),
		AnchorPoint = Vector2.new(1, 0),
	})
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.VerticalAlignment = Enum.VerticalAlignment.Top
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.Padding = UDim.new(0, 6)
	list.Parent = notifyHolder
end

local KIND_COLORS = {
	info = COLORS.PanelLight,
	warn = Color3.fromRGB(140, 60, 60),
	reward = Color3.fromRGB(60, 110, 70),
	levelup = Color3.fromRGB(90, 80, 140),
	boss = Color3.fromRGB(150, 50, 120),
}

function HUDController.pushNotification(text: string, kind: string?)
	local color = KIND_COLORS[kind or "info"] or COLORS.PanelLight
	local toast = makeFrame({
		Parent = notifyHolder,
		Color = color,
		Transparency = 0.1,
		Radius = 8,
		Size = UDim2.fromOffset(300, 34),
	})
	makeText({
		Parent = toast,
		Text = text,
		TextSize = 15,
		Font = Enum.Font.GothamBold,
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		XAlign = Enum.TextXAlignment.Left,
	})
	task.delay(3.5, function()
		local tween = TweenService:Create(toast, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
		tween:Play()
		tween.Completed:Wait()
		toast:Destroy()
	end)
end

-- Build: shop (intermission) --------------------------------------------------

local function buildShop(parent: Instance)
	shopPanel = makeFrame({
		Parent = parent,
		Color = COLORS.Panel,
		Transparency = 0.05,
		Radius = 14,
		Size = UDim2.fromOffset(360, 320),
		Position = UDim2.new(1, -12, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Visible = false,
	})
	makeText({
		Parent = shopPanel,
		Text = "🛒 Магазин апгрейдов",
		Font = Enum.Font.GothamBold,
		TextSize = 20,
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.fromOffset(0, 8),
	})
	makeText({
		Parent = shopPanel,
		Text = "Доступно между волнами",
		TextColor = COLORS.Dim,
		TextSize = 13,
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.fromOffset(0, 40),
	})

	local listHolder = makeFrame({
		Parent = shopPanel,
		Transparency = 1,
		Size = UDim2.new(1, -24, 1, -80),
		Position = UDim2.fromOffset(12, 66),
	})
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 8)
	list.Parent = listHolder

	for _, id in UpgradeCatalogue.Order do
		local entry = UpgradeCatalogue.Entries[id]
		local btn = makeButton({
			Parent = listHolder,
			Color = COLORS.PanelLight,
			Text = ("%s   (от %d💰)"):format(entry.Label, entry.BaseCost),
			Size = UDim2.new(1, 0, 0, 44),
			Radius = 10,
		})
		btn.Activated:Connect(function()
			local remote = Remotes.func(Remotes.Names.PurchaseUpgrade)
			local ok, result = pcall(function()
				return remote:InvokeServer(id)
			end)
			if ok and type(result) == "table" then
				HUDController.pushNotification(result.Message or "", result.Ok and "reward" or "warn")
			end
		end)
	end
end

-- Build: book selector (lobby / idle) ----------------------------------------

local function buildBookPanel(parent: Instance)
	bookPanel = makeFrame({
		Parent = parent,
		Color = COLORS.Panel,
		Transparency = 0.03,
		Radius = 14,
		Size = UDim2.fromOffset(420, 380),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
	})
	makeText({
		Parent = bookPanel,
		Text = "📖 Выбор книги заклинаний",
		Font = Enum.Font.GothamBold,
		TextSize = 20,
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.fromOffset(0, 10),
	})

	local scroll = Instance.new("ScrollingFrame")
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.new(1, -24, 1, -60)
	scroll.Position = UDim2.fromOffset(12, 52)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 6
	scroll.Parent = bookPanel
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 8)
	list.Parent = scroll

	local function refresh()
		-- Rebuilt each open to reflect unlock state.
		for _, child in scroll:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		for _, bookId in SpellbookModule.getBookIds() do
			local book = SpellbookModule.getBook(bookId)
			if not book then
				continue
			end
			local unlocked = ClientState.UnlockedBooks[bookId] == true
			local selected = ClientState.SelectedBook == bookId

			local row = makeFrame({
				Parent = scroll,
				Color = selected and COLORS.Accent or COLORS.PanelLight,
				Radius = 10,
				Size = UDim2.new(1, 0, 0, 70),
			})
			makeText({
				Parent = row,
				Text = book.Name,
				Font = Enum.Font.GothamBold,
				TextSize = 16,
				Size = UDim2.new(1, -110, 0, 22),
				Position = UDim2.fromOffset(12, 8),
				XAlign = Enum.TextXAlignment.Left,
			})
			makeText({
				Parent = row,
				Text = ("%s • %s"):format(book.Role, book.Description),
				TextColor = COLORS.Dim,
				TextSize = 12,
				Size = UDim2.new(1, -110, 0, 34),
				Position = UDim2.fromOffset(12, 30),
				XAlign = Enum.TextXAlignment.Left,
			})

			local action = makeButton({
				Parent = row,
				Color = unlocked and COLORS.Accent or COLORS.Essence,
				Text = unlocked and (selected and "Выбрано" or "Выбрать") or ("🔮 " .. book.UnlockCost),
				Size = UDim2.fromOffset(92, 40),
				Position = UDim2.new(1, -12, 0.5, 0),
				AnchorPoint = Vector2.new(1, 0.5),
				Radius = 8,
			})
			action.Activated:Connect(function()
				local remote = Remotes.func(Remotes.Names.SelectSpellbook)
				local payload = { BookId = bookId, Action = unlocked and "select" or "unlock" }
				local ok, result = pcall(function()
					return remote:InvokeServer(payload)
				end)
				if ok and type(result) == "table" then
					HUDController.pushNotification(result.Message or "", result.Ok and "reward" or "warn")
				end
			end)
		end
	end

	bookPanel:GetAttributeChangedSignal("Refresh"):Connect(refresh)
	ClientState.Changed:Connect(function()
		if bookPanel.Visible then
			refresh()
		end
	end)
	-- Prime once.
	refresh()
end

-- Build: results screen -------------------------------------------------------

local function buildResults(parent: Instance)
	resultsPanel = makeFrame({
		Parent = parent,
		Color = COLORS.Panel,
		Transparency = 0.02,
		Radius = 16,
		Size = UDim2.fromOffset(420, 320),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
	})
end

function HUDController.showResults(data: { [string]: any })
	for _, child in resultsPanel:GetChildren() do
		if not child:IsA("UICorner") then
			child:Destroy()
		end
	end
	makeText({
		Parent = resultsPanel,
		Text = "Матч окончен",
		Font = Enum.Font.GothamBold,
		TextSize = 26,
		Size = UDim2.new(1, 0, 0, 44),
		Position = UDim2.fromOffset(0, 16),
	})
	local rows = {
		{ "Волн пройдено", tostring(data.WavesCleared or 0) },
		{ "Убийств", tostring(data.Kills or 0) },
		{ "Нанесено урона", tostring(data.Damage or 0) },
		{ "Исцелено", tostring(data.Healing or 0) },
	}
	for i, row in rows do
		makeText({
			Parent = resultsPanel,
			Text = row[1],
			TextColor = COLORS.Dim,
			TextSize = 16,
			Size = UDim2.new(0.5, -20, 0, 30),
			Position = UDim2.fromOffset(24, 60 + (i - 1) * 36),
			XAlign = Enum.TextXAlignment.Left,
		})
		makeText({
			Parent = resultsPanel,
			Text = row[2],
			Font = Enum.Font.GothamBold,
			TextSize = 18,
			Size = UDim2.new(0.5, -20, 0, 30),
			Position = UDim2.new(0.5, 0, 0, 60 + (i - 1) * 36),
			XAlign = Enum.TextXAlignment.Right,
		})
	end
	local close = makeButton({
		Parent = resultsPanel,
		Text = "Продолжить",
		Size = UDim2.fromOffset(180, 44),
		Position = UDim2.new(0.5, 0, 1, -20),
		AnchorPoint = Vector2.new(0.5, 1),
	})
	close.Activated:Connect(function()
		resultsPanel.Visible = false
	end)
	resultsPanel.Visible = true
end

-- Update loops ----------------------------------------------------------------

local function updateVitals()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local frac = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
		hpFill.Size = UDim2.fromScale(frac, 1)
		hpText.Text = ("%d / %d"):format(math.ceil(humanoid.Health), humanoid.MaxHealth)
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
			local remaining = frac * spell.Cooldown
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

		-- Shop during intermission; book selector when idle/ended.
		shopPanel.Visible = (data.Phase == "Intermission")
		if data.Phase == "Idle" or data.Phase == "Ended" then
			bookPanel:SetAttribute("Refresh", os.clock())
			bookPanel.Visible = true
		elseif data.Phase == "Active" then
			bookPanel.Visible = false
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
	end)

	Remotes.event(Remotes.Names.Notify).OnClientEvent:Connect(function(data)
		HUDController.pushNotification(data.Text or "", data.Kind)
	end)

	Remotes.event(Remotes.Names.MatchEnded).OnClientEvent:Connect(function(data)
		HUDController.showResults(data)
	end)
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
	buildNotifications(gui)
	buildShop(gui)
	buildBookPanel(gui)
	buildResults(gui)

	-- "Книги" toggle button.
	local toggle = makeButton({
		Parent = gui,
		Text = "📖 Книги",
		Color = COLORS.PanelLight,
		Size = UDim2.fromOffset(110, 34),
		Position = UDim2.fromOffset(200, 12),
		Radius = 8,
	})
	toggle.Activated:Connect(function()
		bookPanel:SetAttribute("Refresh", os.clock())
		bookPanel.Visible = not bookPanel.Visible
	end)
end

function HUDController.Start()
	wireRemotes()
	updateCurrency()
	RunService.RenderStepped:Connect(function()
		updateVitals()
		updateCooldowns()
	end)
end

return HUDController
