--!strict
--[[
	PartyFrameController
	--------------------
	Табло отряда: HP и мана союзников (§6).

	Draws one frame per teammate down the left edge, under the currency panel:
	name, class colour, health bar and mana bar. Data comes from PartyService's
	PartyStateChanged broadcast — the client never reads other players'
	Humanoids directly, so a modified client learns nothing it wasn't told.

	The local player is excluded (their own bars are in the HUD's vitals panel),
	so the whole panel hides when playing solo.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Remotes = require(Shared.Remotes)

local UIKit = require(script.Parent.UIKit)

local PartyFrameController = {}

local localPlayer = Players.LocalPlayer

local ROW_HEIGHT = 54
local ROW_WIDTH = 210
local MAX_ROWS = 7 -- MaxPartySize minus the local player

type Row = {
	Root: Frame,
	Name: TextLabel,
	HealthFill: Frame,
	HealthText: TextLabel,
	ManaFill: Frame,
	Accent: Frame,
	LastHealth: number,
}

local panelRoot: Frame -- titled container; owns visibility
local rowHolder: Frame -- list container; parent of the pooled rows
local title: TextLabel
-- Rows are pooled and re-bound each broadcast: allocating GUI objects five
-- times a second would churn badly during a wave.
local rows: { Row } = {}

local function buildRow(index: number): Row
	local root = UIKit.frame({
		Parent = rowHolder,
		Color = UIKit.Colors.Panel,
		Transparency = 0.15,
		Radius = 8,
		Size = UDim2.fromOffset(ROW_WIDTH, ROW_HEIGHT),
		Visible = false,
	})
	root.LayoutOrder = index

	-- Class colour stripe down the left edge.
	local accent = UIKit.frame({
		Parent = root,
		Color = UIKit.Colors.Accent,
		Radius = 3,
		Size = UDim2.new(0, 4, 1, -12),
		Position = UDim2.fromOffset(6, 6),
	})

	local name = UIKit.text({
		Parent = root,
		Text = "",
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		Size = UDim2.new(1, -24, 0, 16),
		Position = UDim2.fromOffset(16, 5),
		XAlign = Enum.TextXAlignment.Left,
	})

	local healthBar, healthFill = UIKit.bar({
		Parent = root,
		FillColor = UIKit.Colors.Health,
		Radius = 5,
		Size = UDim2.new(1, -24, 0, 12),
		Position = UDim2.fromOffset(16, 23),
	})
	-- The label sits on the bar's background so it stays put as the fill shrinks.
	local healthText = UIKit.text({
		Parent = healthBar,
		Text = "",
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		ZIndex = 3,
	})

	local _, manaFill = UIKit.bar({
		Parent = root,
		FillColor = UIKit.Colors.Mana,
		Radius = 4,
		Size = UDim2.new(1, -24, 0, 7),
		Position = UDim2.fromOffset(16, 39),
	})

	return {
		Root = root,
		Name = name,
		HealthFill = healthFill,
		HealthText = healthText,
		ManaFill = manaFill,
		Accent = accent,
		LastHealth = -1,
	}
end

--[[ Applies one member's snapshot to a pooled row. ]]
local function bindRow(row: Row, member: any)
	row.Root.Visible = true
	row.Name.Text = member.Name
	row.Accent.BackgroundColor3 = UIKit.elementColor(member.Element)

	local maxHealth = math.max(1, member.MaxHealth)
	local healthFrac = math.clamp(member.Health / maxHealth, 0, 1)
	row.HealthFill.Size = UDim2.fromScale(healthFrac, 1)
	row.HealthText.Text = ("%d / %d"):format(member.Health, member.MaxHealth)

	-- Downed allies grey out so you can spot who needs a revive at a glance.
	if not member.Alive then
		row.HealthFill.BackgroundColor3 = UIKit.Colors.Dim
		row.Name.TextColor3 = UIKit.Colors.Dim
		row.HealthText.Text = "ПАЛ"
	else
		row.Name.TextColor3 = UIKit.Colors.Text
		row.HealthFill.BackgroundColor3 = healthFrac > 0.3 and UIKit.Colors.Health or UIKit.Colors.Danger

		-- Flash the bar when an ally takes a hit (§6.1).
		if row.LastHealth >= 0 and member.Health < row.LastHealth - 0.5 then
			row.HealthFill.BackgroundColor3 = Color3.fromRGB(255, 235, 235)
			TweenService:Create(row.HealthFill, TweenInfo.new(0.35), {
				BackgroundColor3 = UIKit.Colors.Health,
			}):Play()
		end
	end
	row.LastHealth = member.Health

	local maxMana = math.max(1, member.MaxMana)
	row.ManaFill.Size = UDim2.fromScale(math.clamp(member.Mana / maxMana, 0, 1), 1)
end

local function onPartyState(payload: any)
	if type(payload) ~= "table" or type(payload.Members) ~= "table" then
		return
	end

	local allies = {}
	for _, member in payload.Members do
		if member.UserId ~= localPlayer.UserId then
			table.insert(allies, member)
		end
	end

	-- Solo play needs no party frames; the HUD already shows your own bars.
	panelRoot.Visible = #allies > 0
	title.Text = ("👥 Отряд (%d)"):format(#allies + 1)

	for i = 1, MAX_ROWS do
		local row = rows[i]
		local member = allies[i]
		if member then
			if not row then
				row = buildRow(i)
				rows[i] = row
			end
			bindRow(row, member)
		elseif row then
			row.Root.Visible = false
			row.LastHealth = -1
		end
	end
end

--[[ Builds the panel under the currency box on the left edge. ]]
function PartyFrameController.mount(parent: Instance)
	panelRoot = UIKit.frame({
		Parent = parent,
		Transparency = 1,
		Size = UDim2.fromOffset(ROW_WIDTH, MAX_ROWS * (ROW_HEIGHT + 6) + 22),
		Position = UDim2.fromOffset(12, 98),
		Visible = false,
	})
	title = UIKit.text({
		Parent = panelRoot,
		Text = "👥 Отряд",
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor = UIKit.Colors.Dim,
		Size = UDim2.new(1, 0, 0, 18),
		XAlign = Enum.TextXAlignment.Left,
	})

	rowHolder = UIKit.frame({
		Parent = panelRoot,
		Transparency = 1,
		Size = UDim2.new(1, 0, 1, -22),
		Position = UDim2.fromOffset(0, 22),
	})
	UIKit.list(rowHolder, 6)

	Remotes.event(Remotes.Names.PartyStateChanged).OnClientEvent:Connect(onPartyState)
end

function PartyFrameController.Init() end

function PartyFrameController.Start() end

return PartyFrameController
