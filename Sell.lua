local _, ns = ...
local L = ns.L

-- Selling. On the left, what your bags can sell (what Wanderer Bags sets
-- aside for the auction house first), with the price of the market (a dot says
-- how fresh) and a chip for what matters (better at a merchant, identical ones
-- posted together, no price seen). In the middle, the item chosen: one price,
-- filled as your way says (a setting: optimized, just below the cheapest, at
-- the cheapest), typed as you like ("1.5" is 1g 50s), matched to the lowest or
-- stepped 5 % down or up; one line says why, or one chip when something
-- matters; how many, for how long (the game's durations), what you will
-- receive against what a merchant gives (the cut and the deposit on hover),
-- one button (Space or Enter too, the pointer over the window; the arrows
-- choose another item). On the right, the market: the
-- cheapest and what is for sale now, yours lit. Never below a merchant: the
-- price is raised to the floor, and said why. On arrival, the prices of what
-- is set aside for the auction house are looked up by themselves, one by one;
-- the button under the list looks up all of them: one by one, in full, for
-- the optimized price (the default); for the other ways in one look, then one
-- by one what it did not bring back; a line saying what happens.
--
-- Selling everything (the button under the list): every item that brings more
-- here than at a merchant, at the way chosen, for the duration chosen, in a
-- queue card (the next one big, how far, its button); a check before each row
-- says what is posted, left aside (a click on its row) or done. An item with no
-- price to trust (nobody selling it and none ever seen, or a market too young
-- for the optimized price) is left out, said on its row: a click on it sets
-- your own. The game asks a click (or a key) for each sale: the button posts
-- the next one each time, never more than one per gesture.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local COMMODITY = Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity or 2
local BOOK_ROWS = 7 -- what is for sale now, shown
local LIST_WIDTH, MARKET_WIDTH = 360, 220
local STRIP = 22 -- the status strip at the bottom of the page

local list, entries, selected = nil, {}, nil
local detail = {}
local pending -- a price search waiting for the auction house to be ready
local posting -- the last sale asked: what, how many, at what price (and its arguments, for a confirmation)
local queue = {} -- the items looked up one by one (on arrival, or what the look at all of them missed)
local scanning -- the one being looked up: { id, commodity, key, kind, entry }
-- Selling everything (on), this visit: what each kind's look found (seen: { lowest, mine }, or false: nobody
-- sells it; silent: no answer), what you left aside, what was posted (or refused), how many, your choices.
local batch = { on = false, seen = {}, aside = {}, done = {}, doneSlots = {}, silent = {}, posted = 0, way = nil, duration = nil }
local filling = false -- the money boxes being filled by the page (not typed)
-- A look at all of them (the button): how far, what came back (a price, nobody selling it, no answer), the
-- one looked up now, whether the auction house makes it wait, whether the one look is under way.
local scan = {}
local function ResetScan(total)
	scan.total, scan.done, scan.found, scan.nobody, scan.silent = total or 0, 0, 0, 0, 0
	scan.current, scan.waiting, scan.bulkOn, scan.waitSaid = nil, false, false, false
end
ResetScan()
local KindOf, Seen, BatchPrice, BatchChip, UpdateBatch, Batch, ShowScan, Draw, Soon, Select, PriceCell, ShowStrip, WaitBar -- (below)
local postedKinds = {} -- what was posted at this visit, one at a time (its row says so)

-- The next slot of an item still to post ({ bag, slot }), nil when all were; a commodity: its first.
local function SlotKey(slot) return slot[1] .. ":" .. slot[2] end
local function NextSlot(entry)
	for _, slot in ipairs(entry.slots or {}) do
		local done = batch.doneSlots[SlotKey(slot)]
		if not done or done ~= (entry.link or true) then return slot end
	end
	return nil
end

-- Selling everything is on (the follow page waits before asking the lots again).
function ns.SellingAll() return batch.on end

-- Posted (or refused) in this round of selling everything.
local function Done(entry)
	if batch.done[KindOf(entry)] then return true end
	return not entry.commodity and NextSlot(entry) == nil
end

-- What Wanderer Bags says of an item (kept: never offered; for the auction house: first).
-- (each call guarded: Wanderer Bags may ask Auctionator, another addon, behind them)
local Marks = ns.Marks
local function Mark(name, ...)
	local fn = Marks()[name]
	if type(fn) ~= "function" then return nil end
	local ok, value, more = pcall(fn, ...)
	if ok then return value, more end
	return nil
end
-- Not offered here: what Wanderer Bags says is not for the auction house (kept, an outfit's piece; an item in one of
-- your sections may be posted), the older rule with an older Bags. Kept when it cannot say: an item you keep is
-- never offered by mistake.
local function NotForAuction(id)
	local fn = Marks().NotForAuction or Marks().IsKept
	if type(fn) ~= "function" then return false end
	local ok, kept = pcall(fn, id)
	return not ok or kept and true or false
end
local function IsForAuction(id) return Mark("IsForAuction", id) and true or false end
-- Asked by one of your quests: never offered either.
local function ForQuest(id) return W.QuestNeed(id) ~= nil end
-- Without Wanderer Bags to say it: Wanderer Outfits' pieces (item id -> outfit names), never offered either; nil
-- when Bags says it, or without Outfits.
local function OutfitPieces()
	if type(Marks().NotForAuction) == "function" then return nil end
	local api = type(WandererOutfits) == "table" and WandererOutfits.Pieces
	if type(api) ~= "function" then return nil end
	local ok, pieces = pcall(api)
	return ok and type(pieces) == "table" and pieces or nil
end

-- Everything your bags can sell here: a commodity once (all its stacks), identical items once (the same
-- link: posted together), each in its slots.
local function Read()
	local found, commodities, items = {}, {}, {}
	local pieces = OutfitPieces()
	U.EachBagItem(function(bag, slot, info)
		local id = Clean(info.itemID)
		local location = ItemLocation and ItemLocation:CreateFromBagAndSlot(bag, slot)
		if location and not Clean(info.isBound) and not NotForAuction(id) and not (pieces and id and pieces[id]) and not ForQuest(id)
			and Clean(Safe(AH.IsSellItemValid, location, false)) then
			local commodity = Clean(Safe(AH.GetItemCommodityStatus, location)) == COMMODITY
			local count = Clean(info.stackCount) or 1
			local link = Clean(info.hyperlink)
			local entry
			if commodity then entry = commodities[id] elseif link then entry = items[link] end
			if entry then
				entry.count = entry.count + count
				entry.slots[#entry.slots + 1] = { bag, slot }
				entry.stacked = entry.stacked or count > 1
			else
				entry = { id = id, bag = bag, slot = slot, location = location, link = link, count = count, stacked = count > 1,
					name = U.LinkName(link) or "", quality = Clean(info.quality) or 1,
					icon = Clean(info.iconFileID), commodity = commodity, auction = IsForAuction(id), section = Mark("InSection", id) and true or false,
					slots = { { bag, slot } } }
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

ns.sellDetail = detail -- (tests)

-- The least worth asking for it, each (its net above what a merchant gives).
local function Floor(entry)
	return ns.Floor(ns.Vendor(entry.link))
end

-- The price an item was last known at (the market's days, else the last one seen), else Auctionator's (through
-- Wanderer Bags); nil when no price was ever seen: nothing is made up then.
local function Remembered(id) return ns.Market(id) or ns.Price(id) end
local function Known(entry)
	local price = Remembered(entry.id) or Mark("AuctionPrice", entry.link)
	return type(price) == "number" and price > 0 and price or nil
end

-- Whole silver: Forever's server refuses a copper price with its "internal error", although the game says it takes
-- copper (C_AuctionHouse.SupportsCopperValues answers true there): every price offered, typed or sent is a number of
-- silver pieces. (The offline tests alone may ask the game's answer, WANDERER_TEST_COPPER.)
local SILVER = rawget(_G, "COPPER_PER_SILVER") or 100
local function WholeSilver()
	if not rawget(_G, "WANDERER_TEST_COPPER") then return true end
	return Clean(Safe(AH.SupportsCopperValues)) ~= true
end
ns.WholeSilver = WholeSilver -- (tests)
-- A price the auction house takes: down to the silver (to stay under what it was), up when said, a silver at
-- least; as it is where copper is taken.
local function Whole(price, up)
	price = math.floor(tonumber(price) or 0)
	if price <= 0 or not WholeSilver() then return price end
	local whole = up and math.ceil(price / SILVER) * SILVER or math.floor(price / SILVER) * SILVER
	return math.max(SILVER, whole)
end
ns.Whole = Whole -- (tests)
-- The smallest step of a price: a copper, or a silver.
local function PriceStep() return WholeSilver() and SILVER or 1 end

-- Just below the lowest: one step less (a copper, or a silver).
local function Below(lowest)
	local step = PriceStep()
	return lowest > step and Whole(lowest - step) or lowest
end

-- An item's starting bid when only a buyout is asked: just below it, one step (some auction houses refuse an
-- item without one: "internal error"); none when there is no room under it. A commodity has none.
local function StartBid(buyout)
	local step = PriceStep()
	if not buyout or buyout <= step then return nil end
	return Whole(buyout - step)
end
ns.StartBid = StartBid -- (tests)

local function SavedDuration() return tonumber(ns.Settings() and ns.Settings().duration) or 2 end
-- The way to price by default: yours (the last chosen), else the optimized one.
local function DefaultWay() return ns.Settings() and ns.Settings().sellWay or "optimized" end
local function Duration() return detail.duration or SavedDuration() end

-- An item (not a commodity) that stacks: one per auction. The game's PostItem takes a quantity, but what it
-- does with part of a stack of such an item is not verified on this server (a whole stack at the price of one
-- would be lost money): until it is, each auction holds one, from the same stack, one gesture each. (A stack of
-- more than one in the bags says it too, when the game does not know the item's stack size yet.)
local function OnePerAuction(entry)
	return not entry.commodity and (entry.stacked or (U.ItemMaxStack(entry.id) or 1) > 1) and true or false
end

-- How many of it can be posted at once.
local function PostCount(entry, location)
	if OnePerAuction(entry) then return 1 end
	return math.max(1, math.min(Clean(Safe(AH.GetAvailablePostCount, location or entry.location)) or entry.count, entry.count))
end
ns.PostCount = PostCount -- (tests)

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

-- Far from its usual value (under half of it, over 3 times): the words of the red line, nil when it looks usual.
local function Odd(entry, buyout, bid)
	local unit = buyout > 0 and buyout or bid
	local kind, usual = ns.OddPrice(entry.id, unit)
	if kind == "low" then return L.ALERT_PRICE_LOW:format(math.floor((1 - unit / usual) * 100 + 0.5), U.Coins(usual)) end
	if kind == "high" then return L.ALERT_PRICE_HIGH:format(math.floor(unit / usual * 10 + 0.5) / 10, U.Coins(usual)) end
	return nil
end

-- The item still in its bag place (slot: { bag, slot }, else the entry's own): the bags may change meanwhile.
local function InPlace(entry, slot)
	slot = slot or (entry.bag and entry.slot and { entry.bag, entry.slot })
	if not slot then return true end
	local info = Safe(C_Container and C_Container.GetContainerItemInfo, slot[1], slot[2])
	if type(info) ~= "table" or Clean(info.itemID) ~= entry.id then return false end
	return not entry.link or Clean(info.hyperlink) == entry.link
end

-- A sale at such a price asked first (the kit's question): go() posts it, on your yes; at once otherwise. A yes
-- given a while later posts only when the item is still in its place and the auction house free: else
-- held(busy) and nothing sent (the click kept as an order when busy, as the button does).
local function Guarded(entry, buyout, bid, go, slot, held)
	local odd = Odd(entry, buyout, bid)
	if not odd then return go() end
	Skin.Ask(L.ASK_PRICE_ODD:format(odd), function()
		if not InPlace(entry, slot) then return held(false) end
		if not ns.Ready() then return held(true) end
		go()
	end)
end

-- How many can be posted, and how many are asked.
local function Most()
	return selected and PostCount(selected) or 1
end
local function Quantity()
	local most = Most()
	return math.max(1, math.min(most, detail.qty or most)), most
end

-- The least an item is offered at: one step above the floor (a whole silver where copper is not taken), so that
-- its starting bid, one step below, is never under a merchant's either.
local function ItemFloor(entry)
	local floor = Floor(entry)
	if floor <= 0 then return 0 end
	floor = Whole(floor, true)
	if not entry.commodity then floor = floor + PriceStep() end
	return floor
end

-- Your price for it (kept from its price box, Prices.lua), up to the silver where copper is not taken; 0: none.
local function YourFloor(entry)
	local yours = ns.YourPrice(entry.id)
	return yours and Whole(yours, true) or 0
end

-- The price each, as the way says: optimized (the bait left out, see Prices.lua), sell fast (just below the
-- cheapest, or yours matched), or the market's price; none for sale: the last one known. opt: what the
-- optimized price found (only when everything for sale was read; else the cheapest is checked against the
-- market's days). Never below the floor (then raised): the price, and whether raised. Nil when there is no
-- price to trust: none ever seen, or a market too young for the optimized price (yours asked then).
local function PriceFor(entry, lowest, mine, way, opt)
	local price
	local days = way == "optimized" and not opt and ns.Market(entry.id)
	if way == "optimized" and opt then
		if opt.young or not opt.price then return nil, false end
		price = opt.price
	elseif days and lowest and lowest < days * ns.TRUSTED_SHARE then
		price = days -- (only the cheapest known, far under the market's days: a bait; the market's value)
	elseif not lowest then
		price = Known(entry)
		if not price then return nil, false end
	elseif way == "market" or mine then
		price = lowest
	else
		price = Below(lowest)
	end
	-- (whole silver where copper is not taken: down, never under the floor, itself whole; nor under your price)
	local floor, yours = ItemFloor(entry), YourFloor(entry)
	if yours > floor and Whole(price) < yours then return yours, false end
	return math.max(Whole(price), floor), Whole(price) < floor
end

-- An item's starting bid: yours, else one step (a silver where copper is not taken) under the buyout (never under the floor). A commodity has
-- none.
local function EffectiveBid(entry, buyout, bid)
	if entry.commodity then return 0 end
	if bid and bid > 0 then return Whole(bid) end
	local auto = StartBid(buyout) or 0
	local floor = Whole(Floor(entry), true)
	if auto > 0 and auto < floor and floor < buyout then auto = floor end
	return auto
end

ns.PriceFor = PriceFor -- (tests)

-- The chosen item's price each, as the way chosen says (or yours).
local function Unit()
	if not selected then return 0, false end
	-- (yours as typed, to the silver where copper is not taken)
	if detail.mode == "custom" then return Whole(detail.price:Get()), false end
	local price, raised = PriceFor(selected, selected.lowest, selected.mine, detail.mode, selected.opt)
	return price or 0, raised
end

-- Why there is no price to trust for an item: "young" (too few offers for the optimized price), "unpriced"
-- (nobody selling it, none ever seen), or nil.
local function Unsure(entry, lowest, opt, way)
	if way == "optimized" and opt and opt.young then return "young" end
	if not lowest and not Known(entry) then return "unpriced" end
	return nil
end

-- The one line saying why this price (the way's words, the cheapest, the usual value).
local function Why(unit)
	local usual = ns.Market(selected.id)
	local parts = {}
	local opt, lowest = selected.opt, selected.lowest
	if detail.mode == "custom" then
		parts[1] = L.WHY_TYPED
		-- (copper typed where it is not taken: posted at the silver below, said)
		if Whole(detail.price:Get()) ~= detail.price:Get() then parts[1] = L.WHY_ROUNDED:format(U.Coins(Whole(detail.price:Get()))) end
		if lowest then parts[#parts + 1] = L.WHY_CHEAPEST:format(U.Coins(lowest)) end
	elseif not selected.searched then
		parts[1] = L.SEARCHING
	elseif not lowest then
		parts[1] = L.HINT_NONE
	elseif selected.mine and detail.mode ~= "market" then
		parts[1] = L.HINT_YOURS
	elseif detail.mode == "optimized" and opt then
		parts[1] = opt.credible and L.WHY_UNDER:format(U.Coins(opt.credible)) or L.WHY_VALUE:format(U.Coins(opt.reference))
		if opt.left > 0 then parts[#parts + 1] = L.CHIP_BAIT:format(opt.left) end
	elseif detail.mode == "market" then
		parts[1] = L.WHY_AT:format(U.Coins(lowest))
	else
		parts[1] = L.WHY_UNDER:format(U.Coins(lowest))
	end
	if usual and unit > 0 then parts[#parts + 1] = L.WHY_USUAL:format(U.Coins(usual)) end
	-- (your price kept: the least offered)
	if YourFloor(selected) > 0 then parts[#parts + 1] = L.WHY_YOUR_PRICE:format(U.Coins(YourFloor(selected))) end
	-- (several in the bags, one per auction: why "All (1)")
	if (selected.count or 1) > 1 and OnePerAuction(selected) then parts[#parts + 1] = L.ONE_EACH_WHY end
	return table.concat(parts, U.SEPARATOR)
end

-- The money, as things stand: the price, what you receive (the cut and the deposit on hover), a merchant's;
-- one line saying why the price, or one chip when something matters; the button.
local function UpdateSale()
	if not selected then return end
	local quantity, most = Quantity()
	local unit, raised = Unit()
	local typed = not selected.commodity and detail.mode == "custom" and Whole(detail.bid:Get()) or 0
	local bid = EffectiveBid(selected, unit, typed)
	detail.qtyText:SetText(tostring(quantity))
	detail.allButton:SetText(L.ALL_COUNT:format(most))
	detail.allButton:Fit()
	detail.durations:Select(Duration())
	-- The price shown is the one posted (yours as typed; else the way's, kept up to date).
	if detail.mode ~= "custom" and not detail.price.input:HasFocus() then detail.price:Set(unit) end
	detail.bidLine:SetShown(detail.mode == "custom" and not selected.commodity)
	detail.reset:SetShown(detail.changed and true or false)
	detail.match:SetEnabled(selected.lowest ~= nil)
	-- The money: what you receive after the cut, a merchant's; the cut and the deposit kept for the hover.
	local cheapest = Cheapest(unit, bid)
	local gross = cheapest * quantity
	local net = ns.Net(cheapest) * quantity
	local vendor = ns.Vendor(selected.link)
	local deposit = Deposit(selected, Duration(), quantity)
	local losing = Losing(selected, unit, bid)
	detail.net.value:SetText(cheapest > 0 and U.Coins(net) or "")
	detail.merchant.value:SetText(vendor > 0 and U.Coins(vendor * quantity) or L.NO_MERCHANT)
	detail.fees = { cut = cheapest > 0 and gross - net or nil, deposit = deposit }
	local gain = vendor > 0 and net - vendor * quantity
	local risky = deposit and gain and not losing and cheapest > 0 and deposit > gain
	-- What matters, in one chip (the most serious first); else the line saying why.
	local unsure = selected.searched and Unsure(selected, selected.lowest, selected.opt, detail.mode == "custom" and "optimized" or detail.mode)
	local alert, tone
	local odd = Odd(selected, unit, bid)
	if ns.Refused(selected.id) then
		alert, tone = L.CHIP_REFUSED, "red"
	elseif losing then
		alert, tone = L.ALERT_BELOW:format(U.Coins(ItemFloor(selected))), "red"
	elseif detail.refusal then
		alert, tone = detail.refusal, "red"
	elseif odd then
		alert, tone = odd, "red"
	elseif raised then
		alert, tone = L.ALERT_RAISED, "gold"
	elseif unsure == "young" and (detail.mode == "custom" or detail.mode == "optimized") and not detail.changed then
		alert, tone = L.ALERT_YOUNG, "gold"
	elseif unsure == "unpriced" and not detail.changed then
		alert, tone = L.ALERT_UNPRICED, "gold"
	elseif risky then
		alert, tone = L.ALERT_DEPOSIT, "gold"
	end
	detail.alert:Set(alert, tone)
	detail.hint:SetText(Why(unit))
	detail.hint:SetShown(alert == nil)
	detail.canPost = (unit > 0 or typed > 0) and (unit == 0 or typed <= unit) and not losing
	detail.post:SetEnabled(detail.canPost)
	-- (waiting for the auction house, then ready for your click; else as it is)
	detail.post:SetText(detail.order and L.POST_QUEUED or detail.readyAgain and L.POST_READY or L.POST)
	detail.post.keyLabel:SetShown(not detail.order)
	detail.post.wait:SetShown(detail.order and true or false)
	detail.loading:SetShown(selected.key ~= nil and not selected.searched)
	detail.what:SetText(L.POST_WHAT:format(quantity, selected.name or ""))
	-- Your price: this one kept, or the one kept forgotten when it is the price shown.
	detail.forget = YourFloor(selected) > 0 and YourFloor(selected) == unit
	detail.keep:SetLabel(detail.forget and L.FORGET_YOUR_PRICE or L.KEEP_YOUR_PRICE)
	detail.keep:SetEnabled(detail.forget or unit > 0)
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

-- A look at all of them under way (what the journal follows).
local function Looking() return scan.total > 0 and scan.done < scan.total end

-- One more answer of the look at all of them, counted: a price, nobody selling it, or no answer; the
-- last one: the tally written in the journal.
local function Count(what)
	if Looking() then
		scan.done = scan.done + 1
		scan[what] = scan[what] + 1
		if scan.done == scan.total then
			ns.Log("title", L.SCAN_FINISHED:format(L.SCAN_TALLY:format(scan.found, scan.nobody, scan.silent)))
		end
	end
end

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
		.. (opt and not opt.young and L.LOG_OPTIMIZED:format(U.Coins(opt.price)) or ""))
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

-- The other items wait while you look at the one chosen (its price just come, or a sale asked): the auction house
-- takes one message at a time, and a look sent then would make your sale wait behind it.
local PAUSE = 5 -- seconds after the chosen item's price came, or your last touch of it
local FRESH = 300 -- seconds an answer of this visit is used again rather than asked again
local touched = 0 -- when the chosen item was last priced or touched
local function Paused()
	if detail.order or batch.order then return true end
	return selected ~= nil and selected.searched and GetTime() - touched < PAUSE
end
ns.SellPaused = Paused -- (tests)

-- The next search: the item you chose, else the next item for the auction house.
local retrying, resuming = false, false
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
			-- (said at once: its line moving, its row's dots)
			if detail.loading then detail.loading:Show() end
			Draw()
			-- (the queue goes on after this one's answer, or a moment later without it)
			C_Timer.After(LOOK_WAIT, function() if not scanning then Search() end end)
			return
		end
		selected.unknown = true -- (the auction house has no key for it: the others looked up all the same)
	end
	-- One look at a time: the next when this one is answered (or, unanswered, a moment later); none while you
	-- look at the item chosen (asked again once the pause is over).
	if scanning then return end
	if queue[1] and Paused() then
		if not resuming then
			resuming = true
			C_Timer.After(1, function()
				resuming = false
				Search()
			end)
		end
		return
	end
	local entry = table.remove(queue, 1)
	-- (one seen in full a moment ago at this visit: not asked again; a look at all of them you asked asks all)
	while entry and not Looking() and batch.seen[KindOf(entry)] and batch.seen[KindOf(entry)].full and GetTime() - (batch.seen[KindOf(entry)].at or 0) < FRESH do
		entry = table.remove(queue, 1)
	end
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

-- The offers for sale now as the game gives them (the cheapest first, at most this many), and how many there
-- are: { price each, how many, buyout (an item's), yours (the game's word), owned (a commodity's own count) }.
local function Offers(entry, most)
	local offers, count = {}, 0
	if entry.commodity then
		count = Clean(Safe(AH.GetNumCommoditySearchResults, entry.id)) or 0
		for index = 1, math.min(count, most) do
			local result = Safe(AH.GetCommoditySearchResultInfo, entry.id, index)
			if type(result) == "table" then
				offers[#offers + 1] = { price = Clean(result.unitPrice), quantity = Clean(result.quantity) or 1,
					own = Clean(result.containsOwnerItem), owned = (Clean(result.numOwnerItems) or 0) > 0 }
			end
		end
	elseif entry.key then
		count = Clean(Safe(AH.GetNumItemSearchResults, entry.key)) or 0
		for index = 1, math.min(count, most) do
			local result = Safe(AH.GetItemSearchResultInfo, entry.key, index)
			if type(result) == "table" then
				local buyout, quantity = Clean(result.buyoutAmount), Clean(result.quantity) or 1
				offers[#offers + 1] = { price = buyout and math.floor(buyout / math.max(1, quantity)), quantity = quantity,
					buyout = buyout, own = Clean(result.containsOwnerItem), owned = false }
			end
		end
	end
	return offers, count
end

-- The lowest asked (by others, or yours), each; how many for sale; whether the lowest is yours.
function Lowest(entry)
	if not entry then return nil end
	if entry.commodity then
		local offers, count = Offers(entry, 1)
		local first = offers[1]
		if not first then return nil, count end
		return first.price, Clean(Safe(AH.GetCommoditySearchResultsQuantity, entry.id)) or count, first.own
	end
	local offers, count = Offers(entry, math.huge)
	for _, offer in ipairs(offers) do
		if offer.buyout and offer.buyout > 0 then return offer.price, count, offer.own end
	end
	return nil, count
end

-- What is for sale now (the cheapest first): { price each, how many, yours }.
local function Book(entry)
	local book = {}
	for _, offer in ipairs((Offers(entry, BOOK_ROWS))) do
		-- (an item without a buyout left out)
		if entry.commodity or offer.buyout then
			book[#book + 1] = { offer.price or 0, offer.quantity, offer.owned or offer.own and true or false }
		end
	end
	return book
end

-- Everything others sell now, cheapest first: { price each, how many } (yours left out).
local LISTINGS = 300 -- read at most
local function Listings(entry)
	local listings = {}
	for _, offer in ipairs((Offers(entry, LISTINGS))) do
		local asked = entry.commodity and offer.price or offer.buyout
		if asked and asked > 0 and not offer.owned and not offer.own then
			listings[#listings + 1] = { offer.price, offer.quantity }
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
	if not price then return nil end
	-- (young: too few offers now and no day of its own before today, nothing credible to follow)
	return { price = price, left = left, reference = reference, credible = credible, offers = #listings,
		young = ns.Young(listings, ns.Market(entry.id, true)) }
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
-- An item's price as it stands this visit: being looked up (dots coming and going), the price with its dot of
-- freshness, no answer ("try again": a click on it asks again), or never seen.
local DOTS = { ".", "..", "..." }
local dotsStep = 1
-- A price to look up again: none remembered, or older than a day.
local DAY = 86400
local function Stale(entry)
	local price, age = ns.Price(entry.id)
	return not price or age > DAY
end
local function Searching(entry)
	if scanning and scanning.entry == entry then return true end
	return entry == selected and selected.key ~= nil and not selected.searched
end
function PriceCell(entry)
	if Searching(entry) then return Skin.Colorize(L.ROW_SEARCHING .. DOTS[dotsStep], "muted") end
	local price = ns.Price(entry.id)
	if price then return ns.Fresh(entry.id) .. U.Coins(price) end
	if batch.silent[KindOf(entry)] then return Skin.Colorize(L.ROW_RETRY, "muted") end
	return Skin.Colorize(L.NEVER_SEEN, "muted")
end
ns.PriceCell = function(entry) return PriceCell(entry) end -- (tests)

local function Chip(entry)
	if ns.Refused(entry.id) then return L.CHIP_REFUSED, "red" end
	-- (posted at this visit: said on its row while it is still in your bags)
	if postedKinds[KindOf(entry)] then return L.CHIP_POSTED, "green" end
	local price = ns.Price(entry.id)
	if not price and batch.silent[KindOf(entry)] then return L.CHIP_SILENT, "grey" end
	if not price then return L.CHIP_NO_PRICE, "grey" end
	local seen = batch.seen[KindOf(entry)]
	if Losing(entry, seen and seen.opt and Credible(seen.lowest, seen.opt) or ns.Market(entry.id) or price, 0) then
		return L.CHIP_MERCHANT, "red"
	end
	if not entry.commodity and entry.count > 1 then
		-- (one per auction for some: each copy its own sale, said so)
		if OnePerAuction(entry) then return L.CHIP_ONE_EACH:format(entry.count), "grey" end
		return L.CHIP_TOGETHER:format(entry.count), "blue"
	end
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

-- Selling everything: a mark before each row's square (a gold check: to post; a green one: posted; a cross: left
-- aside; a dot: waiting for a price), the square stepped right for it; one at a time: none.
local MARK_ROOM = 22
local function QueueMark(row, entry)
	if not row.queueMark then
		row.queueMark = Skin.Glyph(row, "check", 12)
		row.queueMark:SetPoint("LEFT", row, "LEFT", 6, 0)
	end
	local shown = batch.on and entry ~= nil and not entry.header
	row.queueMark:SetShown(shown)
	if row.icon then
		row.icon:ClearAllPoints()
		row.icon:SetPoint("LEFT", row, "LEFT", 6 + (batch.on and MARK_ROOM or 0), 0)
	end
	if not shown then return end
	local glyph, role
	if Done(entry) then
		glyph, role = "check", "good"
	elseif batch.aside[KindOf(entry)] then
		glyph, role = "close", "muted"
	elseif BatchPrice(entry) then
		glyph, role = "check", "gold"
	else
		glyph, role = "dot", "muted"
	end
	Skin.SetGlyph(row.queueMark, glyph)
	local c = Skin.COLORS[role]
	row.queueMark:SetVertexColor(c[1], c[2], c[3])
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
			local shown = unit and not batch.aside[kind] and not Done(entry)
			values = { qty = tostring(entry.count), market = shown and U.Coins(unit) or "" }
			chip, tone = BatchChip(entry)
		elseif entry and not entry.header then
			values = { qty = tostring(entry.count), market = PriceCell(entry) }
			chip, tone = Chip(entry)
		end
		row:Fill(entry, entry ~= nil and not batch.on and entry == selected, values, chip, tone)
		QueueMark(row, entry)
	end
	list.empty:SetShown(#listed == 0)
	ShowStrip()
end

-- The strip at the bottom of the page: what was done last (posted, in green; refused, in red), and how things
-- stand: the prices known this visit, the auction house ready or busy (and how many asks wait).
function ShowStrip()
	if not detail.stripRight then return end
	local done, total = 0, 0
	for _, entry in ipairs(entries) do
		if not entry.header then
			total = total + 1
			-- (a price of this visit, no answer, or one remembered from the day: not looked up again)
			if batch.seen[KindOf(entry)] ~= nil or batch.silent[KindOf(entry)] or not Stale(entry) then done = done + 1 end
		end
	end
	local waiting = #queue + (scanning and 1 or 0) + ((detail.order or batch.order) and 1 or 0)
	local house = ns.Ready() and Skin.Colorize(L.STRIP_READY, "good") or Skin.Colorize(L.STRIP_BUSY:format(waiting), "warn")
	detail.stripRight:SetText(L.STRIP_PRICES:format(done, total) .. U.SEPARATOR .. house)
	local last = detail.last
	detail.stripLeft:SetText(last and Skin.Colorize(last[1], last[2]) or "")
end
ns.SellStrip = function() return detail.stripLeft:GetText(), detail.stripRight:GetText() end -- (tests)

-- The auction house ready again: an order waiting turns into "ready, click again" (a sound, the button
-- glowing); the looks go on.
local function HouseReady()
	if detail.order and selected then
		detail.order, detail.readyAgain = false, true
		Skin.Play("mark")
		UpdateSale()
	end
	if batch.order then
		batch.order, batch.readyAgain = nil, true
		Skin.Play("mark")
		UpdateBatch()
	end
	ShowStrip()
end
ns.SellHouseReady = HouseReady -- (tests)

-- The arrows: the item above or below chosen (selling everything: none), the list scrolled to it.
local function Move(delta)
	local listed, at = {}, nil
	for _, entry in ipairs(Listed()) do
		if not entry.header then
			listed[#listed + 1] = entry
			if entry == selected then at = #listed end
		end
	end
	if not listed[1] then return end
	local target = listed[at and math.max(1, math.min(#listed, at + delta)) or (delta > 0 and 1 or #listed)]
	if target == selected then return end
	-- (its place in the list as drawn, titles counted, kept in sight)
	for index, entry in ipairs(Listed()) do
		if entry == target then
			if index - 1 < list.offset then list.offset = index - 1 end
			if index > list.offset + list.count then list.offset = index - list.count end
		end
	end
	Select(target)
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

-- An item made junk in Wanderer Bags, remembered as made by Auction (not by you): uncommon or better, it is
-- then never sold at a merchant without your click. True when done.
-- (a Wanderer that cannot wait for your click, without W.JUNK_ASK, would sell it by itself: then only grey ones)
local POOR = Enum and Enum.ItemQuality and Enum.ItemQuality.Poor or 0
local function MakeJunk(id, quality)
	if (tonumber(quality or U.ItemQuality(id)) or POOR) > POOR and not W.JUNK_ASK then return false end
	if not Mark("ToJunk", id) then return false end
	ns.MadeJunk(id, true)
	return true
end
-- What is said of it: sold at the next merchant (grey), or there by the junk button, a click (better).
local function JunkWords(quality) return (tonumber(quality) or POOR) > POOR and L.MOVED_TO_JUNK_ASK or L.MOVED_TO_JUNK end

-- Set aside for the auction house (Wanderer Bags), but bringing more at a merchant: made junk (the option);
-- said in the chat. Judged only on a market's value sure enough (3 offers or more now, else 2 days or more:
-- ns.SureValue), never on one look at a lone offer. (From a look at the prices, or the item you chose.)
local function ToMerchant(kind, value, mine)
	if not (value and not mine and ns.Settings() and ns.Settings().toMerchant) then return end
	for _, entry in ipairs(entries) do
		if not entry.header and entry.auction and KindOf(entry) == kind and Losing(entry, value, 0) and MakeJunk(entry.id, entry.quality) then
			entry.auction = false
			W.Print(JunkWords(entry.quality):format(entry.link or entry.name or ""))
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
	Seen(this.kind, lowest, mine, opt, true)
	if Looking() then Logged(this.entry, lowest, mine, opt) end
	-- (nobody selling it now: judged by its days alone)
	ToMerchant(this.kind, ns.SureValue(this.id, opt), mine)
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
	if type(entry.key) ~= "table" then return false end
	local own = entry.key
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
		-- (the optimized price reads everything for sale: the ones found looked at alone too)
		if not this.found[KindOf(entry)] or (batch.way or DefaultWay()) == "optimized" then queue[#queue + 1] = entry end
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
				-- (only the cheapest known here: junk judged by the market's days alone)
				ToMerchant(kind, ns.SureValue(entry.id, nil), mine)
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
	ns.browsing = "sell"
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

-- What only the look at all of them at once saw (its cheapest), looked at again alone, in full.
function ns.LookAgainAlone()
	local queued = {}
	for _, entry in ipairs(queue) do queued[entry] = true end
	for _, entry in ipairs(entries) do
		local seen = not entry.header and batch.seen[KindOf(entry)]
		if seen and not seen.full and not queued[entry] then
			queued[entry] = true
			queue[#queue + 1] = entry
		end
	end
	Search()
end

function ns.ScanAll()
	wipe(queue)
	scanning = nil -- (a look started before: its answer no longer counted)
	bulk = nil -- (and one look at all of them: let go, its wait no longer ends this one)
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
	Seen(KindOf(selected), lowest, mine, selected.opt, true)
	ToMerchant(KindOf(selected), ns.SureValue(selected.id, selected.opt), mine)
	-- Your own price: offered once (what you type after is never overwritten), as your way prices it.
	if not selected.offered then
		selected.offered = true
		local mode = detail.mode
		if mode == "custom" then detail.mode = DefaultWay() end
		filling = true
		local offered = Unit()
		-- (a market too young for the optimized price: the fast one offered as a start, to check)
		if offered == 0 and detail.mode == "optimized" and selected.opt and selected.opt.young then
			detail.mode = "fast"
			offered = Unit()
		end
		detail.price:Set(offered)
		selected.start = offered
		filling = false
		detail.mode = mode
		-- No price to trust for the way chosen: your own asked (the price box, as offered).
		if detail.mode ~= "custom" and Unit() == 0 then detail.mode = "custom" end
		touched = GetTime()
		Search()
	end
	ShowMarket()
	UpdateSale()
	Draw()
	if ns.debugging then
		ns.Debug("sell prices", { id = selected.id, key = selected.key, lowest = lowest, onSale = onSale, mine = mine, mode = detail.mode,
			price = detail.price:Get(), canPost = detail.canPost, why = detail.hint:GetText(), alert = detail.alert:IsShown() and detail.alert.text:GetText() or nil,
			book = #(selected.book or {}) }, selected.opt, detail.fees)
	end
end

function Select(entry)
	if entry and batch.on then Batch(false) end
	selected = entry
	if not detail.frame then return end
	detail.frame:SetShown(entry ~= nil)
	detail.pick:SetShown(entry == nil)
	if entry and ns.debugging then
		local _, _, _, equip, _, class, subclass = U.ItemInstant(entry.id)
		ns.Debug("sell select", { link = entry.link, id = entry.id, bag = entry.bag, slot = entry.slot, count = entry.count,
			commodity = entry.commodity, quality = entry.quality, stacked = entry.stacked, equip = equip, class = class, subclass = subclass,
			slots = #(entry.slots or {}) }, entry.location)
	end
	if entry then
		detail.icon:Set(entry.icon, entry.quality)
		detail.name:SetText(entry.name or "")
		Skin.Quality(detail.name, entry.quality)
		detail.sub:SetText(L.IN_BAGS:format(entry.count))
		entry.key, entry.offered, entry.lowest, entry.searched, entry.book, entry.opt, entry.counted = nil, nil, nil, false, nil, nil, nil
		detail.mode, detail.qty, detail.duration = DefaultWay(), nil, nil
		detail.changed, detail.refusal, detail.order, detail.readyAgain = false, nil, false, false
		if detail.price.input:HasFocus() then detail.price.input:ClearFocus() end
		filling = true
		detail.bid:Set(0)
		detail.price:Set((Unit()))
		filling = false
		ShowMarket()
		UpdateSale()
		-- Seen in full a moment ago at this visit, the game still holding its answer: shown at once, nothing asked.
		local seen = batch.seen[KindOf(entry)]
		local key = seen and seen.full and GetTime() - (seen.at or 0) < FRESH and Safe(AH.GetItemKeyFromItem, entry.location)
		if key then entry.key = key end
		if key and Answered({ commodity = entry.commodity, id = entry.id, key = key }) then
			ShowPrices()
		else
			entry.key = nil
			Search()
		end
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
			for _, key in ipairs({ "key", "offered", "start", "lowest", "onSale", "mine", "searched", "book", "opt", "counted" }) do
				still[key] = selected[key]
			end
			selected = still
			detail.sub:SetText(L.IN_BAGS:format(still.count))
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
local function Send(entry, quantity, buyout, bid, duration, batchKind, location, slot)
	bid = EffectiveBid(entry, buyout, bid)
	location = location or entry.location
	ns.Debug("sell send", { id = entry.id, link = entry.link, commodity = entry.commodity, quantity = quantity, buyout = buyout, bid = bid,
		duration = duration, batch = batchKind and true or false, losing = Losing(entry, buyout, bid), floor = ItemFloor(entry) }, location, slot)
	-- (never below what a merchant gives, once the cut taken: whoever asks)
	if Losing(entry, buyout, bid) then return false, L.BELOW_MERCHANT:format(U.Coins(ItemFloor(entry))) end
	local ok, needsConfirmation
	if entry.commodity then
		ok, needsConfirmation = pcall(AH.PostCommodity, location, duration, quantity, buyout)
	else
		ok, needsConfirmation = pcall(AH.PostItem, location, duration, quantity, bid > 0 and bid or nil, buyout > 0 and buyout or nil)
	end
	if not ok then return false, needsConfirmation end
	posting = { kind = KindOf(entry), name = entry.link or entry.name, quantity = quantity, unit = buyout > 0 and buyout or bid, bid = bid,
		buyout = buyout, id = entry.id, commodity = entry.commodity, location = location, duration = duration,
		batch = batchKind, slotKey = slot and SlotKey(slot) or nil, single = OnePerAuction(entry), quality = entry.quality,
		at = GetTime() }
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
	local bid = not selected.commodity and detail.mode == "custom" and Whole(detail.bid:Get()) or 0
	if buyout <= 0 and bid <= 0 or Losing(selected, buyout, EffectiveBid(selected, buyout, bid)) then return end
	-- An order waiting: a click lets it go.
	if detail.order then
		detail.order = false
		return UpdateSale()
	end
	-- The auction house busy (a look just sent): a sale now would be dropped. Your click kept as an order: the
	-- button waits, then says it is ready (the game wants a click of yours for each sale: one more, then).
	if not ns.Ready() then
		detail.order, detail.readyAgain = true, false
		ShowStrip()
		return UpdateSale()
	end
	detail.readyAgain = false
	-- (far from its usual value: asked first; what is posted is what was asked, whatever is chosen since)
	local entry, quantity, duration = selected, Quantity(), Duration()
	Guarded(entry, buyout, bid, function()
		local ok, why = Send(entry, quantity, buyout, bid, duration)
		if not ok then
			local said = L.POST_REFUSED:format(tostring(why))
			-- (said on the chip until another item is chosen)
			detail.refusal = said
			UpdateSale()
			ns.Log("bad", said)
		end
	end, nil, function(busy)
		if busy then
			detail.order, detail.readyAgain = true, false
			ShowStrip()
		end
		UpdateSale()
	end)
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

-- full: an item's own look, everything for sale read (what the optimized price needs); the look at all of them
-- at once brings only the cheapest.
function Seen(kind, lowest, mine, opt, full)
	if kind == nil then return end
	batch.seen[kind] = lowest and { lowest = lowest, mine = mine and true or false, opt = opt, full = full and true or false, at = GetTime() } or false
	batch.silent[kind] = nil
end

local function Way() return batch.way or DefaultWay() end
local WAY_NAMES = { optimized = L.MODE_OPTIMIZED, fast = L.MODE_FAST, market = L.MODE_MARKET }
local function BatchDuration() return batch.duration or SavedDuration() end

-- The price each when selling everything, or nil and why ("refused": by the server before, "search": not
-- looked up yet, "merchant": better there, "unpriced": nobody selling it and no price ever seen, "young": too
-- few offers for the optimized price; the last two wait for your own price). Nobody selling it: the last
-- price known, said so ("nobody").
function BatchPrice(entry)
	if ns.Refused(entry.id) then return nil, "refused" end
	local seen = batch.seen[KindOf(entry)]
	if seen == nil then return nil, "search" end
	-- (the optimized price, after the look at all of them at once: only the cheapest known, looked at again alone)
	if seen and Way() == "optimized" and not seen.full then return nil, "search" end
	local opt = seen and Way() == "optimized" and seen.opt or nil
	if seen and Losing(entry, Credible(seen.lowest, seen.opt), 0) then return nil, "merchant" end
	-- (nobody selling it: better at a merchant by the price it was last known at, as its row says)
	local known = seen == false and Known(entry)
	if known and Losing(entry, known, 0) then return nil, "merchant" end
	local unsure = Unsure(entry, seen and seen.lowest, opt, Way())
	if unsure then return nil, unsure end
	local price = PriceFor(entry, seen and seen.lowest, seen and seen.mine, Way(), opt)
	if not price then return nil, "unpriced" end
	return price, seen == false and "nobody" or nil
end

-- What will be posted, in the list's order: { entry, unit, quantity }.
local function BatchItems()
	local items = {}
	for _, entry in ipairs(entries) do
		local kind = not entry.header and KindOf(entry)
		if kind and not batch.aside[kind] and not Done(entry) then
			local unit = BatchPrice(entry)
			local slot = not entry.commodity and NextSlot(entry) or nil
			local location = slot and ItemLocation and ItemLocation:CreateFromBagAndSlot(slot[1], slot[2]) or entry.location
			-- (count: how many it holds in all, for the money said; one per auction for some, see OnePerAuction)
			if unit and unit > 0 then
				local quantity = PostCount(entry, location)
				items[#items + 1] = { entry = entry, unit = unit, quantity = quantity, slot = slot, location = location,
					count = OnePerAuction(entry) and entry.count or quantity }
			end
		end
	end
	return items
end
ns.BatchItems = BatchItems -- (tests)

-- The row's chip while selling everything.
function BatchChip(entry)
	local kind = KindOf(entry)
	if Done(entry) then return L.CHIP_POSTED, "green" end
	if batch.aside[kind] then return L.CHIP_ASIDE, "grey" end
	local unit, why = BatchPrice(entry)
	if why == "search" then return batch.silent[kind] and L.CHIP_SILENT or L.CHIP_SEARCHING, "grey" end
	if why == "nobody" then return L.CHIP_NOBODY, "blue" end
	if why == "refused" then return L.CHIP_REFUSED, "red" end
	if why == "unpriced" then return L.CHIP_UNPRICED, "blue" end
	if why == "young" then return L.CHIP_YOUNG, "blue" end
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
		net = net + ns.Net(item.unit) * item.count
		merchant = merchant + ns.Vendor(entry.link) * item.count
		deposit = deposit + (Deposit(entry, BatchDuration(), item.quantity) or 0) * math.max(1, item.count / item.quantity)
	end
	local b = detail.batch
	b.totals = { deposit = deposit, merchant = merchant }
	b.summary:SetText(L.QUEUE_SUMMARY:format(#items, U.Coins(net)))
	b.way:SetLabel(L.QUEUE_WAY:format(WAY_NAMES[Way()] or ""))
	b.duration:SetLabel(L.QUEUE_DURATION:format(ns.DurationName(BatchDuration())))
	b.status:SetText(batch.told and Skin.Colorize(batch.told, "warn") or "")
	local first = items[1]
	-- (as many auctions as gestures: one per auction for some, see OnePerAuction)
	local auctions = 0
	for _, item in ipairs(items) do auctions = auctions + (OnePerAuction(item.entry) and item.count or 1) end
	local total = batch.posted + auctions
	b.bar:Set(total > 0 and batch.posted / total or 0)
	b.progress:SetText(total > 0 and L.QUEUE_DONE:format(batch.posted, total) or "")
	b.next:SetShown(first ~= nil)
	b.skip:SetEnabled(first ~= nil)
	if first then
		local entry = first.entry
		b.icon:Set(entry.icon, entry.quality)
		b.name:SetText(OnePerAuction(entry) and entry.name or L.POST_WHAT:format(first.quantity, entry.name or ""))
		Skin.Quality(b.name, entry.quality)
		b.each:SetText(L.QUEUE_EACH:format(U.Coins(first.unit)))
		b.post:SetText(batch.order and L.POST_QUEUED or batch.readyAgain and L.POST_READY or L.QUEUE_POST:format(batch.posted + 1, total))
	else
		b.post:SetText(batch.posted > 0 and L.SELL_ALL_FINISHED:format(batch.posted) or L.SELL_ALL_NONE)
	end
	b.post.keyLabel:SetShown(first ~= nil and not batch.order)
	if b.post.wait then b.post.wait:SetShown(batch.order and true or false) end
	b.post:SetEnabled(first ~= nil and not Waiting())
	Draw()
end

-- (said above the button: why nothing was posted, until the next sale)
local function Tell(text)
	batch.told = text
	if detail.batch then detail.batch.status:SetText(Skin.Colorize(text, "warn")) end
end

-- The next one posted (a click on the button or the key: the game asks one for each sale). Never while a
-- sale waits for its answer or its confirmation. (No mouse wheel: rolled, it posts many at once without a
-- look at each, and every sale must be a gesture of its own.)
-- The item about to be posted still in its bag place (the bags are read again a moment after each sale).
local function StillInPlace(item)
	if not item.slot then return true end
	return InPlace(item.entry, item.slot)
end
ns.StillInPlace = StillInPlace -- (tests)

local function PostNext()
	if not batch.on or Waiting() or Skin.Asking() then return end
	-- The auction house busy (a look just made): your click kept as an order, the button says when to click again.
	if not ns.Ready() then
		batch.order = not batch.order or nil
		batch.readyAgain = nil
		return UpdateBatch()
	end
	batch.order, batch.readyAgain = nil, nil
	local item = BatchItems()[1]
	ns.Debug("queue next", item and { id = item.entry.id, link = item.entry.link, unit = item.unit, quantity = item.quantity,
		count = item.count } or "nothing", item and item.slot)
	if not item then return end
	local entry = item.entry
	-- (its place emptied by the last sale, the bags not read again yet: read now, the next press posts)
	if not StillInPlace(item) then
		Soon()
		return
	end
	-- (far from its usual value: asked first, your yes posts it)
	Guarded(entry, item.unit, 0, function()
		local ok, why = Send(entry, item.quantity, item.unit, 0, BatchDuration(), KindOf(entry), item.location, item.slot)
		-- Refused by the game at once: said why, this one left aside, the next one offered.
		if not ok then
			batch.done[KindOf(entry)] = true
			UpdateBatch()
			local said = L.SELL_ALL_REFUSED:format(entry.name or "", tostring(why))
			ns.Log("bad", said)
			return Tell(said)
		end
		batch.told = nil
		UpdateBatch()
		-- (unanswered: the button given back once the wait is over)
		C_Timer.After(10.1, function() if batch.on then UpdateBatch() end end)
	end, item.slot, function(busy)
		if not batch.on then return end
		if not busy then return Soon() end
		batch.order, batch.readyAgain = true, nil
		UpdateBatch()
	end)
end
-- The key binding (Key Bindings, Wanderer Auction): the next one while selling everything, else the item chosen
-- (the game's own key press, where a window's key could not post).
function WandererAuction_PostNext()
	if batch.on then return PostNext() end
	if selected and detail.canPost and ns.IsShown() and not Skin.Asking() then Post() end
end

-- The next one left aside for this round (its row's click takes it back).
local function Skip()
	local item = batch.on and BatchItems()[1]
	if not item then return end
	batch.aside[KindOf(item.entry)] = true
	UpdateBatch()
end

-- The way and the duration of this round, each a click away (the next one, round and round).
local WAYS = { "optimized", "fast", "market" }
local function NextWay()
	local now = Way()
	for index, way in ipairs(WAYS) do
		if way == now then
			batch.way = WAYS[index % #WAYS + 1]
			break
		end
	end
	batch.way = batch.way or "optimized"
	W.ChangeEverywhere(function() if ns.Settings() then ns.Settings().sellWay = batch.way end end)
	-- (the optimized price reads everything for sale: what only the look at all of them saw, looked at alone)
	if batch.way == "optimized" then ns.LookAgainAlone() end
	UpdateBatch()
end
local function NextDuration()
	batch.duration = BatchDuration() % 3 + 1
	-- (kept as the duration offered, as the way is)
	W.ChangeEverywhere(function() if ns.Settings() then ns.Settings().duration = tostring(batch.duration) end end)
	UpdateBatch()
end

function Batch(on)
	batch.on = on and true or false
	ns.Debug("queue " .. (batch.on and "on" or "off"), { way = Way(), duration = BatchDuration(), posted = batch.posted })
	batch.told = nil
	if batch.on and selected then Select(nil) end
	if detail.batch then detail.batch:SetShown(batch.on) end
	if detail.pick then detail.pick:SetShown(not batch.on and selected == nil) end
	if batch.on then
		-- Your sections' items start aside (sorted to keep, more often than for sale): one click on its row takes one back.
		for _, entry in ipairs(entries) do
			if not entry.header and entry.section and not entry.auction then batch.aside[KindOf(entry)] = true end
		end
		-- The prices of this visit: looked up when one is still unknown (and no look is under way).
		local unknown = false
		for _, entry in ipairs(entries) do
			if not entry.header and batch.seen[KindOf(entry)] == nil then unknown = true end
		end
		if unknown and not Looking() then
			ns.ScanAll()
		elseif Way() == "optimized" then
			ns.LookAgainAlone()
		end
		UpdateBatch()
	else
		Draw()
	end
end
ns.SellAll = Batch -- (tests)

-- A thin line with a gold piece moving along it (something under way, its end not known): hidden at first.
function WaitBar(parent)
	local bar = Skin.ProgressLine(parent)
	bar:Wander(true)
	bar:Hide()
	return bar
end

local function BuildBatch(page)
	local b = CreateFrame("Frame", nil, page)
	b:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, 0)
	b:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, STRIP)
	b:Hide()
	detail.batch = b
	-- The queue, in one card: what is left and what it brings, the next one big, how far, its button, then the
	-- quiet choices of the round.
	local card = Skin.Panel(b)
	card:SetPoint("TOPLEFT")
	card:SetWidth(440)
	card:SetHeight(324)
	local pad = 16
	local caps = Skin.Caps(card, L.SELL_ALL, "kicker")
	caps:SetPoint("TOPLEFT", card, "TOPLEFT", pad, -pad)
	-- (the deposit and what merchants would give, under the mouse)
	local summary = CreateFrame("Frame", nil, card)
	summary:SetPoint("TOPLEFT", caps, "BOTTOMLEFT", 0, -6)
	summary:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
	summary:SetHeight(18)
	summary:EnableMouse(true)
	b.summary = Skin.Text(summary, "GameTooltipText", "soft")
	b.summary:SetPoint("LEFT")
	Skin.Tooltip(summary, function()
		local totals = b.totals or {}
		return { L.SELL_ALL, { L.DEPOSIT_LINE .. ": " .. U.Coins(totals.deposit or 0), 0.9, 0.88, 0.82 },
			{ L.MERCHANT_LINE .. ": " .. U.Coins(totals.merchant or 0), 0.9, 0.88, 0.82 } }
	end)
	-- The next one.
	b.next = CreateFrame("Frame", nil, card)
	b.next:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -18)
	b.next:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
	b.next:SetHeight(58)
	local nextCaps = Skin.Caps(b.next, L.QUEUE_NEXT)
	nextCaps:SetPoint("TOPLEFT")
	b.icon = Skin.Icon(b.next, 40)
	b.icon:SetPoint("TOPLEFT", nextCaps, "BOTTOMLEFT", 0, -6)
	b.name = W.Skin.CreateText(b.next, "GameFontNormal")
	b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 10, -3)
	b.name:SetPoint("RIGHT", b.next, "RIGHT", 0, 0)
	if b.name.SetWordWrap then b.name:SetWordWrap(false) end
	b.each = Skin.Text(b.next, "GameTooltipText", "soft")
	b.each:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -5)
	-- How far: a thin bar, posted in gold.
	b.bar = Skin.ProgressLine(card, 3)
	b.bar:SetPoint("TOPLEFT", b.next, "BOTTOMLEFT", 0, -14)
	b.bar:SetWidth(440 - pad * 2 - 90)
	b.progress = Skin.Text(card, "GameTooltipTextSmall", "muted")
	b.progress:SetPoint("LEFT", b.bar, "RIGHT", 10, 0)
	-- The button (its key inside), what went wrong above it.
	b.post = Skin.Button(card, L.SELL_ALL_NONE, PostNext, "main")
	b.post:SetPoint("TOPLEFT", b.bar, "BOTTOMLEFT", 0, -14)
	b.post:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
	ns.KeyLabel(b.post, L.SPACE_KEY)
	b.post.wait = WaitBar(b.post)
	b.post.wait:SetPoint("BOTTOMLEFT", b.post, "BOTTOMLEFT", 1, 1)
	b.post.wait:SetPoint("BOTTOMRIGHT", b.post, "BOTTOMRIGHT", -1, 1)
	Skin.Tooltip(b.post, L.QUEUE_POST_DESC, "ANCHOR_TOP")
	b.status = Skin.Text(card, "GameTooltipTextSmall", "muted")
	b.status:SetPoint("TOPLEFT", b.post, "BOTTOMLEFT", 0, -8)
	b.status:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
	b.status:SetJustifyH("LEFT")
	if b.status.SetMaxLines then b.status:SetMaxLines(2) end
	-- The quiet choices: this one aside, the way, the duration; back to one at a time.
	b.skip = Skin.SmallButton(card, L.QUEUE_SKIP, Skip, L.QUEUE_SKIP_DESC)
	b.skip:SetPoint("TOPLEFT", b.post, "BOTTOMLEFT", 0, -34)
	b.way = Skin.SmallButton(card, "", NextWay, L.QUEUE_WAY_DESC)
	b.way:SetPoint("LEFT", b.skip, "RIGHT", 6, 0)
	b.duration = Skin.SmallButton(card, "", NextDuration, L.QUEUE_DURATION_DESC)
	b.duration:SetPoint("LEFT", b.way, "RIGHT", 6, 0)
	b.back = Skin.SmallButton(card, L.SELL_ALL_BACK, function() Batch(false) end)
	b.back:SetPoint("TOPLEFT", b.skip, "BOTTOMLEFT", 0, -10)
end

-- The page ----------------------------------------------------------------------------------------------

local function Build(page)
	list = Skin.Table(page, {
		nameTitle = L.COL_ITEM,
		width = LIST_WIDTH, rows = 26, onDraw = Draw,
		onClick = function(entry)
			if not batch.on then return Select(entry) end
			-- Selling everything: a click leaves it aside, or takes it back. No price to trust: chosen alone, your
			-- own price asked.
			local why = entry and not entry.header and select(2, BatchPrice(entry))
			if why == "unpriced" or why == "young" then return Select(entry) end
			local kind = entry and KindOf(entry)
			if kind and not Done(entry) then
				batch.aside[kind] = not batch.aside[kind] or nil
				UpdateBatch()
			end
		end,
		columns = { { key = "qty", title = L.COL_QTY, width = 40 }, { key = "market", title = L.COL_LAST, width = 110 } },
	})
	list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	list.empty:SetText(L.EMPTY)
	-- Under the table: the prices of all your items looked up in one go, and how far it is.
	detail.scan = Skin.Button(page, L.SCAN_PRICES, function() ns.ScanAll() end)
	detail.scan:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, STRIP)
	Skin.Tooltip(detail.scan, L.SCAN_PRICES_DESC, "ANCHOR_TOP")
	detail.sellAll = Skin.Button(page, L.SELL_ALL, function() Batch(not batch.on) end)
	detail.sellAll:SetPoint("LEFT", detail.scan, "RIGHT", 8, 0)
	Skin.Tooltip(detail.sellAll, L.SELL_ALL_DESC, "ANCHOR_TOP")
	detail.log = Skin.SmallButton(page, L.LOG_OPEN, function() ns.ShowLog() end, L.LOG_OPEN_DESC)
	-- (its right edge on the list's, level with the buttons)
	detail.log:SetPoint("RIGHT", detail.scan, "LEFT", LIST_WIDTH, 0)
	detail.scanText = Skin.Text(page, "GameTooltipTextSmall", "muted")
	detail.scanText:SetPoint("BOTTOMLEFT", detail.scan, "TOPLEFT", 0, 6)
	detail.scanText:SetPoint("RIGHT", detail.log, "RIGHT", 0, 0)
	detail.scanText:SetJustifyH("LEFT")
	function page:Fit(height) list:Fit(height - 64 - STRIP) end
	-- At the bottom: what was done last, and how things stand (the prices, the auction house).
	local stripRule = Skin.Rule(page, false, 0.1)
	stripRule:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, STRIP - 6)
	stripRule:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	detail.stripRight = Skin.Text(page, "GameTooltipTextSmall", "muted")
	detail.stripRight:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	detail.stripLeft = Skin.Text(page, "GameTooltipTextSmall", "soft")
	detail.stripLeft:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
	detail.stripLeft:SetPoint("RIGHT", detail.stripRight, "LEFT", -16, 0)
	if detail.stripLeft.SetWordWrap then detail.stripLeft:SetWordWrap(false) end
	-- What moves while waiting: the dots of a price looked up, the button ready again (a few times a second, only
	-- while the page is shown; the lines under the price and the buttons move by themselves, Skin.ProgressLine).
	local ticker = CreateFrame("Frame", nil, page)
	ticker.elapsed, ticker.clock = 0, 0
	ticker:SetScript("OnUpdate", function(self, elapsed)
		self.clock = self.clock + elapsed
		-- (every frame only while a button glows or one is to put back still)
		if self.glowing or detail.readyAgain or batch.readyAgain then
			local glow = 0.75 + 0.25 * math.sin(self.clock * 6)
			if detail.post then detail.post:SetAlpha(detail.readyAgain and detail.canPost and glow or 1) end
			if detail.batch then detail.batch.post:SetAlpha(batch.readyAgain and glow or 1) end
			self.glowing = (detail.readyAgain or batch.readyAgain) and true or nil
		end
		self.elapsed = self.elapsed + elapsed
		if self.elapsed < 0.4 then return end
		self.elapsed = 0
		-- (an order waiting, the auction house ready without saying it: ready now)
		if (detail.order or batch.order) and ns.Ready() then HouseReady() end
		if scanning or (selected and selected.key and not selected.searched) then
			dotsStep = dotsStep % #DOTS + 1
			Draw()
		else
			ShowStrip()
		end
	end)
	local rule = Skin.Rule(page, true, 0.12)
	rule:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP / 2, 0)
	rule:SetPoint("BOTTOM", page, "BOTTOM", 0, STRIP)
	detail.pick = Skin.Text(page, "GameTooltipText", "muted")
	detail.pick:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, -60)
	detail.pick:SetText(L.PICK)
	local frame = CreateFrame("Frame", nil, page)
	frame:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, 0)
	frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, STRIP)
	frame:Hide()
	detail.frame = frame
	-- On the right: the market.
	local market = CreateFrame("Frame", nil, frame)
	market:SetWidth(MARKET_WIDTH)
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
	-- Your price, each: one box, filled as your way says (a setting), typed as you like; beside it, the cheapest
	-- matched, 5 % less or more, and back to the price offered once changed.
	local priceCaps = Skin.Caps(middle, L.YOUR_PRICE_EACH)
	priceCaps:SetPoint("TOPLEFT", detail.icon, "BOTTOMLEFT", 0, -16)
	-- Your own price (and, for an item, a starting bid): typed or stepped, it is the one posted.
	local function Typed()
		if filling then return end
		detail.mode, detail.changed, detail.refusal = "custom", true, nil
		UpdateSale()
	end
	detail.price = ns.PriceBox(middle, { width = 220, height = 40, big = true, onChange = Typed, tip = L.PRICE_FIELD_DESC })
	detail.price:SetPoint("TOPLEFT", priceCaps, "BOTTOMLEFT", 0, -6)
	-- (a thin line moving under it while its prices are looked up)
	detail.loading = WaitBar(middle)
	detail.loading:SetPoint("TOPLEFT", detail.price, "BOTTOMLEFT", 0, -2)
	detail.loading:SetPoint("TOPRIGHT", detail.price, "BOTTOMRIGHT", 0, -2)
	-- A price set by a click: yours from then on.
	local function SetPrice(copper)
		if not (selected and copper and copper > 0) then return end
		detail.price:Set(copper)
		Typed()
	end
	detail.match = Skin.Button(middle, L.MATCH_LOWEST, function()
		if selected and selected.lowest then SetPrice(Whole(selected.lowest)) end
	end)
	detail.match:SetPoint("LEFT", detail.price, "RIGHT", 8, 0)
	Skin.Tooltip(detail.match, L.MATCH_LOWEST_DESC, "ANCHOR_TOP")
	-- (5 % less or more than the price now, one step at least: a copper, or a silver where copper is not taken)
	local function Stepped(share)
		local unit = Unit()
		if unit <= 0 then return end
		local step, up = PriceStep(), share > 1
		local price = Whole(math.floor(unit * share + 0.5), up)
		if up and price <= unit then price = unit + step end
		if not up and price >= unit then price = unit - step end
		SetPrice(math.max(step, price))
	end
	detail.stepDown = Skin.SmallButton(middle, "-5 %", function() Stepped(0.95) end, L.STEP_DOWN_DESC, 26)
	detail.stepDown:SetPoint("TOPLEFT", detail.price, "BOTTOMLEFT", 0, -8)
	detail.stepUp = Skin.SmallButton(middle, "+5 %", function() Stepped(1.05) end, L.STEP_UP_DESC, 26)
	detail.stepUp:SetPoint("LEFT", detail.stepDown, "RIGHT", 6, 0)
	detail.stepped = Stepped
	detail.reset = Skin.CreateLink(middle, L.PRICE_RESET, function()
		if not selected then return end
		Skin.Play("click")
		detail.mode, detail.changed, detail.refusal = DefaultWay(), false, nil
		if Unit() == 0 then
			detail.mode = "custom"
			detail.price:Set(selected.start or 0)
		end
		UpdateSale()
	end, L.PRICE_RESET_DESC)
	detail.reset:SetPoint("LEFT", detail.stepUp, "RIGHT", 10, 0)
	detail.reset:Hide()
	-- At the row's end: the price shown kept as yours for this item (never offered under it), or forgotten.
	detail.keep = Skin.SmallButton(middle, L.KEEP_YOUR_PRICE, function()
		if not selected then return end
		ns.SetYourPrice(selected.id, not detail.forget and Unit() or nil)
		UpdateSale()
	end, function() return detail.forget and L.FORGET_YOUR_PRICE_DESC or L.KEEP_YOUR_PRICE_DESC end, 26)
	detail.keep:SetPoint("TOP", detail.stepDown, "TOP", 0, 0)
	detail.keep:SetPoint("RIGHT", middle, "RIGHT", 0, 0)
	-- Why this price, in one line; or, in its place, one chip when something matters.
	detail.hint = Skin.Text(middle, "GameTooltipTextSmall", "muted")
	detail.hint:SetPoint("TOPLEFT", detail.stepDown, "BOTTOMLEFT", 0, -10)
	detail.hint:SetPoint("RIGHT", middle, "RIGHT", 0, 0)
	detail.hint:SetJustifyH("LEFT")
	if detail.hint.SetWordWrap then detail.hint:SetWordWrap(false) end
	detail.alert = Skin.Chip(middle)
	detail.alert:SetPoint("TOPLEFT", detail.stepDown, "BOTTOMLEFT", 0, -9)
	-- (its words, for those who read them: the tests)
	detail.finance = detail.alert.text
	detail.bidLine = CreateFrame("Frame", nil, middle)
	detail.bidLine:SetSize(300, 28)
	detail.bidLine:SetPoint("TOPLEFT", detail.stepDown, "BOTTOMLEFT", 0, -34)
	local bidLabel = Skin.Text(detail.bidLine, "GameTooltipTextSmall", "muted")
	bidLabel:SetPoint("LEFT")
	bidLabel:SetText(L.START_BID)
	detail.bid = ns.PriceBox(detail.bidLine, { width = 150, height = 26, onChange = Typed, tip = L.PRICE_FIELD_DESC })
	detail.bid:SetPoint("LEFT", bidLabel, "RIGHT", 10, 0)
	detail.bidLine:Hide()
	-- The button (its key inside), the money above it, how many and how long above that.
	detail.post = Skin.Button(middle, L.POST, Post, "main")
	detail.post:SetPoint("BOTTOMLEFT")
	detail.post:SetPoint("BOTTOMRIGHT")
	ns.KeyLabel(detail.post, L.SPACE_KEY)
	Skin.Tooltip(detail.post, L.POST_DESC, "ANCHOR_TOP")
	detail.post.wait = WaitBar(detail.post)
	detail.post.wait:SetPoint("BOTTOMLEFT", detail.post, "BOTTOMLEFT", 1, 1)
	detail.post.wait:SetPoint("BOTTOMRIGHT", detail.post, "BOTTOMRIGHT", -1, 1)
	detail.what = Skin.Text(middle, "GameTooltipTextSmall", "muted")
	detail.what:SetPoint("BOTTOM", detail.post, "TOP", 0, 6)
	-- What you receive and what a merchant gives; the cut and the deposit under the mouse.
	local summary = Skin.Panel(middle)
	summary:SetPoint("BOTTOMLEFT", detail.what, "TOPLEFT", 0, 8)
	summary:SetPoint("LEFT", middle, "LEFT", 0, 0)
	summary:SetPoint("RIGHT", middle, "RIGHT", 0, 0)
	summary:SetHeight(66)
	summary:EnableMouse(true)
	detail.net = Skin.SummaryLine(summary, nil, L.YOU_RECEIVE, true)
	detail.merchant = Skin.SummaryLine(summary, detail.net, L.MERCHANT_LINE)
	Skin.Tooltip(summary, function()
		local fees = detail.fees or {}
		local soft = Skin.COLORS.text
		return { L.YOU_RECEIVE,
			{ L.CUT_LINE:format(ns.CutPercent()) .. ": " .. U.Coins(fees.cut or 0), soft[1], soft[2], soft[3] },
			{ L.DEPOSIT_LINE .. ": " .. U.Coins(fees.deposit or 0), soft[1], soft[2], soft[3] } }
	end, "ANCHOR_TOP")
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
		-- (kept as the duration offered, as the way is)
		W.ChangeEverywhere(function() if ns.Settings() then ns.Settings().duration = tostring(key) end end)
		UpdateSale()
	end, 30)
	detail.durations:SetPoint("BOTTOMLEFT", summary, "TOPLEFT", 0, 12)
	local durationCaps = Skin.Caps(middle, L.DURATION_TITLE)
	durationCaps:SetPoint("BOTTOMLEFT", detail.durations, "TOPLEFT", 0, 6)
	local less = Skin.Button(middle, "-", Step(-1), nil, 32)
	less:SetPoint("BOTTOMLEFT", durationCaps, "TOPLEFT", 0, 12)
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
	if bulk or scanning or Looking() then return Search() end
	wipe(queue)
	ResetScan()
	ShowScan()
	-- One queue, in order: what is set aside for the auction house, then the rest of your bags whose price is
	-- unknown or older than a day (the others keep theirs, looked up when chosen or by "Look up the prices").
	-- Each waits while you look at the item chosen, which is always asked first.
	for _, entry in ipairs(entries) do
		if entry.auction then queue[#queue + 1] = entry end
	end
	for _, entry in ipairs(entries) do
		if not entry.header and not entry.auction and Stale(entry) then queue[#queue + 1] = entry end
	end
	Search()
end

local function Closed()
	Select(nil)
	Batch(false)
	wipe(batch.seen)
	wipe(batch.aside)
	wipe(batch.done)
	wipe(batch.doneSlots)
	wipe(batch.silent)
	batch.posted, batch.way, batch.duration = 0, nil, nil
	wipe(postedKinds)
	detail.last, detail.order, detail.readyAgain = nil, false, false
	wipe(queue)
	ResetScan()
	ns.ClearLog()
	pending, posting, scanning, bulk = false, nil, nil, nil
end

ns.AddPage("sell", L.SELL, Build, Shown, Closed)
ns.PageHelp("sell", L.HELP_SELL)

-- The keys of the page (the pointer over the window): the arrows choose the item above or below, Ctrl with them
-- steps the price 5 % up or down, Space or Enter posts; selling everything, Space or Enter posts the next one
-- and S leaves it aside. (The game may want a click for a sale: the key binding of Wanderer Auction then.)
local POST_KEYS = { SPACE = true, ENTER = true, NUMPADENTER = true }
ns.PageKeys("sell", function(key)
	-- (an order waiting: Escape lets it go; Space or Enter does not post twice)
	if key == "ESCAPE" and (detail.order or batch.order) then
		detail.order, batch.order = false, nil
		if selected then UpdateSale() end
		UpdateBatch()
		return true
	end
	if (detail.order or batch.order) and POST_KEYS[key] then return true end
	if batch.on then
		if POST_KEYS[key] then
			PostNext()
			return true
		end
		if key == "S" then
			Skip()
			return true
		end
		return false
	end
	if key == "UP" or key == "DOWN" then
		if IsControlKeyDown() then
			if not selected then return false end
			detail.stepped(key == "UP" and 1.05 or 0.95)
			return true
		end
		Move(key == "UP" and -1 or 1)
		return true
	end
	if POST_KEYS[key] and selected and detail.canPost then
		Post()
		return true
	end
	return false
end)

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

ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	HouseReady()
	if pending then Search() end
end)
-- (only the answer to the look this page sent: another page's is not ours)
local function Bulk() if bulk and ns.browsing == "sell" and list and list:IsVisible() then ReadBulk() end end
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
		W.Print(said)
		ns.Log("good", said)
		-- (said on the page at once, its row marked)
		detail.last = { L.POSTED_LINE:format(posting.name or "", posting.quantity, U.Coins(posting.unit)), "good" }
		if posting.kind ~= nil then postedKinds[posting.kind] = true end
		if not batch.on then Draw() end
		if posting.batch then
			-- (one per auction: its stack stays offered while it holds some, the bags say when it is empty)
			if posting.slotKey and not posting.single then
				batch.doneSlots[posting.slotKey] = posting.name or true
			elseif not posting.slotKey then
				batch.done[posting.batch] = true
			end
			batch.posted = batch.posted + 1
		end
		posting = nil
		UpdateBatch()
	end
	Soon()
	if ns.RefreshTabs then ns.RefreshTabs() end
end)
-- A sale refused (the auction house's answer, or the game's "internal error" said on the screen): said in
-- the journal, the sale let go.
local refused -- the sale just refused (the "internal error" may be said after the auction house's answer)
local function PostRefused()
	if not posting then return end
	ns.Log("bad", L.LOG_POST_ERROR:format(posting.name or ""))
	detail.last = { L.REFUSED_LINE:format(posting.name or ""), "bad" }
	ShowStrip()
	-- (refused while selling everything: left aside, the next one offered)
	if posting.batch then batch.done[posting.batch] = true end
	refused, posting = posting, nil
	refused.refusedAt = GetTime()
	UpdateBatch()
end
-- An item the server refuses (its "internal error" only): at its second refusal (the first may be passing),
-- remembered (never offered again to sell everything); set aside for the auction house, made junk (the
-- option): grey, sold at the next merchant; better, there by the junk button (a click).
local function ServerRefuses(sale)
	if not sale.id then return end
	if not ns.Refuse(sale.id) then
		local said = L.REFUSED_ONCE:format(sale.name or "")
		W.Print(said)
		return ns.Log("bad", said)
	end
	local junk = ns.Settings() and ns.Settings().toMerchant and IsForAuction(sale.id) and MakeJunk(sale.id, sale.quality)
	local better = (tonumber(sale.quality or U.ItemQuality(sale.id)) or POOR) > POOR
	local said = (junk and (better and L.REFUSED_JUNK_ASK or L.REFUSED_JUNK) or L.REFUSED_SAID):format(sale.name or "")
	W.Print(said)
	ns.Log("bad", said)
end
ns.Listen("AUCTION_HOUSE_POST_ERROR", PostRefused)
-- A price with copper refused where copper is not taken (never sent now, see Whole): said as such, the item not
-- remembered as refused.
local function HasCopper(sale)
	return WholeSilver() and ((sale.buyout or 0) % SILVER ~= 0 or (sale.bid or 0) % SILVER ~= 0)
end
local function Judge(sale)
	if sale.judged then return end
	sale.judged = true
	if HasCopper(sale) then
		local said = L.REFUSED_COPPER:format(sale.name or "")
		W.Print(said)
		return ns.Log("bad", said)
	end
	ServerRefuses(sale)
end
-- The auction house's own error for a sale (Forever says it this way, AUCTION_HOUSE_SHOW_ERROR, its "internal
-- error" being Enum.AuctionHouseError.DatabaseError): the sale under way let go, judged.
local DATABASE_ERROR = Enum and Enum.AuctionHouseError and Enum.AuctionHouseError.DatabaseError or 10
ns.Listen("AUCTION_HOUSE_SHOW_ERROR", function(code)
	local sale = posting
	if not sale then return end
	PostRefused()
	if code == DATABASE_ERROR then Judge(sale) end
	if detail.frame and detail.frame:IsShown() and not batch.on then
		detail.refusal = code == DATABASE_ERROR and L.CHIP_REFUSED or L.POST_REFUSED:format(tostring(code))
		UpdateSale()
	end
end)
ns.Listen("UI_ERROR_MESSAGE", function(_, message)
	if not (ERR_AUCTION_DATABASE_ERROR and message == ERR_AUCTION_DATABASE_ERROR) then return end
	-- (the one the auction house refused a moment ago: the game says it with that answer, at once, so a sale sent
	-- since is not the one refused; else the sale under way)
	local sale = refused and GetTime() - refused.refusedAt < 1 and refused
	if not sale then
		sale = posting
		PostRefused()
	end
	refused = nil
	if sale then Judge(sale) end
end)
ns.Listen("BAG_UPDATE_DELAYED", Soon)
