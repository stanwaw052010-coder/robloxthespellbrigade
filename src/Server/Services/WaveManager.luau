--!strict
--[[
	WaveManager
	-----------
	Серверная логика волн: тайминги, спавн, боссы, победа/поражение.

	Drives the whole match: a grace period, then repeating cycles of
	[intermission -> spawn wave -> wait until cleared]. Difficulty scales via
	WaveDefinitions. The match ends when the base is destroyed; rewards are paid
	and a fresh match starts. Broadcasts wave state to clients for the HUD.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local GameConfig = require(Shared.GameConfig)
local Remotes = require(Shared.Remotes)
local WaveDefinitions = require(Shared.WaveDefinitions)

local EnemyService = require(script.Parent.EnemyService)
local BaseService = require(script.Parent.BaseService)
local EconomyService = require(script.Parent.EconomyService)
local UpgradeService = require(script.Parent.UpgradeService)
local DamageService = require(script.Parent.DamageService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local MatchmakingService = require(script.Parent.MatchmakingService)

local WaveManager = {}

type MatchStat = { Kills: number, Damage: number, Healing: number }

local PHASE_IDLE = "Idle"
local PHASE_INTERMISSION = "Intermission"
local PHASE_ACTIVE = "Active"
local PHASE_ENDED = "Ended"

local currentWave = 0
local phase = PHASE_IDLE
local matchRunning = false
local enemiesLeftToSpawn = 0
local matchStats: { [Player]: MatchStat } = {}

-- State broadcasting ----------------------------------------------------------

local function enemiesRemaining(): number
	return enemiesLeftToSpawn + EnemyService.getAliveWaveEnemyCount()
end

local function broadcast(countdown: number?)
	Remotes.event(Remotes.Names.WaveStateChanged):FireAllClients({
		Wave = currentWave,
		Phase = phase,
		Countdown = countdown,
		EnemiesRemaining = enemiesRemaining(),
		IsBossWave = currentWave > 0 and (currentWave % GameConfig.Wave.BossEvery == 0),
	})
end
WaveManager.broadcast = broadcast

-- Match-stat tracking ---------------------------------------------------------

local function statFor(player: Player): MatchStat
	local s = matchStats[player]
	if not s then
		s = { Kills = 0, Damage = 0, Healing = 0 }
		matchStats[player] = s
	end
	return s
end

local function resetMatchStats()
	table.clear(matchStats)
end

-- Wave execution --------------------------------------------------------------

local function spawnWave(spec)
	-- Build a flat spawn list from the composition, shuffled for variety.
	local spawnList: { string } = {}
	for enemyId, count in spec.Composition do
		for _ = 1, count do
			table.insert(spawnList, enemyId)
		end
	end
	-- Fisher-Yates shuffle.
	for i = #spawnList, 2, -1 do
		local j = math.random(1, i)
		spawnList[i], spawnList[j] = spawnList[j], spawnList[i]
	end

	enemiesLeftToSpawn = #spawnList + (spec.Boss and 1 or 0)

	-- Boss enters first with a fanfare.
	if spec.Boss then
		Remotes.event(Remotes.Names.Notify):FireAllClients({
			Text = ("⚠ БОСС: волна %d!"):format(spec.WaveNumber),
			Kind = "boss",
		})
		EnemyService.spawnEnemy(spec.Boss, spec.HealthMultiplier, spec.DamageMultiplier)
		enemiesLeftToSpawn -= 1
		broadcast()
	end

	for _, enemyId in spawnList do
		if BaseService.isDestroyed() or not matchRunning then
			break
		end
		EnemyService.spawnEnemy(enemyId, spec.HealthMultiplier, spec.DamageMultiplier)
		enemiesLeftToSpawn -= 1
		broadcast()
		task.wait(spec.SpawnDelay)
	end
	enemiesLeftToSpawn = 0
end

local function waitForWaveClear()
	while matchRunning and not BaseService.isDestroyed() do
		if enemiesRemaining() <= 0 then
			return
		end
		broadcast()
		task.wait(0.5)
	end
end

local function runIntermission(seconds: number)
	phase = PHASE_INTERMISSION
	for remaining = seconds, 1, -1 do
		if not matchRunning or BaseService.isDestroyed() then
			return
		end
		broadcast(remaining)
		task.wait(1)
	end
end

-- Match flow ------------------------------------------------------------------

local function endMatch()
	phase = PHASE_ENDED
	matchRunning = false
	broadcast()

	local wavesCleared = math.max(0, currentWave - 1)

	-- Pay rewards and send each player their results.
	for _, player in Players:GetPlayers() do
		if PlayerDataService.get(player) then
			EconomyService.payMatchReward(player, wavesCleared)
			local s = statFor(player)
			Remotes.event(Remotes.Names.MatchEnded):FireClient(player, {
				WavesCleared = wavesCleared,
				Kills = s.Kills,
				Damage = s.Damage,
				Healing = s.Healing,
			})
		end
	end
end

local function runMatch()
	matchRunning = true
	currentWave = 0
	resetMatchStats()
	UpgradeService.resetAll()
	BaseService.reset()
	EnemyService.clearAll()

	phase = PHASE_INTERMISSION
	broadcast(GameConfig.Wave.FirstWaveGraceSeconds)
	runIntermission(GameConfig.Wave.FirstWaveGraceSeconds)

	while matchRunning and not BaseService.isDestroyed() do
		currentWave += 1
		local spec = WaveDefinitions.build(currentWave)

		phase = PHASE_ACTIVE
		broadcast()
		spawnWave(spec)
		waitForWaveClear()

		if BaseService.isDestroyed() then
			break
		end

		-- Wave cleared: pay the clear bonus to everyone.
		EconomyService.grantGoldToAll(spec.Reward)
		Remotes.event(Remotes.Names.Notify):FireAllClients({
			Text = ("Волна %d зачищена! +%d золота"):format(currentWave, spec.Reward),
			Kind = "reward",
		})

		-- Intermission for shopping/repairs.
		runIntermission(GameConfig.Wave.IntermissionSeconds)
	end

	endMatch()
end

--[[ Starts a match if one isn't already running and there are players. ]]
function WaveManager.tryStartMatch()
	if matchRunning then
		return
	end
	if #Players:GetPlayers() < GameConfig.MinPlayersToStart then
		return
	end
	-- Claim the running flag synchronously so a second near-simultaneous caller
	-- can't spawn a duplicate match before runMatch sets it.
	matchRunning = true
	task.spawn(function()
		runMatch()
		-- Brief post-match lobby, then loop into a new match if players remain.
		task.wait(10)
		if #Players:GetPlayers() >= GameConfig.MinPlayersToStart then
			WaveManager.tryStartMatch()
		else
			phase = PHASE_IDLE
			broadcast()
		end
	end)
end

function WaveManager.getPhase(): string
	return phase
end

function WaveManager.getCurrentWave(): number
	return currentWave
end

-- Lifecycle -------------------------------------------------------------------

function WaveManager.Init() end

function WaveManager.Start()
	-- Track per-match contribution for the results screen.
	DamageService.EnemyDied:Connect(function(_def, killer)
		if killer then
			statFor(killer).Kills += 1
		end
	end)
	DamageService.DamageDealt:Connect(function(player, amount)
		if not player then
			return
		end
		local s = statFor(player)
		if amount >= 0 then
			s.Damage += math.floor(amount)
		else
			s.Healing += math.floor(-amount)
		end
	end)

	-- Defeat ends the match immediately.
	BaseService.BaseDestroyed:Connect(function()
		Remotes.event(Remotes.Names.Notify):FireAllClients({
			Text = "База уничтожена! Матч окончен.",
			Kind = "warn",
		})
	end)

	-- A party leader pressing "start" in the lobby kicks the match off here
	-- (either because matchmaking is off, or because the teleport fell back to
	-- this instance).
	MatchmakingService.LocalStartRequested:Connect(function()
		WaveManager.tryStartMatch()
	end)

	-- Auto-start when the first player is ready.
	Players.PlayerAdded:Connect(function()
		task.wait(GameConfig.Wave.FirstWaveGraceSeconds)
		WaveManager.tryStartMatch()
	end)
	if #Players:GetPlayers() >= GameConfig.MinPlayersToStart then
		task.delay(3, WaveManager.tryStartMatch)
	end
end

return WaveManager
