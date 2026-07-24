--!strict
--[[
	MatchmakingService
	------------------
	Отряды и телепорт в отдельный сервер матча (TeleportService).

	Players form a party in the lobby, then the leader starts the run and the
	whole party is teleported into a reserved server of its own — so a party of
	four is not sharing an arena with strangers.

	Two modes, chosen by GameConfig.Matchmaking.Enabled:

	  • Enabled = false (default) — parties are still tracked and shown in the
	    lobby UI, but "start" simply plays the match in the CURRENT instance.
	    This is what runs in Studio, where TeleportService cannot reserve a
	    server, and it keeps the single-place setup working unchanged.

	  • Enabled = true — the leader's start reserves a server via
	    TeleportService:ReserveServer and teleports the party with
	    TeleportToPrivateServer, passing the roster as TeleportData.

	Teleporting can fail for reasons outside our control (rate limits, the
	target place being unpublished, a player leaving mid-teleport). Every
	failure path falls back to playing locally and tells the party why, rather
	than leaving anyone stuck on a loading screen.

	NOTE: reserved servers require a published place. In Studio the reserve call
	throws, which is caught here and treated as "play locally".
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Shared = game:GetService("ReplicatedStorage").Shared
local GameConfig = require(Shared.GameConfig)
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)

local MatchmakingService = {}

-- Fires (party) when a party asks to start in THIS instance (teleporting off,
-- or teleport failed). WaveManager listens so a lobby party can kick a match.
MatchmakingService.LocalStartRequested = Signal.new()

export type Party = {
	Id: string,
	LeaderUserId: number,
	Members: { Player },
	Teleporting: boolean,
}

local parties: { [string]: Party } = {}
local partyOf: { [Player]: string } = {}
local nextPartyId = 0

-- Helpers ---------------------------------------------------------------------

local function newPartyId(): string
	nextPartyId += 1
	return ("party_%d_%d"):format(os.time() % 100000, nextPartyId)
end

--[[ Returns the party with this id, creating it if this server has not seen it
     before — which is exactly what happens in a freshly reserved server, where
     the first arriving member has to rebuild the roster from TeleportData. ]]
local function ensureParty(partyId: string, leaderUserId: number): Party
	local existing = parties[partyId]
	if existing then
		return existing
	end
	local party: Party = {
		Id = partyId,
		LeaderUserId = leaderUserId,
		Members = {},
		Teleporting = false,
	}
	parties[partyId] = party
	return party
end

local function indexOfMember(party: Party, player: Player): number?
	for i, member in party.Members do
		if member == player then
			return i
		end
	end
	return nil
end

--[[ Serialisable view of a party for the client lobby panel. ]]
local function describe(party: Party?): any
	if not party then
		return { InParty = false, Members = {} }
	end
	local members = {}
	for _, player in party.Members do
		table.insert(members, {
			UserId = player.UserId,
			Name = player.DisplayName ~= "" and player.DisplayName or player.Name,
			IsLeader = player.UserId == party.LeaderUserId,
		})
	end
	return {
		InParty = true,
		PartyId = party.Id,
		LeaderUserId = party.LeaderUserId,
		Members = members,
		Teleporting = party.Teleporting,
		MaxSize = GameConfig.MaxPartySize,
	}
end

local function pushState(player: Player)
	local party = parties[partyOf[player] or ""]
	Remotes.event(Remotes.Names.MatchmakingStateChanged):FireClient(player, describe(party))
end

local function pushPartyState(party: Party)
	for _, member in party.Members do
		pushState(member)
	end
end

local function notify(player: Player, text: string, kind: string?)
	Remotes.event(Remotes.Names.Notify):FireClient(player, { Text = text, Kind = kind or "info" })
end

--[[ Removes a player from their party, disbanding or promoting as needed. ]]
local function leaveParty(player: Player)
	local partyId = partyOf[player]
	if not partyId then
		return
	end
	local party = parties[partyId]
	partyOf[player] = nil
	if not party then
		return
	end

	local index = indexOfMember(party, player)
	if index then
		table.remove(party.Members, index)
	end

	if #party.Members == 0 then
		parties[partyId] = nil
		return
	end

	-- Promote the longest-standing remaining member.
	if party.LeaderUserId == player.UserId then
		party.LeaderUserId = party.Members[1].UserId
		notify(party.Members[1], "Вы теперь лидер отряда", "info")
	end
	pushPartyState(party)
	pushState(player)
end

-- Teleport --------------------------------------------------------------------

--[[ Reserves a private server and sends the party there. Returns (ok, message).
     Any failure leaves the party intact in this instance. ]]
local function teleportParty(party: Party): (boolean, string)
	local placeId = GameConfig.Matchmaking.MatchPlaceId
	if placeId == 0 then
		placeId = game.PlaceId
	end

	local ok, accessCode = pcall(function()
		return TeleportService:ReserveServer(placeId)
	end)
	if not ok or type(accessCode) ~= "string" then
		return false, "Не удалось зарезервировать сервер"
	end

	-- Only teleport members who are still connected.
	local present: { Player } = {}
	for _, member in party.Members do
		if member.Parent then
			table.insert(present, member)
		end
	end
	if #present == 0 then
		return false, "Отряд пуст"
	end

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = accessCode
	options:SetTeleportData({
		PartyId = party.Id,
		LeaderUserId = party.LeaderUserId,
	})

	local sent, err = pcall(function()
		TeleportService:TeleportAsync(placeId, present, options)
	end)
	if not sent then
		return false, "Телепорт не удался: " .. tostring(err)
	end
	return true, "Переходим в матч…"
end

-- Request handling ------------------------------------------------------------

local function handleRequest(player: Player, payload: any): any
	if type(payload) ~= "table" or type(payload.Action) ~= "string" then
		return { Ok = false, Message = "Некорректный запрос" }
	end
	local action = payload.Action

	if action == "state" then
		return { Ok = true, State = describe(parties[partyOf[player] or ""]) }
	elseif action == "list" then
		-- Parties a player could still join, for the lobby browser.
		local open = {}
		for _, party in parties do
			if not party.Teleporting and #party.Members > 0 and #party.Members < GameConfig.MaxPartySize then
				local leaderName = "?"
				for _, member in party.Members do
					if member.UserId == party.LeaderUserId then
						leaderName = member.DisplayName ~= "" and member.DisplayName or member.Name
						break
					end
				end
				table.insert(open, {
					PartyId = party.Id,
					LeaderName = leaderName,
					Size = #party.Members,
					MaxSize = GameConfig.MaxPartySize,
				})
			end
		end
		return { Ok = true, Parties = open, State = describe(parties[partyOf[player] or ""]) }
	elseif action == "create" then
		if partyOf[player] then
			return { Ok = false, Message = "Вы уже в отряде" }
		end
		local party: Party = {
			Id = newPartyId(),
			LeaderUserId = player.UserId,
			Members = { player },
			Teleporting = false,
		}
		parties[party.Id] = party
		partyOf[player] = party.Id
		pushState(player)
		return { Ok = true, Message = "Отряд создан", State = describe(party) }
	elseif action == "join" then
		if type(payload.PartyId) ~= "string" then
			return { Ok = false, Message = "Некорректный запрос" }
		end
		if partyOf[player] then
			return { Ok = false, Message = "Вы уже в отряде" }
		end
		local party = parties[payload.PartyId]
		if not party then
			return { Ok = false, Message = "Отряд не найден" }
		end
		if party.Teleporting then
			return { Ok = false, Message = "Отряд уже уходит в матч" }
		end
		if #party.Members >= GameConfig.MaxPartySize then
			return { Ok = false, Message = "Отряд полон" }
		end
		table.insert(party.Members, player)
		partyOf[player] = party.Id
		pushPartyState(party)
		return { Ok = true, Message = "Вы вступили в отряд", State = describe(party) }
	elseif action == "leave" then
		if not partyOf[player] then
			return { Ok = false, Message = "Вы не в отряде" }
		end
		leaveParty(player)
		return { Ok = true, Message = "Вы покинули отряд", State = describe(nil) }
	elseif action == "start" then
		local party = parties[partyOf[player] or ""]
		if not party then
			return { Ok = false, Message = "Вы не в отряде" }
		end
		if party.LeaderUserId ~= player.UserId then
			return { Ok = false, Message = "Только лидер может начать матч" }
		end
		if party.Teleporting then
			return { Ok = false, Message = "Матч уже запускается" }
		end

		if not GameConfig.Matchmaking.Enabled or RunService:IsStudio() then
			-- Single-instance mode: play right here.
			MatchmakingService.LocalStartRequested:Fire(party)
			return { Ok = true, Message = "Матч начинается здесь", State = describe(party) }
		end

		party.Teleporting = true
		pushPartyState(party)

		local ok, message = teleportParty(party)
		if not ok then
			-- Never strand the party on a failed teleport: play locally instead.
			party.Teleporting = false
			pushPartyState(party)
			for _, member in party.Members do
				notify(member, message .. " — играем на этом сервере", "warn")
			end
			MatchmakingService.LocalStartRequested:Fire(party)
			return { Ok = true, Message = message, State = describe(party) }
		end
		return { Ok = true, Message = message, State = describe(party) }
	end

	return { Ok = false, Message = "Неизвестное действие" }
end

-- Public API ------------------------------------------------------------------

--[[ The party a player belongs to, or nil. ]]
function MatchmakingService.getParty(player: Player): Party?
	return parties[partyOf[player] or ""]
end

--[[ Every player currently grouped with `player` (including them). Players not
     in a party are treated as a party of one. ]]
function MatchmakingService.getPartyMembers(player: Player): { Player }
	local party = MatchmakingService.getParty(player)
	if not party then
		return { player }
	end
	return table.clone(party.Members)
end

-- Lifecycle -------------------------------------------------------------------

function MatchmakingService.Init() end

function MatchmakingService.Start()
	Players.PlayerRemoving:Connect(leaveParty)

	Players.PlayerAdded:Connect(function(player)
		-- Players arriving in a reserved server carry their party roster in
		-- TeleportData; surface it so the lobby panel shows the right thing.
		local data = player:GetJoinData()
		local teleportData = data and data.TeleportData
		if type(teleportData) == "table" and type(teleportData.PartyId) == "string" then
			local party = ensureParty(
				teleportData.PartyId,
				tonumber(teleportData.LeaderUserId) or player.UserId
			)
			table.insert(party.Members, player)
			partyOf[player] = party.Id
			pushPartyState(party)
			return
		end
		pushState(player)
	end)

	Remotes.func(Remotes.Names.MatchmakingRequest).OnServerInvoke = function(player: Player, payload: any)
		return handleRequest(player, payload)
	end
end

return MatchmakingService
