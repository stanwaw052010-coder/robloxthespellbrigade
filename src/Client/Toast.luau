--!strict
--[[
	Toast
	-----
	Всплывающие уведомления (награды, предупреждения, боссы).

	Owns the notification stack in the top-right corner. Lives in its own module
	so any panel can raise a toast without depending on the HUD — which would
	otherwise make the HUD and the lobby panel require each other.
]]

local TweenService = game:GetService("TweenService")

local UIKit = require(script.Parent.UIKit)

local Toast = {}

local holder: Frame? = nil

local KIND_COLORS: { [string]: Color3 } = {
	info = UIKit.Colors.PanelLight,
	warn = Color3.fromRGB(140, 60, 60),
	reward = Color3.fromRGB(60, 110, 70),
	levelup = Color3.fromRGB(90, 80, 140),
	boss = Color3.fromRGB(150, 50, 120),
}

--[[ Builds the stack. `topOffset` leaves room for whatever sits above it
     (the minimap). ]]
function Toast.mount(parent: Instance, topOffset: number)
	holder = UIKit.frame({
		Parent = parent,
		Transparency = 1,
		Size = UDim2.fromOffset(300, 260),
		Position = UDim2.new(1, -12, 0, topOffset),
		AnchorPoint = Vector2.new(1, 0),
	})
	local layout = UIKit.list(holder :: Frame, 6)
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
end

function Toast.push(text: string, kind: string?)
	if not holder then
		return
	end
	local toast = UIKit.frame({
		Parent = holder,
		Color = KIND_COLORS[kind or "info"] or UIKit.Colors.PanelLight,
		Transparency = 0.1,
		Radius = 8,
		Size = UDim2.fromOffset(300, 34),
	})
	local label = UIKit.text({
		Parent = toast,
		Text = text,
		TextSize = 15,
		Font = Enum.Font.GothamBold,
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		XAlign = Enum.TextXAlignment.Left,
	})

	task.delay(3.5, function()
		if not toast.Parent then
			return
		end
		local info = TweenInfo.new(0.4)
		TweenService:Create(label, info, { TextTransparency = 1 }):Play()
		local tween = TweenService:Create(toast, info, { BackgroundTransparency = 1 })
		tween:Play()
		tween.Completed:Wait()
		toast:Destroy()
	end)
end

return Toast
