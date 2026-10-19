local _, ns = ...
local L = ns.L

-- What the auction house was seen asking for an item, remembered: the game
-- tells prices only there, so the ones shown elsewhere (Wanderer Bags, the
-- tooltips) are those of your last visit, with how long ago. For the whole
-- account and the realm's market, by item id.

local W = Wanderer
local U = W and W.Util

local HOUR, DAY = 3600, 86400
local KEPT = 30 * DAY -- a price older than this says nothing more: let go

local db
local function DB()
	if db then return db end
	WandererAuctionDB = WandererAuctionDB or {}
	WandererAuctionDB.prices = WandererAuctionDB.prices or {}
	db = WandererAuctionDB
	-- The old prices let go once a session (the file read at login stays small).
	local now = time()
	for id, seen in pairs(db.prices) do
		if type(seen) ~= "table" or now - (seen.time or 0) > KEPT then db.prices[id] = nil end
	end
	return db
end
ns.DB = DB

function ns.Settings()
	return W and W.Settings("auction")
end

-- An item's day (today's, made when missing): { day, the market's value (nil until a full look), how many
-- looks counted it, the cheapest seen }. The last 14 days kept.
local DAYS_KEPT = 14
local function Today(seen)
	local today = math.floor(time() / DAY)
	seen.days = seen.days or {}
	local last = seen.days[#seen.days]
	if not (last and last[1] == today) then
		last = { today, nil, 0, nil }
		seen.days[#seen.days + 1] = last
	end
	while seen.days[1] and today - seen.days[1][1] >= DAYS_KEPT do table.remove(seen.days, 1) end
	return last
end

-- The lowest price seen for an item, each (copper), now. followed: an item of yours looked up to sell, its
-- day's cheapest kept with its days (the history); a price only passing by (a search) keeps none.
function ns.Remember(id, price, followed)
	id, price = tonumber(id), tonumber(price)
	if not (id and price and price > 0) then return end
	local seen = DB().prices[id] or {}
	seen.price, seen.time = price, time()
	DB().prices[id] = seen
	if followed then
		local day = Today(seen)
		day[4] = math.min(day[4] or price, price)
	end
end

-- The market's value ------------------------------------------------------------------------------
--
-- As TradeSkillMaster's AuctionDB counts it, from what is for sale now ({ price each, how many }, cheapest
-- first): only the cheapest part (at most 30 % of the quantity; past 15 %, cut where a price jumps by 20 %
-- or more), then what lies further than 1.5 standard deviations from their mean left out, then the mean of
-- the rest, weighted by quantity. Nil when nothing is for sale.
function ns.MarketValue(listings)
	local total = 0
	for _, offer in ipairs(listings) do total = total + offer[2] end
	if total <= 0 then return nil end
	-- (counted by units, as TSM does: the offer that crosses 30 % counts only for its share, so one cheap unit
	-- before a big pile never makes the whole value)
	local most = math.max(1, math.floor(total * 0.3))
	local kept, counted, last = {}, 0, nil
	for _, offer in ipairs(listings) do
		if counted >= most then break end
		if counted / total >= 0.15 and last and offer[1] >= last * 1.2 then break end
		local units = math.min(offer[2], most - counted)
		if units > 0 then kept[#kept + 1] = { offer[1], units } end
		counted, last = counted + units, offer[1]
	end
	local function Mean(list)
		local sum, weight = 0, 0
		for _, offer in ipairs(list) do sum, weight = sum + offer[1] * offer[2], weight + offer[2] end
		return weight > 0 and sum / weight or nil, weight
	end
	local mean, weight = Mean(kept)
	if not mean then return nil end
	local spread = 0
	for _, offer in ipairs(kept) do spread = spread + offer[2] * (offer[1] - mean) ^ 2 end
	spread = math.sqrt(spread / weight)
	local close = {}
	for _, offer in ipairs(kept) do
		if math.abs(offer[1] - mean) <= 1.5 * spread then close[#close + 1] = offer end
	end
	return math.floor((Mean(close[1] and close or kept)) + 0.5)
end

-- The market's value over the last 14 days, each day weighing half as much every 2 days (a day's value:
-- the mean of that day's looks). Kept with the item's price.
local HALF_LIFE = 2
function ns.RememberMarket(id, value)
	id, value = tonumber(id), tonumber(value)
	if not (id and value and value > 0) then return end
	local seen = DB().prices[id]
	if not seen then
		seen = { time = time() }
		DB().prices[id] = seen
	end
	local day = Today(seen)
	local looks = day[3] or 0
	day[2], day[3] = ((day[2] or 0) * looks + value) / (looks + 1), looks + 1
end

-- The weighted value (beforeToday: without today's, to judge today against the days before).
function ns.Market(id, beforeToday)
	local seen = DB().prices[tonumber(id) or -1]
	local days = seen and seen.days
	if not (days and days[1]) then return nil end
	local today = math.floor(time() / DAY)
	local sum, weight = 0, 0
	for _, day in ipairs(days) do
		if day[2] and today - day[1] < DAYS_KEPT and not (beforeToday and day[1] == today) then
			local w = 0.5 ^ ((today - day[1]) / HALF_LIFE)
			sum, weight = sum + day[2] * w, weight + w
		end
	end
	return weight > 0 and math.floor(sum / weight + 0.5) or nil
end

-- An item's days, oldest first: { day, value, looks, cheapest } (a copy to read, never to change).
function ns.Days(id)
	local seen = DB().prices[tonumber(id) or -1]
	local copy, today = {}, math.floor(time() / DAY)
	for _, day in ipairs(seen and seen.days or {}) do
		if today - day[1] < DAYS_KEPT then copy[#copy + 1] = { day[1], day[2], day[3], day[4] } end
	end
	return copy
end

-- Whether to sell now, as TradeSkillMaster's sellers judge it: today's value against the days before.
-- Returns "few" (fewer than 2 days with a value), "merchant" (a merchant gives as much once the cut taken),
-- "good" (10 % or more above), "wait" (15 % or more below), or "usual"; and today's value against the days
-- before (1.12: 12 % above).
ns.SELL_NOW, ns.WAIT_UNDER = 1.10, 0.85
function ns.Advice(id, vendor)
	local days, valued = ns.Days(id), 0
	for _, day in ipairs(days) do if day[2] then valued = valued + 1 end end
	local today = days[#days]
	local now = today and today[1] == math.floor(time() / DAY) and today[2] or nil
	local before = ns.Market(id, true)
	if vendor and vendor > 0 and (now or before) and ns.Net(now or before) <= vendor then return "merchant" end
	if valued < 2 or not (now and before) then return "few" end
	local ratio = now / before
	if ratio >= ns.SELL_NOW then return "good", ratio end
	if ratio <= ns.WAIT_UNDER then return "wait", ratio end
	return "usual", ratio
end

-- The optimized price: the reference is the market's value now and over the last days (their mean when
-- both are known); what is offered under 80 % of it is left out (a bait: sold low to be bought and sold
-- again dearer, it says nothing of the market); one copper under the first offer left, never under the
-- floor (a merchant's) nor 80 % of the reference, never over twice the reference (the reference itself
-- when nothing credible is for sale). Returns the price, how many offers were left out, the reference
-- and the cheapest credible offer (nil without any reference).
ns.TRUSTED_SHARE, ns.HIGHEST_SHARE = 0.8, 2
function ns.Optimize(listings, history, floor)
	local now = ns.MarketValue(listings)
	local reference = now and history and (now + history) / 2 or now or history
	if not reference then return nil end
	reference = math.floor(reference + 0.5)
	local trusted = math.floor(reference * ns.TRUSTED_SHARE)
	local low = math.max(1, floor or 0, trusted)
	local high = math.max(low, math.floor(reference * ns.HIGHEST_SHARE))
	local left = 0 -- (the bait: under 80 % of the reference; under the floor only, it is no bait)
	for _, offer in ipairs(listings) do
		if offer[1] >= low then
			if offer[1] > high then break end
			return math.max(low, offer[1] - 1), left, reference, offer[1]
		end
		if offer[1] < trusted then left = left + 1 end
	end
	return math.min(high, math.max(low, math.floor(reference + 0.5))), left, reference, nil
end

-- The items the server refuses to post (some of Forever's, with stats of their own: "of the owl"), kept
-- for every character; forgotten as soon as one is posted after all.
function ns.Refused(id)
	local refused = DB().refused
	return refused and refused[tonumber(id) or -1] ~= nil or false
end
function ns.Refuse(id, on)
	local saved = DB()
	saved.refused = saved.refused or {}
	saved.refused[tonumber(id) or -1] = on ~= false and time() or nil
end

-- The price remembered and its age in seconds, or nil.
function ns.Price(id)
	local seen = DB().prices[tonumber(id) or -1]
	if not seen then return nil end
	return seen.price, math.max(0, time() - (seen.time or time()))
end

-- "2 d ago"
function ns.Age(seconds)
	if not seconds or seconds < HOUR then return L.AGE_NOW end
	if seconds < DAY then return L.AGE_HOURS:format(math.floor(seconds / HOUR)) end
	return L.AGE_DAYS:format(math.floor(seconds / DAY))
end

-- Money ----------------------------------------------------------------------------------------

-- The auction house's cut on a sale (the game says it nowhere: 5 %, as it has long been).
ns.CUT = 0.05

-- What a sale at this price brings once the auction house has taken its cut (the deposit comes back).
function ns.Net(price)
	return math.floor((price or 0) * (1 - ns.CUT))
end

-- What a merchant gives for one (0: none buys it).
function ns.Vendor(link)
	local price = link and U.SellPrice(link)
	return price and price > 0 and price or 0
end

-- The least price worth asking, each: its net above the merchant's. 0 when no merchant buys it.
function ns.Floor(vendor)
	if not vendor or vendor <= 0 then return 0 end
	local price = math.ceil((vendor + 1) / (1 - ns.CUT))
	while ns.Net(price) <= vendor do price = price + 1 end
	return price
end

-- Under an item to buy: what a merchant gives for it, in green when more than its price here.
function ns.MerchantLine(link, unit)
	local vendor = ns.Vendor(link)
	if vendor == 0 then return "" end
	local color = unit and unit < vendor and "|cff66dd66" or "|cff8c8070"
	return "\n" .. color .. L.MERCHANT_GIVES:format(U.Coins(vendor)) .. "|r"
end

local ItemID = U.ItemID

-- The shopping list ------------------------------------------------------------------------------

-- This character's own: its list (item id -> { count, note (what for), time }), its automatic buying at
-- merchants (autoBuy, buyCap in gold). Its first time: the list once shared by the whole account, and the
-- buying as the settings had it, as its start; then its own.
local function Mine()
	local saved = DB()
	saved.characters = type(saved.characters) == "table" and saved.characters or {}
	local who = U.Clean(U.Safe(UnitGUID, "player"))
	local mine = who and saved.characters[who]
	if not mine then
		local list = {}
		-- (the old shared list, a month long after the first character took it: one made later starts clean)
		local now = time()
		saved.sharedUntil = saved.sharedUntil or now + 30 * 86400
		local old = now <= saved.sharedUntil and saved.shopping or nil
		for id, entry in pairs(type(old) == "table" and old or {}) do
			if type(entry) == "table" then
				local copy = {}
				for key, value in pairs(entry) do copy[key] = value end
				list[id] = copy
			end
		end
		local settings = ns.Settings and ns.Settings() or {}
		mine = { shopping = list, autoBuy = settings.autoBuy and true or false, buyCap = tonumber(settings.buyCap) or 5 }
		-- (the character not known yet, at the very start: a passing copy, nothing kept)
		if who then saved.characters[who] = mine end
	end
	mine.shopping = type(mine.shopping) == "table" and mine.shopping or {}
	return mine
end

function ns.Shopping() return Mine().shopping end

-- Buying on arrival at merchants, for this character: on or off (value: set), and its cap in gold.
function ns.AutoBuy(value)
	local mine = Mine()
	if value ~= nil then mine.autoBuy = value and true or false end
	return mine.autoBuy and true or false
end
-- Taking from the bank what the list lacks, at the banker, for this character (value: set). Off at first.
function ns.FromBank(value)
	local mine = Mine()
	if value ~= nil then mine.fromBank = value and true or false end
	return mine.fromBank and true or false
end
function ns.BuyCap(gold)
	local mine = Mine()
	if gold then mine.buyCap = math.max(1, math.min(math.floor(gold), 100)) end
	return tonumber(mine.buyCap) or 5
end

-- An item's name, or its number while the game has not sent it.
local function ItemName(id) return U.ItemName(id) or ("#" .. id) end

-- An item added (or how many raised): said once (unless the caller says it for several).
function ns.AddToShopping(id, count, note, quiet)
	id, count = tonumber(id), math.max(1, tonumber(count) or 1)
	if not id then return false end
	local list = ns.Shopping()
	local entry = list[id]
	if entry then
		entry.count = math.max(entry.count or 1, count)
	else
		list[id] = { count = count, note = type(note) == "string" and note or nil, time = time() }
	end
	if W.Print and not quiet then W.Print(L.SHOPPING_ADDED:format(ItemName(id))) end
	if ns.RefreshShopping then ns.RefreshShopping() end
	return true
end

function ns.RemoveFromShopping(id)
	local list = ns.Shopping()
	if not list[id] then return end
	list[id] = nil
	if W.Print then W.Print(L.SHOPPING_REMOVED:format(ItemName(id))) end
	if ns.RefreshShopping then ns.RefreshShopping() end
end

local Carried = U.ItemCount

-- The list as rows for a table (its page at the auction house, its small window): { id, name, link, want,
-- have, note, keep, max, quality, icon }, by name. A name the game has not sent yet is asked for.
function ns.ShoppingRows()
	local rows = {}
	for id, wanted in pairs(ns.Shopping()) do
		local name, link, quality = U.ItemInfo(id)
		name = name or U.ItemName(id)
		if not name then U.LoadItem(id) end
		rows[#rows + 1] = { id = id, name = name or ("#" .. id), link = link, want = wanted.count or 1, have = Carried(id),
			note = wanted.note, keep = wanted.keep or false, max = wanted.max, quality = quality or U.ItemQuality(id) or 1,
			icon = U.ItemIcon(id) }
	end
	table.sort(rows, function(a, b) return a.name < b.name end)
	return rows
end

-- How many you want to carry, set by hand (from your bags, the list). Once: what you already carry said,
-- nothing added then. Always (keep, or a line kept already): it stays on the list, filled up at each merchant.
function ns.SetShopping(id, count, note, keep)
	id, count = tonumber(id), tonumber(count)
	if not (id and count and count > 0) then return false end
	local list = ns.Shopping()
	if keep == nil then keep = list[id] and list[id].keep or false end
	local have = Carried(id)
	-- (a line already there, only its kind changed: kept as it is, once now)
	if keep == false and list[id] and list[id].keep then
		list[id].keep = nil
		if ns.RefreshShopping then ns.RefreshShopping() end
		return true
	end
	if have >= count and not keep then
		if W.Print then W.Print(L.SHOPPING_ALREADY:format(have, ItemName(id))) end
		return false
	end
	local entry = list[id] or { time = time() }
	entry.count, entry.note = count, type(note) == "string" and note or entry.note
	entry.keep = keep or nil
	list[id] = entry
	if W.Print then W.Print((keep and L.SHOPPING_KEEP_SET or L.SHOPPING_SET):format(ItemName(id), count, have)) end
	if ns.RefreshShopping then ns.RefreshShopping() end
	if ns.RefreshMerchant then ns.RefreshMerchant() end
	return true
end

-- What the list still lacks of an item (0: nothing, or not on it).
function ns.Lacking(id)
	local entry = ns.Shopping()[id]
	if not entry then return 0 end
	return math.max(0, (entry.count or 1) - Carried(id))
end

-- "3 / 8" on a row of the list, in green once you carry enough.
function ns.HaveWant(have, want)
	local enough = have >= want
	return (enough and "|cff8fe0a2" or "") .. have .. " / " .. want .. (enough and "|r" or "")
end

-- What you now carry enough of leaves the list, said (a line always on you stays).
-- Your bags changed (looted, made, bought anywhere), or the list searched at the auction house.
function ns.PruneShopping()
	local list = ns.Shopping()
	for id, entry in pairs(list) do
		if not entry.keep and Carried(id) >= (entry.count or 1) then
			list[id] = nil
			if W.Print then W.Print(L.SHOPPING_ENOUGH:format(ItemName(id))) end
		end
	end
	if ns.RefreshShopping then ns.RefreshShopping() end
end
do
	local bags = CreateFrame("Frame")
	pcall(bags.RegisterEvent, bags, "BAG_UPDATE_DELAYED")
	bags:SetScript("OnEvent", U and U.Debounce and U.Debounce(1, function()
		if next(ns.Shopping()) then ns.PruneShopping() end
	end) or nil)
end

-- For the other addons (Wanderer Bags): the price of an item by its link, and its age in days.
WandererAuction = {
	Price = function(link)
		local price, age = ns.Price(ItemID(link))
		return price, age and math.floor(age / DAY) or nil
	end,
	-- A name searched at the auction house (open), in the window's buying page.
	Search = function(text) if ns.SearchFor then return ns.SearchFor(text) end end,
	-- The auction house open, in Wanderer's window.
	IsOpen = function() return ns.IsShown and ns.IsShown() or false end,
	-- The shopping list: an item to buy (how many, what for), one known.
	AddToShopping = function(id, count, note) return ns.AddToShopping(id, count, note) end,
	InShopping = function(id) return ns.Shopping()[tonumber(id) or -1] ~= nil end,
	-- How many you want to carry, set by hand; how many the list wants (nil: not on it); off it.
	SetShopping = function(id, count, note, keep) return ns.SetShopping(id, count, note, keep) end,
	-- A line always on you (true), else nil.
	IsAlways = function(id)
		local entry = ns.Shopping()[tonumber(id) or -1]
		return entry and entry.keep or nil
	end,
	ShoppingCount = function(id)
		local entry = ns.Shopping()[tonumber(id) or -1]
		return entry and entry.count or nil
	end,
	RemoveFromShopping = function(id) return ns.RemoveFromShopping(tonumber(id)) end,
}

-- Over an item, its price at the auction house (only without Auctionator: it says it already).
function ns.InitTooltip()
	if not (TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item) then return end
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
		local id = type(data) == "table" and U.Clean(data.id)
		-- On your shopping list: how many you carry, how many it wants.
		local entry = id and ns.Shopping()[id]
		if entry and not InCombatLockdown() then
			tooltip:AddLine((entry.keep and L.TOOLTIP_KEEP or L.TOOLTIP_SHOPPING):format(Carried(id), entry.count or 1), 1, 0.82, 0)
			tooltip:Show()
		end
		-- (the price first: most items have none, nothing more asked then)
		local price, age = ns.Price(id)
		if not price then return end
		local settings = ns.Settings()
		if not (settings and settings.tooltip) or type(Auctionator) == "table" or InCombatLockdown() then return end
		local name = tooltip.GetName and U.Clean(U.Safe(tooltip.GetName, tooltip)) or ""
		if name:find("^ShoppingTooltip") or name:find("^ItemRefShoppingTooltip") then return end
		tooltip:AddLine(L.TOOLTIP_LINE:format(U.Coins(price), ns.Age(age)), 0.62, 0.74, 0.86)
		tooltip:Show()
	end)
end
