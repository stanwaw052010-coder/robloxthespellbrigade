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

-- Controllers expose optional Init/Start, so the list is deliberately loose:
-- annotating it as { any } stops the checker from inferring the whole array
-- from its first element.
--
-- HUDController creates the ScreenGui and mounts the panel controllers into it
-- during Init, so it must run before their Start. Every Init runs before every
-- Start, which guarantees that ordering regardless of position in this list.
local CONTROLLERS: { any } = {
	require(script.ClientState),
	require(script.AmbianceController),
	require(script.VFXController),
	require(script.SpellInputController),
	require(script.HUDController),
	require(script.MinimapController),
	require(script.PartyFrameController),
	require(script.LobbyPanelController),
}

for _, controller in CONTROLLERS do
	if type(controller.Init) == "function" then
		local ok: boolean, err: any = pcall(controller.Init)
		if not ok then
			warn("[Client] Init failed: " .. tostring(err))
		end
	end
end

for _, controller in CONTROLLERS do
	if type(controller.Start) == "function" then
		local ok: boolean, err: any = pcall(controller.Start)
		if not ok then
			warn("[Client] Start failed: " .. tostring(err))
		end
	end
end

print("[MagicBrigade] Client controllers online.")
