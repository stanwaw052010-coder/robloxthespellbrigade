--!strict
--[[
	ClientState
	-----------
	Локальное зеркало серверного состояния игрока (для HUD и ввода).

	A small client-only mirror of the player's server-synced state. The server
	is always authoritative; this is just the latest snapshot the client uses to
	render the HUD and decide which spell each key maps to. Updated from the
	PlayerStatsChanged remote (which arrives as partial payloads that we merge).
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local SpellbookModule = require(Shared.SpellbookModule)
local GameConfig = require(Shared.GameConfig)
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)
local UpgradeCatalogue = require(Shared.UpgradeCatalogue)

local ClientState = {}

ClientState.Gold = 0
ClientState.Essence = 0
ClientState.Xp = 0
ClientState.Level = 1
ClientState.SelectedBook = "Fire"
ClientState.UnlockedBooks = { Fire = true } :: { [string]: boolean }
ClientState.Mana = GameConfig.Player.MaxMana
ClientState.MaxMana = GameConfig.Player.MaxMana

-- Cosmetics, mirrored from the profile. Keyed by kind ("Aura" | "Hat");
-- UnlockedCosmetics uses the flat "<kind>:<id>" key the server stores.
ClientState.Cosmetics = { Aura = "Ember", Hat = "Hood" } :: { [string]: string }
ClientState.UnlockedCosmetics = {} :: { [string]: boolean }

-- Purchased upgrade levels, mirrored from the server (levels only — the server
-- owns what each level is worth). Used by the shop UI and to keep the HUD's
-- cooldown prediction in step with the cooldowns the server actually applies.
ClientState.GlobalLevels = {} :: { [string]: number }
ClientState.SpellLevels = {} :: { [string]: { [string]: number } }

ClientState.Changed = Signal.new() -- fires () after any merge
ClientState.UpgradesChanged = Signal.new() -- fires () when upgrade levels arrive

--[[ Merges a partial stats payload from the server. ]]
function ClientState.merge(payload: { [string]: any })
	local target = ClientState :: any
	for key, value in payload do
		target[key] = value
	end
	ClientState.Changed:Fire()
end

--[[ Returns the ordered list of spells for the currently equipped book. ]]
function ClientState.getEquippedSpells(): { any }
	local book = SpellbookModule.getBook(ClientState.SelectedBook)
	return book and book.Spells or {}
end

--[[ Finds the equipped spell mapped to a slot ("Basic" | "Q" | "E" | "Ultimate"). ]]
function ClientState.getSpellForSlot(slot: string): any?
	for _, spell in ClientState.getEquippedSpells() do
		if spell.Slot == slot then
			return spell
		end
	end
	return nil
end

--[[ Purchased level of a per-spell tree node (0 if none). ]]
function ClientState.getSpellNodeLevel(spellId: string, nodeId: string): number
	local levels = ClientState.SpellLevels[spellId]
	return (levels and levels[nodeId]) or 0
end

--[[ Mirrors the server's cooldown maths so the HUD's radial timer and the
     client-side cast gate use the same duration the server enforces. ]]
function ClientState.getEffectiveCooldown(spell: any): number
	local mult = 1

	local globalEntry = UpgradeCatalogue.Entries.Cooldown
	local globalLevel = ClientState.GlobalLevels[globalEntry.Id] or 0
	mult += globalEntry.PerLevel * globalLevel

	local perSpell = 1
	local levels = ClientState.SpellLevels[spell.Id]
	if levels then
		local isUltimate = spell.Slot == "Ultimate"
		for nodeId, level in levels do
			local node = UpgradeCatalogue.nodeFor(spell.Id, nodeId, isUltimate)
			if node and node.Kind == "Haste" then
				perSpell += node.PerLevel * level
			end
		end
	end

	return spell.Cooldown * mult * math.max(0.25, perSpell)
end

function ClientState.Init()
	Remotes.event(Remotes.Names.SpellTreeChanged).OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		if type(payload.SpellLevels) == "table" then
			ClientState.SpellLevels = payload.SpellLevels
		end
		if type(payload.GlobalLevels) == "table" then
			ClientState.GlobalLevels = payload.GlobalLevels
		end
		ClientState.UpgradesChanged:Fire()
	end)
end

return ClientState
