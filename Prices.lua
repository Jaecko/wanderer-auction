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

-- What Wanderer Bags says of the items (kept, for the auction house, made junk...): its marks, or none.
local NONE = {}
function ns.Marks()
	if type(WandererBags) == "table" and type(WandererBags.Marks) == "table" then return WandererBags.Marks end
	return type(WandererBagsMarks) == "table" and WandererBagsMarks or NONE
end

-- What each file starts once Wanderer's check has passed (Init, Window.lua): no event heard, no hook, no table
-- for the other addons before it (an older Wanderer: nothing of Auction runs).
ns.starts = {}
function ns.AtStart(start)
	-- (a file read after Init: started at once)
	if ns.started then return start() end
	ns.starts[#ns.starts + 1] = start
end
function ns.Start()
	if ns.started then return end
	ns.started = true
	WandererAuction = ns.public
	for _, start in ipairs(ns.starts) do start() end
end

-- A debug session (Debug.lua): off, nothing written, until that file says otherwise.
ns.debugging = false
function ns.Debug() end

-- Wanderer Bags there (its marks: what "made junk" works with).
function ns.BagsLoaded()
	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or rawget(_G, "IsAddOnLoaded")
	local ok, on = pcall(loaded or function() return false end, "WandererBags")
	return ok and on and true or false
end

local db
local function DB()
	if db then return db end
	WandererAuctionDB = WandererAuctionDB or {}
	WandererAuctionDB.prices = WandererAuctionDB.prices or {}
	db = WandererAuctionDB
	-- (once: the items remembered as refused by the server were refused for a copper in their price, which this
	-- auction house does not take; never sent now: forgotten, each may be posted again)
	if db.silverPrices ~= 2 then
		db.refused, db.strikes, db.silverPrices = nil, nil, 2
	end
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
-- again dearer, it says nothing of the market); one copper under the first offer left (then down to the
-- whole silver where it is posted), never under the
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

-- A young market: fewer than 3 offers now and no day of its own before today. The optimized price says
-- nothing credible then: your own price is asked.
ns.YOUNG_OFFERS = 3
function ns.Young(listings, history)
	return #(listings or {}) < ns.YOUNG_OFFERS and not history
end

-- How many days an item's market value was seen on (the last 14).
function ns.ValuedDays(id)
	local valued = 0
	for _, day in ipairs(ns.Days(id)) do if day[2] then valued = valued + 1 end end
	return valued
end

-- The market's value sure enough to make an item junk: from 3 offers or more seen now (with its days), else
-- from 2 days or more; nil on less (nothing judged then). opt: what the optimized price found now.
ns.SURE_DAYS = 2
function ns.SureValue(id, opt)
	if opt and opt.reference and (opt.offers or 0) >= ns.YOUNG_OFFERS then return opt.reference end
	if ns.ValuedDays(id) >= ns.SURE_DAYS then return ns.Market(id) end
	return nil
end

-- The items the server refuses to post (some of Forever's, with stats of their own: "of the owl"), kept
-- for every character; forgotten as soon as one is posted after all. One refusal may be passing (the
-- server busy): an item counts as refused at its second.
ns.REFUSALS = 2
function ns.Refused(id)
	local refused = DB().refused
	return refused and refused[tonumber(id) or -1] ~= nil or false
end
-- A refusal counted (on: false, all of them forgotten). True once the item counts as refused.
function ns.Refuse(id, on)
	local saved = DB()
	id = tonumber(id) or -1
	saved.refused = saved.refused or {}
	saved.strikes = type(saved.strikes) == "table" and saved.strikes or {}
	if on == false then
		saved.refused[id], saved.strikes[id] = nil, nil
		return false
	end
	local strikes = (tonumber(saved.strikes[id]) or 0) + 1
	if strikes >= ns.REFUSALS then
		saved.refused[id], saved.strikes[id] = time(), nil
		return true
	end
	saved.strikes[id] = strikes
	return ns.Refused(id)
end

-- Your price for an item, kept as the prices are (the account, the realm's market): the least ever offered
-- for it, set from its price box. ns.SetYourPrice(id, nil) forgets it.
function ns.YourPrice(id)
	local yours = DB().yours
	local price = type(yours) == "table" and tonumber(yours[tonumber(id) or -1]) or nil
	return price and price > 0 and price or nil
end
function ns.SetYourPrice(id, copper)
	id, copper = tonumber(id), tonumber(copper)
	if not id then return end
	local saved = DB()
	saved.yours = type(saved.yours) == "table" and saved.yours or {}
	saved.yours[id] = copper and copper > 0 and math.floor(copper) or nil
end

-- A price far from an item's usual value (the market's days): "low" under half of it, "high" over 3 times;
-- with the usual value. Nil when it looks usual, or no usual value is known.
ns.ODD_LOW, ns.ODD_HIGH = 0.5, 3
function ns.OddPrice(id, unit)
	local usual = ns.Market(id)
	unit = tonumber(unit) or 0
	if not (usual and usual > 0 and unit > 0) then return nil end
	if unit < usual * ns.ODD_LOW then return "low", usual end
	if unit > usual * ns.ODD_HIGH then return "high", usual end
	return nil
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
	return U.AgoWords(seconds)
end

-- How fresh a remembered price is: a small dot before it, green when seen within the hour, gold within the
-- day, grey older (Wanderer's own dot, in the kit's colors). "" when no price was seen.
function ns.Fresh(id)
	local price, age = ns.Price(id)
	if not price then return "" end
	local role = age < HOUR and "good" or age < DAY and "gold" or "muted"
	return W.Skin.GlyphText("dot", role, 10) .. " "
end

-- Money typed: "1.5" (1g 50s), "1,05" (1g 5s), "12" (12g), "1g50s", "75s", "30c", "1 g 50 s", or the client's own
-- coin words (po pa pc, g s k...). The copper, or nil when it cannot be read.
local function CoinOf(unit)
	unit = unit:lower()
	if unit == "" then return nil end
	local symbols = { { GOLD_AMOUNT_SYMBOL, 10000 }, { SILVER_AMOUNT_SYMBOL, 100 }, { COPPER_AMOUNT_SYMBOL, 1 } }
	for _, symbol in ipairs(symbols) do
		if type(symbol[1]) == "string" and symbol[1] ~= "" and unit == symbol[1]:lower() then return symbol[2] end
	end
	local first = unit:sub(1, 1)
	return ({ g = 10000, s = 100, c = 1 })[first]
end
function ns.ParseMoney(text)
	text = strtrim(tostring(text or "")):lower()
	if text == "" then return nil end
	-- A plain number: gold, its decimals the silver then the copper.
	local whole, decimals = text:match("^(%d*)[%.,](%d*)$")
	if whole and (whole ~= "" or decimals ~= "") then
		decimals = (decimals .. "0000"):sub(1, 4)
		return (tonumber(whole) or 0) * 10000 + tonumber(decimals:sub(1, 2)) * 100 + tonumber(decimals:sub(3, 4))
	end
	if text:match("^%d+$") then return tonumber(text) * 10000 end
	-- Numbers with their coins.
	local copper, rest = 0, text
	for number, unit in text:gmatch("(%d+)%s*([^%d%s]*)") do
		local coin = CoinOf(unit)
		if not coin then return nil end
		copper = copper + tonumber(number) * coin
	end
	rest = rest:gsub("(%d+)%s*([^%d%s]*)", ""):gsub("%s", "")
	if rest ~= "" or not text:match("%d") then return nil end
	return copper
end

-- An amount as it is typed back: "1g 50s 4c" in the client's coin words (what ns.ParseMoney reads).
function ns.MoneyText(copper)
	copper = math.max(0, math.floor(tonumber(copper) or 0))
	local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local parts = {}
	local function Part(value, symbol, short)
		local word = type(symbol) == "string" and symbol ~= "" and symbol or short
		parts[#parts + 1] = value .. word
	end
	if gold > 0 then Part(gold, GOLD_AMOUNT_SYMBOL, "g") end
	if silver > 0 then Part(silver, SILVER_AMOUNT_SYMBOL, "s") end
	if rest > 0 or not parts[1] then Part(rest, COPPER_AMOUNT_SYMBOL, "c") end
	return table.concat(parts, " ")
end

-- Money ----------------------------------------------------------------------------------------

-- The auction house's cut on a sale (the game says it nowhere): 5 % at a faction's, 15 % at a neutral one
-- (the goblins' of Gadgetzan, Booty Bay and Everlook). Set on arrival at the auction house.
ns.FACTION_CUT, ns.NEUTRAL_CUT = 0.05, 0.15
ns.CUT = ns.FACTION_CUT

-- The zones whose only auction house is a neutral one (Tanaris, Stranglethorn, Winterspring), by map: the
-- classic ids and the modern ones (Booty Bay lies in the Cape of Stranglethorn there).
local NEUTRAL_MAPS = { [1446] = true, [1434] = true, [1452] = true, [71] = true, [224] = true, [210] = true, [83] = true }

-- The auction house open is a neutral one: its auctioneer of neither faction (an Alliance or Horde one says
-- his faction's), then the zone (and the zones around it, up the map).
function ns.NeutralHouse()
	local faction = U.Clean(U.Safe(UnitFactionGroup, "npc"))
	if faction == "Alliance" or faction == "Horde" then return false end
	local map = C_Map and U.Clean(U.Safe(C_Map.GetBestMapForUnit, "player"))
	local known = false -- (a zone read: its answer stands)
	for _ = 1, 8 do
		if not map or map == 0 then break end
		known = true
		if NEUTRAL_MAPS[map] then return true end
		local info = U.Safe(C_Map.GetMapInfo, map)
		map = type(info) == "table" and U.Clean(info.parentMapID) or nil
	end
	if known then return false end
	-- (no zone known: an auctioneer there, of no faction, is a goblin)
	return faction == "Neutral" or (faction == nil and U.Clean(U.Safe(UnitExists, "npc")) == true)
end

-- The cut set for the auction house open (left: back to a faction's).
function ns.SetCut(neutral)
	ns.CUT = neutral and ns.NEUTRAL_CUT or ns.FACTION_CUT
end

-- The cut as a percentage (5, 15).
function ns.CutPercent() return math.floor(ns.CUT * 100 + 0.5) end

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
			if type(entry) == "table" then list[id] = U.Copy(entry) end
		end
		local settings = ns.Settings() or {}
		mine = { shopping = list, autoBuy = settings.autoBuy and true or false, buyCap = tonumber(settings.buyCap) or 5 }
		-- (the character not known yet, at the very start: a passing copy, nothing kept)
		if who then saved.characters[who] = mine end
	end
	mine.shopping = type(mine.shopping) == "table" and mine.shopping or {}
	return mine
end

ns.Mine = Mine

function ns.Shopping() return Mine().shopping end

-- What this character's auction house made junk (Wanderer Bags' mark, set by Auction and not by you): item id
-- -> when (on: set, false: forgotten). Uncommon or better, such an item is never sold at a merchant by itself.
function ns.MadeJunk(id, on)
	id = tonumber(id)
	if not id then return false end
	local mine = Mine()
	mine.madeJunk = type(mine.madeJunk) == "table" and mine.madeJunk or {}
	if on ~= nil then mine.madeJunk[id] = on and time() or nil end
	return mine.madeJunk[id] ~= nil
end

-- Wanderer's junk rule at merchants: what Auction made junk, uncommon or better, waits for your click (the
-- junk button) instead of being sold by itself ("ask"). No longer junk in Wanderer Bags (your mark changed or
-- taken off, Wanderer Bags gone): yours, forgotten.
local POOR = Enum and Enum.ItemQuality and Enum.ItemQuality.Poor or 0
function ns.JunkRule(id, quality)
	if not ns.MadeJunk(id) then return nil end
	local marks = ns.Marks()
	local isJunk = type(marks) == "table" and marks.IsJunk or nil
	local ok, junk = true, false
	if type(isJunk) == "function" then ok, junk = pcall(isJunk, id) end
	-- (Wanderer Bags switched off: it says nothing, the mark kept for when it is back)
	if ok and junk == nil then return nil end
	-- (Wanderer Bags unable to say: still waiting for your click; only a clear no forgets it)
	if ok and junk == false then
		ns.MadeJunk(id, false)
		return nil
	end
	if (tonumber(quality) or POOR) > POOR then return "ask" end
	return nil
end

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

-- Asked from another addon (Wanderer Bags, Quests, Wanderer's reminders): true while Auction is on; switched off,
-- nothing taken and said so (unless quiet), as its list's window does.
function ns.TellOff(quiet)
	if ns.On and ns.On() then return true end
	if not quiet then W.Print(L.EXT_TURNED_OFF:format(L.TITLE)) end
	return false
end

-- An item added (or how many raised): said once (unless the caller says it for several).
function ns.AddToShopping(id, count, note, quiet)
	id, count = tonumber(id), math.max(1, tonumber(count) or 1)
	if not id then return false end
	local list = ns.Shopping()
	local entry = list[id]
	-- (already there for another reason, a recipe or a quest: both needs counted, both names kept; for the same
	-- one again: the larger need, never twice)
	local other = entry and type(note) == "string" and note ~= "" and type(entry.note) == "string"
		and not (", " .. entry.note .. ", "):find(", " .. note .. ", ", 1, true)
	if other then
		entry.count = (entry.count or 1) + count
		entry.note = entry.note .. ", " .. note
	elseif entry then
		entry.count = math.max(entry.count or 1, count)
	else
		list[id] = { count = count, note = type(note) == "string" and note or nil, time = time() }
	end
	if not quiet then W.Print(L.SHOPPING_ADDED:format(ItemName(id))) end
	if ns.RefreshShopping then ns.RefreshShopping() end
	return true
end

function ns.RemoveFromShopping(id)
	local list = ns.Shopping()
	if not list[id] then return end
	list[id] = nil
	W.Print(L.SHOPPING_REMOVED:format(ItemName(id)))
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

-- What a line of the list is for, the same words on both tables: its note, else always on you, else your list.
function ns.ShoppingWhat(entry)
	return entry.note or (entry.keep and L.KEEP_NOTE) or L.YOUR_LIST
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
		W.Print(L.SHOPPING_ALREADY:format(have, ItemName(id)))
		return false
	end
	local entry = list[id] or { time = time() }
	entry.count, entry.note = count, type(note) == "string" and note or entry.note
	entry.keep = keep or nil
	list[id] = entry
	W.Print((keep and L.SHOPPING_KEEP_SET or L.SHOPPING_SET):format(ItemName(id), count, have))
	if ns.RefreshShopping then ns.RefreshShopping() end
	if ns.RefreshMerchant then ns.RefreshMerchant() end
	return true
end

-- From the shopping card (a click each, said on the card itself, not in the chat): how many, always on you or
-- once, your highest price for one (nil or 0: none). False when the item is not on the list.
local function Changed()
	if ns.RefreshShopping then ns.RefreshShopping() end
	if ns.RefreshMerchant then ns.RefreshMerchant() end
	return true
end
function ns.SetShoppingCount(id, count)
	local entry = ns.Shopping()[tonumber(id) or -1]
	count = tonumber(count)
	if not (entry and count) then return false end
	entry.count = math.max(1, math.min(9999, math.floor(count)))
	return Changed()
end
function ns.ToggleShoppingKeep(id)
	local entry = ns.Shopping()[tonumber(id) or -1]
	if not entry then return false end
	entry.keep = not entry.keep or nil
	return Changed()
end
function ns.SetShoppingMax(id, copper)
	local entry = ns.Shopping()[tonumber(id) or -1]
	if not entry then return false end
	copper = tonumber(copper)
	entry.max = copper and copper > 0 and math.floor(copper) or nil
	return Changed()
end

-- What the list still lacks of an item (0: nothing, or not on it).
function ns.Lacking(id)
	local entry = ns.Shopping()[id]
	if not entry then return 0 end
	return math.max(0, (entry.count or 1) - Carried(id))
end

-- "3 / 8" on a row of the list, in green once you carry enough.
function ns.HaveWant(have, want)
	local text = have .. " / " .. want
	return have >= want and W.Skin.Colorize(text, "good") or text
end

-- What you now carry enough of leaves the list, said (a line always on you stays).
-- Your bags changed (looted, made, bought anywhere), or the list searched at the auction house.
function ns.PruneShopping()
	local list = ns.Shopping()
	for id, entry in pairs(list) do
		if not entry.keep and Carried(id) >= (entry.count or 1) then
			list[id] = nil
			W.Print(L.SHOPPING_ENOUGH:format(ItemName(id)))
		end
	end
	if ns.RefreshShopping then ns.RefreshShopping() end
end
ns.AtStart(function()
	local bags = CreateFrame("Frame")
	pcall(bags.RegisterEvent, bags, "BAG_UPDATE_DELAYED")
	bags:SetScript("OnEvent", U.Debounce(1, function()
		-- (the addon switched off: its list left as it is, nothing said)
		if ns.On and ns.On() and next(ns.Shopping()) then ns.PruneShopping() end
	end))
end)

-- For the other addons (Wanderer Bags): the price of an item by its link, and its age in days (switched off:
-- none, as everything else here). Given as WandererAuction by Init only.
ns.public = {
	Price = function(link)
		if not (ns.On and ns.On()) then return nil end
		local price, age = ns.Price(ItemID(link))
		return price, age and math.floor(age / DAY) or nil
	end,
	-- A name searched at the auction house (open), in the window's buying page.
	Search = function(text) if ns.SearchFor then return ns.SearchFor(text) end end,
	-- The auction house open, in Wanderer's window.
	IsOpen = function() return ns.IsShown and ns.IsShown() or false end,
	-- Auction switched on (off: nothing added to its list, said unless quiet).
	IsOn = function() return ns.On and ns.On() or false end,
	-- The shopping list: an item to buy (how many, what for; quiet: nothing said in the chat), one known.
	AddToShopping = function(id, count, note, quiet)
		if not ns.TellOff(quiet) then return false end
		return ns.AddToShopping(id, count, note, quiet)
	end,
	-- (Auction switched off: nothing on its list, nothing taken off it)
	InShopping = function(id) return (ns.On and ns.On()) and ns.Shopping()[tonumber(id) or -1] ~= nil or false end,
	-- How many you want to carry, set by hand; how many the list wants (nil: not on it); off it.
	SetShopping = function(id, count, note, keep)
		if not ns.TellOff() then return false end
		return ns.SetShopping(id, count, note, keep)
	end,
	-- A line always on you (true), else nil.
	IsAlways = function(id)
		if not (ns.On and ns.On()) then return nil end
		local entry = ns.Shopping()[tonumber(id) or -1]
		return entry and entry.keep or nil
	end,
	ShoppingCount = function(id)
		if not (ns.On and ns.On()) then return nil end
		local entry = ns.Shopping()[tonumber(id) or -1]
		return entry and entry.count or nil
	end,
	RemoveFromShopping = function(id)
		if not (ns.On and ns.On()) then return false end
		return ns.RemoveFromShopping(tonumber(id))
	end,
}

-- Over an item, its price at the auction house (only without Auctionator: it says it already).
function ns.InitTooltip()
	U.OnItemTooltip(function(tooltip, id)
		-- (the addon switched off: nothing of it over items either)
		if not ns.On() then return false end
		local added = false
		-- On your shopping list: how many you carry, how many it wants.
		local entry = id and ns.Shopping()[id]
		if entry then
			local gold = W.Skin.COLORS.gold
			tooltip:AddLine((entry.keep and L.TOOLTIP_KEEP or L.TOOLTIP_SHOPPING):format(Carried(id), entry.count or 1), gold[1], gold[2], gold[3])
			added = true
		end
		-- (the price first: most items have none, nothing more asked then)
		local price, age = ns.Price(id)
		local settings = price and ns.Settings()
		if settings and settings.tooltip and type(Auctionator) ~= "table" then
			local blue = W.Skin.COLORS.blue
			tooltip:AddLine(L.TOOLTIP_LINE:format(U.Coins(price), ns.Age(age)), blue[1], blue[2], blue[3])
			added = true
		end
		return added
	end)
end
