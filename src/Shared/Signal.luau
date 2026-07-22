--!strict
--[[
	Signal
	------
	Минимальная реализация сигналов (наблюдатель) для связи сервисов.
	A tiny observer/signal implementation for decoupled communication between
	server services without leaning on BindableEvents (which serialize their
	arguments). Pure-Luau, synchronous fire, supports :Connect / :Once / :Wait.
]]

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({
		_connections = {},
	}, Signal)
	return (self :: any) :: Signal<T...>
end

function Signal:Connect(fn)
	local connection = {
		Connected = true,
		_fn = fn,
	}
	function connection:Disconnect()
		if not self.Connected then
			return
		end
		self.Connected = false
	end
	table.insert(self._connections, connection)
	return connection
end

function Signal:Once(fn)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Fire(...)
	-- Iterate over a snapshot so handlers may connect/disconnect during fire.
	local snapshot = table.clone(self._connections)
	local alive = {}
	for _, connection in snapshot do
		if connection.Connected then
			table.insert(alive, connection)
			-- Isolate handler errors so one bad listener can't stop the rest.
			task.spawn(connection._fn, ...)
		end
	end
	-- Compact out disconnected connections.
	self._connections = alive
end

function Signal:Wait()
	local co = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(co, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	for _, connection in self._connections do
		connection.Connected = false
	end
	table.clear(self._connections)
end

return Signal
