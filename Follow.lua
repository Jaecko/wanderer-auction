local _, ns = ...
local L = ns.L

-- What you follow: your auctions and your bids, in one table. Each says
-- where it stands in a chip (cheaper elsewhere, the cheapest, sold and on its
-- way by mail; outbid, the best offer) and offers what to do in one button
-- (cancel, its cost asked first; bid again at the least possible; buy it
-- out). A row of filters: all, those to look at, those sold, your bids. The
-- tab says how many wait for you. A canceled auction goes back by mail (the
-- game's rule): to sell it again, take it from your mailbox.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local SOLD = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1

local list, rows = nil, {}
local sales, bids = {}, {}
local filter = "all"
local detail = {}
local canceling -- the name of the auction being canceled, for its message
local waiting = {} -- queries asked while the auction house was busy: owned, bids, look
local looking = false -- their prices looked up, the answer not come yet

local Ready = ns.Ready

local function QueryOwned()
	waiting.owned = not Ready()
	if waiting.owned then return end
	Safe(AH.QueryOwnedAuctions, { { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } })
end

local function QueryBids()
	waiting.bids = not Ready()
	if waiting.bids then return end
	Safe(AH.QueryBids, { { sortOrder = Enum.AuctionHouseSortOrder.TimeRemaining, reverseSort = false } }, {})
end

-- Your price for one: the buyout read as the whole auction's, divided by how many it holds. (Not verified on
-- Forever for a commodity, which the retail game may give for one already: "/wauction debug" writes the owned
-- auctions as the game gives them; this is the one place to change then.)
local function Each(entry)
	if not entry.buyout then return nil end
	return math.floor(entry.buyout / math.max(1, entry.quantity or 1))
end

-- The lowest price of the last hour, else nil: older, it may have changed, nothing is judged on it.
local FRESH = 3600
local function Fresh(entry)
	local price, age = ns.Price(entry.id)
	if price and age <= FRESH then return price end
	return nil
end

-- A lower price seen within the hour than yours (each): that price, else nil.
local function Undercut(entry)
	if entry.sold then return nil end
	local lowest, mine = Fresh(entry), Each(entry)
	return lowest ~= nil and mine ~= nil and lowest < mine and lowest or nil
end

-- What waits for you: auctions cheaper elsewhere, bids outbid.
local function ToReview(entry)
	if entry.bid then return entry.outbid end
	return Undercut(entry) ~= nil
end

local function Count()
	local all, review, sold, bidCount = 0, 0, 0, 0
	for _, entry in ipairs(sales) do
		all = all + 1
		if entry.sold then sold = sold + 1 elseif ToReview(entry) then review = review + 1 end
	end
	for _, entry in ipairs(bids) do
		all, bidCount = all + 1, bidCount + 1
		if ToReview(entry) then review = review + 1 end
	end
	return all, review, sold, bidCount
end

-- The actions ------------------------------------------------------------------------------------------

local function Cancel(entry)
	local cost = Clean(Safe(AH.GetCancelCost, entry.auctionID)) or 0
	Skin.Ask(L.CONFIRM_CANCEL:format(entry.link or entry.name, U.Coins(cost)), function()
		canceling = entry.link or entry.name
		Safe(AH.CancelAuction, entry.auctionID)
	end)
end

-- Taking back what is cheaper elsewhere, in a queue card (as selling everything): one cancel per click, its
-- deposit said first. Only an auction worth it is offered: reposted at the cheapest price now, it would bring
-- more than a merchant gives by more than the deposit lost. Never by itself.
local CARD_WIDTH = 380
local takeBack = { on = false, aside = {}, done = 0 }

-- What taking it back costs and brings: { lowest, cost, gain }, or nil when not worth it.
local function Worth(entry)
	local lowest = Undercut(entry)
	if not lowest or entry.bid or not Clean(Safe(AH.CanCancelAuction, entry.auctionID)) then return nil end
	local cost = Clean(Safe(AH.GetCancelCost, entry.auctionID)) or 0
	local gain = (ns.Net(lowest) - ns.Vendor(entry.link)) * (entry.quantity or 1)
	if gain <= cost then return nil end
	return { lowest = lowest, cost = cost, gain = gain }
end

-- The auctions to take back, in the table's order: { entry, lowest, cost, gain }.
local function TakeBackItems()
	local items = {}
	for _, entry in ipairs(sales) do
		local worth = not takeBack.aside[entry.auctionID] and Worth(entry)
		if worth then
			worth.entry = entry
			items[#items + 1] = worth
		end
	end
	return items
end
ns.TakeBackItems = TakeBackItems -- (tests)

-- (a cancel under way: the next waits for its answer; unanswered, a moment at most)
local function CancelWaiting() return takeBack.at ~= nil and GetTime() - takeBack.at < 10 end

local Draw, TakeBack, UpdateTakeBack -- (below)
-- (the auction house busy: looked at again a moment later, the button given back once it is free)
local recheckSoon = U.Debounce(0.5, function() UpdateTakeBack() end)
function UpdateTakeBack()
	local card = detail.takeBack
	if not card then return end
	local items = TakeBackItems()
	detail.takeBackButton:SetLabel(L.TAKE_BACK_COUNT:format(#items))
	detail.takeBackButton:SetEnabled(#items > 0 or takeBack.on)
	if not takeBack.on then return end
	local cost = 0
	for _, item in ipairs(items) do cost = cost + item.cost end
	card.summary:SetText(L.TAKE_BACK_SUMMARY:format(#items, U.Coins(cost)))
	local first, total = items[1], takeBack.done + #items
	card.next:SetShown(first ~= nil)
	card.skip:SetEnabled(first ~= nil)
	card.progress:SetText(total > 0 and L.QUEUE_DONE:format(takeBack.done, total) or "")
	card.bar:Set(total > 0 and takeBack.done / total or 0)
	if first then
		local entry = first.entry
		card.icon:Set(entry.icon, entry.quality)
		card.name:SetText(L.POST_WHAT:format(entry.quantity or 1, entry.name or ""))
		Skin.Quality(card.name, entry.quality)
		card.cost:SetText(L.TAKE_BACK_COST:format(U.Coins(first.cost), U.Coins(first.lowest)))
		card.gain:SetText(L.TAKE_BACK_GAIN:format(U.Coins(first.gain)))
		card.cancel:SetText(L.TAKE_BACK_CANCEL:format(takeBack.done + 1, total))
	else
		card.cancel:SetText(takeBack.done > 0 and L.TAKE_BACK_FINISHED:format(takeBack.done) or L.TAKE_BACK_NONE)
	end
	-- (busy a moment after each cancel, your auctions read anew: a cancel sent then would be dropped unsaid)
	local ready = Ready()
	card.cancel:SetEnabled(first ~= nil and not CancelWaiting() and ready)
	if first and not ready then recheckSoon() end
end

-- The next one canceled: one per click, never while the last waits for its answer nor the auction house busy.
local function CancelNext()
	if not takeBack.on or CancelWaiting() or Skin.Asking() then return end
	if not Ready() then return UpdateTakeBack() end
	local item = TakeBackItems()[1]
	if not item then return end
	canceling, takeBack.at = item.entry.link or item.entry.name, GetTime()
	takeBack.auction = item.entry.auctionID
	Safe(AH.CancelAuction, item.entry.auctionID)
	UpdateTakeBack()
	-- (unanswered: the button given back once the wait is over)
	C_Timer.After(10.1, UpdateTakeBack)
end

-- The queue card shown (the table beside it) or put away.
function TakeBack(on)
	takeBack.on = on and true or false
	if takeBack.on then takeBack.aside, takeBack.done, takeBack.at = {}, 0, nil end
	detail.takeBack:SetShown(takeBack.on)
	list:SetPoint("RIGHT", detail.page, "RIGHT", takeBack.on and -(CARD_WIDTH + ns.GAP) or 0, 0)
	UpdateTakeBack()
	Draw()
end
ns.TakeBack = function(on) TakeBack(on) end -- (tests)

local function BuildTakeBack(page)
	local card = Skin.Panel(page)
	card:SetWidth(CARD_WIDTH)
	card:SetHeight(270)
	card:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, -46)
	card:Hide()
	detail.takeBack = card
	local pad = 16
	local caps = Skin.Caps(card, L.TAKE_BACK, "kicker")
	caps:SetPoint("TOPLEFT", card, "TOPLEFT", pad, -pad)
	card.summary = Skin.Text(card, "GameTooltipText", "soft")
	card.summary:SetPoint("TOPLEFT", caps, "BOTTOMLEFT", 0, -6)
	card.summary:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
	card.summary:SetJustifyH("LEFT")
	-- The next one: what it is, what canceling costs, what reposting would bring.
	card.next = CreateFrame("Frame", nil, card)
	card.next:SetPoint("TOPLEFT", card.summary, "BOTTOMLEFT", 0, -16)
	card.next:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
	card.next:SetHeight(76)
	local nextCaps = Skin.Caps(card.next, L.QUEUE_NEXT)
	nextCaps:SetPoint("TOPLEFT")
	card.icon = Skin.Icon(card.next, 40)
	card.icon:SetPoint("TOPLEFT", nextCaps, "BOTTOMLEFT", 0, -6)
	card.name = W.Skin.CreateText(card.next, "GameFontNormal")
	card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10, -1)
	card.name:SetPoint("RIGHT", card.next, "RIGHT", 0, 0)
	card.name:SetJustifyH("LEFT")
	if card.name.SetWordWrap then card.name:SetWordWrap(false) end
	card.cost = Skin.Text(card.next, "GameTooltipTextSmall", "warn")
	card.cost:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -4)
	card.cost:SetPoint("RIGHT", card.next, "RIGHT", 0, 0)
	card.cost:SetJustifyH("LEFT")
	card.gain = Skin.Text(card.next, "GameTooltipTextSmall", "soft")
	card.gain:SetPoint("TOPLEFT", card.cost, "BOTTOMLEFT", 0, -3)
	card.gain:SetPoint("RIGHT", card.next, "RIGHT", 0, 0)
	card.gain:SetJustifyH("LEFT")
	-- How far, the button, the quiet choices.
	card.bar = Skin.ProgressLine(card, 3)
	card.bar:SetPoint("TOPLEFT", card.next, "BOTTOMLEFT", 0, -12)
	card.bar:SetWidth(CARD_WIDTH - pad * 2 - 90)
	card.progress = Skin.Text(card, "GameTooltipTextSmall", "muted")
	card.progress:SetPoint("LEFT", card.bar, "RIGHT", 10, 0)
	card.cancel = Skin.Button(card, L.TAKE_BACK_NONE, CancelNext, "main")
	card.cancel:SetPoint("TOPLEFT", card.bar, "BOTTOMLEFT", 0, -14)
	card.cancel:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
	Skin.Tooltip(card.cancel, L.TAKE_BACK_CANCEL_DESC, "ANCHOR_TOP")
	card.skip = Skin.SmallButton(card, L.TAKE_BACK_SKIP, function()
		local item = TakeBackItems()[1]
		if item then takeBack.aside[item.entry.auctionID] = true end
		UpdateTakeBack()
	end, L.TAKE_BACK_SKIP_DESC)
	card.skip:SetPoint("TOPLEFT", card.cancel, "BOTTOMLEFT", 0, -12)
	card.back = Skin.SmallButton(card, L.TAKE_BACK_CLOSE, function() TakeBack(false) end)
	card.back:SetPoint("LEFT", card.skip, "RIGHT", 6, 0)
end

local function BidAgain(entry)
	local amount = entry.minBid
	if not amount then return end
	Skin.Ask(L.CONFIRM_BID:format(U.Coins(amount), entry.link or entry.name), function()
		ns.BidOn = entry.link or entry.name
		Safe(AH.PlaceBid, entry.auctionID, amount)
	end)
end

local function Buyout(entry)
	if not entry.buyout then return end
	Skin.Ask(L.CONFIRM_BUY:format(entry.link or entry.name, U.Coins(entry.buyout)), function()
		ns.Bought = entry.link or entry.name
		Safe(AH.PlaceBid, entry.auctionID, entry.buyout)
	end)
end

-- Drawing ----------------------------------------------------------------------------------------------

-- A row's chip and button: where it stands, what to do.
local function State(entry)
	if entry.bid then
		if entry.outbid then
			return L.CHIP_OUTBID, "red", entry.minBid and L.BID_AT:format(U.Coins(entry.minBid)), function() BidAgain(entry) end
		end
		return L.CHIP_LEADING, "green", entry.buyout and L.BUY_AT:format(U.Coins(entry.buyout)), function() Buyout(entry) end
	end
	if entry.sold then return L.CHIP_SOLD, "blue" end
	local cancel = Clean(Safe(AH.CanCancelAuction, entry.auctionID)) and L.CANCEL_BUTTON or nil
	local lowest = Undercut(entry)
	if lowest then
		-- Cheaper elsewhere; below a merchant's price there, not worth following.
		local vendor = ns.Vendor(entry.link)
		if vendor > 0 and ns.Net(lowest) <= vendor then return L.CHIP_DONT_FOLLOW, "grey", cancel, function() Cancel(entry) end end
		return L.CHIP_UNDERCUT:format(U.Coins(lowest)), "red", cancel, function() Cancel(entry) end
	end
	if Fresh(entry) then return L.CHIP_CHEAPEST, "green", cancel, function() Cancel(entry) end end
	-- (no price of the last hour: nothing claimed; "Look up their prices" asks)
	return L.CHIP_NOT_TODAY, "grey", cancel, function() Cancel(entry) end
end

function Draw()
	if not (list and list:IsVisible()) then return end
	local offset = list:Clamp(#rows)
	for index, row in ipairs(list.rows) do
		local entry = rows[index + offset]
		local values, chip, tone, action, run
		if entry then
			local price = entry.bid and entry.bidAmount or entry.buyout
			values = {
				kind = entry.bid and L.KIND_BID or L.KIND_SALE,
				qty = tostring(entry.quantity or 1),
				price = price and U.Coins(price) or "",
				left = entry.sold and "" or ns.TimeLeft(entry.timeLeft),
			}
			chip, tone, action, run = State(entry)
		end
		row:Fill(entry, false, values, chip, tone, action, run)
	end
	list.empty:SetShown(#rows == 0)
	list.empty:SetText(filter == "all" and L.FOLLOW_EMPTY or L.FILTER_EMPTY)
	-- The filters with their counts; what sold, said on the right.
	local all, review, sold, bidCount = Count()
	detail.filters:SetLabels({ L.FILTER_ALL:format(all), L.FILTER_REVIEW:format(review), L.FILTER_SOLD:format(sold), L.FILTER_BIDS:format(bidCount) })
	local gold, active = 0, 0
	for _, entry in ipairs(sales) do
		-- (what reaches your mail: the winning bid, else the buyout, once the cut taken)
		if entry.sold then gold = gold + ns.Net(entry.bidAmount or entry.buyout or 0) else active = active + 1 end
	end
	detail.summary:SetText(L.FOLLOW_SUMMARY:format(active, U.Coins(gold)))
	detail.look:SetEnabled(active > 0 and not looking)
	UpdateTakeBack()
end

-- The rows as the filter says: what waits for you first.
local function Gather()
	rows = {}
	local function Keep(entry)
		if filter == "review" then return ToReview(entry) and not entry.sold end
		if filter == "sold" then return entry.sold end
		if filter == "bids" then return entry.bid end
		return true
	end
	for _, entry in ipairs(sales) do if Keep(entry) then rows[#rows + 1] = entry end end
	for _, entry in ipairs(bids) do if Keep(entry) then rows[#rows + 1] = entry end end
	table.sort(rows, function(a, b)
		local ra, rb = ToReview(a) and not a.sold, ToReview(b) and not b.sold
		if ra ~= rb then return ra end
		if (a.sold or false) ~= (b.sold or false) then return not a.sold end
		return (a.name or "") < (b.name or "")
	end)
	Draw()
	if ns.RefreshTabs then ns.RefreshTabs() end
end

-- Reading ------------------------------------------------------------------------------------------------

local function ReadOwned()
	sales = {}
	local owned = Safe(AH.GetOwnedAuctions)
	-- (as the game gives them: the price of a commodity, for one or for all, to verify)
	if ns.debugging then ns.Debug("owned auctions", type(owned) == "table" and owned[1], type(owned) == "table" and owned[2]) end
	for _, info in ipairs(type(owned) == "table" and owned or {}) do
		local key = info.itemKey
		local id = type(key) == "table" and Clean(key.itemID)
		if id then
			local entry = { auctionID = Clean(info.auctionID), key = key, id = id, link = Clean(info.itemLink), name = "",
				quality = 1, quantity = Clean(info.quantity) or 1, buyout = Clean(info.buyoutAmount), bidAmount = Clean(info.bidAmount),
				timeLeft = Clean(info.timeLeft), sold = Clean(info.status) == SOLD }
			ns.Describe(entry)
			sales[#sales + 1] = entry
		end
	end
	Gather()
end

local function ReadBids()
	bids = {}
	local me = Clean(Safe(UnitGUID, "player"))
	local found = Safe(AH.GetBids)
	for _, info in ipairs(type(found) == "table" and found or {}) do
		local key = info.itemKey
		local id = type(key) == "table" and Clean(key.itemID)
		if id then
			local bidder = Clean(info.bidder)
			local entry = { auctionID = Clean(info.auctionID), key = key, id = id, link = Clean(info.itemLink), name = "", quality = 1,
				bid = true, bidAmount = Clean(info.bidAmount), minBid = Clean(info.minBid), buyout = Clean(info.buyoutAmount),
				timeLeft = Clean(info.timeLeft), outbid = bidder ~= nil and me ~= nil and bidder ~= me }
			ns.Describe(entry)
			bids[#bids + 1] = entry
		end
	end
	Gather()
end

-- Their prices looked up in one search (your auctions still for sale), as the shopping list does: remembered,
-- each judged against them for the hour.
local function LookUp()
	local keys, seen = {}, {}
	for _, entry in ipairs(sales) do
		local suffix = type(entry.key) == "table" and Clean(entry.key.itemSuffix) or 0
		local kind = entry.id .. ":" .. tostring(suffix)
		if not entry.sold and type(entry.key) == "table" and not seen[kind] then
			seen[kind] = true
			keys[#keys + 1] = entry.key
		end
	end
	if not keys[1] then return end
	waiting.look = not Ready() or nil
	if waiting.look then return end
	looking = true
	ns.browsing = "follow"
	Safe(AH.SearchForItemKeys, keys, { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } })
	Draw()
end

local function ReadLooked()
	looking = false
	-- (one row per variant: the cheapest of an item remembered)
	local low = {}
	local found = Safe(AH.GetBrowseResults)
	for _, result in ipairs(type(found) == "table" and found or {}) do
		local id = type(result.itemKey) == "table" and Clean(result.itemKey.itemID)
		local price = Clean(result.minPrice)
		if id and price and price > 0 then low[id] = math.min(low[id] or price, price) end
	end
	for id, price in pairs(low) do ns.Remember(id, price) end
	Gather()
end

-- The page ---------------------------------------------------------------------------------------------------

local function Build(page)
	detail.page = page
	detail.filters = Skin.Choices(page, { { "all", "" }, { "review", "" }, { "sold", "" }, { "bids", "" } }, function(key)
		filter = key
		list.offset = 0
		Gather()
	end, 32)
	detail.filters:SetPoint("TOPLEFT")
	detail.filters:Select("all")
	-- On the right, quiet: their prices looked up now, and what sold beside it.
	detail.look = Skin.SmallButton(page, L.FOLLOW_LOOK, LookUp, L.FOLLOW_LOOK_DESC)
	detail.look:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	detail.look:SetPoint("TOP", detail.filters, "TOP", 0, -4)
	-- Beside it: the auctions cheaper elsewhere taken back, one by one, in a queue card.
	detail.takeBackButton = Skin.SmallButton(page, L.TAKE_BACK_COUNT:format(0), function() TakeBack(not takeBack.on) end, L.TAKE_BACK_DESC)
	detail.takeBackButton:SetPoint("RIGHT", detail.look, "LEFT", -6, 0)
	detail.summary = Skin.Text(page, "GameTooltipTextSmall", "soft")
	detail.summary:SetPoint("RIGHT", detail.takeBackButton, "LEFT", -16, 0)
	list = Skin.Table(page, {
		nameTitle = L.COL_ITEM,
		width = 1040, rows = 26, action = 150, onClick = function() end, onDraw = Draw,
		columns = {
			{ key = "kind", title = L.COL_KIND, width = 110, justify = "LEFT" },
			{ key = "qty", title = L.COL_QTY, width = 50 },
			{ key = "price", title = L.COL_PRICE, width = 130 },
			{ key = "left", title = L.COL_TIME, width = 110 },
		},
	})
	list:SetPoint("TOPLEFT", detail.filters, "BOTTOMLEFT", 0, -14)
	list:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	-- (the cancel rule, which only matters once: under the page's "Help")
	function page:Fit(height) list:Fit(height - 46) end
	BuildTakeBack(page)
end

local function Shown()
	list.offset = 0
	Gather()
	QueryOwned()
	QueryBids()
end

local function Closed()
	sales, bids, rows, canceling = {}, {}, {}, nil
	waiting, looking = {}, false
	if detail.takeBack then TakeBack(false) end
end

-- The tab: how many wait for you (cheaper elsewhere, outbid).
local function Badge()
	local _, review = Count()
	return review
end

ns.AddPage("follow", L.FOLLOW, Build, Shown, Closed, Badge)
ns.PageHelp("follow", L.HELP_FOLLOW)

-- On arrival: what you follow, looked at (the tab says what waits).
function ns.OnArrive()
	QueryOwned()
	QueryBids()
end

ns.Listen("OWNED_AUCTIONS_UPDATED", ReadOwned)
ns.Listen("BIDS_UPDATED", ReadBids)
ns.Listen("AUCTION_CANCELED", function()
	-- (one taken back from the queue: counted, the next one offered)
	-- (never offered again while your auctions are read anew: the auction house may wait before answering)
	if takeBack.at then
		takeBack.done, takeBack.at = takeBack.done + 1, nil
		if takeBack.auction then takeBack.aside[takeBack.auction] = true end
		UpdateTakeBack()
	end
	if canceling then W.Print(L.CANCELED:format(canceling)) end
	canceling = nil
	QueryOwned()
end)
local queryOwnedSoon = U.Debounce(2, function()
	if ns.SellingAll and ns.SellingAll() then return end
	QueryOwned()
end)
ns.Listen("AUCTION_HOUSE_AUCTION_CREATED", function() queryOwnedSoon() end)
-- (the names the game had not yet: the lines described again when they come, drawn once for a burst)
local gatherSoon = U.Debounce(0.3, function() Gather() end)
ns.Listen("ITEM_KEY_ITEM_INFO_RECEIVED", function(itemID)
	local again = false
	for _, set in ipairs({ sales, bids }) do
		for _, entry in ipairs(set) do
			if not entry.described and (itemID == nil or entry.id == itemID) and ns.Describe(entry) then again = true end
		end
	end
	if again then gatherSoon() end
end)
ns.Listen("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
	if not looking then return end
	if ns.browsing == "follow" then return ReadLooked() end
	-- (another page's search took its place: no answer will come, the button given back)
	looking = false
	Draw()
end)
ns.Listen("AUCTION_HOUSE_BROWSE_FAILURE", function()
	if not looking then return end
	looking = false
	Draw()
end)
ns.Listen("BID_ADDED", QueryBids)
ns.Listen("ITEM_PURCHASED", QueryBids)
ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	if waiting.owned then QueryOwned() elseif waiting.bids then QueryBids() elseif waiting.look and list and list:IsVisible() then LookUp() end
	UpdateTakeBack()
end)
