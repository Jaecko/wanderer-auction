local _, ns = ...
local L = ns.L

-- Buying, with all the game offers: a search by name and/or a category of
-- the game's, its filters (quality, usable...), a range of levels, a sort,
-- your favorites (a right click on a result). A commodity chosen: a quantity,
-- its cost from the cheapest up, bought after the game says the final price
-- and you agree. An item chosen: its auctions, cheapest first; one chosen,
-- bought at its buyout or bid on. Every purchase and every bid asks you
-- first (and the game wants your click for it).

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local RESULT_ROWS = ns.ROWS - 3
local AUCTION_ROWS = 7
local AUCTION_ROW_HEIGHT = 18
local SORTS = { "price", "name", "level" }

local box, list, results = nil, nil, {}
local chosen, auctions, auctionOffset, auction = nil, {}, 0, nil
local detail, links = {}, {}
local pendingSearch, pendingQuery -- waiting for the auction house to be ready
local buying -- a commodity's purchase under way: { id, quantity, name }
local category -- the game's category chosen (its filters), or nil for all
local shopping = false -- the results are the shopping list's
local DrawResults -- (below)
local pendingShopping = false -- its search waiting for the auction house to be ready

local function Ready() return Clean(Safe(AH.IsThrottledMessageSystemReady)) and true or false end

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

-- Searching -------------------------------------------------------------------------------------

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
	pendingSearch, shopping = nil, false
	detail.listStatus:SetText(L.SEARCHING)
	Safe(AH.SendBrowseQuery, Query(text))
end

local function Favorites()
	if not Ready() then return end
	shopping = false
	detail.listStatus:SetText(L.SEARCHING)
	Safe(AH.SearchForFavorites, Sorts())
end

-- The shopping list: what you already carry enough of leaves it; the rest searched at once.
local function ShoppingCount()
	local count = 0
	for _ in pairs(ns.Shopping()) do count = count + 1 end
	return count
end

local function ShoppingLabel()
	local count = ShoppingCount()
	return count > 0 and L.SHOPPING_COUNT:format(count) or L.SHOPPING
end

local function Shopping()
	local keys = {}
	for id, entry in pairs(ns.Shopping()) do
		local have = Clean(Safe(C_Item and C_Item.GetItemCount or GetItemCount, id)) or 0
		if have >= (entry.count or 1) then
			ns.RemoveFromShopping(id)
		else
			local key = Safe(AH.MakeItemKey, id)
			if key then keys[#keys + 1] = key end
		end
	end
	if links.shopping then links.shopping:SetLabel(ShoppingLabel()) end
	shopping = true
	if not keys[1] then
		results = {}
		detail.listStatus:SetText(L.SHOPPING_EMPTY)
		if list then DrawResults() end
		return
	end
	if not Ready() then
		pendingShopping = true
		return
	end
	pendingShopping = false
	detail.listStatus:SetText(L.SEARCHING)
	Safe(AH.SearchForItemKeys, keys, Sorts())
end
function ns.RefreshShopping()
	if links.shopping then links.shopping:SetLabel(ShoppingLabel()) end
end

local asked = false -- the rest of the results asked, not come yet
function DrawResults()
	if not (list and list:IsVisible()) then return end
	local offset = list:Clamp(#results)
	for index, row in ipairs(list.rows) do
		local entry = results[index + offset]
		row:Fill(entry, entry ~= nil and chosen ~= nil and entry.id == chosen.id, entry and entry.total and ("x" .. entry.total),
			entry and entry.minPrice and U.Coins(entry.minPrice))
	end
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
				name = "", quality = 1, favorite = Clean(Safe(AH.IsFavoriteItem, key)) and true or false }
			ns.Describe(entry)
			if entry.minPrice and entry.minPrice > 0 then ns.Remember(id, entry.minPrice) end
			results[#results + 1] = entry
		end
	end
	-- The shopping list: what is not on sale now, said.
	if shopping then
		local missing, shown = {}, {}
		for _, entry in ipairs(results) do shown[entry.id] = true end
		for id in pairs(ns.Shopping()) do
			if not shown[id] then
				missing[#missing + 1] = Clean(Safe(C_Item and C_Item.GetItemNameByID or GetItemInfo, id)) or ("#" .. id)
			end
		end
		detail.listStatus:SetText(missing[1] and L.SHOPPING_MISSING:format(table.concat(missing, ", ")) or "")
		-- (under the results when some came, else in their place)
		detail.listStatus:ClearAllPoints()
		if results[1] then
			detail.listStatus:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -4)
			detail.listStatus:SetPoint("RIGHT", list, "RIGHT", 0, 0)
		else
			detail.listStatus:SetPoint("TOP", list, "TOP", 0, -20)
		end
	else
		detail.listStatus:ClearAllPoints()
		detail.listStatus:SetPoint("TOP", list, "TOP", 0, -20)
		detail.listStatus:SetText(results[1] and "" or L.SEARCH_NONE)
	end
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

-- A commodity ---------------------------------------------------------------------------------

-- What buying this many costs, from the cheapest up (your own auctions left out), and how many can be bought.
local function Cost(quantity)
	local id = chosen.id
	local count = Clean(Safe(AH.GetNumCommoditySearchResults, id)) or 0
	local left, total, available = quantity, 0, 0
	for index = 1, count do
		local result = Safe(AH.GetCommoditySearchResultInfo, id, index)
		if type(result) == "table" then
			local here = (Clean(result.quantity) or 0) - (Clean(result.numOwnerItems) or 0)
			local unit = Clean(result.unitPrice) or 0
			available = available + math.max(0, here)
			local take = math.max(0, math.min(here, left))
			total, left = total + take * unit, left - take
		end
	end
	return total, available, left <= 0
end

local function UpdateCommodity()
	if not (chosen and chosen.commodity) then return end
	local quantity = math.max(1, tonumber(detail.quantity:GetText()) or 1)
	local total, available, enough = Cost(quantity)
	local full = Clean(Safe(AH.HasFullCommoditySearchResults, chosen.id))
	if not enough and not full and not chosen.askedMore then
		-- Not all of them came yet: the rest asked (once until it comes), the total said after.
		chosen.askedMore = true
		Safe(AH.RequestMoreCommoditySearchResults, chosen.id)
		detail.total:SetText(L.SEARCHING)
		detail.buy:SetEnabled(false)
		return
	end
	detail.quantityMax:SetText("/ " .. available .. (full and "" or "+"))
	detail.total:SetText(enough and L.TOTAL:format(U.Coins(total)) or L.NOT_ENOUGH)
	detail.buy:SetEnabled(enough and quantity > 0)
end

local function ShowCommodity()
	local first = Safe(AH.GetCommoditySearchResultInfo, chosen.id, 1)
	local unit = type(first) == "table" and Clean(first.unitPrice)
	if unit then ns.Remember(chosen.id, unit) end
	detail.status:SetText((unit and L.LOWEST:format(U.Coins(unit)) .. "   |cff8c8070" .. L.ON_SALE:format(
		Clean(Safe(AH.GetCommoditySearchResultsQuantity, chosen.id)) or 0) .. "|r" or L.SEARCH_NONE)
		.. ns.MerchantLine(chosen.link, unit))
	UpdateCommodity()
end

-- An item: its auctions --------------------------------------------------------------------------

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
			row.buyout:SetText(entry.buyout and U.Coins(entry.buyout) or L.NO_BUYOUT)
			row.bid:SetText(entry.minBid and L.BID_SHORT:format(U.Coins(entry.bid or entry.minBid)) or "")
			row.time:SetText((entry.mine and ("|cff8c8070" .. L.YOURS .. "|r  ") or "") .. ns.TimeLeft(entry.timeLeft))
		end
	end
	detail.noAuction:SetShown(#auctions == 0)
end

local function UpdateItem()
	local mine = auction and auction.mine
	detail.buy:SetEnabled(auction ~= nil and auction.buyout ~= nil and not mine)
	local bid = detail.bidMoney:Get()
	detail.bidButton:SetEnabled(auction ~= nil and auction.minBid ~= nil and not mine and bid >= (auction.minBid or 0))
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
	detail.status:SetText((cheapest and L.LOWEST:format(U.Coins(cheapest)) .. "   |cff8c8070" .. L.ON_SALE:format(#auctions) .. "|r"
		or L.SEARCH_NONE) .. ns.MerchantLine(chosen.link, cheapest and math.floor(cheapest / math.max(1, auctions[1].quantity))))
	-- The one chosen, still there: kept; else the cheapest.
	local keep
	for _, entry in ipairs(auctions) do
		if auction and entry.id == auction.id then keep = entry end
	end
	ChooseAuction(keep or auctions[1])
end

local function Choose(entry, mouse)
	-- A right click: off the shopping list (shown), else a favorite or one no more.
	if mouse == "RightButton" then
		if entry and shopping then
			ns.RemoveFromShopping(entry.id)
			ns.RefreshShopping()
			for index, result in ipairs(results) do
				if result == entry then table.remove(results, index) break end
			end
			DrawResults()
		elseif entry then
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
		detail.icon:SetTexture(entry.icon)
		detail.name:SetText(entry.link or entry.name)
		detail.status:SetText(L.SEARCHING)
		detail.commodity:SetShown(entry.commodity)
		detail.item:SetShown(not entry.commodity)
		detail.quantity:SetText("1")
		detail.bidMoney:ShowCopper(ns.CopperOnly())
		detail.bidMoney:Set(0)
		DrawAuctions()
		detail.buy:SetEnabled(false)
		Look()
	end
	DrawResults()
end

-- Buying and bidding ------------------------------------------------------------------------------

local function Buy()
	if not chosen then return end
	local name = chosen.link or chosen.name
	if chosen.commodity then
		local quantity = math.max(1, tonumber(detail.quantity:GetText()) or 1)
		-- The game tells the final price first (COMMODITY_PRICE_UPDATED), then you agree.
		buying = { id = chosen.id, quantity = quantity, name = name }
		Safe(AH.StartCommoditiesPurchase, chosen.id, quantity)
	elseif auction and auction.buyout then
		local id, amount = auction.id, auction.buyout
		ns.Ask(L.CONFIRM_BUY:format(name, U.Coins(amount)), function()
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
	ns.Ask(L.CONFIRM_BID:format(U.Coins(amount), name), function()
		Safe(AH.PlaceBid, id, amount)
		ns.BidOn = name
	end)
end

-- The page ---------------------------------------------------------------------------------------

-- The game's categories, in a menu: each, its sub-categories, theirs.
local function CategoryMenu(owner)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
	local function Pick(data)
		category = data
		links.category:SetLabel(data and data.name or L.CATEGORY)
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
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateButton(L.ALL_CATEGORIES, function() Pick(nil) end)
		root:CreateDivider()
		for _, data in ipairs(AuctionCategories or {}) do Add(root, data) end
	end)
end

-- The game's filters, in a menu of checkboxes.
local function FilterMenu(owner)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
	MenuUtil.CreateContextMenu(owner, function(_, root)
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

local function SortLabel() return L.SORT_BY:format(L["SORT_" .. Saved().sort:upper()]) end

local function Build(page)
	-- The words, then the levels.
	detail.maxLevel = W.Skin.CreateInput(page, nil, 3)
	detail.maxLevel:SetSize(34, 22)
	detail.maxLevel:SetNumeric(true)
	detail.maxLevel:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
	detail.minLevel = W.Skin.CreateInput(page, nil, 3)
	detail.minLevel:SetSize(34, 22)
	detail.minLevel:SetNumeric(true)
	detail.minLevel:SetPoint("RIGHT", detail.maxLevel, "LEFT", -4, 0)
	local levels = W.Skin.CreateText(page, "GameTooltipTextSmall", 0.75, 0.68, 0.5)
	levels:SetPoint("RIGHT", detail.minLevel, "LEFT", -4, 0)
	levels:SetText(L.LEVELS)
	box = W.Skin.CreateInput(page, "WandererAuctionSearch", 60)
	box:SetHeight(22)
	box:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	box:SetPoint("RIGHT", levels, "LEFT", -6, 0)
	box.hint = W.Skin.CreateText(box, "GameTooltipTextSmall", 0.5, 0.5, 0.5)
	box.hint:SetPoint("LEFT", box, "LEFT", 8, 0)
	box.hint:SetText(L.SEARCH_HINT)
	box:SetScript("OnTextChanged", function(self) self.hint:SetShown((self:GetText() or "") == "" and not self:HasFocus()) end)
	box:SetScript("OnEditFocusGained", function(self) self.hint:Hide() end)
	box:SetScript("OnEditFocusLost", function(self) self.hint:SetShown((self:GetText() or "") == "") end)
	box:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
		Browse(self:GetText())
	end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	for _, levelBox in ipairs({ detail.minLevel, detail.maxLevel }) do
		levelBox:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
			Browse(box:GetText())
		end)
	end
	-- Category, filters, favorites, sort.
	links.category = W.Skin.CreateLink(page, L.CATEGORY, function(self) CategoryMenu(self) end)
	links.category:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -5, -2)
	links.filters = W.Skin.CreateLink(page, L.FILTERS, function(self) FilterMenu(self) end)
	links.filters:SetPoint("LEFT", links.category, "RIGHT", 2, 0)
	links.favorites = W.Skin.CreateLink(page, L.FAVORITES, Favorites, L.FAVORITES_DESC)
	links.favorites:SetPoint("LEFT", links.filters, "RIGHT", 2, 0)
	links.shopping = W.Skin.CreateLink(page, ShoppingLabel(), Shopping, L.SHOPPING_DESC)
	links.shopping:SetPoint("LEFT", links.favorites, "RIGHT", 2, 0)
	links.sort = W.Skin.CreateLink(page, SortLabel(), function(self)
		local db = Saved()
		for index, name in ipairs(SORTS) do
			if name == db.sort then
				db.sort = SORTS[index % #SORTS + 1]
				break
			end
		end
		self:SetLabel(SortLabel())
		Browse(box:GetText())
	end)
	links.sort:SetPoint("TOPRIGHT", detail.maxLevel, "BOTTOMRIGHT", 5, -2)
	list = ns.NewList(page, RESULT_ROWS, Choose, DrawResults)
	list:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -24)
	detail.listStatus = W.Skin.CreateText(page, "GameTooltipText", 0.6, 0.6, 0.6)
	detail.listStatus:SetPoint("TOP", list, "TOP", 0, -20)
	local frame = ns.NewDetail(page, list, L.PICK_RESULT, detail)
	-- The buy button, for both.
	detail.buy = ns.Button(frame, L.BUY_BUTTON, Buy)
	detail.buy:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
	-- A commodity: a quantity, its total.
	local commodity = CreateFrame("Frame", nil, frame)
	commodity:SetPoint("TOPLEFT", detail.status, "BOTTOMLEFT", 0, 0)
	commodity:SetPoint("BOTTOMRIGHT", detail.buy, "TOPRIGHT", 0, 4)
	detail.commodity = commodity
	local quantityLabel = W.Skin.CreateText(commodity, "GameTooltipTextSmall", 0.75, 0.68, 0.5)
	quantityLabel:SetPoint("TOPLEFT", commodity, "TOPLEFT", 0, -14)
	quantityLabel:SetText(L.QUANTITY)
	detail.quantity = W.Skin.CreateInput(commodity, nil, 6)
	detail.quantity:SetSize(64, 22)
	detail.quantity:SetNumeric(true)
	detail.quantity:SetPoint("LEFT", quantityLabel, "LEFT", ns.VALUE_LEFT, 0)
	detail.quantity:SetScript("OnTextChanged", UpdateCommodity)
	detail.quantity:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	detail.quantityMax = W.Skin.CreateText(commodity, "GameTooltipTextSmall", 0.6, 0.6, 0.6)
	detail.quantityMax:SetPoint("LEFT", detail.quantity, "RIGHT", 6, 0)
	detail.total = W.Skin.CreateText(commodity, "GameTooltipText", 1, 1, 1)
	detail.total:SetPoint("TOPLEFT", quantityLabel, "BOTTOMLEFT", 0, -16)
	-- An item: its auctions, a bid.
	local item = CreateFrame("Frame", nil, frame)
	item:SetPoint("TOPLEFT", detail.status, "BOTTOMLEFT", 0, -6)
	item:SetPoint("BOTTOMRIGHT", detail.buy, "TOPRIGHT", 0, 4)
	item:EnableMouseWheel(true)
	item:SetScript("OnMouseWheel", function(_, delta)
		auctionOffset = auctionOffset - delta
		DrawAuctions()
	end)
	detail.item = item
	detail.auctionRows = {}
	for index = 1, AUCTION_ROWS do
		local row = CreateFrame("Button", nil, item)
		row:SetHeight(AUCTION_ROW_HEIGHT)
		row:SetPoint("TOPLEFT", item, "TOPLEFT", 0, -(index - 1) * AUCTION_ROW_HEIGHT)
		row:SetPoint("RIGHT", item, "RIGHT", 0, 0)
		row.chosen = row:CreateTexture(nil, "BACKGROUND")
		row.chosen:SetAllPoints()
		row.chosen:SetColorTexture(1, 0.82, 0, 0.12)
		row.buyout = W.Skin.CreateText(row, "GameTooltipTextSmall", 1, 1, 1)
		row.buyout:SetPoint("LEFT", row, "LEFT", 4, 0)
		row.time = W.Skin.CreateText(row, "GameTooltipTextSmall", 0.6, 0.6, 0.6)
		row.time:SetPoint("RIGHT", row, "RIGHT", -4, 0)
		row.bid = W.Skin.CreateText(row, "GameTooltipTextSmall", 0.75, 0.68, 0.5)
		row.bid:SetPoint("RIGHT", row.time, "LEFT", -8, 0)
		row:SetScript("OnClick", function(self) if self.entry then ChooseAuction(self.entry) end end)
		row:SetScript("OnEnter", function(self)
			if not (self.entry and self.entry.link) then return end
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:SetHyperlink(self.entry.link)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		detail.auctionRows[index] = row
	end
	detail.noAuction = W.Skin.CreateText(item, "GameTooltipTextSmall", 0.6, 0.6, 0.6)
	detail.noAuction:SetPoint("TOPLEFT", item, "TOPLEFT", 4, -2)
	detail.noAuction:SetText(L.SEARCH_NONE)
	local bidLabel = W.Skin.CreateText(item, "GameTooltipTextSmall", 0.75, 0.68, 0.5)
	bidLabel:SetPoint("TOPLEFT", item, "TOPLEFT", 0, -(AUCTION_ROWS * AUCTION_ROW_HEIGHT + 12))
	bidLabel:SetText(L.YOUR_BID)
	detail.bidMoney = ns.NewMoney(item, UpdateItem)
	detail.bidMoney:SetPoint("LEFT", bidLabel, "LEFT", ns.VALUE_LEFT, 0)
	detail.bidButton = ns.Button(frame, L.BID_BUTTON, Bid)
	detail.bidButton:SetPoint("RIGHT", detail.buy, "LEFT", -6, 0)
	item:HookScript("OnShow", function() detail.bidButton:Show() end)
	item:HookScript("OnHide", function() detail.bidButton:Hide() end)
end

local function Shown()
	DrawResults()
	-- Something to buy and nothing searched yet: the shopping list, searched at once.
	if not results[1] and (box:GetText() or "") == "" and not category and ShoppingCount() > 0 then return Shopping() end
	if box and (box:GetText() or "") == "" and not category then box:SetFocus() end
end

local function Closed()
	Choose(nil)
	results, buying, shopping = {}, nil, false
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

if hooksecurefunc and ChatEdit_InsertLink then
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		if not (box and box:HasFocus() and type(link) == "string") then return end
		local name = link:match("%[(.-)%]")
		if not name then return end
		box:SetText(name)
		box:ClearFocus()
		Browse(name)
	end)
end

-- Events ------------------------------------------------------------------------------------------

local function Again()
	if chosen then Look() end
end

ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	if pendingSearch then Browse(pendingSearch) elseif pendingShopping then Shopping() elseif pendingQuery then Look() end
end)
ns.Listen("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function() if list and list:IsVisible() then ReadResults() end end)
ns.Listen("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function() if list and list:IsVisible() then ReadResults() end end)
ns.Listen("AUCTION_HOUSE_BROWSE_FAILURE", function() if detail.listStatus then detail.listStatus:SetText(L.SEARCH_NONE) end end)
ns.Listen("ITEM_KEY_ITEM_INFO_RECEIVED", function()
	if not (list and list:IsVisible()) then return end
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
	ns.Ask(L.CONFIRM_BUY:format(("%d x %s"):format(purchase.quantity, purchase.name), U.Coins(Clean(total) or 0)),
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
