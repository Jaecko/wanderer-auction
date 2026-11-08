local _, ns = ...
local L = ns.L

-- A debug session, for a problem seen in game: "/wauction debug" turns it on or off, "/wauction debug clear"
-- empties it. While on, what the auction house is asked and answers, what the Sell page does with the item
-- chosen, and every Lua error (anyone's: the game's own handler is still called after) are written in the
-- account's saved variables (WandererAuctionAccountDB.debug), read after a /reload in
-- WTF/Account/<account>/SavedVariables/WandererAuction.lua. Nothing behaves otherwise; off by default; it turns
-- itself off after two hours, or at the next login when forgotten (its lines kept a week after it ends).

local W = Wanderer

local MAX_ENTRIES = 3000
local MAX_TEXT = 400
local MAX_FIELDS = 40
local LASTS = 2 * 3600 -- seconds a session stays on
local KEPT_AFTER = 7 * 86400 -- seconds the lines of a session ended are kept

ns.debugging = false

local function Store()
	WandererAuctionAccountDB = type(WandererAuctionAccountDB) == "table" and WandererAuctionAccountDB or {}
	local db = WandererAuctionAccountDB
	if type(db.debug) ~= "table" then db.debug = { entries = {} } end
	db.debug.entries = type(db.debug.entries) == "table" and db.debug.entries or {}
	return db.debug
end
ns.DebugStore = Store -- (tests)

-- A value as it can be written: a secret one said so, a string cut, a table copied one level deep (its own
-- tables named only), a function or a frame by its kind.
local function IsSecret(value) return issecretvalue ~= nil and issecretvalue(value) or false end
local function Plain(value)
	if IsSecret(value) then return "<secret>" end
	local kind = type(value)
	if kind == "string" then return #value > MAX_TEXT and (value:sub(1, MAX_TEXT) .. "...") or value end
	if kind == "number" or kind == "boolean" or kind == "nil" then return value end
	if kind == "table" then return "<table>" end
	return "<" .. kind .. ">"
end
local function Value(value)
	if IsSecret(value) then return "<secret>" end
	if type(value) ~= "table" then return Plain(value) end
	local copy, count = {}, 0
	local ok = pcall(function()
		for key, field in pairs(value) do
			count = count + 1
			if count > MAX_FIELDS then
				copy["..."] = true
				break
			end
			if type(field) ~= "function" then copy[type(key) == "number" and key or tostring(Plain(key))] = Plain(field) end
		end
	end)
	if not ok then return "<table, unreadable>" end
	-- (an ItemLocation: its place, read by its own methods)
	if type(value.GetBagAndSlot) == "function" then
		local got, bag, slot = pcall(value.GetBagAndSlot, value)
		if got then copy.bag, copy.slot = Plain(bag), Plain(slot) end
	end
	return copy
end
ns.DebugValue = Value -- (tests)

local Listen -- (below: the game's answers heard, or no more)
local function Stop(quiet)
	ns.debugging = false
	Listen(false)
	local store = Store()
	store.on = false
	store.stopped = time()
	if ns.RestoreErrorHandler then ns.RestoreErrorHandler() end
	if not quiet then W.Print(L.DEBUG_OFF) end
end

-- One line of the session: what (a word), and its fields. Nothing while off.
function ns.Debug(what, ...)
	if not ns.debugging then return end
	local store = Store()
	if time() - (store.started or 0) > LASTS then return Stop() end
	local entry = { t = time(), at = GetTime and GetTime() or nil, what = Plain(what) }
	local count = select("#", ...)
	for index = 1, math.min(count, MAX_FIELDS) do entry[index] = Value((select(index, ...))) end
	local entries = store.entries
	entries[#entries + 1] = entry
	while #entries > MAX_ENTRIES do table.remove(entries, 1) end
end

-- Lua errors ------------------------------------------------------------------------------------------------------
-- The handler in place when the session began, called after each error is written down; given back at its end
-- (unless another addon put its own over ours meanwhile: then ours only stops writing).
local original, ours
local function Get() return rawget(_G, "geterrorhandler"), rawget(_G, "seterrorhandler") end
local function Handler(message, ...)
	if ns.debugging then
		pcall(function()
			local stack, locals = rawget(_G, "debugstack"), rawget(_G, "debuglocals")
			stack = stack and stack(2) or nil
			locals = locals and locals(2) or nil
			ns.Debug("lua error", message, stack, locals)
		end)
	end
	if original then return original(message, ...) end
end
local function WrapErrorHandler()
	local get, set = Get()
	if not (get and set) or ours then return end
	original = get()
	ours = Handler
	set(ours)
end
function ns.RestoreErrorHandler()
	if not ours then return end
	local get, set = Get()
	if get and set and get() == ours and original then set(original) end
	ours, original = nil, nil
end

-- The auction house's functions, written down with their answers while on (Window.lua's ns.AH goes through it).
local wrapped = {}
local QUIET = { IsThrottledMessageSystemReady = true } -- (asked again and again: left out)
function ns.DebugCall(name, fn)
	if not (ns.debugging and type(fn) == "function") or QUIET[name] then return fn end
	if wrapped[name] and wrapped[name].fn == fn then return wrapped[name].call end
	local call = function(...)
		local results = { pcall(fn, ...) }
		ns.Debug("call " .. name, { ... }, { select(2, unpack(results)) }, results[1] and "ok" or "error")
		if not results[1] then error(results[2], 2) end
		return select(2, unpack(results))
	end
	wrapped[name] = { fn = fn, call = call }
	return call
end

-- The game's answers, heard while on.
local EVENTS = { "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED",
	"COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED", "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT",
	"AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED", "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED",
	"AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "AUCTION_HOUSE_AUCTION_CREATED",
	"AUCTION_HOUSE_POST_ERROR", "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_SHOW_ERROR", "AUCTION_HOUSE_SHOW_NOTIFICATION",
	"AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_FAILURE",
	"UI_ERROR_MESSAGE", "CHAT_MSG_SYSTEM", "BAG_UPDATE_DELAYED", "OWNED_AUCTIONS_UPDATED" }
local listener = CreateFrame("Frame")
listener:SetScript("OnEvent", function(_, event, ...)
	-- (the chat's lines and the game's errors only while the auction house is open)
	if (event == "CHAT_MSG_SYSTEM" or event == "UI_ERROR_MESSAGE") and not (ns.AtAuction and ns.AtAuction()) then return end
	ns.Debug("event " .. event, ...)
end)
function Listen(on)
	for _, event in ipairs(EVENTS) do
		pcall(on and listener.RegisterEvent or listener.UnregisterEvent, listener, event)
	end
end

-- The game and the addons, as they are.
local function Versions()
	local versions = {}
	local metadata = C_AddOns and C_AddOns.GetAddOnMetadata or rawget(_G, "GetAddOnMetadata")
	for _, addon in ipairs({ "Wanderer", "WandererAuction", "WandererBags", "WandererMail", "Auctionator", "TradeSkillMaster" }) do
		local ok, version = pcall(metadata or function() end, addon, "Version")
		if ok and version then versions[addon] = Plain(version) end
	end
	return versions
end

local function Start()
	local store = Store()
	ns.debugging = true
	store.on = true
	store.started = time()
	local build = rawget(_G, "GetBuildInfo")
	local version, number, date, interface
	if build then version, number, date, interface = build() end
	store.client = { version = Plain(version), build = Plain(number), date = Plain(date), interface = Plain(interface),
		locale = Plain(GetLocale and GetLocale()) }
	store.addons = Versions()
	WrapErrorHandler()
	Listen(true)
	ns.Debug("session started")
	W.Print(L.DEBUG_ON)
end

function ns.DebugCommand(rest)
	rest = strtrim(rest or ""):lower()
	if rest == "clear" then
		local store = Store()
		store.entries = {}
		W.Print(L.DEBUG_CLEARED)
		return
	end
	if ns.debugging then
		ns.Debug("session stopped")
		Stop()
	else
		Start()
	end
end

-- At login: a session left on (a /reload keeps it going, a new login ends it; its lines kept).
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:RegisterEvent("PLAYER_ENTERING_WORLD")
login:SetScript("OnEvent", function(self, event, isLogin, isReload)
	if event == "PLAYER_LOGIN" then return end
	self:UnregisterAllEvents()
	local store = Store()
	-- (a session ended more than a week ago: its lines let go, the account's file kept small)
	if not store.on and store.stopped and time() - store.stopped > KEPT_AFTER and store.entries[1] then store.entries = {} end
	if not store.on then return end
	if isLogin and not isReload or time() - (store.started or 0) > LASTS then
		Stop(true)
		return
	end
	-- (a /reload in the middle: going on, from where it was)
	ns.debugging = true
	WrapErrorHandler()
	Listen(true)
	ns.Debug("session resumed after a reload")
end)
ns.DebugListener = listener -- (tests)
ns.DebugStop = Stop -- (tests)
