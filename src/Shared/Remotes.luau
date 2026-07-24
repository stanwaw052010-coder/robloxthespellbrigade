--!strict
--[[
	Remotes
	-------
	Единый реестр RemoteEvent / RemoteFunction.
	Central registry for every networking object. The server calls
	`Remotes.get(name, className)` which creates the instance on demand; the
	client calls the same and waits for replication. Keeping the names in one
	table prevents typos and makes the client/server contract explicit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

-- Canonical names. Grouped by direction for readability.
Remotes.Names = {
	-- Client -> Server (requests, validated on the server)
	CastSpell = "CastSpell", -- fire a spell (RemoteEvent)
	SelectSpellbook = "SelectSpellbook", -- pick class/book in lobby (RemoteFunction)
	PurchaseUpgrade = "PurchaseUpgrade", -- buy an in-match upgrade (RemoteFunction)
	PurchaseSpellNode = "PurchaseSpellNode", -- buy a per-spell tree node (RemoteFunction)
	RequestJoinMatch = "RequestJoinMatch", -- ready up (RemoteEvent)
	CosmeticRequest = "CosmeticRequest", -- unlock/equip a cosmetic (RemoteFunction)
	MatchmakingRequest = "MatchmakingRequest", -- create/join/leave/start a party (RemoteFunction)

	-- Server -> Client (state + presentation)
	PlayVFX = "PlayVFX", -- spawn a visual effect (RemoteEvent)
	WaveStateChanged = "WaveStateChanged", -- wave number / phase / countdown
	BaseHealthChanged = "BaseHealthChanged",
	PlayerStatsChanged = "PlayerStatsChanged", -- gold / mana / hp / xp
	PartyStateChanged = "PartyStateChanged", -- ally roster for the party frames
	SpellTreeChanged = "SpellTreeChanged", -- owned per-spell node levels
	MatchmakingStateChanged = "MatchmakingStateChanged", -- lobby party roster
	MatchEnded = "MatchEnded", -- results screen payload
	Notify = "Notify", -- transient toast messages
}

local FOLDER_NAME = "MagicBrigadeRemotes"

local function getFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		return existing :: Folder
	end

	if RunService:IsServer() then
		local folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
		return folder
	end

	-- Client: the folder is replicated from the server; wait for it.
	return ReplicatedStorage:WaitForChild(FOLDER_NAME, 30) :: Folder
end

--[[
	Returns (creating on the server if needed) a networking instance by name.
	@param name string   -- one of Remotes.Names
	@param className "RemoteEvent" | "RemoteFunction"
]]
function Remotes.get(name: string, className: string): Instance
	assert(type(name) == "string" and name ~= "", "Remotes.get requires a name")
	assert(className == "RemoteEvent" or className == "RemoteFunction", "Unsupported remote class: " .. tostring(className))

	local folder = getFolder()
	local existing = folder:FindFirstChild(name)
	if existing then
		return existing
	end

	if RunService:IsServer() then
		local remote = Instance.new(className)
		remote.Name = name
		remote.Parent = folder
		return remote
	end

	return folder:WaitForChild(name, 30)
end

-- Convenience typed helpers ---------------------------------------------------
function Remotes.event(name: string): RemoteEvent
	return Remotes.get(name, "RemoteEvent") :: RemoteEvent
end

function Remotes.func(name: string): RemoteFunction
	return Remotes.get(name, "RemoteFunction") :: RemoteFunction
end

-- Which names are RemoteFunctions; everything else is a RemoteEvent.
local FUNCTIONS = {
	[Remotes.Names.SelectSpellbook] = true,
	[Remotes.Names.PurchaseUpgrade] = true,
	[Remotes.Names.PurchaseSpellNode] = true,
	[Remotes.Names.CosmeticRequest] = true,
	[Remotes.Names.MatchmakingRequest] = true,
}

--[[
	Server-only: eagerly create every remote so clients never race a lazily
	created one. Call once during server startup, before clients wire listeners.
]]
function Remotes.preCreateAll()
	assert(RunService:IsServer(), "preCreateAll must run on the server")
	for _, name in Remotes.Names do
		Remotes.get(name, FUNCTIONS[name] and "RemoteFunction" or "RemoteEvent")
	end
end

return Remotes
