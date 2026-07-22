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
local Signal = require(Shared.Signal)

local ClientState = {}

ClientState.Gold = 0
ClientState.Essence = 0
ClientState.Xp = 0
ClientState.Level = 1
ClientState.SelectedBook = "Fire"
ClientState.UnlockedBooks = { Fire = true } :: { [string]: boolean }
ClientState.Mana = GameConfig.Player.MaxMana
ClientState.MaxMana = GameConfig.Player.MaxMana

ClientState.Changed = Signal.new() -- fires () after any merge

--[[ Merges a partial stats payload from the server. ]]
function ClientState.merge(payload: { [string]: any })
	for key, value in payload do
		;(ClientState :: any)[key] = value
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

return ClientState
