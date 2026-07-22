--!strict
--[[
	Client bootstrap (MagicBrigade)
	-------------------------------
	Точка входа клиента: инициализирует контроллеры ввода, HUD и VFX.

	Entry point for each player's client. Requires the controllers and runs
	their Init() then Start(). The client only handles input, presentation and
	local prediction — all authority lives on the server.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Remotes = require(Shared.Remotes)

-- Ensure the remotes folder has replicated before controllers wire listeners.
Remotes.event(Remotes.Names.WaveStateChanged)

local CONTROLLERS = {
	require(script.ClientState),
	require(script.VFXController),
	require(script.SpellInputController),
	require(script.HUDController),
}

for _, controller in CONTROLLERS do
	if type(controller.Init) == "function" then
		local ok, err = pcall(controller.Init)
		if not ok then
			warn("[Client] Init failed: " .. tostring(err))
		end
	end
end

for _, controller in CONTROLLERS do
	if type(controller.Start) == "function" then
		local ok, err = pcall(controller.Start)
		if not ok then
			warn("[Client] Start failed: " .. tostring(err))
		end
	end
end

print("[MagicBrigade] Client controllers online.")
