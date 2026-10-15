local _, ns = ...
local L = ns.L

-- Selling: what your bags can sell, what Wanderer Bags sets aside for the
-- auction house first. An item chosen: its lowest price is looked up, a price
-- just below is offered once (or yours matched), the deposit said; for an
-- item (not a commodity), a starting bid can be asked too. A click posts it:
-- nothing is ever posted without it (the game wants it so). On arrival, the
-- prices of what is set aside for the auction house are looked up by
-- themselves, one by one.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local ROWS = ns.ROWS
local DURATIONS = { 12, 24, 48 }
local COMMODITY = Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity or 2

local list, entries, selected = nil, {}, nil
local detail = {}
local pending -- a price search waiting for the auction house to be ready
local posting -- the last sale asked: what, how many, at what price (and its arguments, for a confirmation)
local queue = {} -- the items for the auction house, their prices looked up by themselves on arrival
local scanning -- the one being looked up: { id, commodity, key }

-- What Wanderer Bags says of an item (kept: never offered; for the auction house: first).
local function Marks() return type(WandererBagsMarks) == "table" and WandererBagsMarks or {} end
local function IsKept(id) return Marks().IsKept and Marks().IsKept(id) or false end
local function IsForAuction(id) return Marks().IsForAuction and Marks().IsForAuction(id) or false end

-- Everything your bags can sell here: a commodity once (all its stacks), identical items once (the same
-- link: posted together), each in its slots.
local function Read()
	local found, commodities, items = {}, {}, {}
	local container = C_Container or {}
	for _, bag in ipairs(U.BagIDs()) do
		for slot = 1, Clean(Safe(container.GetContainerNumSlots, bag)) or 0 do
			local info = Safe(container.GetContainerItemInfo, bag, slot)
			local id = type(info) == "table" and Clean(info.itemID)
			local location = id and ItemLocation and ItemLocation:CreateFromBagAndSlot(bag, slot)
			if location and not Clean(info.isBound) and not IsKept(id) and Clean(Safe(AH.IsSellItemValid, location, false)) then
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
						name = link and link:match("%[(.-)%]") or "", quality = Clean(info.quality) or 1,
						icon = Clean(info.iconFileID), commodity = commodity, auction = IsForAuction(id), slots = { { bag, slot } } }
					found[#found + 1] = entry
					if commodity then commodities[id] = entry elseif link then items[link] = entry end
				end
			end
		end
	end
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

local function Quantity()
	local most = 1
	if selected then most = math.min(Clean(Safe(AH.GetAvailablePostCount, selected.location)) or selected.count, selected.count) end
	return math.max(1, math.min(most, tonumber(detail.quantity:GetText()) or 1)), most
end

-- The deposit and the button, as the inputs stand (a starting bid never above the buyout).
local function UpdateSale()
	if not selected then return end
	local quantity = Quantity()
	local deposit
	if selected.commodity then
		deposit = Clean(Safe(AH.CalculateCommodityDeposit, selected.id, Duration(), quantity))
	else
		deposit = Clean(Safe(AH.CalculateItemDeposit, selected.location, Duration(), quantity))
	end
	detail.durationButton:SetLabel(L.DURATION:format(DURATIONS[Duration()] or 24))
	local buyout, bid = detail.price:Get(), not selected.commodity and detail.bid:Get() or 0
	local vendor = ns.Vendor(selected.link)
	local losing = Losing(selected, buyout, bid)
	-- The money: what you would get, against a merchant; below one, not posted.
	local cheapest = Cheapest(buyout, bid)
	if losing then
		detail.finance:SetText("|cffff6060" .. L.BELOW_MERCHANT:format(U.Coins(Floor(selected))) .. "|r")
	elseif cheapest > 0 then
		local net = ns.Net(cheapest) * quantity
		detail.finance:SetText(vendor > 0 and L.NET_VS:format(U.Coins(net), U.Coins(vendor * quantity))
			or L.NET:format(U.Coins(net)))
	else
		detail.finance:SetText("")
	end
	-- The deposit, lost if it does not sell: said in orange when more than you would gain over a merchant.
	local gain = vendor > 0 and (ns.Net(cheapest) - vendor) * quantity
	if deposit and gain and not losing and cheapest > 0 and deposit > gain then
		detail.deposit:SetText("|cffe0a040" .. L.DEPOSIT_RISK:format(U.Coins(deposit)) .. "|r")
	else
		detail.deposit:SetText(deposit and L.DEPOSIT:format(U.Coins(deposit)) or "")
	end
	detail.post:SetEnabled((buyout > 0 or bid > 0) and (buyout == 0 or bid <= buyout) and not losing)
end

-- Searching ------------------------------------------------------------------------------------

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
	if not Clean(Safe(AH.IsThrottledMessageSystemReady)) then
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

-- The lowest asked (by others, or yours), each.
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

local function Draw()
	if not (list and list:IsVisible()) then return end
	local offset = list:Clamp(#entries)
	for index, row in ipairs(list.rows) do
		local entry = entries[index + offset]
		local price = entry and not entry.header and ns.Price(entry.id)
		-- A price seen below a merchant's: in red (better sold to one).
		local shown = price and U.Coins(price)
		if shown and Losing(entry, price, 0) then shown = "|cffff6060" .. shown .. "|r" end
		row:Fill(entry, entry ~= nil and entry == selected, entry and entry.count and entry.count > 1 and ("x" .. entry.count), shown)
	end
	list.empty:SetShown(#entries == 0)
end

-- An item looked up by itself: its lowest remembered, its row drawn again, the next one asked.
local function Scanned()
	local lowest = Lowest(scanning)
	if lowest then ns.Remember(scanning.id, lowest) end
	scanning = nil
	Draw()
	Search()
end

-- The prices found: said; the price offered once (what you type after is never overwritten).
local function ShowPrices()
	if not selected then return end
	local lowest, onSale, mine = Lowest(selected)
	local offer
	if lowest then
		ns.Remember(selected.id, lowest)
		offer = mine and lowest or Below(lowest)
		-- The market below a merchant: never followed there.
		local floor = Floor(selected)
		local under = offer < floor
		if under then offer = floor end
		detail.status:SetText((mine and L.LOWEST_YOURS or L.LOWEST):format(U.Coins(lowest)) .. "   |cff8c8070"
			.. L.ON_SALE:format(onSale or 1) .. "|r" .. (under and ("\n|cffe0a040" .. L.MARKET_UNDER .. "|r") or ""))
	else
		detail.status:SetText(L.NONE)
		offer = Fallback(selected)
	end
	local first = not selected.offered
	if first then
		selected.offered = true
		detail.price:Set(offer)
	end
	UpdateSale()
	-- Then the items for the auction house, by themselves.
	if first then Search() end
end

local function Select(entry)
	selected = entry
	if not detail.frame then return end
	detail.frame:SetShown(entry ~= nil)
	detail.pick:SetShown(entry == nil)
	if entry then
		detail.icon:SetTexture(entry.icon)
		detail.name:SetText(entry.link or entry.name)
		local remembered, age = ns.Price(entry.id)
		detail.remembered:SetText(remembered and L.REMEMBERED:format(U.Coins(remembered), ns.Age(age)) or "")
		detail.status:SetText(L.SEARCHING)
		entry.key, entry.offered = nil, nil
		local _, most = Quantity()
		detail.quantity:SetText(tostring(most))
		detail.quantityMax:SetText("/ " .. most)
		detail.duration = nil
		local copper = ns.CopperOnly()
		detail.price:ShowCopper(copper)
		detail.bid:ShowCopper(copper)
		-- A starting bid: for an item only (a commodity sells at its price).
		detail.bidLabel:SetShown(not entry.commodity)
		detail.bid:SetShown(not entry.commodity)
		detail.bid:Set(0)
		-- A price at once (the search refines it when it comes).
		detail.price:Set(Fallback(entry))
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
			still.key, still.offered = selected.key, selected.offered
			selected = still
		else
			Select(nil)
		end
	end
	Draw()
end

-- Posting -------------------------------------------------------------------------------------

local Confirm -- (below: a sale confirmed)

local function Post()
	if not selected then return end
	local quantity, buyout = Quantity(), detail.price:Get()
	local bid = not selected.commodity and detail.bid:Get() or 0
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
	if Clean(needsConfirmation) then ns.Ask(L.CONFIRM, Confirm, function() posting = nil end) end
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


-- The page --------------------------------------------------------------------------------------

local function Build(page)
	list = ns.NewList(page, ROWS, Select, Draw)
	list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	list.empty = W.Skin.CreateText(page, "GameTooltipText", 0.6, 0.6, 0.6)
	list.empty:SetPoint("TOP", list, "TOP", 0, -20)
	list.empty:SetText(L.EMPTY)
	local frame = ns.NewDetail(page, list, L.PICK, detail)
	detail.remembered = W.Skin.CreateText(frame, "GameTooltipTextSmall", 0.55, 0.55, 0.55)
	detail.remembered:SetPoint("TOPLEFT", detail.name, "BOTTOMLEFT", 0, -3)
	-- Quantity, price each, a starting bid (items), duration.
	local quantityLabel = ns.Label(frame, L.QUANTITY, detail.status)
	detail.quantity = W.Skin.CreateInput(frame, nil, 5)
	detail.quantity:SetSize(54, 22)
	detail.quantity:SetNumeric(true)
	detail.quantity:SetPoint("LEFT", quantityLabel, "LEFT", ns.VALUE_LEFT, 0)
	detail.quantity:SetScript("OnTextChanged", UpdateSale)
	detail.quantity:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	detail.quantityMax = W.Skin.CreateText(frame, "GameTooltipTextSmall", 0.6, 0.6, 0.6)
	detail.quantityMax:SetPoint("LEFT", detail.quantity, "RIGHT", 6, 0)
	detail.durationButton = W.Skin.CreateLink(frame, L.DURATION:format(24), function()
		detail.duration = Duration() % #DURATIONS + 1
		UpdateSale()
	end, L.DURATION_DESC)
	detail.durationButton:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	detail.durationButton:SetPoint("TOP", detail.quantity, "TOP", 0, -2)
	local priceLabel = ns.Label(frame, L.PRICE_UNIT, quantityLabel, 18)
	detail.price = ns.NewMoney(frame, UpdateSale)
	detail.price:SetPoint("LEFT", priceLabel, "LEFT", ns.VALUE_LEFT, 0)
	detail.bidLabel = ns.Label(frame, L.START_BID, priceLabel, 18)
	detail.bid = ns.NewMoney(frame, UpdateSale)
	detail.bid:SetPoint("LEFT", detail.bidLabel, "LEFT", ns.VALUE_LEFT, 0)
	-- The money (net against a merchant), the deposit, then the button.
	detail.finance = W.Skin.CreateText(frame, "GameTooltipText", 0.9, 0.88, 0.82)
	detail.finance:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 34)
	detail.finance:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	detail.finance:SetJustifyH("LEFT")
	detail.deposit = W.Skin.CreateText(frame, "GameTooltipTextSmall", 0.6, 0.6, 0.6)
	detail.deposit:SetPoint("BOTTOMLEFT", detail.finance, "TOPLEFT", 0, 4)
	detail.deposit:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	detail.deposit:SetJustifyH("LEFT")
	detail.post = ns.Button(frame, L.POST, Post, 130)
	detail.post:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
end

-- Shown: your bags read, the items for the auction house looked up by themselves.
local function Shown()
	list.offset = 0
	Refresh()
	wipe(queue)
	scanning = nil
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

-- Events ----------------------------------------------------------------------------------------

local soon = false
local function Soon()
	if soon or not (list and list:IsVisible()) then return end
	soon = true
	C_Timer.After(0.2, function()
		soon = false
		Refresh()
	end)
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
end)
ns.Listen("AUCTION_HOUSE_POST_ERROR", function() posting = nil end)
ns.Listen("BAG_UPDATE_DELAYED", Soon)
