--!strict
--[[
	UIKit
	-----
	Общие цвета и фабрики элементов интерфейса (только клиент).

	Shared palette and widget factories for every client panel. Kept in one
	module so the HUD, lobby, party frames and minimap look like one interface
	and a colour change lands everywhere at once.

	Style follows §6.1: bold outlined text, rounded corners, element-coloured
	accents so a player reads their class at a glance.
]]

local UIKit = {}

UIKit.Colors = {
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
	Success = Color3.fromRGB(90, 200, 130),
}

-- Element accent colours (skill frames, party frames, minimap blips).
UIKit.ElementColors = {
	Fire = Color3.fromRGB(255, 90, 40),
	Ice = Color3.fromRGB(120, 200, 255),
	Earth = Color3.fromRGB(180, 140, 90),
	Lightning = Color3.fromRGB(255, 235, 110),
	Holy = Color3.fromRGB(255, 225, 150),
	Shadow = Color3.fromRGB(170, 110, 230),
} :: { [string]: Color3 }

function UIKit.elementColor(element: string?): Color3
	return (element and UIKit.ElementColors[element]) or UIKit.Colors.Accent
end

-- Widget factories ------------------------------------------------------------

function UIKit.corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

function UIKit.stroke(parent: Instance, color: Color3, thickness: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 2
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

function UIKit.frame(props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = props.Color or UIKit.Colors.Panel
	f.BackgroundTransparency = props.Transparency or 0
	f.BorderSizePixel = 0
	f.Size = props.Size or UDim2.fromOffset(100, 100)
	f.Position = props.Position or UDim2.fromScale(0, 0)
	f.AnchorPoint = props.AnchorPoint or Vector2.zero
	f.Visible = props.Visible ~= false
	f.ZIndex = props.ZIndex or 1
	if props.Parent then
		f.Parent = props.Parent
	end
	if props.Radius then
		UIKit.corner(f, props.Radius)
	end
	return f
end

function UIKit.text(props: { [string]: any }): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = props.Font or Enum.Font.GothamMedium
	t.Text = props.Text or ""
	t.TextColor3 = props.TextColor or UIKit.Colors.Text
	t.TextScaled = props.TextScaled or false
	t.TextSize = props.TextSize or 16
	t.TextWrapped = props.Wrapped or false
	t.TextXAlignment = props.XAlign or Enum.TextXAlignment.Center
	t.TextYAlignment = props.YAlign or Enum.TextYAlignment.Center
	t.Size = props.Size or UDim2.fromScale(1, 1)
	t.Position = props.Position or UDim2.fromScale(0, 0)
	t.AnchorPoint = props.AnchorPoint or Vector2.zero
	t.ZIndex = props.ZIndex or 1
	if props.Parent then
		t.Parent = props.Parent
	end
	return t
end

function UIKit.button(props: { [string]: any }): TextButton
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = props.Color or UIKit.Colors.Accent
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.GothamBold
	b.Text = props.Text or ""
	b.TextColor3 = props.TextColor or UIKit.Colors.Text
	b.TextSize = props.TextSize or 15
	b.TextWrapped = props.Wrapped or false
	b.Size = props.Size or UDim2.fromOffset(160, 40)
	b.Position = props.Position or UDim2.fromScale(0, 0)
	b.AnchorPoint = props.AnchorPoint or Vector2.zero
	b.ZIndex = props.ZIndex or 1
	if props.Parent then
		b.Parent = props.Parent
	end
	UIKit.corner(b, props.Radius or 8)
	return b
end

--[[ A background bar with a coloured fill child. Returns the fill so callers
     can drive it with `fill.Size = UDim2.fromScale(fraction, 1)`. ]]
function UIKit.bar(props: { [string]: any }): (Frame, Frame)
	local bg = UIKit.frame({
		Parent = props.Parent,
		Color = props.BackgroundColor or UIKit.Colors.PanelLight,
		Radius = props.Radius or 6,
		Size = props.Size or UDim2.new(1, 0, 0, 14),
		Position = props.Position or UDim2.fromScale(0, 0),
		AnchorPoint = props.AnchorPoint,
		ZIndex = props.ZIndex,
	})
	local fill = UIKit.frame({
		Parent = bg,
		Color = props.FillColor or UIKit.Colors.Health,
		Radius = props.Radius or 6,
		Size = UDim2.fromScale(1, 1),
		ZIndex = (props.ZIndex or 1) + 1,
	})
	return bg, fill
end

--[[ Vertical list layout helper used by every scrolling panel. ]]
function UIKit.list(parent: Instance, padding: number?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, padding or 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent
	return layout
end

--[[ A scrolling container that grows with its children. ]]
function UIKit.scroll(props: { [string]: any }): ScrollingFrame
	local s = Instance.new("ScrollingFrame")
	s.BackgroundTransparency = 1
	s.BorderSizePixel = 0
	s.Size = props.Size or UDim2.fromScale(1, 1)
	s.Position = props.Position or UDim2.fromScale(0, 0)
	s.CanvasSize = UDim2.new()
	s.AutomaticCanvasSize = Enum.AutomaticSize.Y
	s.ScrollBarThickness = 6
	s.ScrollBarImageColor3 = UIKit.Colors.Accent
	s.ZIndex = props.ZIndex or 1
	if props.Parent then
		s.Parent = props.Parent
	end
	return s
end

return UIKit
