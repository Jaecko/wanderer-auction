local _, ns = ...
local L = ns.L

-- Selling. On the left, what your bags can sell (what Wanderer Bags sets
-- aside for the auction house first), with the price of the market and a chip
-- for what matters (better at a merchant, identical ones posted together, no
-- price seen). In the middle, the item chosen: your price in three ways (sell
-- fast, just below the cheapest; at the market's price; your own), how many,
-- for how long (the game's durations), then what you will receive against
-- what a merchant gives, and one button. On the right, the market: the
-- cheapest and what is for sale now, yours lit. Never below a merchant: the
-- price is raised to the floor, and said why. On arrival, the prices of what
-- is set aside for the auction house are looked up by themselves, one by one;
-- the button under the list looks up all of them in one look (then, one by
-- one, what it did not bring back), a line saying what happens.
--
-- Selling everything (the button under the list): every item that brings more
-- here than at a merchant, at the way chosen (fast or the market's price), for
-- the duration chosen; one left aside with a click on its row. The game asks
-- a click (or a key) for each sale: the button posts the next one each time.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local COMMODITY = Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity or 2
local BOOK_ROWS = 7 -- what is for sale now, shown

local list, entries, selected = nil, {}, nil
local detail = {}
local pending -- a price search waiting for the auction house to be ready
local posting -- the last sale asked: what, how many, at what price (and its arguments, for a confirmation)
local queue = {} -- the items looked up one by one (on arrival, or what the look at all of them missed)
local scanning -- the one being looked up: { id, commodity, key, kind, entry }
-- Selling everything (on), this visit: what each kind's look found (seen: { lowest, mine }, or false: nobody
-- sells it; silent: no answer), what you left aside, what was posted (or refused), how many, your choices.
local batch = { on = false, seen = {}, aside = {}, done = {}, silent = {}, posted = 0, way = nil, duration = nil }
-- A look at all of them (the button): how far, what came back (a price, nobody selling it, no answer), the
-- one looked up now, whether the auction house makes it wait, whether the one look is under way.
local scan = {}
local function ResetScan(total)
	scan.total, scan.done, scan.found, scan.nobody, scan.silent = total or 0, 0, 0, 0, 0
	scan.current, scan.waiting, scan.bulkOn, scan.waitSaid = nil, false, false, false
end
ResetScan()
local KindOf, Seen, BatchPrice, BatchChip, UpdateBatch, Batch, ShowScan, Draw, Soon -- (below)

-- What Wanderer Bags says of an item (kept: never offered; for the auction house: first).
local NONE = {}
local function Marks() return type(WandererBagsMarks) == "table" and WandererBagsMarks or NONE end
local function IsKept(id) return Marks().IsKept and Marks().IsKept(id) or false end
local function IsForAuction(id) return Marks().IsForAuction and Marks().IsForAuction(id) or false end
-- Asked by one of your quests: never offered either.
local function ForQuest(id) return W.QuestNeed and W.QuestNeed(id) ~= nil or false end

-- Everything your bags can sell here: a commodity once (all its stacks), identical items once (the same
-- link: posted together), each in its slots.
local function Read()
	local found, commodities, items = {}, {}, {}
	U.EachBagItem(function(bag, slot, info)
		local id = Clean(info.itemID)
		local location = ItemLocation and ItemLocation:CreateFromBagAndSlot(bag, slot)
		if location and not Clean(info.isBound) and not IsKept(id) and not ForQuest(id) and Clean(Safe(AH.IsSellItemValid, location, false)) then
			local commodity = Clean(Safe(AH.GetItemCommodityStatus, location)) == COMMODITY
			local count = Clean(info.stackCount) or 1
			local link = Clean(info.hyperlink)
			local entry
			if commodity then entry = commodities[id] elseif link then entry = items[link] end
			if entry then
				entry.count = entry.count + count
				entry.slots[#entry.slots + 1] = { bag, slot }
			else
				entry = { id = id, bag = bag, slot = slot, location = location, link = link, count = count,
					name = U.LinkName(link) or "", quality = Clean(info.quality) or 1,
					icon = Clean(info.iconFileID), commodity = commodity, auction = IsForAuction(id), slots = { { bag, slot } } }
				found[#found + 1] = entry
				if commodity then commodities[id] = entry elseif link then items[link] = entry end
			end
		end
	end)
	table.sort(found, function(a, b)
		if a.auction ~= b.auction then return a.auction end
		if a.quality ~= b.quality then return a.quality > b.quality end
		if a.name ~= b.name then return a.name < b.name end
		return a.bag * 100 + a.slot < b.bag * 100 + b.slot
	end)
	-- The list as drawn: a title before each part.
	local drawn, part = {}, nil
	for _, entry in ipairs(found) do
		local here = entry.auction and "auction" or "rest"
		if here ~= part then
			part = here
			drawn[#drawn + 1] = { header = here == "auction" and L.FOR_AUCTION or L.SECTION_REST }
		end
		drawn[#drawn + 1] = entry
	end
	return drawn
end

-- The game's own starting price: what a merchant gives, times 1.5 (a silver when no merchant buys it).
local function BasePrice(entry)
	local constants = Constants and Constants.AuctionConstants
	local multiplier = constants and constants.DEFAULT_AUCTION_PRICE_MULTIPLIER or 1.5
	local vendor = entry.link and U.SellPrice(entry.link)
	return vendor and vendor > 0 and math.ceil(vendor * multiplier) or 100
end

ns.BasePrice, ns.sellDetail = BasePrice, detail -- (tests)

-- The least worth asking for it, each (its net above what a merchant gives).
local function Floor(entry)
	return ns.Floor(ns.Vendor(entry.link))
end

-- A price to offer when none is for sale now: the last one seen, Auctionator's, else the game's own;
-- never below what a merchant gives.
local function Fallback(entry)
	local price = ns.Price(entry.id) or (Marks().AuctionPrice and Marks().AuctionPrice(entry.link)) or BasePrice(entry)
	return math.max(price, Floor(entry))
end

-- Just below the lowest: one copper less.
local function Below(lowest)
	return lowest > 1 and lowest - 1 or lowest
end

-- An item's starting bid when only a buyout is asked: just below it (some auction houses refuse an item
-- without one: "internal error"). A commodity has none.
local function StartBid(buyout)
	if not buyout or buyout <= 1 then return nil end
	return buyout - 1
end
ns.StartBid = StartBid -- (tests)

local function SavedDuration() return tonumber(ns.Settings() and ns.Settings().duration) or 2 end
-- The way to price by default: yours (the last chosen), else the optimized one.
local function DefaultWay() return ns.Settings() and ns.Settings().sellWay or "optimized" end
local function Duration() return detail.duration or SavedDuration() end

-- How many of it can be posted at once.
local function PostCount(entry)
	return math.max(1, math.min(Clean(Safe(AH.GetAvailablePostCount, entry.location)) or entry.count, entry.count))
end

-- The deposit for posting this many, for this long.
local function Deposit(entry, duration, quantity)
	if entry.commodity then return Clean(Safe(AH.CalculateCommodityDeposit, entry.id, duration, quantity)) end
	return Clean(Safe(AH.CalculateItemDeposit, entry.location, duration, quantity))
end

-- What could sell it cheapest: the starting bid when there is one, else the buyout.
local function Cheapest(buyout, bid)
	if bid > 0 then return bid end
	return buyout
end

-- Worse than a merchant: what it could sell for brings less, once the cut taken, than a merchant gives.
local function Losing(entry, buyout, bid)
	local vendor = ns.Vendor(entry.link)
	local cheapest = Cheapest(buyout, bid)
	return vendor > 0 and cheapest > 0 and ns.Net(cheapest) <= vendor
end

-- How many can be posted, and how many are asked.
local function Most()
	return selected and PostCount(selected) or 1
end
local function Quantity()
	local most = Most()
	return math.max(1, math.min(most, detail.qty or most)), most
end

-- The least an item is offered at: one copper above the floor, so that its starting bid, one copper below,
-- is never under a merchant's either.
local function ItemFloor(entry)
	local floor = Floor(entry)
	if floor > 0 and not entry.commodity then floor = floor + 1 end
	return floor
end

-- The price each, as the way says: optimized (the bait left out, see Prices.lua), sell fast (just below the
-- cheapest, or yours matched), or the market's price; none for sale: the last one seen. opt: what the
-- optimized price found (only when everything for sale was read; else the cheapest is checked against the
-- market's days). Never below the floor (then raised): the price, and whether raised.
local function PriceFor(entry, lowest, mine, way, opt)
	local price
	local days = way == "optimized" and not opt and ns.Market(entry.id)
	if way == "optimized" and opt then
		price = opt.price
	elseif days and lowest and lowest < days * ns.TRUSTED_SHARE then
		price = days -- (only the cheapest known, far under the market's days: a bait; the market's value)
	elseif not lowest then
		price = Fallback(entry)
	elseif way == "market" or mine then
		price = lowest
	else
		price = Below(lowest)
	end
	return math.max(price, ItemFloor(entry)), price < ItemFloor(entry)
end

-- An item's starting bid: yours, else one copper under the buyout (never under the floor). A commodity has
-- none.
local function EffectiveBid(entry, buyout, bid)
	if entry.commodity then return 0 end
	if bid and bid > 0 then return bid end
	local auto = StartBid(buyout) or 0
	local floor = Floor(entry)
	if auto > 0 and auto < floor and floor < buyout then auto = floor end
	return auto
end

ns.PriceFor = PriceFor -- (tests)

-- The chosen item's price each, as the way chosen says (or yours).
local function Unit()
	if not selected then return 0, false end
	if detail.mode == "custom" then return detail.price:Get(), false end
	return PriceFor(selected, selected.lowest, selected.mine, detail.mode, selected.opt)
end

-- The money, as things stand: the price, what you receive, the deposit, a merchant's; the button.
local function UpdateSale()
	if not selected then return end
	local quantity, most = Quantity()
	local unit, raised = Unit()
	local typed = not selected.commodity and detail.mode == "custom" and detail.bid:Get() or 0
	local bid = EffectiveBid(selected, unit, typed)
	detail.qtyText:SetText(tostring(quantity))
	detail.allButton:SetText(L.ALL_COUNT:format(most))
	detail.allButton:Fit()
	detail.durations:Select(Duration())
	detail.custom:SetShown(detail.mode == "custom")
	detail.big:SetShown(detail.mode ~= "custom")
	detail.each:SetShown(detail.mode ~= "custom")
	detail.bidLine:SetShown(detail.mode == "custom" and not selected.commodity)
	detail.big:SetText(unit > 0 and U.Coins(unit) or "")
	-- Why this price.
	local hint
	if raised then
		hint = "|cffe0a040" .. L.HINT_RAISED .. "|r"
	elseif detail.mode == "custom" then
		hint = L.HINT_CUSTOM
	elseif detail.mode == "optimized" and selected.opt then
		local opt = selected.opt
		hint = opt.left > 0 and L.HINT_OPTIMIZED_LEFT:format(opt.left, U.Coins(opt.reference))
			or L.HINT_OPTIMIZED:format(U.Coins(opt.reference))
	elseif not selected.lowest then
		hint = selected.searched and L.HINT_NONE or L.SEARCHING
	elseif selected.mine and detail.mode ~= "market" then
		hint = L.HINT_YOURS
	else
		hint = detail.mode == "market" and L.HINT_MARKET or L.HINT_FAST
	end
	detail.hint:SetText(hint)
	-- The money: what you receive after the cut, a merchant's, the deposit (orange when more than you gain).
	local cheapest = Cheapest(unit, bid)
	local gross = cheapest * quantity
	local net = ns.Net(cheapest) * quantity
	local vendor = ns.Vendor(selected.link)
	local deposit = Deposit(selected, Duration(), quantity)
	local losing = Losing(selected, unit, bid)
	detail.net.value:SetText(cheapest > 0 and U.Coins(net) or "")
	detail.cut.value:SetText(cheapest > 0 and U.Coins(gross - net) or "")
	detail.merchant.value:SetText(vendor > 0 and U.Coins(vendor * quantity) or L.NO_MERCHANT)
	local gain = vendor > 0 and net - vendor * quantity
	if deposit and gain and not losing and cheapest > 0 and deposit > gain then
		detail.deposit.value:SetText("|cffe0a040" .. U.Coins(deposit) .. "|r")
		detail.finance:SetText("|cffe0a040" .. L.DEPOSIT_RISK_SHORT .. "|r")
	else
		detail.deposit.value:SetText(deposit and U.Coins(deposit) or "")
		detail.finance:SetText("")
	end
	if losing then detail.finance:SetText("|cffff6060" .. L.BELOW_MERCHANT:format(U.Coins(ItemFloor(selected))) .. "|r") end
	if ns.Refused(selected.id) then detail.finance:SetText("|cffff6060" .. L.HINT_REFUSED .. "|r") end
	detail.post:SetEnabled((unit > 0 or typed > 0) and (unit == 0 or typed <= unit) and not losing)
	detail.what:SetText(L.POST_WHAT:format(quantity, selected.name or ""))
end

-- Searching ------------------------------------------------------------------------------------------

local Lowest, Scanned -- (below: the lowest price found for an item; an item's look answered)
local LOOK_WAIT = 8 -- seconds: unanswered after this, the next one is asked

-- Whether the game holds the answer to a look: it does not always say so when it already had it (an item
-- looked at before), so this is also checked by itself, twice a second.
local function Answered(this)
	if this.commodity then
		if Clean(Safe(AH.HasFullCommoditySearchResults, this.id)) then return true end
		return (Clean(Safe(AH.GetNumCommoditySearchResults, this.id)) or 0) > 0
	end
	if not this.key then return false end
	if Clean(Safe(AH.HasFullItemSearchResults, this.key)) then return true end
	return (Clean(Safe(AH.GetNumItemSearchResults, this.key)) or 0) > 0
end

local function Query(entry)
	local key = Safe(AH.GetItemKeyFromItem, entry.location)
	if not key then return false end
	entry.key = key
	-- (the buying search, as the Buy page: the selling one is left unanswered by some games)
	local order = Enum.AuctionHouseSortOrder
	Safe(AH.SendSearchQuery, key, { { sortOrder = order.Price, reverseSort = false }, { sortOrder = order.Name, reverseSort = false } }, true)
	return true
end

-- One more answer of the look at all of them, counted: a price, nobody selling it, or no answer; the
-- last one: the tally written in the journal.
local function Count(what)
	if scan.total > 0 and scan.done < scan.total then
		scan.done = scan.done + 1
		scan[what] = scan[what] + 1
		if scan.done == scan.total then
			ns.Log("title", L.SCAN_FINISHED:format(L.SCAN_TALLY:format(scan.found, scan.nobody, scan.silent)))
		end
	end
end

-- A look at all of them under way (what the journal follows).
local function Looking() return scan.total > 0 and scan.done < scan.total end

-- The cheapest offer to believe: the first credible one (the bait left out), else the cheapest.
local function Credible(lowest, opt)
	return opt and (opt.credible or opt.reference) or lowest
end

-- What a look found for an item, written in the journal: its price (yours, said so; the optimized one and
-- the bait left out), better at a merchant, or nobody selling it.
local function Logged(entry, lowest, mine, opt)
	local name = entry.link or entry.name or ""
	if not lowest then return ns.Log("none", L.LOG_NOBODY:format(name)) end
	local vendor = ns.Vendor(entry.link)
	if vendor > 0 and Losing(entry, Credible(lowest, opt), 0) then
		return ns.Log("none", L.LOG_MERCHANT:format(name, U.Coins(lowest), U.Coins(vendor)))
	end
	ns.Log("good", L.LOG_FOUND:format(name, U.Coins(lowest)) .. (mine and " " .. L.LOG_YOURS or "")
		.. (opt and L.LOG_OPTIMIZED:format(U.Coins(opt.price)) or ""))
	if opt and opt.left > 0 then ns.Log("bad", L.LOG_BAIT:format(name, opt.left)) end
end

-- The auction house makes the look wait: said once in the journal.
local function SayWaiting()
	if Looking() and not scan.waitSaid then
		scan.waitSaid = true
		ns.Log("bad", L.SCAN_WAITING)
	end
end

-- No answer from the game: said on its row, in the tally and in the journal.
local function Unanswered(entry)
	batch.silent[KindOf(entry)] = true
	if Looking() then ns.Log("bad", L.LOG_SILENT:format(entry.link or entry.name or "")) end
	Count("silent")
end

-- The next search: the item you chose, else the next item for the auction house.
local retrying = false
local function Search()
	-- (the page put away: the looks wait for it, they use the same search as the Buy page)
	if not (list and list:IsVisible()) then return end
	if not ns.Ready() then
		pending = true
		if not scan.waiting then
			scan.waiting = true
			SayWaiting()
			ShowScan()
		end
		if not retrying then
			retrying = true
			C_Timer.After(1, function()
				retrying = false
				if pending then Search() end
			end)
		end
		return
	end
	pending = false
	scan.waiting = false
	if selected and not selected.key and not selected.unknown then
		if Query(selected) then
			-- (the queue goes on after this one's answer, or a moment later without it)
			C_Timer.After(LOOK_WAIT, function() if not scanning then Search() end end)
			return
		end
		selected.unknown = true -- (the auction house has no key for it: the others looked up all the same)
	end
	-- One look at a time: the next when this one is answered (or, unanswered, a moment later).
	if scanning then return end
	local entry = table.remove(queue, 1)
	if entry and Query(entry) then
		local this = { id = entry.id, commodity = entry.commodity, key = entry.key, entry = entry, kind = KindOf(entry) }
		scanning = this
		scan.current = entry.name
		ShowScan()
		local function Check(tries)
			if scanning ~= this then return end
			if Answered(this) then return Scanned() end
			if tries > 1 then C_Timer.After(0.5, function() Check(tries - 1) end) end
		end
		C_Timer.After(0.5, function() Check(LOOK_WAIT * 2 - 2) end)
		C_Timer.After(LOOK_WAIT, function()
			if scanning == this then
				scanning = nil
				Unanswered(this.entry)
				ShowScan()
				Search()
			end
		end)
	elseif entry then
		-- (no key for it: nothing to ask, counted all the same)
		Unanswered(entry)
		ShowScan()
		Search()
	end
end

-- The lowest asked (by others, or yours), each; how many for sale; whether the lowest is yours.
function Lowest(entry)
	if not entry then return nil end
	if entry.commodity then
		local count = Clean(Safe(AH.GetNumCommoditySearchResults, entry.id)) or 0
		local first = count > 0 and Safe(AH.GetCommoditySearchResultInfo, entry.id, 1)
		if type(first) ~= "table" then return nil, count end
		return Clean(first.unitPrice), Clean(Safe(AH.GetCommoditySearchResultsQuantity, entry.id)) or count,
			Clean(first.containsOwnerItem)
	end
	local key = entry.key
	local count = key and Clean(Safe(AH.GetNumItemSearchResults, key)) or 0
	for index = 1, count do
		local result = Safe(AH.GetItemSearchResultInfo, key, index)
		local buyout = type(result) == "table" and Clean(result.buyoutAmount)
		if buyout and buyout > 0 then
			return math.floor(buyout / math.max(1, Clean(result.quantity) or 1)), count, Clean(result.containsOwnerItem)
		end
	end
	return nil, count
end

-- What is for sale now (the cheapest first): { price each, how many, yours }.
local function Book(entry)
	local book = {}
	if entry.commodity then
		local count = Clean(Safe(AH.GetNumCommoditySearchResults, entry.id)) or 0
		for index = 1, math.min(count, BOOK_ROWS) do
			local result = Safe(AH.GetCommoditySearchResultInfo, entry.id, index)
			if type(result) == "table" then
				book[#book + 1] = { Clean(result.unitPrice) or 0, Clean(result.quantity) or 1,
					(Clean(result.numOwnerItems) or 0) > 0 or Clean(result.containsOwnerItem) and true or false }
			end
		end
	elseif entry.key then
		local count = Clean(Safe(AH.GetNumItemSearchResults, entry.key)) or 0
		for index = 1, math.min(count, BOOK_ROWS) do
			local result = Safe(AH.GetItemSearchResultInfo, entry.key, index)
			local buyout = type(result) == "table" and Clean(result.buyoutAmount)
			if buyout then
				local quantity = Clean(result.quantity) or 1
				book[#book + 1] = { math.floor(buyout / math.max(1, quantity)), quantity, Clean(result.containsOwnerItem) and true or false }
			end
		end
	end
	return book
end

-- Everything others sell now, cheapest first: { price each, how many } (yours left out).
local LISTINGS = 300 -- read at most
local function Listings(entry)
	local listings = {}
	if entry.commodity then
		local count = Clean(Safe(AH.GetNumCommoditySearchResults, entry.id)) or 0
		for index = 1, math.min(count, LISTINGS) do
			local result = Safe(AH.GetCommoditySearchResultInfo, entry.id, index)
			local price = type(result) == "table" and Clean(result.unitPrice)
			if price and price > 0 and (Clean(result.numOwnerItems) or 0) == 0 and not Clean(result.containsOwnerItem) then
				listings[#listings + 1] = { price, Clean(result.quantity) or 1 }
			end
		end
	elseif entry.key then
		local count = Clean(Safe(AH.GetNumItemSearchResults, entry.key)) or 0
		for index = 1, math.min(count, LISTINGS) do
			local result = Safe(AH.GetItemSearchResultInfo, entry.key, index)
			local buyout = type(result) == "table" and Clean(result.buyoutAmount)
			if buyout and buyout > 0 and not Clean(result.containsOwnerItem) then
				local quantity = Clean(result.quantity) or 1
				listings[#listings + 1] = { math.floor(buyout / math.max(1, quantity)), quantity }
			end
		end
	end
	table.sort(listings, function(a, b) return a[1] < b[1] end)
	return listings
end

-- The optimized price of an item from everything for sale now and its market's days (remember: today's
-- value counted with them, once per look): { price, left (offers left out), reference, credible }, or nil.
local function Optimized(entry, remember)
	local listings = Listings(entry)
	local history = ns.Market(entry.id)
	local value = ns.MarketValue(listings)
	if value and remember then ns.RememberMarket(entry.id, value) end
	local price, left, reference, credible = ns.Optimize(listings, history, ItemFloor(entry))
	return price and { price = price, left = left, reference = reference, credible = credible } or nil
end

-- The market, on the right.
local function ShowMarket()
	local entry = selected
	local lowest = entry and entry.lowest
	-- (a price large; words, when there is none, as small as the rest of the card)
	detail.lowest:SetFontObject(lowest and "GameTooltipHeaderText" or "GameTooltipText")
	detail.lowest:SetText(lowest and U.Coins(lowest) or (entry and entry.searched and L.NOBODY or L.SEARCHING))
	detail.onSale:SetText(entry and entry.onSale and tostring(entry.onSale) or "")
	local book = entry and entry.book or {}
	for index, line in ipairs(detail.book) do
		local offer = book[index]
		line:SetShown(offer ~= nil)
		if offer then
			line.price:SetText(U.Coins(offer[1]))
			line.count:SetText(offer[3] and L.YOURS or ("x" .. offer[2]))
			line.mine:SetShown(offer[3])
		end
	end
	detail.bookEmpty:SetShown(entry ~= nil and entry.searched and not book[1] or false)
end

-- The table: the price of the market for each, a chip for what matters.
local function Chip(entry)
	if ns.Refused(entry.id) then return L.CHIP_REFUSED, "red" end
	local price = ns.Price(entry.id)
	if not price and batch.silent[KindOf(entry)] then return L.CHIP_SILENT, "grey" end
	if not price then return L.CHIP_NO_PRICE, "grey" end
	local seen = batch.seen[KindOf(entry)]
	if Losing(entry, seen and seen.opt and Credible(seen.lowest, seen.opt) or ns.Market(entry.id) or price, 0) then
		return L.CHIP_MERCHANT, "red"
	end
	if not entry.commodity and entry.count > 1 then return L.CHIP_TOGETHER:format(entry.count), "blue" end
	return nil
end

-- The list as shown: all of it, or (selling everything) without what brings more at a merchant (its title
-- kept only over what is left under it).
local function Listed()
	if not batch.on then return entries end
	local shown, title = {}, nil
	for _, entry in ipairs(entries) do
		if entry.header then
			title = entry
		elseif select(2, BatchPrice(entry)) ~= "merchant" then
			if title then shown[#shown + 1], title = title, nil end
			shown[#shown + 1] = entry
		end
	end
	return shown
end

function Draw()
	if not (list and list:IsVisible()) then return end
	local listed = Listed()
	local offset = list:Clamp(#listed)
	for index, row in ipairs(list.rows) do
		local entry = listed[index + offset]
		local values, chip, tone
		if entry and not entry.header and batch.on then
			local unit = BatchPrice(entry)
			local kind = KindOf(entry)
			local shown = unit and not batch.aside[kind] and not batch.done[kind]
			values = { qty = tostring(entry.count), market = shown and U.Coins(unit) or "" }
			chip, tone = BatchChip(entry)
		elseif entry and not entry.header then
			local price = ns.Price(entry.id)
			values = { qty = tostring(entry.count), market = price and U.Coins(price) or "|cff8f8676" .. L.NEVER_SEEN .. "|r" }
			chip, tone = Chip(entry)
		end
		row:Fill(entry, entry ~= nil and not batch.on and entry == selected, values, chip, tone)
	end
	list.empty:SetShown(#listed == 0)
end

-- What the look is doing, said: the one looked up now and the tally, or the tally once done.
local function ScanStatus()
	if scan.total == 0 then return "" end
	local tally = L.SCAN_TALLY:format(scan.found, scan.nobody, scan.silent)
	if scan.done >= scan.total then return L.SCAN_FINISHED:format(tally) end
	local now = scan.waiting and L.SCAN_WAITING or scan.bulkOn and L.SCAN_BULK:format(scan.total)
		or L.SCAN_NOW:format(scan.done + 1, scan.total, scan.current or "")
	return now .. "\n" .. tally
end
ns.ScanStatus = ScanStatus -- (tests)

-- The status said, the list drawn again (with the money of selling everything, when on).
function ShowScan()
	if detail.scanText then detail.scanText:SetText(ScanStatus()) end
	if batch.on then UpdateBatch() else Draw() end
end

-- The price an item was last known at (the market's days, else the last one seen).
local function Remembered(id) return ns.Market(id) or ns.Price(id) end

-- Set aside for the auction house (Wanderer Bags), but bringing more at a merchant: made junk (the option),
-- sold at the next merchant; said in the chat. (From a look at the prices, or the item you chose: it could
-- not be posted anyway.)
local function ToMerchant(kind, lowest, mine)
	-- (lowest: the cheapest offer to believe)
	if not (lowest and not mine and ns.Settings() and ns.Settings().toMerchant and Marks().ToJunk) then return end
	for _, entry in ipairs(entries) do
		if not entry.header and entry.auction and KindOf(entry) == kind
			and Losing(entry, lowest, 0) and Marks().ToJunk(entry.id) then
			entry.auction = false
			if W.Print then W.Print(L.MOVED_TO_JUNK:format(entry.link or entry.name or "")) end
			Soon()
		end
	end
end

-- An item's look answered: its lowest remembered and counted, the next one asked.
function Scanned()
	local this = scanning
	local lowest, _, mine = Lowest(this)
	scanning = nil
	local opt = lowest and Optimized(this.entry, true)
	if lowest then ns.Remember(this.id, lowest, true) end
	Seen(this.kind, lowest, mine, opt)
	if Looking() then Logged(this.entry, lowest, mine, opt) end
	-- (nobody selling it now: judged by the price it was last seen at, as its row says)
	ToMerchant(this.kind, lowest and Credible(lowest, opt) or Remembered(this.id), mine)
	Count(lowest and "found" or "nobody")
	ShowScan()
	Search()
end

-- All of them in one look (the auction house's own way of looking up many items at once): the lowest of
-- each. Those it does not bring back are then looked at one by one (nobody sells them, or no answer).
local bulk -- the look at all of them under way: { keys, entries, found = { kind = true }, at = its last answer }

-- The same item: its id, suffix ("of the owl") and item level.
local function SameItem(entry, key)
	if type(key) ~= "table" or Clean(key.itemID) ~= entry.id then return false end
	local own = type(entry.key) == "table" and entry.key or {}
	return (Clean(key.itemSuffix) or 0) == (Clean(own.itemSuffix) or 0)
		and (Clean(key.itemLevel) or 0) == (Clean(own.itemLevel) or 0)
end

local function BulkDone()
	local this = bulk
	if not this then return end
	bulk = nil
	scan.bulkOn = false
	wipe(queue)
	for _, entry in ipairs(this.entries) do
		if not this.found[KindOf(entry)] then queue[#queue + 1] = entry end
	end
	if queue[1] then ns.Log("text", L.LOG_BULK_DONE:format(scan.found, #queue)) end
	ShowScan()
	Search()
end

local function ReadBulk()
	local this = bulk
	if not this then return end
	this.at = GetTime()
	local results = Safe(AH.GetBrowseResults)
	for _, result in ipairs(type(results) == "table" and results or {}) do
		local price = Clean(result.minPrice)
		for _, entry in ipairs(this.entries) do
			local kind = KindOf(entry)
			if not this.found[kind] and price and price > 0 and SameItem(entry, result.itemKey) then
				this.found[kind] = true
				local mine = Clean(result.containsOwnerItem)
				ns.Remember(entry.id, price, true)
				Seen(kind, price, mine)
				Logged(entry, price, mine)
				-- (only the cheapest known here: believed for junk only when near the market's days)
				local days = ns.Market(entry.id)
				if days and price >= days * ns.TRUSTED_SHARE then ToMerchant(kind, price, mine) end
				Count("found")
			end
		end
	end
	ShowScan()
	-- More pages: asked; all of them: the rest looked at one by one.
	if Clean(Safe(AH.HasFullBrowseResults)) == false then
		Safe(AH.RequestMoreBrowseResults)
	else
		BulkDone()
	end
end

local function SendBulk(this)
	if bulk ~= this then return end
	if not ns.Ready() then
		SayWaiting()
		scan.waiting = true
		ShowScan()
		return C_Timer.After(1, function() SendBulk(this) end)
	end
	scan.waiting = false
	scan.bulkOn = true
	ShowScan()
	local order = Enum.AuctionHouseSortOrder
	if not pcall(AH.SearchForItemKeys, this.keys, { { sortOrder = order.Price, reverseSort = false } }) then
		return BulkDone()
	end
	-- Unanswered for a while (since the last page): the one-by-one looks take over.
	this.at = GetTime()
	local function Watch()
		if bulk ~= this then return end
		if GetTime() - this.at >= LOOK_WAIT then return BulkDone() end
		C_Timer.After(1, Watch)
	end
	C_Timer.After(1, Watch)
end

function ns.ScanAll()
	wipe(queue)
	scanning = nil -- (a look started before: its answer no longer counted)
	local this = { keys = {}, entries = {}, found = {} }
	for _, entry in ipairs(entries) do
		if not entry.header and entry ~= selected then
			this.entries[#this.entries + 1] = entry
			local ok, key = pcall(AH.GetItemKeyFromItem, entry.location)
			if ok and key then
				entry.key = key
				this.keys[#this.keys + 1] = key
			end
		end
	end
	ResetScan(#this.entries)
	ns.ShowLog()
	ns.Log("title", L.LOG_START:format(#this.entries))
	-- (the optimized price reads everything for sale: each item looked at in full, one by one)
	if (batch.way or DefaultWay()) == "optimized" then
		wipe(this.keys)
		ns.Log("text", L.LOG_ONE_BY_ONE)
	end
	if this.keys[1] then ns.Log("text", L.LOG_BULK) end
	if not this.keys[1] then
		queue = this.entries
		ShowScan()
		return Search()
	end
	bulk = this
	SendBulk(this)
end
ns.ReadBulk = ReadBulk -- (tests)

-- The prices found: the market shown, the price offered as the way chosen says.
local function ShowPrices()
	if not selected then return end
	local lowest, onSale, mine = Lowest(selected)
	selected.lowest, selected.onSale, selected.mine, selected.searched = lowest, onSale, mine and true or false, true
	selected.book = Book(selected)
	-- (the first answer of this choice counted in the days; the ones after only read)
	selected.opt = lowest and Optimized(selected, not selected.counted) or nil
	if lowest then selected.counted = true end
	if lowest then ns.Remember(selected.id, lowest, true) end
	Seen(KindOf(selected), lowest, mine, selected.opt)
	ToMerchant(KindOf(selected), lowest and Credible(lowest, selected.opt) or Remembered(selected.id), mine)
	-- Your own price: offered once (what you type after is never overwritten), as your way prices it.
	if not selected.offered then
		selected.offered = true
		local mode = detail.mode
		if mode == "custom" then detail.mode = DefaultWay() end
		detail.price:Set((Unit()))
		detail.mode = mode
		Search()
	end
	ShowMarket()
	UpdateSale()
	Draw()
end

local function Select(entry)
	if entry and batch.on then Batch(false) end
	selected = entry
	if not detail.frame then return end
	detail.frame:SetShown(entry ~= nil)
	detail.pick:SetShown(entry == nil)
	if entry then
		detail.icon:Set(entry.icon, entry.quality)
		detail.name:SetText(entry.name or "")
		Skin.Quality(detail.name, entry.quality)
		detail.sub:SetText(L.IN_BAGS:format(entry.count))
		entry.key, entry.offered, entry.lowest, entry.searched, entry.book, entry.opt, entry.counted = nil, nil, nil, false, nil, nil, nil
		detail.mode, detail.qty, detail.duration = DefaultWay(), nil, nil
		detail.modes:Select(detail.mode)
		detail.bid:Set(0)
		detail.price:Set((Unit()))
		ShowMarket()
		UpdateSale()
		Search()
	end
	Draw()
end

local function Refresh()
	if not (list and list:IsVisible()) then return end
	entries = Read()
	-- The item chosen, still there: kept chosen, with its search and the price you set.
	if selected then
		local still
		for _, entry in ipairs(entries) do
			if entry.id == selected.id and (selected.commodity or entry.link == selected.link) then
				still = entry
			end
		end
		if still then
			for _, key in ipairs({ "key", "offered", "lowest", "onSale", "mine", "searched", "book", "opt", "counted" }) do
			still[key] = selected[key]
		end
			selected = still
			UpdateSale()
		else
			Select(nil)
		end
	end
	if batch.on then UpdateBatch() else Draw() end
end

-- Posting --------------------------------------------------------------------------------------------

local Confirm -- (below: a sale confirmed)

-- A sale sent to the game: an item with a starting bid (just below the buyout when none is asked), a
-- commodity by its unit price; remembered for the game's answer (or its confirmation). batchKind: sent while
-- selling everything. Returns false and the game's words when it refuses at once.
local function Send(entry, quantity, buyout, bid, duration, batchKind)
	bid = EffectiveBid(entry, buyout, bid)
	local ok, needsConfirmation
	if entry.commodity then
		ok, needsConfirmation = pcall(AH.PostCommodity, entry.location, duration, quantity, buyout)
	else
		ok, needsConfirmation = pcall(AH.PostItem, entry.location, duration, quantity, bid > 0 and bid or nil, buyout > 0 and buyout or nil)
	end
	if not ok then return false, needsConfirmation end
	posting = { name = entry.link or entry.name, quantity = quantity, unit = buyout > 0 and buyout or bid, bid = bid,
		buyout = buyout, id = entry.id, commodity = entry.commodity, location = entry.location, duration = duration,
		batch = batchKind, at = GetTime() }
	if Clean(needsConfirmation) then
		Skin.Ask(L.CONFIRM, Confirm, function()
			posting = nil
			if batch.on then UpdateBatch() end
		end)
	end
	return true
end

local function Post()
	if not selected then return end
	local buyout = Unit()
	local bid = not selected.commodity and detail.mode == "custom" and detail.bid:Get() or 0
	if buyout <= 0 and bid <= 0 or Losing(selected, buyout, EffectiveBid(selected, buyout, bid)) then return end
	local ok, why = Send(selected, Quantity(), buyout, bid, Duration())
	if not ok then
		local said = L.POST_REFUSED:format(tostring(why))
		detail.finance:SetText("|cffff6060" .. said .. "|r")
		ns.Log("bad", said)
	end
end

-- A confirmation posts exactly what was asked, whatever is chosen since.
function Confirm()
	local sale = posting
	if not sale then return end
	if sale.commodity then
		Safe(AH.ConfirmPostCommodity, sale.location, sale.duration, sale.quantity, sale.buyout)
	else
		Safe(AH.ConfirmPostItem, sale.location, sale.duration, sale.quantity, sale.bid > 0 and sale.bid or nil,
			sale.buyout > 0 and sale.buyout or nil)
	end
end

-- Selling everything ------------------------------------------------------------------------------------

-- An item's kind: a commodity by its id (all its stacks), an item by its link (identical ones together).
function KindOf(entry) return entry.commodity and entry.id or (entry.link or entry.id) end

function Seen(kind, lowest, mine, opt)
	if kind == nil then return end
	batch.seen[kind] = lowest and { lowest = lowest, mine = mine and true or false, opt = opt } or false
	batch.silent[kind] = nil
end

local function Way() return batch.way or DefaultWay() end
local function BatchDuration() return batch.duration or SavedDuration() end

-- The price each when selling everything, or nil and why ("search": not looked up yet, "merchant": better
-- there). Nobody selling it: the last price seen (or the game's own), said so ("nobody").
function BatchPrice(entry)
	if ns.Refused(entry.id) then return nil, "refused" end
	local seen = batch.seen[KindOf(entry)]
	if seen == nil then return nil, "search" end
	local opt = seen and Way() == "optimized" and seen.opt or nil
	if seen and Losing(entry, Credible(seen.lowest, seen.opt), 0) then return nil, "merchant" end
	-- (nobody selling it: better at a merchant by the price it was last known at, as its row says)
	local known = seen == false and Remembered(entry.id)
	if known and Losing(entry, known, 0) then return nil, "merchant" end
	return (PriceFor(entry, seen and seen.lowest, seen and seen.mine, Way(), opt)), seen == false and "nobody" or nil
end

-- What will be posted, in the list's order: { entry, unit, quantity }.
local function BatchItems()
	local items = {}
	for _, entry in ipairs(entries) do
		local kind = not entry.header and KindOf(entry)
		if kind and not batch.aside[kind] and not batch.done[kind] then
			local unit = BatchPrice(entry)
			if unit and unit > 0 then items[#items + 1] = { entry = entry, unit = unit, quantity = PostCount(entry) } end
		end
	end
	return items
end
ns.BatchItems = BatchItems -- (tests)

-- The row's chip while selling everything.
function BatchChip(entry)
	local kind = KindOf(entry)
	if batch.done[kind] then return L.CHIP_POSTED, "green" end
	if batch.aside[kind] then return L.CHIP_ASIDE, "grey" end
	local unit, why = BatchPrice(entry)
	if why == "search" then return batch.silent[kind] and L.CHIP_SILENT or L.CHIP_SEARCHING, "grey" end
	if why == "nobody" then return L.CHIP_NOBODY, "blue" end
	if why == "refused" then return L.CHIP_REFUSED, "red" end
	local seen = batch.seen[kind]
	local opt = seen and Way() == "optimized" and seen.opt
	if unit and opt and opt.left > 0 then return L.CHIP_BAIT:format(opt.left), "blue" end
	return unit and L.CHIP_TO_SELL or nil, "gold"
end

-- (a sale under way: the next waits for its answer; unanswered, a moment at most)
local function Waiting() return posting ~= nil and posting.batch ~= nil and GetTime() - (posting.at or 0) < 10 end

function UpdateBatch()
	if not (batch.on and detail.batch) then return end
	local items = BatchItems()
	local net, deposit, merchant = 0, 0, 0
	for _, item in ipairs(items) do
		local entry = item.entry
		net = net + ns.Net(item.unit) * item.quantity
		merchant = merchant + ns.Vendor(entry.link) * item.quantity
		deposit = deposit + (Deposit(entry, BatchDuration(), item.quantity) or 0)
	end
	local b = detail.batch
	b.way:Select(Way())
	b.durations:Select(BatchDuration())
	b.count.value:SetText(tostring(#items))
	b.net.value:SetText(U.Coins(net))
	b.deposit.value:SetText(U.Coins(deposit))
	b.merchant.value:SetText(U.Coins(merchant))
	b.status:SetText(L.SELL_ALL_CLICKS)
	local first = items[1]
	if first then
		b.post:SetText(L.SELL_ALL_NEXT:format(first.entry.name or "", batch.posted + 1, batch.posted + #items))
	else
		b.post:SetText(batch.posted > 0 and L.SELL_ALL_FINISHED:format(batch.posted) or L.SELL_ALL_NONE)
	end
	b.post:SetEnabled(first ~= nil and not Waiting())
	Draw()
end

-- (said above the button: why nothing was posted)
local function Tell(text)
	if detail.batch then detail.batch.status:SetText("|cffe0a040" .. text .. "|r") end
end

-- The next one posted (a click, the key or a notch of the wheel: the game asks one for each sale). Never
-- while a sale waits for its answer or its confirmation.
local function PostNext()
	if not batch.on or Waiting() or (StaticPopup_Visible and StaticPopup_Visible("WANDERER_ASK")) then return end
	-- The auction house busy (a look just made): said, the next click will do.
	if not ns.Ready() then return Tell(L.SELL_ALL_BUSY) end
	local item = BatchItems()[1]
	if not item then return end
	local entry = item.entry
	local ok, why = Send(entry, item.quantity, item.unit, 0, BatchDuration(), KindOf(entry))
	-- Refused by the game at once: said why, this one left aside, the next one offered.
	if not ok then
		batch.done[KindOf(entry)] = true
		UpdateBatch()
		local said = L.SELL_ALL_REFUSED:format(entry.name or "", tostring(why))
		ns.Log("bad", said)
		return Tell(said)
	end
	UpdateBatch()
	-- (unanswered: the button given back once the wait is over)
	C_Timer.After(10.1, function() if batch.on then UpdateBatch() end end)
end
function WandererAuction_PostNext() PostNext() end

function Batch(on)
	batch.on = on and true or false
	if batch.on and selected then Select(nil) end
	if detail.batch then detail.batch:SetShown(batch.on) end
	if detail.pick then detail.pick:SetShown(not batch.on and selected == nil) end
	if batch.on then
		-- The prices of this visit: looked up when one is still unknown (and no look is under way).
		local unknown = false
		for _, entry in ipairs(entries) do
			if not entry.header and batch.seen[KindOf(entry)] == nil then unknown = true end
		end
		if unknown and not (scan.total > 0 and scan.done < scan.total) then ns.ScanAll() end
		UpdateBatch()
	else
		Draw()
	end
end
ns.SellAll = Batch -- (tests)

local function BuildBatch(page)
	local b = CreateFrame("Frame", nil, page)
	b:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, 0)
	b:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	b:Hide()
	detail.batch = b
	local title = W.Skin.CreateText(b, "GameFontNormalLarge")
	title:SetPoint("TOPLEFT")
	title:SetText(L.SELL_ALL)
	local intro = Skin.Text(b, "GameTooltipTextSmall", "soft")
	intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	intro:SetPoint("RIGHT", b, "RIGHT", 0, 0)
	intro:SetJustifyH("LEFT")
	intro:SetText(L.SELL_ALL_INTRO)
	local wayCaps = Skin.Caps(b, L.YOUR_PRICE)
	wayCaps:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -18)
	b.way = Skin.Choices(b, { { "optimized", L.MODE_OPTIMIZED }, { "fast", L.MODE_FAST }, { "market", L.MODE_MARKET } }, function(key)
		batch.way = key
		if ns.Settings() then ns.Settings().sellWay = key end
		UpdateBatch()
	end, 34)
	b.way:SetPoint("TOPLEFT", wayCaps, "BOTTOMLEFT", 0, -6)
	b.way:SetWidth(380)
	local durationCaps = Skin.Caps(b, L.DURATION_TITLE)
	durationCaps:SetPoint("TOPLEFT", b.way, "BOTTOMLEFT", 0, -16)
	b.durations = Skin.Choices(b, { { 1, ns.DurationName(1) }, { 2, ns.DurationName(2) }, { 3, ns.DurationName(3) } }, function(key)
		batch.duration = key
		UpdateBatch()
	end, 30)
	b.durations:SetPoint("TOPLEFT", durationCaps, "BOTTOMLEFT", 0, -6)
	b.durations:SetWidth(320)
	-- The money, the button, back to one item at a time.
	b.back = Skin.Button(b, L.SELL_ALL_BACK, function() Batch(false) end)
	b.back:SetPoint("BOTTOMLEFT")
	b.post = Skin.Button(b, L.SELL_ALL_NONE, PostNext, "main")
	-- (each notch of the mouse wheel over it posts the next one too: the game takes it as your own gesture)
	b.post:EnableMouseWheel(true)
	b.post:SetScript("OnMouseWheel", function() PostNext() end)
	b.post:SetPoint("BOTTOMLEFT", b.back, "TOPLEFT", 0, 8)
	b.post:SetPoint("RIGHT", b, "RIGHT", 0, 0)
	b.status = Skin.Text(b, "GameTooltipTextSmall", "muted")
	b.status:SetPoint("BOTTOMLEFT", b.post, "TOPLEFT", 0, 8)
	b.status:SetPoint("RIGHT", b, "RIGHT", 0, 0)
	b.status:SetJustifyH("LEFT")
	local summary = Skin.Panel(b)
	summary:SetPoint("BOTTOMLEFT", b.status, "TOPLEFT", 0, 10)
	summary:SetPoint("RIGHT", b, "RIGHT", 0, 0)
	summary:SetHeight(112)
	b.count = Skin.SummaryLine(summary, nil, L.SELL_ALL_COUNT)
	b.net = Skin.SummaryLine(summary, b.count, L.YOU_RECEIVE, true)
	b.deposit = Skin.SummaryLine(summary, b.net, L.DEPOSIT_LINE)
	b.merchant = Skin.SummaryLine(summary, b.deposit, L.MERCHANT_LINE)
end

-- The page ----------------------------------------------------------------------------------------------

local function Build(page)
	list = Skin.Table(page, {
		nameTitle = L.COL_ITEM,
		width = 390, rows = 26, onDraw = Draw,
		onClick = function(entry)
			if not batch.on then return Select(entry) end
			-- Selling everything: a click leaves it aside, or takes it back.
			local kind = entry and KindOf(entry)
			if kind and not batch.done[kind] then
				batch.aside[kind] = not batch.aside[kind] or nil
				UpdateBatch()
			end
		end,
		columns = { { key = "qty", title = L.COL_QTY, width = 40 }, { key = "market", title = L.COL_MARKET, width = 110 } },
	})
	list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	list.empty:SetText(L.EMPTY)
	-- Under the table: the prices of all your items looked up in one go, and how far it is.
	detail.scan = Skin.Button(page, L.SCAN_PRICES, function() ns.ScanAll() end)
	detail.scan:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
	Skin.Tooltip(detail.scan, L.SCAN_PRICES_DESC, "ANCHOR_TOP")
	detail.sellAll = Skin.Button(page, L.SELL_ALL, function() Batch(not batch.on) end)
	detail.sellAll:SetPoint("LEFT", detail.scan, "RIGHT", 8, 0)
	Skin.Tooltip(detail.sellAll, L.SELL_ALL_DESC, "ANCHOR_TOP")
	detail.log = Skin.SmallButton(page, L.LOG_OPEN, function() ns.ShowLog() end, L.LOG_OPEN_DESC)
	-- (its right edge on the list's, 390 wide, level with the buttons)
	detail.log:SetPoint("RIGHT", detail.scan, "LEFT", 390, 0)
	detail.scanText = Skin.Text(page, "GameTooltipTextSmall", "muted")
	detail.scanText:SetPoint("LEFT", detail.sellAll, "RIGHT", 10, 0)
	detail.scanText:SetPoint("RIGHT", detail.log, "LEFT", -8, 0)
	detail.scanText:SetJustifyH("LEFT")
	function page:Fit(height) list:Fit(height - 40) end
	local rule = Skin.Rule(page, true, 0.12)
	rule:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP / 2, 0)
	rule:SetPoint("BOTTOM", page, "BOTTOM", 0, 0)
	detail.pick = Skin.Text(page, "GameTooltipText", "muted")
	detail.pick:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, -60)
	detail.pick:SetText(L.PICK)
	local frame = CreateFrame("Frame", nil, page)
	frame:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, 0)
	frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	frame:Hide()
	detail.frame = frame
	-- On the right: the market.
	local market = CreateFrame("Frame", nil, frame)
	market:SetWidth(230)
	market:SetPoint("TOPRIGHT")
	market:SetPoint("BOTTOMRIGHT")
	local card = Skin.Panel(market)
	card:SetPoint("TOPLEFT")
	card:SetPoint("TOPRIGHT")
	card:SetHeight(104)
	local caps = Skin.Caps(card, L.MARKET)
	caps:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -12)
	local lowestLabel = Skin.Text(card, "GameTooltipTextSmall", "muted")
	lowestLabel:SetPoint("TOPLEFT", caps, "BOTTOMLEFT", 0, -10)
	lowestLabel:SetText(L.CHEAPEST)
	detail.lowest = Skin.Text(card, "GameTooltipHeaderText", "text")
	detail.lowest:SetPoint("TOPLEFT", lowestLabel, "BOTTOMLEFT", 0, -3)
	detail.lowest:SetPoint("RIGHT", card, "RIGHT", -14, 0)
	detail.lowest:SetJustifyH("LEFT")
	local onSaleLabel = Skin.Text(card, "GameTooltipTextSmall", "muted")
	onSaleLabel:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 14, 12)
	onSaleLabel:SetText(L.FOR_SALE)
	detail.onSale = Skin.Text(card, "GameTooltipTextSmall", "soft")
	detail.onSale:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -14, 12)
	local bookCaps = Skin.Caps(market, L.FOR_SALE_NOW)
	bookCaps:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -16)
	detail.book = {}
	for index = 1, BOOK_ROWS do
		local line = CreateFrame("Frame", nil, market)
		line:SetHeight(24)
		line:SetPoint("TOPLEFT", bookCaps, "BOTTOMLEFT", 0, -6 - (index - 1) * 26)
		line:SetPoint("RIGHT", market, "RIGHT", 0, 0)
		line.ground = line:CreateTexture(nil, "BACKGROUND")
		line.ground:SetAllPoints()
		line.ground:SetColorTexture(1, 1, 1, 0.03)
		line.mine = line:CreateTexture(nil, "BACKGROUND", nil, 1)
		line.mine:SetAllPoints()
		line.mine:SetColorTexture(1, 0.82, 0, 0.1)
		line.price = Skin.Text(line, "GameTooltipTextSmall", "text")
		line.price:SetPoint("LEFT", line, "LEFT", 8, 0)
		line.count = Skin.Text(line, "GameTooltipTextSmall", "muted")
		line.count:SetPoint("RIGHT", line, "RIGHT", -8, 0)
		line:Hide()
		detail.book[index] = line
	end
	detail.bookEmpty = Skin.Text(market, "GameTooltipTextSmall", "muted")
	detail.bookEmpty:SetPoint("TOPLEFT", bookCaps, "BOTTOMLEFT", 0, -8)
	detail.bookEmpty:SetText(L.NOBODY)
	-- In the middle: the item, your price, how many, how long, the money, the button.
	local middle = CreateFrame("Frame", nil, frame)
	middle:SetPoint("TOPLEFT")
	middle:SetPoint("BOTTOMRIGHT", market, "BOTTOMLEFT", -ns.GAP, 0)
	detail.icon = Skin.Icon(middle, 40)
	detail.icon:SetPoint("TOPLEFT")
	detail.name = W.Skin.CreateText(middle, "GameFontNormalLarge")
	detail.name:SetPoint("TOPLEFT", detail.icon, "TOPRIGHT", 10, -2)
	detail.name:SetPoint("RIGHT", middle, "RIGHT", 0, 0)
	detail.name:SetJustifyH("LEFT")
	detail.sub = Skin.Text(middle, "GameTooltipTextSmall", "muted")
	detail.sub:SetPoint("TOPLEFT", detail.name, "BOTTOMLEFT", 0, -4)
	local priceCaps = Skin.Caps(middle, L.YOUR_PRICE)
	priceCaps:SetPoint("TOPLEFT", detail.icon, "BOTTOMLEFT", 0, -16)
	detail.modes = Skin.Choices(middle, { { "optimized", L.MODE_OPTIMIZED }, { "fast", L.MODE_FAST }, { "market", L.MODE_MARKET },
		{ "custom", L.MODE_CUSTOM } }, function(key)
		detail.mode = key
		if key ~= "custom" and ns.Settings() then ns.Settings().sellWay = key end
		UpdateSale()
	end, 34)
	detail.modes:SetPoint("TOPLEFT", priceCaps, "BOTTOMLEFT", 0, -6)
	-- The price each: shown, or (your own) typed in its place.
	detail.big = W.Skin.CreateText(middle, "GameFontNormalHuge", 0.9, 0.88, 0.82)
	detail.big:SetPoint("TOPLEFT", detail.modes, "BOTTOMLEFT", 0, -12)
	detail.each = Skin.Text(middle, "GameTooltipTextSmall", "muted")
	detail.each:SetPoint("BOTTOMLEFT", detail.big, "BOTTOMRIGHT", 8, 2)
	detail.each:SetText(L.EACH)
	detail.hint = Skin.Text(middle, "GameTooltipTextSmall", "soft")
	detail.hint:SetPoint("TOPLEFT", detail.modes, "BOTTOMLEFT", 0, -50)
	detail.hint:SetPoint("RIGHT", middle, "RIGHT", 0, 0)
	detail.hint:SetJustifyH("LEFT")
	-- Your own price (and, for an item, a starting bid): typed, it becomes the way chosen.
	local function Typed()
		if detail.mode ~= "custom" then
			detail.mode = "custom"
			detail.modes:Select("custom")
		end
		UpdateSale()
	end
	detail.custom = CreateFrame("Frame", nil, middle)
	detail.custom:SetSize(300, 28)
	detail.custom:SetPoint("TOPLEFT", detail.modes, "BOTTOMLEFT", 0, -10)
	detail.price = Skin.Money(detail.custom, Typed)
	detail.price:SetPoint("LEFT")
	detail.bidLine = CreateFrame("Frame", nil, middle)
	detail.bidLine:SetSize(300, 28)
	detail.bidLine:SetPoint("TOPLEFT", detail.hint, "BOTTOMLEFT", 0, -8)
	local bidLabel = Skin.Text(detail.bidLine, "GameTooltipTextSmall", "muted")
	bidLabel:SetPoint("LEFT")
	bidLabel:SetText(L.START_BID)
	detail.bid = Skin.Money(detail.bidLine, Typed)
	detail.bid:SetPoint("LEFT", bidLabel, "RIGHT", 10, 0)
	-- The button, the money above it, how many and how long above that.
	detail.post = Skin.Button(middle, L.POST, Post, "main")
	detail.post:SetPoint("BOTTOMLEFT")
	detail.post:SetPoint("BOTTOMRIGHT")
	detail.what = Skin.Text(middle, "GameTooltipTextSmall", "muted")
	detail.what:SetPoint("BOTTOM", detail.post, "TOP", 0, 6)
	local summary = Skin.Panel(middle)
	summary:SetPoint("BOTTOMLEFT", detail.what, "TOPLEFT", 0, 8)
	summary:SetPoint("LEFT", middle, "LEFT", 0, 0)
	summary:SetPoint("RIGHT", middle, "RIGHT", 0, 0)
	summary:SetHeight(116)
	detail.net = Skin.SummaryLine(summary, nil, L.YOU_RECEIVE, true)
	detail.cut = Skin.SummaryLine(summary, detail.net, L.CUT_LINE)
	detail.deposit = Skin.SummaryLine(summary, detail.cut, L.DEPOSIT_LINE)
	detail.merchant = Skin.SummaryLine(summary, detail.deposit, L.MERCHANT_LINE)
	detail.finance = Skin.Text(summary, "GameTooltipTextSmall", "soft")
	detail.finance:SetPoint("TOPLEFT", detail.merchant, "BOTTOMLEFT", 0, -6)
	detail.finance:SetPoint("RIGHT", summary, "RIGHT", -14, 0)
	detail.finance:SetJustifyH("LEFT")
	-- Over the money: how long (the game's durations), and above it how many (one less, one more, all).
	local function Step(delta)
		return function()
			local quantity, most = Quantity()
			detail.qty = math.max(1, math.min(most, quantity + delta))
			UpdateSale()
		end
	end
	detail.durations = Skin.Choices(middle, { { 1, ns.DurationName(1) }, { 2, ns.DurationName(2) }, { 3, ns.DurationName(3) } }, function(key)
		detail.duration = key
		UpdateSale()
	end, 30)
	detail.durations:SetPoint("BOTTOMLEFT", summary, "TOPLEFT", 0, 10)
	local durationCaps = Skin.Caps(middle, L.DURATION_TITLE)
	durationCaps:SetPoint("BOTTOMLEFT", detail.durations, "TOPLEFT", 0, 6)
	local less = Skin.Button(middle, "-", Step(-1), nil, 32)
	less:SetPoint("BOTTOMLEFT", durationCaps, "TOPLEFT", 0, 10)
	detail.qtyText = Skin.Text(middle, "GameFontNormal", "text")
	detail.qtyText:SetPoint("LEFT", less, "RIGHT", 6, 0)
	detail.qtyText:SetWidth(40)
	local more = Skin.Button(middle, "+", Step(1), nil, 32)
	more:SetPoint("LEFT", detail.qtyText, "RIGHT", 6, 0)
	detail.allButton = Skin.Button(middle, L.ALL_COUNT:format(1), function()
		detail.qty = nil
		UpdateSale()
	end)
	detail.allButton:SetPoint("LEFT", more, "RIGHT", 6, 0)
	local qtyCaps = Skin.Caps(middle, L.QUANTITY)
	qtyCaps:SetPoint("BOTTOMLEFT", less, "TOPLEFT", 0, 6)
	BuildBatch(page)
end

-- Shown: your bags read, the items for the auction house looked up by themselves (a look at all of them
-- under way, from another visit of the page: left to go on).
local function Shown()
	list.offset = 0
	Refresh()
	if bulk or scanning or scan.done < scan.total then return Search() end
	wipe(queue)
	ResetScan()
	ShowScan()
	for _, entry in ipairs(entries) do
		if entry.auction then queue[#queue + 1] = entry end
	end
	Search()
end

local function Closed()
	Select(nil)
	Batch(false)
	wipe(batch.seen)
	wipe(batch.aside)
	wipe(batch.done)
	wipe(batch.silent)
	batch.posted, batch.way, batch.duration = 0, nil, nil
	wipe(queue)
	ResetScan()
	ns.ClearLog()
	pending, posting, scanning, bulk = false, nil, nil, nil
end

ns.AddPage("sell", L.SELL, Build, Shown, Closed)

-- An item of your bags right-clicked at the auction house: this page, the item chosen (a commodity by
-- its kind, wherever its first stack is). What you keep is not in the list: nothing chosen then.
function ns.SellLocation(location)
	if not (location and location.GetBagAndSlot) then return end
	local bag, slot = location:GetBagAndSlot()
	if not (bag and slot) then return end
	ns.Open("sell")
	for _, entry in ipairs(entries) do
		if not entry.header then
			for _, place in ipairs(entry.slots or {}) do
				if place[1] == bag and place[2] == slot then return Select(entry) end
			end
		end
	end
end

-- Events -----------------------------------------------------------------------------------------------

local refreshSoon = U.Debounce(0.2, Refresh)
function Soon()
	if list and list:IsVisible() then refreshSoon() end
end

ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() if pending then Search() end end)
local function Bulk() if bulk and list and list:IsVisible() then ReadBulk() end end
ns.Listen("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", Bulk)
ns.Listen("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", Bulk)
-- A look thrown away by the auction house (asked too soon): asked again a moment later.
ns.Listen("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
	local this, chosen = scanning, selected
	C_Timer.After(1, function()
		if not ns.Ready() then return end
		if this and this.entry and scanning == this then Query(this.entry) end
		if chosen and chosen == selected and not chosen.searched then Query(chosen) end
	end)
end)
ns.Listen("COMMODITY_SEARCH_RESULTS_UPDATED", function(id)
	if selected and selected.commodity and id == selected.id then ShowPrices() end
	if scanning and scanning.commodity and scanning.id == id then Scanned() end
end)
ns.Listen("ITEM_SEARCH_RESULTS_UPDATED", function(key)
	if type(key) ~= "table" then return end
	if selected and not selected.commodity and SameItem(selected, key) then ShowPrices() end
	if scanning and not scanning.commodity and SameItem(scanning.entry, key) then Scanned() end
end)
ns.Listen("AUCTION_HOUSE_AUCTION_CREATED", function()
	if posting then
		-- (yours taken as the price only when none lower was seen: above the market, it is not the market's)
		local seen = ns.Price(posting.id)
		if posting.buyout > 0 and not (seen and seen < posting.buyout) then ns.Remember(posting.id, posting.buyout) end
		ns.Refuse(posting.id, false)
		local said = L.POSTED:format(posting.name, posting.quantity, U.Coins(posting.unit))
		if W.Print then W.Print(said) end
		ns.Log("good", said)
		if posting.batch then
			batch.done[posting.batch] = true
			batch.posted = batch.posted + 1
		end
		posting = nil
		UpdateBatch()
	end
	Soon()
	if ns.RefreshTabs then ns.RefreshTabs() end
end)
-- A sale refused (the auction house's answer, or the game's "internal error" said on the screen).
local function PostRefused()
	if not posting then return end
	-- (refused while selling everything: left aside, the next one offered)
	if posting then ns.Log("bad", L.LOG_POST_ERROR:format(posting.name or "")) end
	-- An item the server refuses: remembered (never offered again to sell everything); set aside for the
	-- auction house, made junk to be sold at the next merchant (the option).
	if posting.id then
		ns.Refuse(posting.id)
		local name = posting.name or ""
		local junk = ns.Settings() and ns.Settings().toMerchant and IsForAuction(posting.id) and Marks().ToJunk
			and Marks().ToJunk(posting.id)
		local said = (junk and L.REFUSED_JUNK or L.REFUSED_SAID):format(name)
		if W.Print then W.Print(said) end
		ns.Log("bad", said)
	end
	if posting and posting.batch then batch.done[posting.batch] = true end
	posting = nil
	UpdateBatch()
end
ns.Listen("AUCTION_HOUSE_POST_ERROR", PostRefused)
ns.Listen("UI_ERROR_MESSAGE", function(_, message)
	if posting and ERR_AUCTION_DATABASE_ERROR and message == ERR_AUCTION_DATABASE_ERROR then PostRefused() end
end)
ns.Listen("BAG_UPDATE_DELAYED", Soon)
