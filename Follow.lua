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
local waiting = {} -- queries asked while the auction house was busy: owned, bids

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

-- A lower price seen since than yours (each): that price, else nil.
local function Undercut(entry)
	if entry.sold or not entry.buyout then return nil end
	local lowest = ns.Price(entry.id)
	local mine = math.floor(entry.buyout / math.max(1, entry.quantity))
	return lowest ~= nil and lowest < mine and lowest or nil
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
	if ns.Price(entry.id) then return L.CHIP_CHEAPEST, "green", cancel, function() Cancel(entry) end end
	return nil, nil, cancel, function() Cancel(entry) end
end

local function Draw()
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
		if entry.sold then gold = gold + (entry.buyout or entry.bidAmount or 0) else active = active + 1 end
	end
	detail.summary:SetText(L.FOLLOW_SUMMARY:format(active, U.Coins(gold)))
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

-- A bidder's name (the game gives who it is, not how they are called).
local function Bidder(guid)
	guid = Clean(guid)
	if not (guid and GetPlayerInfoByGUID) then return nil end
	local _, _, _, _, _, name = Safe(GetPlayerInfoByGUID, guid)
	return Clean(name)
end

local function ReadOwned()
	sales = {}
	local owned = Safe(AH.GetOwnedAuctions)
	for _, info in ipairs(type(owned) == "table" and owned or {}) do
		local key = info.itemKey
		local id = type(key) == "table" and Clean(key.itemID)
		if id then
			local entry = { auctionID = Clean(info.auctionID), key = key, id = id, link = Clean(info.itemLink), name = "",
				quality = 1, quantity = Clean(info.quantity) or 1, buyout = Clean(info.buyoutAmount), bidAmount = Clean(info.bidAmount),
				bidderName = Bidder(info.bidder), timeLeft = Clean(info.timeLeft), sold = Clean(info.status) == SOLD }
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

-- The page ---------------------------------------------------------------------------------------------------

local function Build(page)
	detail.filters = Skin.Choices(page, { { "all", "" }, { "review", "" }, { "sold", "" }, { "bids", "" } }, function(key)
		filter = key
		list.offset = 0
		Gather()
	end, 32)
	detail.filters:SetPoint("TOPLEFT")
	detail.filters:Select("all")
	detail.summary = Skin.Text(page, "GameTooltipTextSmall", "soft")
	detail.summary:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	detail.summary:SetPoint("TOP", detail.filters, "TOP", 0, -9)
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
	function page:Fit(height) list:Fit(height - 46 - 22) end
	local note = Skin.Text(page, "GameTooltipTextSmall", "muted")
	note:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
	note:SetText(L.CANCEL_NOTE)
end

local function Shown()
	list.offset = 0
	Gather()
	QueryOwned()
	QueryBids()
end

local function Closed()
	sales, bids, rows, canceling = {}, {}, {}, nil
	waiting = {}
end

-- The tab: how many wait for you (cheaper elsewhere, outbid).
local function Badge()
	local _, review = Count()
	return review
end

ns.AddPage("follow", L.FOLLOW, Build, Shown, Closed, Badge)

-- On arrival: what you follow, looked at (the tab says what waits).
function ns.OnArrive()
	QueryOwned()
	QueryBids()
end

ns.Listen("OWNED_AUCTIONS_UPDATED", ReadOwned)
ns.Listen("BIDS_UPDATED", ReadBids)
ns.Listen("AUCTION_CANCELED", function()
	if canceling and W.Print then W.Print(L.CANCELED:format(canceling)) end
	canceling = nil
	QueryOwned()
end)
ns.Listen("AUCTION_HOUSE_AUCTION_CREATED", QueryOwned)
ns.Listen("BID_ADDED", QueryBids)
ns.Listen("ITEM_PURCHASED", QueryBids)
ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	if waiting.owned then QueryOwned() elseif waiting.bids then QueryBids() end
end)
