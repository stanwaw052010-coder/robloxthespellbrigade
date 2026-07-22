--!strict
--[[
	LobbyService
	------------
	Выбор книги заклинаний и разблокировка новых книг за эссенцию.

	Handles the lobby-side player choices: selecting an equipped spellbook and
	buying new books with the meta currency (Essence). All validated on the
	server against the player's persistent profile.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Remotes = require(Shared.Remotes)
local SpellbookModule = require(Shared.SpellbookModule)

local PlayerDataService = require(script.Parent.PlayerDataService)
local EconomyService = require(script.Parent.EconomyService)

local LobbyService = {}

--[[ Handles a SelectSpellbook / UnlockSpellbook request.
     action = "select" | "unlock" ]]
local function handleRequest(player: Player, payload: any)
	if type(payload) ~= "table" or type(payload.BookId) ~= "string" then
		return { Ok = false, Message = "Некорректный запрос" }
	end
	local book = SpellbookModule.getBook(payload.BookId)
	if not book then
		return { Ok = false, Message = "Такой книги нет" }
	end

	local profile = PlayerDataService.get(player)
	if not profile then
		return { Ok = false, Message = "Профиль не загружен" }
	end

	local action = payload.Action == "unlock" and "unlock" or "select"

	if action == "unlock" then
		if profile.UnlockedBooks[book.Id] then
			return { Ok = false, Message = "Уже разблокировано" }
		end
		if not EconomyService.trySpendEssence(player, book.UnlockCost) then
			return { Ok = false, Message = "Недостаточно эссенции" }
		end
		PlayerDataService.unlockBook(player, book.Id)
		return { Ok = true, Message = ("Разблокировано: %s"):format(book.Name) }
	else
		-- select
		if PlayerDataService.setSelectedBook(player, book.Id) then
			return { Ok = true, Message = ("Выбрано: %s"):format(book.Name) }
		end
		return { Ok = false, Message = "Сначала разблокируйте книгу" }
	end
end

function LobbyService.Init() end

function LobbyService.Start()
	local remote = Remotes.func(Remotes.Names.SelectSpellbook)
	remote.OnServerInvoke = function(player: Player, payload: any)
		return handleRequest(player, payload)
	end
end

return LobbyService
