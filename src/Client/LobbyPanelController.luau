--!strict
--[[
	LobbyPanelController
	--------------------
	Лобби: выбор книги, кастомизация внешности и сбор отряда (§6, §6.1).

	One tabbed window, opened from the HUD's "📖 Лобби" button:

	  • Книги    — pick your spellbook, unlock new ones for Essence.
	  • Внешность — auras and headwear (кастомизация персонажа).
	  • Отряд    — create/join a party and start the run together.

	Every action is a request: the server validates ownership and cost and
	answers with { Ok, Message }. This panel only renders what came back.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local CosmeticsCatalogue = require(Shared.CosmeticsCatalogue)
local Remotes = require(Shared.Remotes)
local SpellbookModule = require(Shared.SpellbookModule)

local ClientState = require(script.Parent.ClientState)
local Toast = require(script.Parent.Toast)
local UIKit = require(script.Parent.UIKit)

local LobbyPanelController = {}

local localPlayer = Players.LocalPlayer

local TABS = {
	{ Id = "Books", Label = "📖 Книги" },
	{ Id = "Looks", Label = "✨ Внешность" },
	{ Id = "Party", Label = "👥 Отряд" },
}

local panel: Frame
local content: ScrollingFrame
local tabButtons: { [string]: TextButton } = {}
local activeTab = "Books"
local partyState: any = { InParty = false, Members = {} }
local openParties: { any } = {}

-- Rendering helpers -----------------------------------------------------------

local function clearContent()
	for _, child in content:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

--[[ A standard list row: title, subtitle and one action button. ]]
local function makeRow(props: { [string]: any }): (Frame, TextButton)
	local row = UIKit.frame({
		Parent = content,
		Color = props.Highlighted and UIKit.Colors.Accent or UIKit.Colors.PanelLight,
		Radius = 10,
		Size = UDim2.new(1, 0, 0, 70),
	})
	row.LayoutOrder = props.Order or 0

	if props.AccentColor then
		local stripe = UIKit.frame({
			Parent = row,
			Color = props.AccentColor,
			Radius = 3,
			Size = UDim2.new(0, 5, 1, -16),
			Position = UDim2.fromOffset(8, 8),
		})
		stripe.ZIndex = 2
	end

	UIKit.text({
		Parent = row,
		Text = props.Title or "",
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		Size = UDim2.new(1, -130, 0, 22),
		Position = UDim2.fromOffset(20, 8),
		XAlign = Enum.TextXAlignment.Left,
	})
	UIKit.text({
		Parent = row,
		Text = props.Subtitle or "",
		TextColor = props.Highlighted and UIKit.Colors.Text or UIKit.Colors.Dim,
		TextSize = 12,
		Wrapped = true,
		Size = UDim2.new(1, -130, 0, 34),
		Position = UDim2.fromOffset(20, 30),
		XAlign = Enum.TextXAlignment.Left,
		YAlign = Enum.TextYAlignment.Top,
	})

	local button = UIKit.button({
		Parent = row,
		Color = props.ButtonColor or UIKit.Colors.Accent,
		Text = props.ButtonText or "",
		TextSize = 13,
		Wrapped = true,
		Size = UDim2.fromOffset(100, 42),
		Position = UDim2.new(1, -12, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Radius = 8,
	})
	return row, button
end

--[[ Invokes a RemoteFunction and toasts the server's answer. Returns the
     result table so callers can read extra fields. ]]
local function request(remoteName: string, payload: any, silent: boolean?): any
	local ok, result = pcall(function()
		return Remotes.func(remoteName):InvokeServer(payload)
	end)
	if not ok then
		warn("[LobbyPanelController] request failed: " .. tostring(result))
		return nil
	end
	if type(result) == "table" and not silent and result.Message then
		Toast.push(result.Message, result.Ok and "reward" or "warn")
	end
	return result
end

-- Tabs ------------------------------------------------------------------------

local renderTab -- forward declaration (tab renderers re-render on action)

local function renderBooks()
	for i, bookId in SpellbookModule.getBookIds() do
		local book = SpellbookModule.getBook(bookId)
		if not book then
			continue
		end
		local unlocked = ClientState.UnlockedBooks[bookId] == true
		local selected = ClientState.SelectedBook == bookId

		local _, button = makeRow({
			Order = i,
			Title = book.Name,
			Subtitle = ("%s • %s"):format(book.Role, book.Description),
			Highlighted = selected,
			AccentColor = UIKit.elementColor(book.Element),
			ButtonColor = unlocked and UIKit.Colors.Accent or UIKit.Colors.Essence,
			ButtonText = unlocked and (selected and "Выбрано" or "Выбрать") or ("🔮 " .. book.UnlockCost),
		})
		button.Activated:Connect(function()
			request(Remotes.Names.SelectSpellbook, {
				BookId = bookId,
				Action = unlocked and "select" or "unlock",
			})
			renderTab()
		end)
	end
end

local function renderCosmeticSection(kind: string, heading: string, order: number)
	local header = UIKit.text({
		Parent = content,
		Text = heading,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextColor = UIKit.Colors.Dim,
		Size = UDim2.new(1, 0, 0, 24),
		XAlign = Enum.TextXAlignment.Left,
	})
	header.LayoutOrder = order

	for i, id in CosmeticsCatalogue.order(kind) do
		local entry = CosmeticsCatalogue.get(kind, id)
		if not entry then
			continue
		end
		local owned = entry.Cost <= 0 or ClientState.UnlockedCosmetics[kind .. ":" .. id] == true
		local equipped = ClientState.Cosmetics[kind] == id

		local _, button = makeRow({
			Order = order + i,
			Title = entry.Name,
			Subtitle = entry.Description,
			Highlighted = equipped,
			AccentColor = kind == "Aura" and entry.Color or nil,
			ButtonColor = owned and UIKit.Colors.Accent or UIKit.Colors.Essence,
			ButtonText = owned and (equipped and "Надето" or "Надеть") or ("🔮 " .. entry.Cost),
		})
		button.Activated:Connect(function()
			request(Remotes.Names.CosmeticRequest, {
				Kind = kind,
				Id = id,
				Action = owned and "equip" or "unlock",
			})
			renderTab()
		end)
	end
end

local function renderLooks()
	renderCosmeticSection("Aura", "Ауры", 0)
	renderCosmeticSection("Hat", "Головные уборы", 100)
end

local function renderParty()
	if partyState.InParty then
		local isLeader = partyState.LeaderUserId == localPlayer.UserId

		local header = UIKit.text({
			Parent = content,
			Text = ("Ваш отряд (%d/%d)"):format(#partyState.Members, partyState.MaxSize or 8),
			Font = Enum.Font.GothamBold,
			TextSize = 15,
			TextColor = UIKit.Colors.Dim,
			Size = UDim2.new(1, 0, 0, 24),
			XAlign = Enum.TextXAlignment.Left,
		})
		header.LayoutOrder = 0

		for i, member in partyState.Members do
			local row = UIKit.frame({
				Parent = content,
				Color = UIKit.Colors.PanelLight,
				Radius = 8,
				Size = UDim2.new(1, 0, 0, 38),
			})
			row.LayoutOrder = i
			UIKit.text({
				Parent = row,
				Text = (member.IsLeader and "👑 " or "• ") .. member.Name,
				TextSize = 14,
				Size = UDim2.new(1, -20, 1, 0),
				Position = UDim2.fromOffset(14, 0),
				XAlign = Enum.TextXAlignment.Left,
			})
		end

		local actions = UIKit.frame({
			Parent = content,
			Transparency = 1,
			Size = UDim2.new(1, 0, 0, 48),
		})
		actions.LayoutOrder = 500

		local leave = UIKit.button({
			Parent = actions,
			Color = UIKit.Colors.Danger,
			Text = "Покинуть отряд",
			Size = UDim2.new(0.48, 0, 1, 0),
		})
		leave.Activated:Connect(function()
			request(Remotes.Names.MatchmakingRequest, { Action = "leave" })
			renderTab()
		end)

		local start = UIKit.button({
			Parent = actions,
			Color = isLeader and UIKit.Colors.Success or UIKit.Colors.PanelLight,
			Text = isLeader and "▶ Начать матч" or "Ждём лидера…",
			Size = UDim2.new(0.48, 0, 1, 0),
			Position = UDim2.new(0.52, 0, 0, 0),
		})
		start.Active = isLeader
		start.Activated:Connect(function()
			if not isLeader then
				return
			end
			request(Remotes.Names.MatchmakingRequest, { Action = "start" })
			LobbyPanelController.setVisible(false)
		end)
		return
	end

	-- Not in a party: offer to create one, and list the open ones.
	local create = UIKit.button({
		Parent = content,
		Color = UIKit.Colors.Success,
		Text = "➕ Создать отряд",
		Size = UDim2.new(1, 0, 0, 44),
	})
	create.LayoutOrder = 0
	create.Activated:Connect(function()
		request(Remotes.Names.MatchmakingRequest, { Action = "create" })
		LobbyPanelController.refreshParty()
	end)

	local header = UIKit.text({
		Parent = content,
		Text = #openParties > 0 and "Открытые отряды" or "Открытых отрядов нет",
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextColor = UIKit.Colors.Dim,
		Size = UDim2.new(1, 0, 0, 24),
		XAlign = Enum.TextXAlignment.Left,
	})
	header.LayoutOrder = 1

	for i, party in openParties do
		local _, button = makeRow({
			Order = 1 + i,
			Title = ("Отряд %s"):format(party.LeaderName),
			Subtitle = ("Участников: %d из %d"):format(party.Size, party.MaxSize),
			ButtonText = "Вступить",
		})
		button.Activated:Connect(function()
			request(Remotes.Names.MatchmakingRequest, { Action = "join", PartyId = party.PartyId })
			LobbyPanelController.refreshParty()
		end)
	end
end

function renderTab()
	if not panel or not panel.Visible then
		return
	end
	clearContent()
	for id, button in tabButtons do
		button.BackgroundColor3 = id == activeTab and UIKit.Colors.Accent or UIKit.Colors.PanelLight
	end

	if activeTab == "Books" then
		renderBooks()
	elseif activeTab == "Looks" then
		renderLooks()
	else
		renderParty()
	end
end

--[[ Asks the server for the party roster and the open-party list, then
     re-renders if the party tab is showing. ]]
function LobbyPanelController.refreshParty()
	task.spawn(function()
		local result = request(Remotes.Names.MatchmakingRequest, { Action = "list" }, true)
		if type(result) ~= "table" then
			return
		end
		openParties = type(result.Parties) == "table" and result.Parties or {}
		if type(result.State) == "table" then
			partyState = result.State
		end
		if activeTab == "Party" then
			renderTab()
		end
	end)
end

-- Public ----------------------------------------------------------------------

function LobbyPanelController.setVisible(visible: boolean)
	panel.Visible = visible
	if visible then
		if activeTab == "Party" then
			LobbyPanelController.refreshParty()
		end
		renderTab()
	end
end

function LobbyPanelController.isVisible(): boolean
	return panel.Visible
end

function LobbyPanelController.toggle()
	LobbyPanelController.setVisible(not panel.Visible)
end

function LobbyPanelController.mount(parent: Instance)
	panel = UIKit.frame({
		Parent = parent,
		Color = UIKit.Colors.Panel,
		Transparency = 0.03,
		Radius = 14,
		Size = UDim2.fromOffset(460, 430),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 10,
	})

	local close = UIKit.button({
		Parent = panel,
		Color = UIKit.Colors.PanelLight,
		Text = "✕",
		TextSize = 16,
		Size = UDim2.fromOffset(32, 32),
		Position = UDim2.new(1, -10, 0, 10),
		AnchorPoint = Vector2.new(1, 0),
		Radius = 8,
		ZIndex = 12,
	})
	close.Activated:Connect(function()
		LobbyPanelController.setVisible(false)
	end)

	-- Tab bar.
	local tabBar = UIKit.frame({
		Parent = panel,
		Transparency = 1,
		Size = UDim2.new(1, -60, 0, 36),
		Position = UDim2.fromOffset(14, 10),
		ZIndex = 11,
	})
	local tabLayout = UIKit.list(tabBar, 6)
	tabLayout.FillDirection = Enum.FillDirection.Horizontal

	for i, tab in TABS do
		local button = UIKit.button({
			Parent = tabBar,
			Color = UIKit.Colors.PanelLight,
			Text = tab.Label,
			TextSize = 13,
			Size = UDim2.fromOffset(120, 36),
			Radius = 8,
			ZIndex = 11,
		})
		button.LayoutOrder = i
		button.Activated:Connect(function()
			activeTab = tab.Id
			if tab.Id == "Party" then
				LobbyPanelController.refreshParty()
			end
			renderTab()
		end)
		tabButtons[tab.Id] = button
	end

	content = UIKit.scroll({
		Parent = panel,
		Size = UDim2.new(1, -28, 1, -62),
		Position = UDim2.fromOffset(14, 54),
		ZIndex = 11,
	})
	UIKit.list(content, 8)
end

function LobbyPanelController.Init() end

function LobbyPanelController.Start()
	-- The books and cosmetics tabs render straight from ClientState, so a
	-- profile push (unlock, equip, essence spend) must redraw them.
	ClientState.Changed:Connect(function()
		if panel.Visible and activeTab ~= "Party" then
			renderTab()
		end
	end)

	Remotes.event(Remotes.Names.MatchmakingStateChanged).OnClientEvent:Connect(function(state)
		if type(state) ~= "table" then
			return
		end
		partyState = state
		if panel.Visible and activeTab == "Party" then
			renderTab()
		end
	end)
end

return LobbyPanelController
