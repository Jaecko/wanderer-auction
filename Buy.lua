local _, ns = ...
local L = ns.L

-- Buying. At the top, a search with all the game offers: words, its
-- categories, its filters, a range of levels, your favorites. Below, the
-- results in a table, sorted by name, level or price (a click on a column's
-- title), each with what a merchant gives (in green when it is more). On the
-- right, the one chosen: a commodity by the quantity (its total, the average,
-- the dearest one you will pay), an item by its auctions, the cheapest first,
-- bought or bid on. Every purchase and every bid is asked first (and the game
-- wants your click for it). One click puts it on your shopping list.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local AUCTION_ROWS = 7
local QUANTITIES = { 1, 5, 20, 100 }

local box, list, results = nil, nil, {}
local chosen, auctions, auctionOffset, auction = nil, {}, 0, nil
local detail, buttons = {}, {}
local pendingSearch, pendingQuery -- waiting for the auction house to be ready
local buying -- a commodity's purchase under way: { id, quantity, name }
local category -- the game's category chosen (its filters), or nil for all

local Ready = ns.Ready

-- What the search keeps between visits: its filters, its sort.
local function Saved()
	local db = ns.DB()
	-- The game's own defaults, once they are there (its auction house loaded).
	if type(db.filters) ~= "table" and AUCTION_HOUSE_DEFAULT_FILTERS then
		db.filters = {}
		for filter, on in pairs(AUCTION_HOUSE_DEFAULT_FILTERS) do db.filters[filter] = on end
	end
	db.sort = db.sort or "price"
	return db
end

local function Filters() return Saved().filters or {} end

local function Sorts()
	local order = Enum.AuctionHouseSortOrder
	local first = ({ price = order.Price, name = order.Name, level = order.Level })[Saved().sort] or order.Price
	local second = first == order.Price and order.Name or order.Price
	return { { sortOrder = first, reverseSort = Saved().sort == "level" }, { sortOrder = second, reverseSort = false } }
end

-- Searching ---------------------------------------------------------------------------------------------

-- The query as set: words, category, filters, levels, sort.
local function Query(text)
	local filters = {}
	for filter, on in pairs(Filters()) do
		if on then filters[#filters + 1] = filter end
	end
	if category and category.implicitFilter then filters[#filters + 1] = category.implicitFilter end
	local minimum, maximum = tonumber(detail.minLevel:GetText()), tonumber(detail.maxLevel:GetText())
	return { searchString = text, sorts = Sorts(), filters = filters, itemClassFilters = category and category.filters or {},
		minLevel = minimum and minimum > 0 and minimum or nil, maxLevel = maximum and maximum > 0 and maximum or nil }
end

local function Browse(text)
	text = strtrim(text or "")
	if text == "" and not category then return end
	if not Ready() then
		pendingSearch = text
		return
	end
	pendingSearch = nil
	list.empty:SetText(L.SEARCHING)
	list.empty:Show()
	Safe(AH.SendBrowseQuery, Query(text))
end

local function Favorites()
	if not Ready() then return end
	list.empty:SetText(L.SEARCHING)
	list.empty:Show()
	Safe(AH.SearchForFavorites, Sorts())
end

local asked = false -- the rest of the results asked, not come yet
local function DrawResults()
	if not (list and list:IsVisible()) then return end
	local offset = list:Clamp(#results)
	for index, row in ipairs(list.rows) do
		local entry = results[index + offset]
		local values
		if entry then
			local vendor = ns.Vendor(entry.link)
			local better = vendor > 0 and entry.minPrice and vendor > entry.minPrice
			values = {
				level = entry.level and entry.level > 1 and tostring(entry.level) or "",
				total = tostring(entry.total or ""),
				price = entry.minPrice and U.Coins(entry.minPrice) or "",
				merchant = vendor > 0 and ((better and "|cff8fe0a2" or "|cff8f8676") .. U.Coins(vendor) .. "|r") or "",
			}
		end
		row:Fill(entry, entry ~= nil and chosen ~= nil and entry.id == chosen.id, values, entry and entry.favorite and L.FAVORITE or nil, "gold")
	end
	list:SetSort(Saved().sort)
	-- Scrolled to the end of what came: the rest asked, as the game does.
	if results[1] and offset + #list.rows >= #results and not asked and not Clean(Safe(AH.HasFullBrowseResults)) then
		asked = true
		Safe(AH.RequestMoreBrowseResults)
	end
end

local function ReadResults()
	asked = false
	results = {}
	local found = Safe(AH.GetBrowseResults)
	for _, result in ipairs(type(found) == "table" and found or {}) do
		local key = result.itemKey
		local id = type(key) == "table" and Clean(key.itemID)
		if id then
			local entry = { key = key, id = id, total = Clean(result.totalQuantity) or 0, minPrice = Clean(result.minPrice),
				name = "", quality = 1, favorite = Clean(Safe(AH.IsFavoriteItem, key)) and true or false,
				level = Clean(key.itemLevel) }
			ns.Describe(entry)
			if entry.minPrice and entry.minPrice > 0 then ns.Remember(id, entry.minPrice) end
			results[#results + 1] = entry
		end
	end
	list.empty:SetText(L.SEARCH_NONE)
	list.empty:SetShown(not results[1])
	DrawResults()
end

-- The auctions of the item chosen (or the cheapest of a commodity).
local function Look()
	if not chosen then return end
	if not Ready() then
		pendingQuery = true
		return
	end
	pendingQuery = false
	-- (by price whatever the list's order: the first one is the cheapest)
	local order = Enum.AuctionHouseSortOrder
	Safe(AH.SendSearchQuery, chosen.key, { { sortOrder = order.Price, reverseSort = false }, { sortOrder = order.Name, reverseSort = false } }, true)
end

-- A commodity ------------------------------------------------------------------------------------------

-- What buying this many costs, from the cheapest up (your own auctions left out): the total, how many can
-- be bought, whether enough, the dearest one paid.
local function Cost(quantity)
	local id = chosen.id
	local count = Clean(Safe(AH.GetNumCommoditySearchResults, id)) or 0
	local left, total, available, top = quantity, 0, 0, 0
	for index = 1, count do
		local result = Safe(AH.GetCommoditySearchResultInfo, id, index)
		if type(result) == "table" then
			local here = (Clean(result.quantity) or 0) - (Clean(result.numOwnerItems) or 0)
			local unit = Clean(result.unitPrice) or 0
			available = available + math.max(0, here)
			local take = math.max(0, math.min(here, left))
			if take > 0 then top = unit end
			total, left = total + take * unit, left - take
		end
	end
	return total, available, left <= 0, top
end

local function Wanted()
	if not chosen then return 1 end
	if detail.want == "all" then
		local _, available = Cost(0)
		return math.max(1, available)
	end
	return math.max(1, tonumber(detail.want) or 1)
end

local function UpdateCommodity()
	if not (chosen and chosen.commodity) then return end
	local quantity = Wanted()
	local total, available, enough, top = Cost(quantity)
	local full = Clean(Safe(AH.HasFullCommoditySearchResults, chosen.id))
	if not enough and not full and not chosen.askedMore then
		-- Not all of them came yet: the rest asked (once until it comes), the total said after.
		chosen.askedMore = true
		Safe(AH.RequestMoreCommoditySearchResults, chosen.id)
		detail.total.value:SetText(L.SEARCHING)
		buttons.buy:SetEnabled(false)
		return
	end
	detail.amounts.buttons[#detail.amounts.buttons].text:SetText(L.ALL_COUNT:format(available))
	detail.total.label:SetText(L.TOTAL_FOR:format(quantity))
	detail.total.value:SetText(enough and U.Coins(total) or "|cffff6060" .. L.NOT_ENOUGH .. "|r")
	detail.average.value:SetText(enough and U.Coins(math.floor(total / quantity)) or "")
	detail.top.value:SetText(enough and U.Coins(top) or "")
	buttons.buy:SetEnabled(enough and quantity > 0)
end

local function ShowCommodity()
	local first = Safe(AH.GetCommoditySearchResultInfo, chosen.id, 1)
	local unit = type(first) == "table" and Clean(first.unitPrice)
	if unit then ns.Remember(chosen.id, unit) end
	local onSale = Clean(Safe(AH.GetCommoditySearchResultsQuantity, chosen.id)) or 0
	detail.sub:SetText(unit and L.ON_SALE:format(onSale) or L.SEARCH_NONE)
	UpdateCommodity()
end

-- An item: its auctions ------------------------------------------------------------------------------

local function DrawAuctions()
	auctionOffset = math.max(0, math.min(auctionOffset, #auctions - AUCTION_ROWS))
	if chosen and auctions[1] and auctionOffset + AUCTION_ROWS >= #auctions and not chosen.askedMore
		and not Clean(Safe(AH.HasFullItemSearchResults, chosen.key)) then
		chosen.askedMore = true
		Safe(AH.RequestMoreItemSearchResults, chosen.key)
	end
	for index, row in ipairs(detail.auctionRows) do
		local entry = auctions[index + auctionOffset]
		row.entry = entry
		row:SetShown(entry ~= nil)
		if entry then
			row.chosen:SetShown(entry == auction)
			row.buyout:SetText(entry.buyout and U.Coins(entry.buyout) or "|cff8f8676" .. L.NO_BUYOUT .. "|r")
			row.bid:SetText(entry.minBid and U.Coins(entry.bid or entry.minBid) or "")
			row.time:SetText((entry.mine and ("|cffffd100" .. L.YOURS .. "|r  ") or "") .. ns.TimeLeft(entry.timeLeft))
		end
	end
	detail.noAuction:SetShown(#auctions == 0)
end

local function UpdateItem()
	local mine = auction and auction.mine
	buttons.buy:SetEnabled(auction ~= nil and auction.buyout ~= nil and not mine)
	local bid = detail.bidMoney:Get()
	buttons.bid:SetEnabled(auction ~= nil and auction.minBid ~= nil and not mine and bid >= (auction.minBid or 0))
end

local function ChooseAuction(entry)
	auction = entry
	if entry and entry.minBid then detail.bidMoney:Set(entry.minBid) end
	DrawAuctions()
	UpdateItem()
end

local function ShowItem()
	auctions = {}
	local count = Clean(Safe(AH.GetNumItemSearchResults, chosen.key)) or 0
	for index = 1, count do
		local result = Safe(AH.GetItemSearchResultInfo, chosen.key, index)
		if type(result) == "table" then
			auctions[#auctions + 1] = { id = Clean(result.auctionID), buyout = Clean(result.buyoutAmount),
				bid = Clean(result.bidAmount), minBid = Clean(result.minBid), quantity = Clean(result.quantity) or 1,
				timeLeft = Clean(result.timeLeft), mine = Clean(result.containsOwnerItem) and true or false,
				link = Clean(result.itemLink) }
		end
	end
	local cheapest = auctions[1] and auctions[1].buyout
	if cheapest then ns.Remember(chosen.id, math.floor(cheapest / math.max(1, auctions[1].quantity))) end
	detail.sub:SetText(auctions[1] and L.ON_SALE:format(#auctions) or L.SEARCH_NONE)
	-- The one chosen, still there: kept; else the cheapest.
	local keep
	for _, entry in ipairs(auctions) do
		if auction and entry.id == auction.id then keep = entry end
	end
	ChooseAuction(keep or auctions[1])
end

local function Choose(entry, mouse)
	-- A right click: a favorite, or one no more.
	if mouse == "RightButton" then
		if entry then
			entry.favorite = not entry.favorite
			Safe(AH.SetFavoriteItem, entry.key, entry.favorite)
			DrawResults()
		end
		return
	end
	chosen, auctions, auction, auctionOffset = entry, {}, nil, 0
	if not detail.frame then return end
	detail.frame:SetShown(entry ~= nil)
	detail.pick:SetShown(entry == nil)
	if entry then
		if entry.name == "" then ns.Describe(entry) end
		detail.icon:Set(entry.icon, entry.quality)
		detail.name:SetText(entry.name or "")
		Skin.Quality(detail.name, entry.quality)
		local vendor = ns.Vendor(entry.link)
		detail.merchant:SetText(vendor > 0 and L.MERCHANT_GIVES:format(U.Coins(vendor)) or "")
		detail.sub:SetText(L.SEARCHING)
		detail.commodity:SetShown(entry.commodity)
		detail.item:SetShown(not entry.commodity)
		buttons.bid:SetShown(not entry.commodity)
		detail.want = 1
		detail.amounts:Select(1)
		detail.bidMoney:Set(0)
		DrawAuctions()
		buttons.buy:SetEnabled(false)
		buttons.bid:SetEnabled(false)
		Look()
	end
	DrawResults()
end

-- Buying and bidding --------------------------------------------------------------------------------------

local function Buy()
	if not chosen then return end
	local name = chosen.link or chosen.name
	if chosen.commodity then
		local quantity = Wanted()
		-- The game tells the final price first (COMMODITY_PRICE_UPDATED), then you agree.
		buying = { id = chosen.id, quantity = quantity, name = name }
		Safe(AH.StartCommoditiesPurchase, chosen.id, quantity)
	elseif auction and auction.buyout then
		local id, amount = auction.id, auction.buyout
		Skin.Ask(L.CONFIRM_BUY:format(name, U.Coins(amount)), function()
			-- A buyout is a bid of the buyout's amount.
			Safe(AH.PlaceBid, id, amount)
			ns.Bought = name
		end)
	end
end

local function Bid()
	if not (chosen and auction) then return end
	local amount = detail.bidMoney:Get()
	if amount < (auction.minBid or 0) then return end
	local id, name = auction.id, chosen.link or chosen.name
	Skin.Ask(L.CONFIRM_BID:format(U.Coins(amount), name), function()
		Safe(AH.PlaceBid, id, amount)
		ns.BidOn = name
	end)
end

-- On your shopping list: a commodity by the quantity asked, an item once.
local function ToShopping()
	if not chosen then return end
	ns.AddToShopping(chosen.id, chosen.commodity and Wanted() or 1)
end

-- The page --------------------------------------------------------------------------------------------------

-- The game's categories, in a menu: each, its sub-categories, theirs.
local function CategoryMenu(owner)
	local function Pick(data)
		category = data
		buttons.category:SetText(data and L.CATEGORY_IS:format(data.name) or L.CATEGORY)
		buttons.category:Fit()
		Browse(box:GetText())
	end
	local function Add(parent, data)
		if data.flags and data.flags.WOW_TOKEN_FLAG then return end
		if data.subCategories and data.subCategories[1] then
			local sub = parent:CreateButton(data.name)
			sub:CreateButton(L.ALL_OF:format(data.name), function() Pick(data) end)
			for _, child in ipairs(data.subCategories) do Add(sub, child) end
		else
			parent:CreateButton(data.name, function() Pick(data) end)
		end
	end
	U.Menu(owner, function(_, root)
		root:CreateButton(L.ALL_CATEGORIES, function() Pick(nil) end)
		root:CreateDivider()
		for _, data in ipairs(AuctionCategories or {}) do Add(root, data) end
	end)
end

-- The game's filters, in a menu of checkboxes.
local function FilterMenu(owner)
	U.Menu(owner, function(_, root)
		local groups = Safe(AH.GetFilterGroups)
		for index, group in ipairs(type(groups) == "table" and groups or {}) do
			if index > 1 then root:CreateDivider() end
			local name = AUCTION_HOUSE_FILTER_CATEGORY_STRINGS and AUCTION_HOUSE_FILTER_CATEGORY_STRINGS[group.category]
			if name then root:CreateTitle(name) end
			for _, filter in ipairs(group.filters or {}) do
				local label = AUCTION_HOUSE_FILTER_STRINGS and AUCTION_HOUSE_FILTER_STRINGS[filter] or tostring(filter)
				root:CreateCheckbox(label, function() return Filters()[filter] and true or false end, function()
					Filters()[filter] = not Filters()[filter]
				end)
			end
		end
	end)
end

local function Build(page)
	-- The search: words, category, filters, levels, favorites, the button.
	buttons.search = Skin.Button(page, L.SEARCH_BUTTON, function() Browse(box:GetText()) end, "main", 90)
	buttons.search:SetHeight(32)
	buttons.search:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
	buttons.favorites = Skin.Button(page, L.FAVORITES, Favorites)
	buttons.favorites:SetHeight(32)
	buttons.favorites:SetPoint("RIGHT", buttons.search, "LEFT", -8, 0)
	detail.maxLevel = W.Skin.CreateInput(page, nil, 3)
	detail.maxLevel:SetSize(40, 32)
	detail.maxLevel:SetNumeric(true)
	detail.maxLevel:SetPoint("RIGHT", buttons.favorites, "LEFT", -12, 0)
	local dash = Skin.Text(page, "GameTooltipTextSmall", "muted")
	dash:SetPoint("RIGHT", detail.maxLevel, "LEFT", -4, 0)
	dash:SetText(L.TO)
	detail.minLevel = W.Skin.CreateInput(page, nil, 3)
	detail.minLevel:SetSize(40, 32)
	detail.minLevel:SetNumeric(true)
	detail.minLevel:SetPoint("RIGHT", dash, "LEFT", -4, 0)
	local levels = Skin.Text(page, "GameTooltipTextSmall", "muted")
	levels:SetPoint("RIGHT", detail.minLevel, "LEFT", -6, 0)
	levels:SetText(L.LEVELS)
	buttons.filters = Skin.Button(page, L.FILTERS, function(self) FilterMenu(self) end)
	buttons.filters:SetHeight(32)
	buttons.filters:SetPoint("RIGHT", levels, "LEFT", -12, 0)
	buttons.category = Skin.Button(page, L.CATEGORY, function(self) CategoryMenu(self) end)
	buttons.category:SetHeight(32)
	buttons.category:SetPoint("RIGHT", buttons.filters, "LEFT", -8, 0)
	box = Skin.CreateInput(page, "WandererAuctionSearch", 60, {
		hint = L.SEARCH_HINT,
		onEnter = function(self)
			self:ClearFocus()
			Browse(self:GetText())
		end,
	})
	box:SetHeight(32)
	box:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	box:SetPoint("RIGHT", buttons.category, "LEFT", -8, 0)
	for _, levelBox in ipairs({ detail.minLevel, detail.maxLevel }) do
		levelBox:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
			Browse(box:GetText())
		end)
	end
	-- The results: sorted by a click on a column's title.
	list = Skin.Table(page, {
		nameTitle = L.COL_ITEM,
		width = 560, rows = 26, onClick = Choose, onDraw = DrawResults, nameSort = "name",
		onSort = function(sort)
			Saved().sort = sort
			Browse(box:GetText())
			DrawResults()
		end,
		columns = {
			{ key = "level", title = L.COL_LEVEL, width = 40, sort = "level" },
			{ key = "total", title = L.COL_AVAILABLE, width = 56 },
			{ key = "price", title = L.COL_PRICE, width = 110, sort = "price" },
			{ key = "merchant", title = L.COL_MERCHANT, width = 96 },
		},
	})
	list:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -14)
	list.empty:SetText(L.SEARCH_START)
	function page:Fit(height) list:Fit(height - 46) end
	list.empty:Show()
	local rule = Skin.Rule(page, true, 0.12)
	rule:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP / 2, 0)
	rule:SetPoint("BOTTOM", page, "BOTTOM", 0, 0)
	detail.pick = Skin.Text(page, "GameTooltipText", "muted")
	detail.pick:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, -60)
	detail.pick:SetText(L.PICK_RESULT)
	local frame = CreateFrame("Frame", nil, page)
	frame:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, 0)
	frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	frame:Hide()
	detail.frame = frame
	detail.icon = Skin.Icon(frame, 40)
	detail.icon:SetPoint("TOPLEFT")
	detail.name = W.Skin.CreateText(frame, "GameFontNormalLarge")
	detail.name:SetPoint("TOPLEFT", detail.icon, "TOPRIGHT", 10, -2)
	detail.name:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	detail.name:SetJustifyH("LEFT")
	detail.sub = Skin.Text(frame, "GameTooltipTextSmall", "muted")
	detail.sub:SetPoint("TOPLEFT", detail.name, "BOTTOMLEFT", 0, -4)
	detail.merchant = Skin.Text(frame, "GameTooltipTextSmall", "muted")
	detail.merchant:SetPoint("LEFT", detail.sub, "RIGHT", 14, 0)
	-- The buttons, at the bottom: to your shopping list, a bid (an item), the purchase.
	buttons.buy = Skin.Button(frame, L.BUY_BUTTON, Buy, "main", 130)
	buttons.buy:SetPoint("BOTTOMRIGHT")
	buttons.bid = Skin.Button(frame, L.BID_BUTTON, Bid, nil, 100)
	buttons.bid:SetHeight(36)
	buttons.bid:SetPoint("RIGHT", buttons.buy, "LEFT", -8, 0)
	buttons.shopping = Skin.Button(frame, L.TO_SHOPPING, ToShopping)
	buttons.shopping:SetHeight(36)
	buttons.shopping:SetPoint("BOTTOMLEFT")
	-- A commodity: how many, what it costs.
	local commodity = CreateFrame("Frame", nil, frame)
	commodity:SetPoint("TOPLEFT", detail.icon, "BOTTOMLEFT", 0, -18)
	commodity:SetPoint("BOTTOMRIGHT", buttons.buy, "TOPRIGHT", 0, 12)
	detail.commodity = commodity
	local howMany = Skin.Caps(commodity, L.HOW_MANY)
	howMany:SetPoint("TOPLEFT")
	local choices = {}
	for _, n in ipairs(QUANTITIES) do choices[#choices + 1] = { n, tostring(n) } end
	choices[#choices + 1] = { "all", L.ALL_COUNT:format(0) }
	detail.amounts = Skin.Choices(commodity, choices, function(key)
		detail.want = key
		detail.amount:SetText("")
		UpdateCommodity()
	end, 32)
	detail.amounts:SetPoint("TOPLEFT", howMany, "BOTTOMLEFT", 0, -6)
	detail.amount = W.Skin.CreateInput(commodity, nil, 6)
	detail.amount:SetSize(64, 32)
	detail.amount:SetNumeric(true)
	detail.amount:SetPoint("LEFT", detail.amounts, "RIGHT", 10, 0)
	detail.amount:SetScript("OnTextChanged", function(self, typed)
		if not typed then return end
		local n = tonumber(self:GetText())
		if n and n > 0 then
			detail.want = n
			detail.amounts:Select(nil)
			UpdateCommodity()
		end
	end)
	detail.amount:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	local cost = Skin.Panel(commodity)
	cost:SetPoint("TOPLEFT", detail.amounts, "BOTTOMLEFT", 0, -16)
	cost:SetPoint("RIGHT", commodity, "RIGHT", 0, 0)
	cost:SetHeight(104)
	detail.total = Skin.SummaryLine(cost, nil, L.TOTAL_FOR:format(1), true)
	detail.total.value:SetTextColor(0.9, 0.88, 0.82)
	detail.average = Skin.SummaryLine(cost, detail.total, L.AVERAGE)
	detail.top = Skin.SummaryLine(cost, detail.average, L.DEAREST)
	local note = Skin.Text(cost, "GameTooltipTextSmall", "muted")
	note:SetPoint("TOPLEFT", detail.top, "BOTTOMLEFT", 0, -8)
	note:SetPoint("RIGHT", cost, "RIGHT", -14, 0)
	note:SetJustifyH("LEFT")
	note:SetText(L.PRICE_CONFIRMED)
	-- An item: its auctions (the cheapest first), a bid.
	local item = CreateFrame("Frame", nil, frame)
	item:SetPoint("TOPLEFT", detail.icon, "BOTTOMLEFT", 0, -18)
	item:SetPoint("BOTTOMRIGHT", buttons.buy, "TOPRIGHT", 0, 12)
	item:EnableMouseWheel(true)
	item:SetScript("OnMouseWheel", function(_, delta)
		auctionOffset = auctionOffset - delta
		DrawAuctions()
	end)
	detail.item = item
	local itsAuctions = Skin.Caps(item, L.ITS_AUCTIONS)
	itsAuctions:SetPoint("TOPLEFT")
	local heads = {}
	for index, text in ipairs({ L.COL_BUYOUT, L.COL_BID, L.COL_TIME }) do
		heads[index] = Skin.Caps(item, text)
	end
	heads[1]:SetPoint("TOPLEFT", itsAuctions, "BOTTOMLEFT", 8, -10)
	heads[2]:SetPoint("LEFT", heads[1], "LEFT", 150, 0)
	heads[3]:SetPoint("TOPRIGHT", item, "TOPRIGHT", -8, -24)
	detail.auctionRows = {}
	for index = 1, AUCTION_ROWS do
		local row = CreateFrame("Button", nil, item)
		row:SetHeight(28)
		row:SetPoint("TOPLEFT", itsAuctions, "BOTTOMLEFT", 0, -26 - (index - 1) * 30)
		row:SetPoint("RIGHT", item, "RIGHT", 0, 0)
		row.ground = row:CreateTexture(nil, "BACKGROUND")
		row.ground:SetAllPoints()
		row.ground:SetColorTexture(1, 1, 1, 0.035)
		row.chosen = row:CreateTexture(nil, "BACKGROUND", nil, 1)
		row.chosen:SetAllPoints()
		row.chosen:SetColorTexture(1, 0.82, 0, 0.1)
		row.buyout = Skin.Text(row, "GameTooltipText", "text")
		row.buyout:SetPoint("LEFT", row, "LEFT", 8, 0)
		row.bid = Skin.Text(row, "GameTooltipTextSmall", "soft")
		row.bid:SetPoint("LEFT", row, "LEFT", 158, 0)
		row.time = Skin.Text(row, "GameTooltipTextSmall", "muted")
		row.time:SetPoint("RIGHT", row, "RIGHT", -8, 0)
		row:SetScript("OnClick", function(self) if self.entry then ChooseAuction(self.entry) end end)
		Skin.ItemTooltip(row, function(self) return self.entry and self.entry.link end)
		detail.auctionRows[index] = row
	end
	detail.noAuction = Skin.Text(item, "GameTooltipTextSmall", "muted")
	detail.noAuction:SetPoint("TOPLEFT", itsAuctions, "BOTTOMLEFT", 0, -30)
	detail.noAuction:SetText(L.SEARCH_NONE)
	local bidCaps = Skin.Caps(item, L.YOUR_BID)
	bidCaps:SetPoint("BOTTOMLEFT", item, "BOTTOMLEFT", 0, 38)
	detail.bidMoney = Skin.Money(item, UpdateItem)
	detail.bidMoney:SetPoint("TOPLEFT", bidCaps, "BOTTOMLEFT", 0, -6)
end

local function Shown()
	DrawResults()
	if box and (box:GetText() or "") == "" and not category then box:SetFocus() end
end

local function Closed()
	Choose(nil)
	results, buying = {}, nil
	pendingSearch, pendingQuery = nil, false
end

ns.AddPage("buy", L.BUY, Build, Shown, Closed)

-- From another addon (Wanderer Bags): this name searched at once (at the auction house, Wanderer's
-- window in use; true when done).
function ns.SearchFor(text)
	if not (ns.AtAuction() and ns.On()) then return false end
	if ns.IsShown() then ns.Open("buy") else ns.UseWanderer("buy") end
	if box then
		box:SetText(text or "")
		box:ClearFocus()
	end
	Browse(text)
	return true
end

-- From the shopping list: this item, chosen at once (its auctions looked at).
function ns.BuyItem(id, name)
	local key = Safe(AH.MakeItemKey, id)
	if not key then return ns.SearchFor(name) end
	ns.Open("buy")
	if box then
		box:SetText(name or "")
		box:ClearFocus()
	end
	local entry = { key = key, id = id, name = name or "", quality = 1 }
	ns.Describe(entry)
	results = { entry }
	list.empty:Hide()
	Choose(entry)
end

-- An item shift-clicked (in your bags, a link) while the Buy page is shown: searched at once, as the
-- game's own window does, the search box chosen or not (once: the box may have taken it already).
local insertedAt -- (when the box took a link itself)
if hooksecurefunc and HandleModifiedItemClick then
	hooksecurefunc("HandleModifiedItemClick", function(link)
		if type(link) ~= "string" or not (IsShiftKeyDown and IsShiftKeyDown()) then return end
		if not (ns.IsShown() and ns.CurrentPage() == "buy" and list and list:IsVisible()) then return end
		if insertedAt == GetTime() then return end
		if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then return end -- (a link for the chat)
		local name = U.LinkName(link)
		if not name then return end
		ns.SearchFor(name)
		-- (the game opens its stack splitter on the same shift-click: put away, it was a search)
		C_Timer.After(0, function()
			if StackSplitFrame and StackSplitFrame:IsShown() then StackSplitFrame:Hide() end
		end)
	end)
end

if hooksecurefunc and ChatEdit_InsertLink then
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		if not (box and box:HasFocus() and type(link) == "string") then return end
		local name = U.LinkName(link)
		if not name then return end
		insertedAt = GetTime()
		box:SetText(name)
		box:ClearFocus()
		Browse(name)
	end)
end

-- Events --------------------------------------------------------------------------------------------------

local function Again()
	if chosen then Look() end
end

local function Visible() return list and list:IsVisible() end

ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	if pendingSearch then Browse(pendingSearch) elseif pendingQuery then Look() end
end)
ns.Listen("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function() if Visible() then ReadResults() end end)
ns.Listen("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function() if Visible() then ReadResults() end end)
ns.Listen("AUCTION_HOUSE_BROWSE_FAILURE", function()
	if not Visible() then return end
	list.empty:SetText(L.SEARCH_NONE)
	list.empty:Show()
end)
ns.Listen("ITEM_KEY_ITEM_INFO_RECEIVED", function()
	if not Visible() then return end
	for _, entry in ipairs(results) do
		if entry.name == "" then ns.Describe(entry) end
	end
	DrawResults()
end)
ns.Listen("COMMODITY_SEARCH_RESULTS_ADDED", function(id)
	if not (chosen and chosen.commodity and id == chosen.id) then return end
	chosen.askedMore = false
	if detail.frame:IsVisible() then UpdateCommodity() end
end)
ns.Listen("ITEM_SEARCH_RESULTS_ADDED", function(key)
	if not (chosen and not chosen.commodity and type(key) == "table" and key.itemID == chosen.id) then return end
	chosen.askedMore = false
	if detail.frame:IsVisible() then ShowItem() end
end)
ns.Listen("COMMODITY_SEARCH_RESULTS_UPDATED", function(id)
	if chosen and chosen.commodity and id == chosen.id and detail.frame:IsVisible() then ShowCommodity() end
end)
ns.Listen("ITEM_SEARCH_RESULTS_UPDATED", function(key)
	if chosen and not chosen.commodity and type(key) == "table" and key.itemID == chosen.id and detail.frame:IsVisible() then
		ShowItem()
	end
end)
-- A commodity: the game's final price, then your word.
ns.Listen("COMMODITY_PRICE_UPDATED", function(_, total)
	if not buying then return end
	local purchase = buying
	Skin.Ask(L.CONFIRM_BUY:format(("%d x %s"):format(purchase.quantity, purchase.name), U.Coins(Clean(total) or 0)),
		function() Safe(AH.ConfirmCommoditiesPurchase, purchase.id, purchase.quantity) end,
		function()
			Safe(AH.CancelCommoditiesPurchase)
			buying = nil
		end)
end)
ns.Listen("COMMODITY_PRICE_UNAVAILABLE", function()
	buying = nil
	if W.Print then W.Print(L.BUY_UNAVAILABLE) end
	Again()
end)
ns.Listen("COMMODITY_PURCHASE_SUCCEEDED", function()
	if buying and W.Print then W.Print(L.BOUGHT:format(("%d x %s"):format(buying.quantity, buying.name))) end
	buying = nil
	Again()
end)
ns.Listen("COMMODITY_PURCHASE_FAILED", function()
	buying = nil
	if W.Print then W.Print(L.BUY_FAILED) end
	Again()
end)
ns.Listen("ITEM_PURCHASED", function()
	if ns.Bought and W.Print then W.Print(L.BOUGHT:format(ns.Bought)) end
	ns.Bought = nil
	Again()
end)
ns.Listen("BID_ADDED", function()
	if ns.BidOn and W.Print then W.Print(L.BID_PLACED:format(ns.BidOn)) end
	ns.BidOn = nil
	Again()
end)
