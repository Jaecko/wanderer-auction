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
-- is set aside for the auction house are looked up by themselves, one by one.

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
local queue = {} -- the items for the auction house, their prices looked up by themselves on arrival
local scanning -- the one being looked up: { id, commodity, key }

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
			drawn[#drawn + 1] = { header = here == "auction" and L.SECTION_AUCTION or L.SECTION_REST }
		end
		drawn[#drawn + 1] = entry
	end
	return drawn
end

-- The game's own starting price: what a merchant gives, times 1.5, in whole silver (one at least).
local function BasePrice(entry)
	local constants = Constants and Constants.AuctionConstants
	local multiplier = constants and constants.DEFAULT_AUCTION_PRICE_MULTIPLIER or 1.5
	local vendor = entry.link and U.SellPrice(entry.link)
	local price = vendor and vendor > 0 and vendor * multiplier or 100
	return math.max(100, math.ceil(price / 100) * 100)
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

-- Just below the lowest (silver when the auction house takes no copper).
local function Below(lowest)
	local price = lowest - 1
	if not ns.CopperOnly() then price = math.floor(price / 100) * 100 end
	return price > 0 and price or lowest
end

local function Duration()
	return detail.duration or tonumber(ns.Settings() and ns.Settings().duration) or 2
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
	if not selected then return 1 end
	return math.max(1, math.min(Clean(Safe(AH.GetAvailablePostCount, selected.location)) or selected.count, selected.count))
end
local function Quantity()
	local most = Most()
	return math.max(1, math.min(most, detail.qty or most)), most
end

-- The price each, as the way chosen says: sell fast (just below the cheapest, or yours matched), at the
-- market's price, or yours. Never below the floor (then raised, and said so): the price, and whether raised.
local function Unit()
	if not selected then return 0, false end
	if detail.mode == "custom" then return detail.price:Get(), false end
	local lowest, mine = selected.lowest, selected.mine
	local price
	if not lowest then
		price = Fallback(selected)
	elseif detail.mode == "market" or mine then
		price = lowest
	else
		price = Below(lowest)
	end
	local floor = Floor(selected)
	if price < floor then return floor, true end
	return price, false
end

-- The money, as things stand: the price, what you receive, the deposit, a merchant's; the button.
local function UpdateSale()
	if not selected then return end
	local quantity, most = Quantity()
	local unit, raised = Unit()
	local bid = not selected.commodity and detail.mode == "custom" and detail.bid:Get() or 0
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
	local deposit
	if selected.commodity then
		deposit = Clean(Safe(AH.CalculateCommodityDeposit, selected.id, Duration(), quantity))
	else
		deposit = Clean(Safe(AH.CalculateItemDeposit, selected.location, Duration(), quantity))
	end
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
	if losing then detail.finance:SetText("|cffff6060" .. L.BELOW_MERCHANT:format(U.Coins(Floor(selected))) .. "|r") end
	detail.post:SetEnabled((unit > 0 or bid > 0) and (unit == 0 or bid <= unit) and not losing)
	detail.what:SetText(L.POST_WHAT:format(quantity, selected.name or ""))
end

-- Searching ------------------------------------------------------------------------------------------

local Lowest -- (below: the lowest price found for an item)

local function Query(entry)
	local key = Safe(AH.GetItemKeyFromItem, entry.location)
	if not key then return false end
	entry.key = key
	local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
	Safe(AH.SendSellSearchQuery, key, sorts, true)
	return true
end

-- The next search: the item you chose, else the next item for the auction house.
local retrying = false
local function Search()
	if not ns.Ready() then
		pending = true
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
	if selected and not selected.key then
		Query(selected)
		return
	end
	-- One look at a time: the next when this one is answered (or, unanswered, a moment later).
	if scanning then return end
	local entry = table.remove(queue, 1)
	if entry and Query(entry) then
		local this = { id = entry.id, commodity = entry.commodity, key = entry.key }
		scanning = this
		C_Timer.After(5, function()
			if scanning == this then
				scanning = nil
				Search()
			end
		end)
	elseif entry then
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

-- The market, on the right.
local function ShowMarket()
	local entry = selected
	local lowest = entry and entry.lowest
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
	local price = ns.Price(entry.id)
	if not price then return L.CHIP_NO_PRICE, "grey" end
	if Losing(entry, price, 0) then return L.CHIP_MERCHANT, "red" end
	if not entry.commodity and entry.count > 1 then return L.CHIP_TOGETHER:format(entry.count), "blue" end
	return nil
end

local function Draw()
	if not (list and list:IsVisible()) then return end
	local offset = list:Clamp(#entries)
	for index, row in ipairs(list.rows) do
		local entry = entries[index + offset]
		local values, chip, tone
		if entry and not entry.header then
			local price = ns.Price(entry.id)
			values = { qty = tostring(entry.count), market = price and U.Coins(price) or "|cff8f8676" .. L.NEVER_SEEN .. "|r" }
			chip, tone = Chip(entry)
		end
		row:Fill(entry, entry ~= nil and entry == selected, values, chip, tone)
	end
	list.empty:SetShown(#entries == 0)
end

-- An item looked up by itself: its lowest remembered, its row drawn again, the next one asked.
-- A look at all of them asked (the button): how many, how many done.
local scan = { total = 0, done = 0 }
local function ShowScan()
	if not detail.scanText then return end
	if scan.total == 0 then return detail.scanText:SetText("") end
	detail.scanText:SetText(scan.done < scan.total and L.SCAN_PROGRESS:format(scan.done, scan.total) or L.SCAN_DONE:format(scan.total))
end

local function Scanned()
	local lowest = Lowest(scanning)
	if lowest then ns.Remember(scanning.id, lowest) end
	scanning = nil
	if scan.total > 0 and scan.done < scan.total then scan.done = scan.done + 1 end
	ShowScan()
	Draw()
	Search()
end

-- The prices of all your items looked up in one go (those for the auction house first), one by one.
function ns.ScanAll()
	wipe(queue)
	for _, entry in ipairs(entries) do
		if not entry.header and entry ~= selected then queue[#queue + 1] = entry end
	end
	scan.total, scan.done = #queue, 0
	ShowScan()
	Search()
end

-- The prices found: the market shown, the price offered as the way chosen says.
local function ShowPrices()
	if not selected then return end
	local lowest, onSale, mine = Lowest(selected)
	selected.lowest, selected.onSale, selected.mine, selected.searched = lowest, onSale, mine and true or false, true
	selected.book = Book(selected)
	if lowest then ns.Remember(selected.id, lowest) end
	-- Your own price: offered once (what you type after is never overwritten).
	if not selected.offered then
		selected.offered = true
		local mode = detail.mode
		detail.mode = "fast"
		detail.price:Set(Unit())
		detail.mode = mode
		Search()
	end
	ShowMarket()
	UpdateSale()
	Draw()
end

local function Select(entry)
	selected = entry
	if not detail.frame then return end
	detail.frame:SetShown(entry ~= nil)
	detail.pick:SetShown(entry == nil)
	if entry then
		detail.icon:Set(entry.icon, entry.quality)
		detail.name:SetText(entry.name or "")
		Skin.Quality(detail.name, entry.quality)
		detail.sub:SetText(L.IN_BAGS:format(entry.count))
		entry.key, entry.offered, entry.lowest, entry.searched, entry.book = nil, nil, nil, false, nil
		detail.mode, detail.qty, detail.duration = "fast", nil, nil
		detail.modes:Select("fast")
		local copper = ns.CopperOnly()
		detail.price:ShowCopper(copper)
		detail.bid:ShowCopper(copper)
		detail.bid:Set(0)
		detail.price:Set(Fallback(entry))
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
			for _, key in ipairs({ "key", "offered", "lowest", "onSale", "mine", "searched", "book" }) do still[key] = selected[key] end
			selected = still
			UpdateSale()
		else
			Select(nil)
		end
	end
	Draw()
end

-- Posting --------------------------------------------------------------------------------------------

local Confirm -- (below: a sale confirmed)

local function Post()
	if not selected then return end
	local quantity = Quantity()
	local buyout = Unit()
	local bid = not selected.commodity and detail.mode == "custom" and detail.bid:Get() or 0
	if buyout <= 0 and bid <= 0 or Losing(selected, buyout, bid) then return end
	local location, duration = selected.location, Duration()
	local needsConfirmation
	if selected.commodity then
		needsConfirmation = Safe(AH.PostCommodity, location, duration, quantity, buyout)
	else
		needsConfirmation = Safe(AH.PostItem, location, duration, quantity, bid > 0 and bid or nil, buyout > 0 and buyout or nil)
	end
	posting = { name = selected.link or selected.name, quantity = quantity, unit = buyout > 0 and buyout or bid, bid = bid,
		buyout = buyout, id = selected.id, commodity = selected.commodity, location = location, duration = duration }
	if Clean(needsConfirmation) then Skin.Ask(L.CONFIRM, Confirm, function() posting = nil end) end
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

-- The page ----------------------------------------------------------------------------------------------

local function Build(page)
	list = Skin.Table(page, {
		nameTitle = L.COL_ITEM,
		width = 390, rows = 26, onClick = Select, onDraw = Draw,
		columns = { { key = "qty", title = L.COL_QTY, width = 40 }, { key = "market", title = L.COL_MARKET, width = 110 } },
	})
	list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	list.empty:SetText(L.EMPTY)
	-- Under the table: the prices of all your items looked up in one go, and how far it is.
	detail.scan = Skin.Button(page, L.SCAN_PRICES, function() ns.ScanAll() end)
	detail.scan:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
	Skin.Tooltip(detail.scan, L.SCAN_PRICES_DESC, "ANCHOR_TOP")
	detail.scanText = Skin.Text(page, "GameTooltipTextSmall", "muted")
	detail.scanText:SetPoint("LEFT", detail.scan, "RIGHT", 10, 0)
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
	detail.modes = Skin.Choices(middle, { { "fast", L.MODE_FAST }, { "market", L.MODE_MARKET }, { "custom", L.MODE_CUSTOM } }, function(key)
		detail.mode = key
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
end

-- Shown: your bags read, the items for the auction house looked up by themselves.
local function Shown()
	list.offset = 0
	Refresh()
	wipe(queue)
	scanning = nil
	scan.total, scan.done = 0, 0
	ShowScan()
	for _, entry in ipairs(entries) do
		if entry.auction then queue[#queue + 1] = entry end
	end
	Search()
end

local function Closed()
	Select(nil)
	wipe(queue)
	pending, posting, scanning = false, nil, nil
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
local function Soon()
	if list and list:IsVisible() then refreshSoon() end
end

ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() if pending then Search() end end)
ns.Listen("COMMODITY_SEARCH_RESULTS_UPDATED", function(id)
	if selected and selected.commodity and id == selected.id then ShowPrices() end
	if scanning and scanning.commodity and scanning.id == id then Scanned() end
end)
ns.Listen("ITEM_SEARCH_RESULTS_UPDATED", function(key)
	if type(key) ~= "table" then return end
	if selected and not selected.commodity and key.itemID == selected.id then ShowPrices() end
	if scanning and not scanning.commodity and scanning.id == key.itemID then Scanned() end
end)
ns.Listen("AUCTION_HOUSE_AUCTION_CREATED", function()
	if posting then
		-- (yours taken as the price only when none lower was seen: above the market, it is not the market's)
		local seen = ns.Price(posting.id)
		if posting.buyout > 0 and not (seen and seen < posting.buyout) then ns.Remember(posting.id, posting.buyout) end
		if W.Print then W.Print(L.POSTED:format(posting.name, posting.quantity, U.Coins(posting.unit))) end
		posting = nil
	end
	Soon()
	if ns.RefreshTabs then ns.RefreshTabs() end
end)
ns.Listen("AUCTION_HOUSE_POST_ERROR", function() posting = nil end)
ns.Listen("BAG_UPDATE_DELAYED", Soon)
