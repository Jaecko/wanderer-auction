local _, ns = ...
local L = ns.L

-- Selling, as plain as it can be. On the left, what your bags can sell (what
-- Wanderer Bags sets aside for the auction house first). In the middle, the
-- item chosen: one price, how many, how long, the total, one big button (Space)
-- and one to pass to the next (Shift+Space). On the right, what is for sale now,
-- one line per price with how many are sold at it: a click on a line puts you
-- at that price. Lines a merchant beats are grey, still yours to click (asked
-- first). One place is advised (a star): at the cheapest price worth matching,
-- or between a lone cheap offer and the next ones when the gap is wide.
--
-- Reliable first: one search at a time, the latest asked replacing one that
-- waits, sent only when the auction house is ready, asked again when it gives
-- no answer; the button waits while the auction house is busy, says so, and a
-- sale is never sent twice.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local COMMODITY = Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity or 2
local POOR = Enum and Enum.ItemQuality and Enum.ItemQuality.Poor or 0
local LIST_WIDTH, LEVELS_WIDTH = 300, 300
local STRIP = 22 -- the status strip at the bottom of the page
local SILVER = rawget(_G, "COPPER_PER_SILVER") or 100

-- When a lone cheap offer is passed by: it holds this share of what is for sale or less, and the next price is
-- this much higher or more. Placed then this share of the gap under the next price.
ns.LONE_SHARE, ns.GAP_JUMP, ns.GAP_PLACE = 0.05, 1.15, 0.3

local list, levelsList, entries, selected = nil, nil, {}, nil
local detail = {}
local posting -- the sale sent, waiting for the game's answer: { id, name, quantity, unit, at, ... }
local look = { want = nil, sent = nil, at = 0, tries = 0 } -- the one search: wanted, sent (an entry), when, how often
local LOOK_WAIT, LOOK_TRIES = 4, 3 -- seconds without an answer before asking again, and how often at most
local Draw, DrawLevels, UpdateSale, Select, Pump -- (below)

ns.sellDetail = detail -- (tests)

-- What Wanderer Bags says ----------------------------------------------------------------------------------------

local Marks = ns.Marks
local function Mark(name, ...)
	local fn = Marks()[name]
	if type(fn) ~= "function" then return nil end
	local ok, value = pcall(fn, ...)
	return ok and value or nil
end
-- Not offered: what Wanderer Bags keeps (an outfit's piece too), or an outfit's piece without Bags. Kept when it
-- cannot say: an item you keep is never offered by mistake.
local function NotForAuction(id)
	local fn = Marks().NotForAuction or Marks().IsKept
	if type(fn) ~= "function" then return false end
	local ok, kept = pcall(fn, id)
	return not ok or kept and true or false
end
local function OutfitPieces()
	if type(Marks().NotForAuction) == "function" then return nil end
	local api = type(WandererOutfits) == "table" and WandererOutfits.Pieces
	if type(api) ~= "function" then return nil end
	local ok, pieces = pcall(api)
	return ok and type(pieces) == "table" and pieces or nil
end

-- Your bags ---------------------------------------------------------------------------------------------------

-- Everything your bags can sell here (not what a quest asks): a commodity once (all its stacks), identical items
-- once (the same link), set aside for the auction house first; a title before each part.
local function Read()
	local found, commodities, items = {}, {}, {}
	local pieces = OutfitPieces()
	U.EachBagItem(function(bag, slot, info)
		local id = Clean(info.itemID)
		local location = ItemLocation and ItemLocation:CreateFromBagAndSlot(bag, slot)
		if location and id and not Clean(info.isBound) and not NotForAuction(id) and not (pieces and pieces[id])
			and W.QuestNeed(id) == nil and Clean(Safe(AH.IsSellItemValid, location, false)) then
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
					name = U.LinkName(link) or "", quality = Clean(info.quality) or 1, icon = Clean(info.iconFileID),
					commodity = commodity, auction = Mark("IsForAuction", id) and true or false, slots = { { bag, slot } } }
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

-- Prices --------------------------------------------------------------------------------------------------------

-- Copper kept: a price chosen or matched stays exactly as it is (1s 35c is 1s 35c). Should the auction house
-- refuse a copper price, prices go to the whole silver for the rest of the session (said once).
local copperRefused = false
local function WholeSilver() return copperRefused end
ns.WholeSilver = WholeSilver
function ns.SellCopperRefused(refused) copperRefused = refused and true or false end
local function Step() return SILVER end
-- A price found by Wanderer (between two, remembered, the merchant's line): a round one, in whole silver, down
-- (up when said), a silver at least.
local function Whole(price, up)
	price = math.floor(tonumber(price) or 0)
	if price <= 0 then return price end
	local whole = up and math.ceil(price / SILVER) * SILVER or math.floor(price / SILVER) * SILVER
	return math.max(SILVER, whole)
end
ns.Whole = Whole
-- A price chosen or matched: kept to the copper, unless copper was refused.
local function Keep(price)
	price = math.floor(tonumber(price) or 0)
	if price <= 0 or not copperRefused then return price end
	return Whole(price)
end
ns.Keep = Keep

-- An item's starting bid: this share of its buyout, kept to the copper (some auction houses refuse an item
-- without one), never equal to it; shown in the money card. A commodity has none.
local BID_SHARE = 0.95
ns.BID_SHARE = BID_SHARE
local function StartBid(buyout)
	if not buyout or buyout <= 1 then return nil end
	local bid = Keep(math.floor(buyout * BID_SHARE))
	if bid >= buyout then bid = copperRefused and buyout - SILVER or buyout - 1 end
	return bid > 0 and bid or nil
end
ns.StartBid = StartBid

-- What a merchant gives for one, and the least price that brings more here once the cut is taken.
local function Vendor(entry) return ns.Vendor(entry.link) end
local function MerchantLine(entry) return ns.Floor(Vendor(entry)) end
-- The least price advised: above the merchant's line, whole; for an item, one step more and its starting bid
-- above the line too.
local function Least(entry)
	local line = MerchantLine(entry)
	if line <= 0 then return 0 end
	if entry.commodity then return Whole(line, true) end
	return math.max(Whole(line, true) + Step(), Whole(math.ceil(line / BID_SHARE), true))
end
-- A price a merchant beats.
local function UnderMerchant(entry, price) return price > 0 and price < MerchantLine(entry) end

-- The price an item was last known at (the market's days, else the last seen, else Auctionator's through Bags).
local function Known(entry)
	local price = ns.Market(entry.id) or ns.Price(entry.id) or Mark("AuctionPrice", entry.link)
	return type(price) == "number" and price > 0 and price or nil
end

-- An item (not a commodity) that stacks: one per auction (what the game does with part of a stack of such an
-- item is not sure on this server: a whole stack at the price of one would be lost money).
local function OnePerAuction(entry)
	return not entry.commodity and (entry.stacked or (U.ItemMaxStack(entry.id) or 1) > 1) and true or false
end
-- How many can be posted at once.
local function Most(entry)
	if OnePerAuction(entry) then return 1 end
	return math.max(1, math.min(Clean(Safe(AH.GetAvailablePostCount, entry.location)) or entry.count, entry.count))
end
ns.PostCount = Most
-- How many at first: all of a commodity, one of anything else.
local function FirstQuantity(entry) return entry.commodity and Most(entry) or 1 end

local function Deposit(entry, duration, quantity)
	if entry.commodity then return Clean(Safe(AH.CalculateCommodityDeposit, entry.id, duration, quantity)) end
	return Clean(Safe(AH.CalculateItemDeposit, entry.location, duration, quantity))
end

-- What is for sale now, one line per price, cheapest first: { price (each), count, mine }.
local READ_MOST = 500
local function ReadLevels(entry)
	local byPrice, levels = {}, {}
	local function Add(price, count, mine)
		if not (price and price > 0) then return end
		local level = byPrice[price]
		if not level then
			level = { price = price, count = 0, mine = false }
			byPrice[price] = level
			levels[#levels + 1] = level
		end
		level.count = level.count + (count or 1)
		level.mine = level.mine or (mine and true or false)
	end
	if entry.commodity then
		local count = Clean(Safe(AH.GetNumCommoditySearchResults, entry.id)) or 0
		for index = 1, math.min(count, READ_MOST) do
			local result = Safe(AH.GetCommoditySearchResultInfo, entry.id, index)
			if type(result) == "table" then
				Add(Clean(result.unitPrice), Clean(result.quantity) or 1,
					Clean(result.containsOwnerItem) or (Clean(result.numOwnerItems) or 0) > 0)
			end
		end
	elseif entry.key then
		local count = Clean(Safe(AH.GetNumItemSearchResults, entry.key)) or 0
		for index = 1, math.min(count, READ_MOST) do
			local result = Safe(AH.GetItemSearchResultInfo, entry.key, index)
			if type(result) == "table" then
				local buyout, quantity = Clean(result.buyoutAmount), Clean(result.quantity) or 1
				-- (an auction without a buyout cannot be bought at once: left out)
				if buyout and buyout > 0 then Add(math.floor(buyout / math.max(1, quantity)), quantity, Clean(result.containsOwnerItem)) end
			end
		end
	end
	table.sort(levels, function(a, b) return a.price < b.price end)
	return levels
end
ns.ReadLevels = ReadLevels

-- The place advised: a price, and how it was found ("yours", "match", "between", "low", "memory"), or nil.
-- levels nil: not looked yet; {}: nobody sells it.
function ns.Advise(entry, levels)
	local least = Least(entry)
	if not levels or not levels[1] then
		local known = Known(entry)
		if not known then return nil end
		return math.max(Whole(known), least), "memory"
	end
	local line = MerchantLine(entry)
	local first, firstIndex, total = nil, nil, 0
	for index, level in ipairs(levels) do
		if level.price >= line then
			total = total + level.count
			if not first then first, firstIndex = level, index end
		end
	end
	if not first then return least > 0 and least or nil, "low" end
	if first.mine then return math.max(Keep(first.price), least), "yours" end
	local nextOne
	for index = firstIndex + 1, #levels do
		if not levels[index].mine then
			nextOne = levels[index]
			break
		end
	end
	if nextOne and first.count <= math.max(1, total * ns.LONE_SHARE) and nextOne.price >= first.price * ns.GAP_JUMP then
		local price = Whole(nextOne.price - math.max(Step(), (nextOne.price - first.price) * ns.GAP_PLACE))
		if price > first.price and price < nextOne.price then return math.max(price, least), "between" end
	end
	return math.max(Keep(first.price), least), "match"
end

-- How many others sell cheaper than this price.
local function Ahead(levels, price)
	local count = 0
	for _, level in ipairs(levels or {}) do
		if level.price < price and not level.mine then count = count + level.count end
	end
	return count
end

-- The search ---------------------------------------------------------------------------------------------------
-- One at a time. A new item chosen replaces the one waiting; an answer for an item no longer chosen is read all
-- the same (its prices remembered) and the next one goes.

local function Answered(entry)
	if entry.commodity then
		if Clean(Safe(AH.HasFullCommoditySearchResults, entry.id)) then return true end
		return (Clean(Safe(AH.GetNumCommoditySearchResults, entry.id)) or 0) > 0
	end
	if not entry.key then return false end
	if Clean(Safe(AH.HasFullItemSearchResults, entry.key)) then return true end
	return (Clean(Safe(AH.GetNumItemSearchResults, entry.key)) or 0) > 0
end

-- Set aside for the auction house, but a merchant beats everything for sale: made junk (the option), said once.
local function MakeJunk(entry)
	if not (ns.Settings() and ns.Settings().toMerchant and entry.auction) then return end
	if (tonumber(entry.quality) or POOR) > POOR and not W.JUNK_ASK then return end
	if not Mark("ToJunk", entry.id) then return end
	ns.MadeJunk(entry.id, true)
	entry.auction = false
	W.Print(((tonumber(entry.quality) or POOR) > POOR and L.MOVED_TO_JUNK_ASK or L.MOVED_TO_JUNK):format(entry.link or entry.name or ""))
end

-- The prices of an item read: remembered (the tooltips, the days), and shown when it is the one chosen.
local function Got(entry, silent)
	if look.sent == entry then look.sent, look.tries = nil, 0 end
	entry.levels = ReadLevels(entry)
	entry.searched = true
	entry.silent = silent and not entry.levels[1] or nil
	local others, total = {}, 0
	for _, level in ipairs(entry.levels) do
		if not level.mine then
			others[#others + 1] = { level.price, level.count }
			total = total + level.count
		end
	end
	if others[1] then
		ns.Remember(entry.id, others[1][1], true)
		local value = ns.MarketValue(others)
		if value then ns.RememberMarket(entry.id, value) end
		if total >= 3 and UnderMerchant(entry, others[#others][1]) then MakeJunk(entry) end
	end
	if entry == selected then
		if not detail.typed then
			local price, how = ns.Advise(entry, entry.levels)
			detail.price, detail.how = price or 0, how
		end
		UpdateSale()
		DrawLevels()
	end
	Draw()
	Pump()
end

local function Send(entry)
	local key = Safe(AH.GetItemKeyFromItem, entry.location)
	if not key then
		-- (no key for it: nothing to ask; nobody sells it, as far as can be known)
		return Got(entry)
	end
	entry.key = key
	local order = Enum.AuctionHouseSortOrder
	Safe(AH.SendSearchQuery, key, { { sortOrder = order.Price, reverseSort = false }, { sortOrder = order.Name, reverseSort = false } }, true)
	look.sent, look.at = entry, GetTime()
	ns.Debug("sell search", { id = entry.id, link = entry.link, commodity = entry.commodity, try = look.tries })
end

-- The next search, when the auction house takes it.
function Pump()
	if look.sent or not look.want then return end
	if not ns.Ready() then return end
	local entry = look.want
	look.want = nil
	Send(entry)
end

local function Ask(entry)
	if not entry then return end
	entry.searched, entry.levels, entry.silent = false, nil, nil
	if look.sent == entry then return end
	look.want, look.tries = entry, 0
	Pump()
end

-- Twice a second while the page is shown: an answer the game did not announce, one that never came (asked again,
-- then given up), the auction house ready again.
local function Watch()
	local entry = look.sent
	if entry then
		if Answered(entry) then return Got(entry) end
		if GetTime() - look.at > LOOK_WAIT then
			look.sent = nil
			look.tries = look.tries + 1
			if look.tries >= LOOK_TRIES then return Got(entry, true) end
			if not look.want then look.want = entry end
		end
	end
	Pump()
end

ns.SellWatch = function() Watch() end -- (tests)

-- The page -------------------------------------------------------------------------------------------------------

local function Ready() return ns.Ready() and not posting end

-- The status strip: what was done last (left), the auction house (right).
local function ShowStrip()
	if not detail.stripRight then return end
	local busy = not ns.Ready()
	detail.stripRight:SetText(busy and L.HOUSE_BUSY or L.HOUSE_READY)
	detail.stripRight:SetTextColor(Skin.RGB(busy and "warn" or "good"))
	if detail.last then
		detail.stripLeft:SetText(detail.last[1])
		detail.stripLeft:SetTextColor(Skin.RGB(detail.last[2] or "soft"))
	else
		detail.stripLeft:SetText("")
	end
end

local function Quantity()
	if not selected then return 1, 1 end
	local most = Most(selected)
	return math.max(1, math.min(most, detail.qty or FirstQuantity(selected))), most
end

-- (1 to 3 only: an odd value in old saved settings never reaches the auction house)
local function Duration()
	local duration = tonumber(ns.Settings() and ns.Settings().duration)
	return (duration == 1 or duration == 3) and duration or 2
end

local WHY = { yours = "WHY_YOURS", match = "WHY_MATCH", between = "WHY_BETWEEN", low = "WHY_LOW", memory = "WHY_MEMORY" }
function UpdateSale()
	if not (selected and detail.frame) then return end
	local quantity, most = Quantity()
	local price = detail.price or 0
	if not detail.qtyBox:HasFocus() then detail.qtyBox:SetText(tostring(quantity)) end
	detail.max:SetText(L.SELL_MAX:format(most))
	detail.max:Fit()
	detail.max:SetEnabled(not OnePerAuction(selected) and most > 1)
	detail.durations:Select(Duration())
	if not detail.priceBox.input:HasFocus() then detail.priceBox:Set(price) end
	-- Why this price, in one line.
	local waiting = not selected.searched and (look.sent == selected or look.want == selected)
	local why, tone
	if UnderMerchant(selected, price) then
		why, tone = L.WHY_UNDER_MERCHANT:format(U.Coins(Vendor(selected))), "bad"
	elseif detail.typed then
		why, tone = L.WHY_CHOSEN, "soft"
	elseif waiting then
		why, tone = detail.how == "memory" and L.WHY_SEARCHING_MEMORY or L.WHY_SEARCHING, "muted"
	elseif selected.silent then
		why, tone = L.WHY_SILENT, "bad"
	elseif detail.how == "memory" then
		why, tone = L.WHY_NOBODY, "kicker"
	elseif detail.how then
		why, tone = L[WHY[detail.how]], detail.how == "low" and "bad" or "kicker"
	else
		why, tone = L.WHY_NONE, "muted"
	end
	detail.why:SetText(why)
	detail.why:SetTextColor(Skin.RGB(tone))
	local usual = ns.Market(selected.id)
	detail.usual:SetText(usual and L.SELL_USUAL:format(U.Coins(usual)) or "")
	-- The money.
	local deposit = Deposit(selected, Duration(), quantity)
	detail.total:SetText(price > 0 and U.Coins(price * quantity) or "")
	detail.net:SetText(price > 0 and U.Coins(ns.Net(price * quantity)) or "")
	-- (the cut: a neutral auction house takes more)
	detail.netLabel:SetText(L.SELL_NET:format(ns.CutPercent()))
	detail.deposit:SetText(deposit and U.Coins(deposit) or "")
	-- (an item's starting bid, said: nothing hidden; a commodity has none)
	local bid = not selected.commodity and price > 0 and StartBid(price) or nil
	detail.bid:SetText(bid and U.Coins(bid) or "")
	detail.bidLabel:SetShown(bid ~= nil)
	-- The button: ready, waiting for the auction house, or for the game's answer.
	-- (the price looked up first, unless you typed it: never posted at an old price by a quick Space)
	detail.post:SetEnabled(price > 0 and Ready() and (selected.searched or detail.typed) and true or false)
	detail.skip:SetEnabled(ns.SellNext() ~= nil)
	detail.post:SetText(posting and L.SELL_SENDING or (not ns.Ready()) and L.SELL_WAIT or L.SELL_POST)
	detail.post.keyLabel:SetShown(Ready() and not (U.UsingPad and U.UsingPad()))
	detail.what:SetText(OnePerAuction(selected) and L.SELL_ONE_EACH or "")
	-- How many sell cheaper.
	if selected.levels and selected.levels[1] and price > 0 then
		local ahead = Ahead(selected.levels, price)
		detail.ahead:SetText(ahead > 0 and L.AHEAD_SOME:format(ahead) or L.AHEAD_NONE)
	else
		detail.ahead:SetText("")
	end
	ShowStrip()
end

-- The list on the left.
function Draw()
	if not (list and list:IsVisible()) then return end
	local offset = list:Clamp(#entries)
	for index, row in ipairs(list.rows) do
		local entry = entries[offset + index]
		local values
		if entry and not entry.header then
			local known = entry.levels and entry.levels[1] and entry.levels[1].price or Known(entry)
			values = { qty = tostring(entry.count), price = known and U.Coins(known) or "" }
		end
		row:Fill(entry, entry ~= nil and entry == selected, values)
	end
	list.empty:SetShown(#entries == 0)
end

-- What is for sale now, on the right: one line per price (the advised place among them, a line of its own when
-- it falls between two prices, or above them all).
local levelRows = {}
function DrawLevels()
	if not levelsList then return end
	wipe(levelRows)
	local entry = selected
	local levels = entry and entry.levels
	local advised
	if entry and levels then advised = ns.Advise(entry, levels) end
	for _, level in ipairs(levels or {}) do levelRows[#levelRows + 1] = level end
	if advised and levels and levels[1] then
		local there = false
		for _, level in ipairs(levelRows) do if level.price == advised then there = true end end
		if not there then
			levelRows[#levelRows + 1] = { price = advised, count = 0, gap = true }
			table.sort(levelRows, function(a, b) return a.price < b.price end)
		end
	end
	local offset = levelsList:Clamp(#levelRows)
	for index, row in ipairs(levelsList.rows) do
		local level = levelRows[offset + index]
		if level then
			local low = UnderMerchant(entry, level.price)
			local tag, tagRole = "", "muted"
			if level.mine then tag, tagRole = L.TAG_YOU, "kicker" end
			if low then tag, tagRole = L.TAG_MERCHANT, "muted" end
			if level.price == advised then tag, tagRole = level.gap and L.TAG_BETWEEN or L.TAG_ADVISED, "gold" end
			level.name = U.Coins(level.price, low and Skin.COLORS.muted or nil)
			level.color = low and Skin.COLORS.muted or (level.gap and Skin.COLORS.gold) or nil
			level.quality = 1
			level.tip = low and L.TIP_UNDER_MERCHANT:format(U.Coins(Vendor(entry))) or nil
			row:Fill(level, level.price == detail.price, { count = level.gap and "-" or tostring(level.count), tag = tag })
			row.cells.tag:SetTextColor(Skin.RGB(tagRole))
			row.cells.count:SetTextColor(Skin.RGB(low and "muted" or "soft"))
		else
			row:Fill(nil)
		end
	end
	levelsList.empty:SetText(not entry and "" or not levels and L.SEARCHING or entry.silent and L.WHY_SILENT or L.NOBODY)
	levelsList.empty:SetShown(#levelRows == 0)
end

-- A price chosen (a line clicked, or typed): yours, until another item is chosen.
local function SetPrice(price)
	if not selected then return end
	detail.price, detail.typed = Keep(price), true
	if detail.priceBox.input:HasFocus() then detail.priceBox.input:ClearFocus() end
	UpdateSale()
	DrawLevels()
end
ns.SellSetPrice = SetPrice -- (tests)

function Select(entry)
	selected = entry
	if not detail.frame then return end
	detail.frame:SetShown(entry ~= nil)
	detail.pick:SetShown(entry == nil)
	levelsList:SetShown(entry ~= nil)
	detail.levelsCaps:SetShown(entry ~= nil)
	detail.levelsHint:SetShown(entry ~= nil)
	if entry then
		ns.Debug("sell select", { link = entry.link, id = entry.id, count = entry.count, commodity = entry.commodity, stacked = entry.stacked })
		detail.icon:Set(entry.icon, entry.quality)
		detail.name:SetText(entry.name or "")
		Skin.Quality(detail.name, entry.quality)
		detail.sub:SetText(L.IN_BAGS:format(entry.count))
		detail.qty, detail.typed = nil, false
		if detail.priceBox.input:HasFocus() then detail.priceBox.input:ClearFocus() end
		-- The price remembered at once, the search corrects it.
		local price, how = ns.Advise(entry, nil)
		detail.price, detail.how = price or 0, how
		levelsList.offset = 0
		Ask(entry)
		UpdateSale()
	end
	DrawLevels()
	Draw()
end
ns.SellSelect = function(entry) Select(entry) end -- (tests)
ns.SellEntries = function() return entries end -- (tests)

-- The item after the one chosen (or before), and where it stands in the list; nil at the end.
local function Neighbour(delta)
	local at
	for index, entry in ipairs(entries) do if entry == selected then at = index end end
	local index = (at or 0) + delta
	while entries[index] and entries[index].header do index = index + delta end
	return entries[index], index
end
function ns.SellNext() return (Neighbour(1)) end

-- The next item in the list (or the previous), scrolled into view.
local function Move(delta)
	local entry, index = Neighbour(delta)
	if not entry then return end
	if index <= list.offset then
		list.offset = math.max(0, index - 2)
	elseif index > list.offset + list.count then
		list.offset = index - list.count
	end
	Select(entry)
end

local function Refresh()
	if not (list and list:IsVisible()) then return end
	local before = selected
	local at
	for index, entry in ipairs(entries) do if entry == before then at = index end end
	entries = Read()
	if before then
		local still
		for _, entry in ipairs(entries) do
			if not entry.header and entry.id == before.id and (before.commodity or entry.link == before.link) then still = entry end
		end
		if still then
			for _, key in ipairs({ "key", "levels", "searched", "silent" }) do still[key] = before[key] end
			if look.sent == before then look.sent = still end
			if look.want == before then look.want = still end
			selected = still
			detail.sub:SetText(L.IN_BAGS:format(still.count))
			UpdateSale()
		else
			-- (all of it posted: the next one in the list, where it stood)
			selected = nil
			local index = math.min(at or 1, #entries)
			while entries[index] and entries[index].header do index = index + 1 end
			Select(entries[index])
			return
		end
	end
	Draw()
end

-- Posting --------------------------------------------------------------------------------------------------------

local function SendSale(sale)
	local ok, needsConfirmation
	if sale.commodity then
		ok, needsConfirmation = pcall(AH.PostCommodity, sale.location, sale.duration, sale.quantity, sale.unit)
	else
		ok, needsConfirmation = pcall(AH.PostItem, sale.location, sale.duration, sale.quantity, sale.bid, sale.unit)
	end
	ns.Debug("sell send", { id = sale.id, link = sale.name, quantity = sale.quantity, unit = sale.unit, bid = sale.bid, ok = ok })
	if not ok then
		detail.last = { L.SELL_REFUSED:format(sale.name or "", tostring(needsConfirmation)), "bad" }
		return UpdateSale()
	end
	posting = sale
	sale.at = GetTime()
	-- (the game asks its own question for a price far below the market: its confirmation posts exactly this)
	if Clean(needsConfirmation) then
		Skin.Ask(L.CONFIRM, function()
			if sale.commodity then
				Safe(AH.ConfirmPostCommodity, sale.location, sale.duration, sale.quantity, sale.unit)
			else
				Safe(AH.ConfirmPostItem, sale.location, sale.duration, sale.quantity, sale.bid, sale.unit)
			end
		end, function()
			posting = nil
			UpdateSale()
		end)
	end
	UpdateSale()
end

-- The item still where it was (the bags may change meanwhile).
local function InPlace(entry)
	local info = Safe(C_Container and C_Container.GetContainerItemInfo, entry.bag, entry.slot)
	return type(info) == "table" and Clean(info.itemID) == entry.id
end

local function Post()
	if not selected or posting then return end
	local price = detail.price or 0
	if price <= 0 or not ns.Ready() or not (selected.searched or detail.typed) then return UpdateSale() end
	local entry = selected
	-- (moved or just sold: the list read again, nothing posted from an empty or other slot)
	if not InPlace(entry) then return Refresh() end
	local sale = { id = entry.id, name = entry.link or entry.name, commodity = entry.commodity, location = entry.location,
		quantity = Quantity(), unit = price, bid = not entry.commodity and StartBid(price) or nil, duration = Duration() }
	-- A price a merchant beats, or far under its usual value: asked first.
	local question
	if UnderMerchant(entry, price) then
		question = L.ASK_UNDER_MERCHANT:format(U.Coins(Vendor(entry)), U.Coins(ns.Net(price)))
	elseif ns.OddPrice(entry.id, price) == "low" then
		question = L.ASK_LOW:format(U.Coins(ns.Market(entry.id) or 0))
	end
	if not question then return SendSale(sale) end
	Skin.Ask(question, function()
		if posting or not InPlace(entry) then return end
		if not ns.Ready() then
			detail.last = { L.HOUSE_BUSY, "warn" }
			return UpdateSale()
		end
		SendSale(sale)
	end)
end
ns.SellPost = Post

function WandererAuction_PostNext()
	if ns.IsShown() and ns.CurrentPage() == "sell" then Post() end
end

-- The page --------------------------------------------------------------------------------------------------------

local function Build(page)
	list = Skin.Table(page, {
		nameTitle = L.COL_ITEM, width = LIST_WIDTH, rows = 26, onDraw = function() Draw() end,
		onClick = function(entry) Select(entry) end,
		columns = { { key = "qty", title = L.COL_QTY, width = 34 }, { key = "price", title = L.COL_PRICE, width = 92 } },
	})
	list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	list.empty:SetText(L.EMPTY)
	-- What is for sale now, on the right.
	detail.levelsCaps = Skin.Caps(page, L.LEVELS_TITLE)
	detail.levelsCaps:SetPoint("TOPLEFT", page, "TOPRIGHT", -LEVELS_WIDTH, 0)
	detail.levelsCaps:Hide()
	levelsList = Skin.Table(page, {
		nameTitle = L.LEVEL_PRICE, width = LEVELS_WIDTH, rows = 16, icon = false, rowHeight = Skin.ROW and Skin.ROW.normal or 34,
		onDraw = function() DrawLevels() end,
		onClick = function(level) SetPrice(level.price) end,
		columns = { { key = "count", title = L.LEVEL_COUNT, width = 58 }, { key = "tag", title = "", width = 92 } },
	})
	levelsList:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, -22)
	levelsList:Hide()
	detail.levelsHint = Skin.Text(page, "GameTooltipTextSmall", "muted")
	detail.levelsHint:SetPoint("TOPLEFT", levelsList, "BOTTOMLEFT", 6, -6)
	detail.levelsHint:SetWidth(LEVELS_WIDTH - 12)
	detail.levelsHint:SetJustifyH("LEFT")
	detail.levelsHint:SetText(L.LEVELS_HINT)
	detail.levelsHint:Hide()
	function page:Fit(height)
		list:Fit(height - STRIP - 8)
		levelsList:Fit(height - STRIP - 22 - 60)
	end
	-- The status strip.
	local stripRule = Skin.Rule(page, false, 0.1)
	stripRule:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, STRIP - 6)
	stripRule:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	detail.stripRight = Skin.Text(page, "GameTooltipTextSmall", "good")
	detail.stripRight:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	detail.stripLeft = Skin.Text(page, "GameTooltipTextSmall", "soft")
	detail.stripLeft:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
	detail.stripLeft:SetPoint("RIGHT", detail.stripRight, "LEFT", -16, 0)
	detail.stripLeft:SetJustifyH("LEFT")
	if detail.stripLeft.SetWordWrap then detail.stripLeft:SetWordWrap(false) end
	-- The search watched, twice a second while the page is shown.
	local ticker = CreateFrame("Frame", nil, page)
	ticker.elapsed = 0
	ticker:SetScript("OnUpdate", function(self, elapsed)
		self.elapsed = self.elapsed + elapsed
		if self.elapsed < 0.5 then return end
		self.elapsed = 0
		-- (the game's answer to a sale lost: the button given back after a while)
		if posting and GetTime() - (posting.at or 0) > 10 and not Skin.Asking() then posting = nil end
		Watch()
		if selected then UpdateSale() else ShowStrip() end
	end)
	-- In the middle: the item chosen.
	local rule = Skin.Rule(page, true, 0.12)
	rule:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP / 2, 0)
	rule:SetPoint("BOTTOM", page, "BOTTOM", 0, STRIP)
	detail.pick = Skin.Text(page, "GameTooltipText", "muted")
	detail.pick:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, -60)
	detail.pick:SetText(L.PICK)
	local frame = CreateFrame("Frame", nil, page)
	frame:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, 0)
	frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -(LEVELS_WIDTH + ns.GAP), STRIP)
	frame:Hide()
	detail.frame = frame
	detail.icon = Skin.Icon(frame, 40)
	detail.icon:SetPoint("TOPLEFT")
	-- An item of your bags dropped here (dragged, or carried and clicked): chosen to sell, as on the game's
	-- slot. On the window, the lists' rows and the item's icon.
	local function Take()
		if ns.CurrentPage() ~= "sell" or InCombatLockdown() then return end
		local cursor = rawget(_G, "C_Cursor")
		local location = cursor and cursor.GetCursorItem and Safe(cursor.GetCursorItem)
		if not (location and location.GetBagAndSlot) then return end
		ClearCursor()
		ns.SellLocation(location)
	end
	local window = page:GetParent()
	window:HookScript("OnReceiveDrag", Take)
	window:HookScript("OnMouseDown", Take)
	detail.icon:EnableMouse(true)
	detail.icon:HookScript("OnReceiveDrag", Take)
	for _, rows in ipairs({ list.rows, levelsList.rows }) do
		for _, row in ipairs(rows) do row:HookScript("OnReceiveDrag", Take) end
	end
	detail.name = W.Skin.CreateText(frame, "GameFontNormalLarge")
	detail.name:SetPoint("TOPLEFT", detail.icon, "TOPRIGHT", 10, -2)
	detail.name:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	detail.name:SetJustifyH("LEFT")
	detail.sub = Skin.Text(frame, "GameTooltipTextSmall", "muted")
	detail.sub:SetPoint("TOPLEFT", detail.name, "BOTTOMLEFT", 0, -4)
	-- The price.
	local priceCaps = Skin.Caps(frame, L.SELL_PRICE_EACH)
	priceCaps:SetPoint("TOPLEFT", detail.icon, "BOTTOMLEFT", 0, -22)
	detail.priceBox = ns.PriceBox(frame, { width = 220, height = 40, big = true, tip = L.PRICE_TIP,
		onChange = function(copper)
			detail.price, detail.typed = Keep(copper), true
			UpdateSale()
			DrawLevels()
		end })
	detail.priceBox:SetPoint("TOPLEFT", priceCaps, "BOTTOMLEFT", 0, -6)
	detail.why = Skin.Text(frame, "GameTooltipTextSmall", "kicker")
	detail.why:SetPoint("TOPLEFT", detail.priceBox, "BOTTOMLEFT", 0, -6)
	detail.why:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	detail.why:SetJustifyH("LEFT")
	detail.ahead = Skin.Text(frame, "GameTooltipTextSmall", "soft")
	detail.ahead:SetPoint("TOPLEFT", detail.why, "BOTTOMLEFT", 0, -4)
	detail.usual = Skin.Text(frame, "GameTooltipTextSmall", "muted")
	detail.usual:SetPoint("TOPLEFT", detail.ahead, "BOTTOMLEFT", 0, -4)
	-- How many, how long.
	local qtyCaps = Skin.Caps(frame, L.SELL_QUANTITY)
	qtyCaps:SetPoint("TOPLEFT", detail.usual, "BOTTOMLEFT", 0, -18)
	detail.qtyBox = Skin.CreateInput(frame, nil, 5)
	detail.qtyBox:SetSize(70, 32)
	if detail.qtyBox.SetNumeric then detail.qtyBox:SetNumeric(true) end
	detail.qtyBox:SetPoint("TOPLEFT", qtyCaps, "BOTTOMLEFT", 0, -6)
	detail.qtyBox:SetScript("OnTextChanged", function(self, typed)
		if not typed then return end
		local n = tonumber(self:GetText())
		if n and n > 0 then
			detail.qty = n
			UpdateSale()
		end
	end)
	detail.qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	detail.qtyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	detail.qtyBox:SetScript("OnEditFocusLost", function() UpdateSale() end)
	detail.max = Skin.Button(frame, L.SELL_MAX:format(1), function()
		if selected then
			detail.qty = Most(selected)
			UpdateSale()
		end
	end)
	detail.max:SetPoint("LEFT", detail.qtyBox, "RIGHT", 8, 0)
	detail.what = Skin.Text(frame, "GameTooltipTextSmall", "muted")
	detail.what:SetPoint("LEFT", detail.max, "RIGHT", 10, 0)
	local durationCaps = Skin.Caps(frame, L.SELL_DURATION)
	durationCaps:SetPoint("TOPLEFT", detail.qtyBox, "BOTTOMLEFT", 0, -18)
	detail.durations = Skin.Choices(frame, { { 1, ns.DurationName(1) }, { 2, ns.DurationName(2) }, { 3, ns.DurationName(3) } }, function(value)
		-- (the last one chosen, kept: the next sale uses it)
		W.ChangeEverywhere(function() if ns.Settings() then ns.Settings().duration = tostring(value) end end)
		UpdateSale()
	end)
	detail.durations:SetPoint("TOPLEFT", durationCaps, "BOTTOMLEFT", 0, -6)
	-- The money.
	local card = Skin.Panel(frame)
	card:SetPoint("TOPLEFT", detail.durations, "BOTTOMLEFT", 0, -20)
	card:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	card:SetHeight(98)
	local totalLabel = Skin.Text(card, "GameTooltipText", "soft")
	totalLabel:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -10)
	totalLabel:SetText(L.SELL_TOTAL)
	detail.total = Skin.Text(card, "GameTooltipHeaderText", "text")
	detail.total:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -8)
	-- (what comes to your mailbox once the auction house's cut is taken)
	detail.netLabel = Skin.Text(card, "GameTooltipText", "soft")
	detail.netLabel:SetPoint("TOPLEFT", totalLabel, "BOTTOMLEFT", 0, -8)
	detail.net = Skin.Text(card, "GameTooltipText", "good")
	detail.net:SetPoint("RIGHT", card, "RIGHT", -12, 0)
	detail.net:SetPoint("TOP", detail.netLabel, "TOP", 0, 0)
	local depositLabel = Skin.Text(card, "GameTooltipTextSmall", "soft")
	depositLabel:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 10)
	depositLabel:SetText(L.SELL_DEPOSIT)
	detail.deposit = Skin.Text(card, "GameTooltipTextSmall", "text")
	detail.deposit:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -12, 10)
	-- (an item's starting bid, above the deposit)
	detail.bidLabel = Skin.Text(card, "GameTooltipTextSmall", "soft")
	detail.bidLabel:SetPoint("BOTTOMLEFT", depositLabel, "TOPLEFT", 0, 6)
	detail.bidLabel:SetText(L.START_BID)
	detail.bid = Skin.Text(card, "GameTooltipTextSmall", "text")
	detail.bid:SetPoint("BOTTOMRIGHT", detail.deposit, "TOPRIGHT", 0, 6)
	-- The buttons: post (Space), pass (Shift+Space).
	detail.skip = Skin.Button(frame, L.SELL_SKIP, function() Move(1) end, nil, 150)
	detail.skip:SetHeight(44)
	detail.skip:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", 0, -16)
	ns.KeyLabel(detail.skip, L.KEY_SHIFT_SPACE)
	detail.skip.caption:ClearAllPoints()
	detail.skip.caption:SetPoint("LEFT", detail.skip, "LEFT", 14, 0)
	detail.skip:SetWidth(U.Measure(detail.skip.caption, "GetStringWidth", 60) + U.Measure(detail.skip.keyLabel, "GetStringWidth", 60) + 44)
	detail.post = Skin.Button(frame, L.SELL_POST, function() Post() end, "main")
	detail.post:SetHeight(44)
	detail.post:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -16)
	detail.post:SetPoint("RIGHT", detail.skip, "LEFT", -10, 0)
	ns.KeyLabel(detail.post, L.KEY_SPACE, true)
end

local function Shown()
	list.offset = 0
	entries = Read()
	Draw()
	if selected then
		Ask(selected)
		UpdateSale()
	end
	DrawLevels()
	ShowStrip()
end

local function Closed()
	posting = nil
	look.want, look.sent, look.tries = nil, nil, 0
	detail.last = nil
	if detail.frame then Select(nil) else selected = nil end
end

ns.AddPage("sell", L.SELL, Build, Shown, Closed)
ns.PageHelp("sell", L.HELP_SELL, L.HELP_SELL_PAD)

-- The keys (the pointer over the window): Space posts, Shift+Space passes to the next one, the arrows choose the
-- item above or below. (never Enter: the game's key to chat)
ns.PageKeys("sell", function(key)
	if key == "SPACE" and IsShiftKeyDown() then
		Move(1)
		return true
	end
	if key == "SPACE" then
		if selected then Post() end
		return selected ~= nil
	end
	if key == "UP" or key == "DOWN" then
		Move(key == "UP" and -1 or 1)
		return true
	end
	return false
end)

-- Why an item of your bags is not in the list (the rules of Read, in its order): its words, nil when there is
-- no item there.
local function LeftOutWhy(bag, slot)
	local info = Safe(C_Container.GetContainerItemInfo, bag, slot)
	local id = type(info) == "table" and Clean(info.itemID)
	if not id then return nil end
	if Clean(info.isBound) then return _G.ERR_AUCTION_BOUND_ITEM or L.SELL_LEFT_OTHER end
	local api = type(WandererOutfits) == "table" and WandererOutfits.Pieces
	local ok, pieces = false, nil
	if type(api) == "function" then ok, pieces = pcall(api) end
	if ok and type(pieces) == "table" and pieces[id] then return L.SELL_LEFT_OUTFIT end
	if NotForAuction(id) then return L.SELL_LEFT_KEPT end
	if W.QuestNeed(id) ~= nil then return L.SELL_LEFT_QUEST end
	return L.SELL_LEFT_OTHER
end
ns.SellLeftOutWhy = LeftOutWhy -- (tests)

-- An item of your bags right-clicked at the auction house: this page, the item chosen; one the list leaves out,
-- why said in the page's line.
function ns.SellLocation(location)
	if not (location and location.GetBagAndSlot) then return end
	local bag, slot = location:GetBagAndSlot()
	if not (bag and slot) then return end
	ns.Open("sell")
	for _, entry in ipairs(entries) do
		for _, place in ipairs(entry.slots or {}) do
			if place[1] == bag and place[2] == slot then return Select(entry) end
		end
	end
	-- Left out of the list: said why in the page's line (else the click seems lost).
	local why = LeftOutWhy(bag, slot)
	if not why then return end
	detail.last = { why, "bad" }
	if selected then UpdateSale() else ShowStrip() end
end

-- Events -----------------------------------------------------------------------------------------------------------

local refreshSoon = U.Debounce(0.2, Refresh)
local function Soon() if list and list:IsVisible() then refreshSoon() end end

ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	Pump()
	if selected then UpdateSale() end
end)
-- A search thrown away by the auction house (asked too soon): asked again.
ns.Listen("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
	if look.sent then
		look.want = look.want or look.sent
		look.sent = nil
	end
end)
ns.Listen("COMMODITY_SEARCH_RESULTS_UPDATED", function(id)
	local entry = look.sent
	if entry and entry.commodity and entry.id == id then return Got(entry) end
	if selected and selected.commodity and selected.id == id and selected.searched then Got(selected) end
end)
-- (the same item: its id, suffix and level)
local function SameItem(entry, key)
	local mine = entry and entry.key
	if type(mine) ~= "table" or type(key) ~= "table" then return false end
	return mine.itemID == key.itemID and (mine.itemSuffix or 0) == (key.itemSuffix or 0) and (mine.itemLevel or 0) == (key.itemLevel or 0)
end
ns.Listen("ITEM_SEARCH_RESULTS_UPDATED", function(key)
	local entry = look.sent
	if entry and not entry.commodity and SameItem(entry, key) then return Got(entry) end
	if selected and not selected.commodity and selected.searched and SameItem(selected, key) then Got(selected) end
end)
ns.Listen("AUCTION_HOUSE_AUCTION_CREATED", function()
	local sale = posting
	posting = nil
	if sale then
		local said = L.POSTED:format(sale.name or "", sale.quantity, U.Coins(sale.unit))
		W.Print(said)
		detail.last = { said, "good" }
		-- (looked at again a moment later: your sale among the others)
		C_Timer.After(0.5, function() if selected and selected.id == sale.id then Ask(selected) end end)
	end
	Soon()
	if ns.RefreshTabs then ns.RefreshTabs() end
	if selected then UpdateSale() end
end)
-- A sale refused: said, the button given back.
local function Refused(words)
	local sale = posting
	if not sale then return end
	posting = nil
	local said = L.SELL_REFUSED:format(sale.name or "", words or "")
	-- A price with copper refused: whole silver from now on, the price shown rounded, posted again by you.
	if not copperRefused and (sale.unit % SILVER ~= 0 or (sale.bid and sale.bid % SILVER ~= 0)) then
		copperRefused = true
		if detail.price then detail.price = Keep(detail.price) end
		said = L.SELL_COPPER_REFUSED:format(U.Coins(detail.price or 0))
	end
	W.Print(said)
	detail.last = { said, "bad" }
	if selected then UpdateSale() end
end
ns.Listen("AUCTION_HOUSE_POST_ERROR", function() Refused("") end)
ns.Listen("AUCTION_HOUSE_SHOW_ERROR", function() Refused("") end)
ns.Listen("UI_ERROR_MESSAGE", function(_, message)
	if posting and type(message) == "string" and GetTime() - (posting.at or 0) < 3 then Refused(message) end
end)
ns.Listen("BAG_UPDATE_DELAYED", Soon)
