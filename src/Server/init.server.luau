--!strict
--[[
	Server bootstrap (MagicBrigade)
	-------------------------------
	Точка входа сервера: инициализирует и запускает все сервисы в правильном
	порядке, настраивает персонажей игроков.

	Entry point for the server. Requires every service module, runs their
	Init() (state setup, no cross-service calls) then Start() (wire signals,
	begin loops) in dependency order, and applies per-player character stats.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local GameConfig = require(Shared.GameConfig)
local Remotes = require(Shared.Remotes)

-- Create every networking object up front so clients can wire listeners
-- immediately without waiting on the first fire of a lazily-created remote.
Remotes.preCreateAll()

local Services = script.Services

-- Order matters: dependencies first. Init all, then Start all.
local ORDER = {
	"PlayerDataService",
	"BaseService",
	"DamageService",
	"EconomyService",
	"BossController",
	"EnemyService",
	"AntiExploit",
	"UpgradeService",
	"LobbyService",
	"SpellCastingService",
	"WaveManager",
}

local loaded: { [string]: any } = {}

for _, name in ORDER do
	local module = Services:FindFirstChild(name)
	if not module then
		warn("[Server] missing service module: " .. name)
		continue
	end
	loaded[name] = require(module)
end

for _, name in ORDER do
	local service = loaded[name]
	if service and type(service.Init) == "function" then
		local ok, err = pcall(service.Init)
		if not ok then
			warn(("[Server] %s:Init failed: %s"):format(name, tostring(err)))
		end
	end
end

for _, name in ORDER do
	local service = loaded[name]
	if service and type(service.Start) == "function" then
		local ok, err = pcall(service.Start)
		if not ok then
			warn(("[Server] %s:Start failed: %s"):format(name, tostring(err)))
		end
	end
end

-- Apply configured character stats on every spawn.
local function setupCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if not humanoid then
		return
	end
	humanoid.MaxHealth = GameConfig.Player.MaxHealth
	humanoid.Health = GameConfig.Player.MaxHealth
	humanoid.WalkSpeed = GameConfig.Player.BaseWalkSpeed
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(setupCharacter)
	if player.Character then
		setupCharacter(player.Character)
	end
end
for _, player in Players:GetPlayers() do
	onPlayer(player)
end
Players.PlayerAdded:Connect(onPlayer)

-- Reasonable respawn cadence for a defense game.
Players.RespawnTime = GameConfig.Player.RespawnTime

print("[MagicBrigade] Server started. Services online: " .. #ORDER)
