local _, ns = ...
local L = ns.L

-- Buying, as the game's own auction house: on the left, its categories and
-- their subcategories (the game's own list, else the item classes: weapons by
-- type, armor by type and slot...), the one chosen in gold; at the top, the
-- words to search within it, a range of levels, the rarities shown, usable
-- only, your favorites. Below, the results in a table, sorted by name, level
-- or price (a click on a column's title), each with its usual price (14 days:
-- the price in green when well under it, red when well over) and what a
-- merchant gives (in green when it is more). A result chosen takes the
-- table's place (a button goes back): a commodity by the quantity (its total,
-- the average, the dearest one you will pay), an item by its auctions, the
-- cheapest first, bought or bid on. Every purchase and every bid is asked
-- first (and the game wants your click for it). One click puts it on your
-- shopping list.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local AUCTION_ROWS = 7
local QUANTITIES = { 1, 5, 20, 100 }
local RAIL_WIDTH, RAIL_ROW, RAIL_ROWS = 180, 22, 40
local USUAL_GOOD, USUAL_DEAR = 0.9, 1.25 -- a price under 90 % of its usual one: good; over 125 %: dear

local box, list, results = nil, nil, {}
local chosen, auctions, auctionOffset, auction = nil, {}, 0, nil
local detail, buttons = {}, {}
local pendingSearch, pendingQuery -- waiting for the auction house to be ready
-- This page's search sent, its answer not read yet (sent again when the page comes back and another page's
-- search took its place); that answer come while the page was put away (read when it comes back).
local again, unread = nil, false
local buying -- a commodity's purchase under way: { id, quantity, name }
local category -- the game's category chosen (its filters), or nil for all

local Ready = ns.Ready

-- What the search keeps between visits, for this character: its filters, its sort.
local function Saved()
	local db = ns.Mine()
	-- (once the whole account's: let go, each character starts from the game's)
	local account = ns.DB()
	account.filters, account.sort = nil, nil
	-- The game's own defaults, once they are there (its auction house loaded).
	if type(db.filters) ~= "table" then
		db.filters = {}
		for filter, on in pairs(AUCTION_HOUSE_DEFAULT_FILTERS or {}) do db.filters[filter] = on end
	end
	db.sort = db.sort or "price"
	return db
end

local function Filters() return Saved().filters or {} end

-- The game's filters shown at the top: the rarities (Poor to Epic) and usable only, by their names in the game's
-- list (none of them where the game has no such list: its saved filters then, as they are).
local QUALITIES = { { "PoorQuality", 0 }, { "CommonQuality", 1 }, { "UncommonQuality", 2 }, { "RareQuality", 3 }, { "EpicQuality", 4 } }
local function FilterValue(name)
	local filters = Enum and Enum.AuctionHouseFilter
	return type(filters) == "table" and filters[name] or nil
end

-- The categories --------------------------------------------------------------------------------------------
-- A tree of { name, filters (the game's item class filters), implicitFilter, children, depth }: the game's own
-- (AuctionCategories, once its auction house is loaded), else made from the item classes.

local tree, treeFromGame -- (made once; again once the game's own list is there)
local expanded = {} -- the categories opened, this visit

local function GameTree()
	local source = rawget(_G, "AuctionCategories")
	if type(source) ~= "table" or not source[1] then return nil end
	local function Copy(data, depth)
		if type(data) ~= "table" or type(data.name) ~= "string" then return nil end
		if type(data.flags) == "table" and data.flags.WOW_TOKEN_FLAG then return nil end
		local node = { name = data.name, filters = data.filters, implicitFilter = data.implicitFilter, depth = depth, children = {} }
		for _, child in ipairs(type(data.subCategories) == "table" and data.subCategories or {}) do
			local made = Copy(child, depth + 1)
			if made then node.children[#node.children + 1] = made end
		end
		return node
	end
	local made = {}
	for _, data in ipairs(source) do made[#made + 1] = Copy(data, 0) end
	return made[1] and made or nil
end

-- (the classic item classes in the game's order: weapons, armor, containers, consumables, trade goods,
-- projectiles, quivers, recipes, reagents, gems, miscellaneous, quest items)
local CLASSES = { 2, 4, 1, 0, 7, 6, 11, 9, 5, 3, 15, 12 }
local ARMOR = 4
-- Armor by slot, for each kind of armor (cloth: the cloaks too; miscellaneous: the jewels and what is held).
local SLOTS = { { 1, "INVTYPE_HEAD" }, { 3, "INVTYPE_SHOULDER" }, { 5, "INVTYPE_CHEST", 20 }, { 6, "INVTYPE_WAIST" },
	{ 7, "INVTYPE_LEGS" }, { 8, "INVTYPE_FEET" }, { 9, "INVTYPE_WRIST" }, { 10, "INVTYPE_HAND" } }
local ARMOR_SLOTS = { [0] = { { 2, "INVTYPE_NECK" }, { 11, "INVTYPE_FINGER" }, { 12, "INVTYPE_TRINKET" }, { 23, "INVTYPE_HOLDABLE" } },
	[1] = SLOTS, [2] = SLOTS, [3] = SLOTS, [4] = SLOTS }

local function ClassName(class)
	return U.Clean(U.Safe(C_Item and C_Item.GetItemClassInfo or rawget(_G, "GetItemClassInfo"), class))
end
local function SubclassName(class, sub)
	return U.Clean(U.Safe(C_Item and C_Item.GetItemSubClassInfo or rawget(_G, "GetItemSubClassInfo"), class, sub))
end

local function ClassTree()
	local made = {}
	for _, class in ipairs(CLASSES) do
		local name = ClassName(class)
		if type(name) == "string" and name ~= "" then
			local node = { name = name, filters = { { classID = class } }, depth = 0, children = {} }
			for sub = 0, 20 do
				local subName = SubclassName(class, sub)
				if type(subName) == "string" and subName ~= "" then
					local child = { name = subName, filters = { { classID = class, subClassID = sub } }, depth = 1, children = {} }
					for _, slot in ipairs(class == ARMOR and ARMOR_SLOTS[sub] or {}) do
						local word = _G[slot[2]]
						if type(word) == "string" then
							local filters = { { classID = class, subClassID = sub, inventoryType = slot[1] } }
							if slot[3] then filters[2] = { classID = class, subClassID = sub, inventoryType = slot[3] } end
							child.children[#child.children + 1] = { name = word, filters = filters, depth = 2, children = {} }
						end
					end
					node.children[#node.children + 1] = child
				end
			end
			made[#made + 1] = node
		end
	end
	return made
end

-- The tree, the game's once it is there.
local function Tree()
	if not tree or not treeFromGame then
		local game = GameTree()
		if game then
			tree, treeFromGame = game, true
		elseif not tree then
			tree = ClassTree()
		end
	end
	return tree
end
ns.BuyCategories = Tree -- (tests)

-- The rows of the rail: all categories, then each one, its children under it when opened.
local function RailRows()
	local rows = { { all = true, depth = 0, children = {} } }
	local function Add(nodes)
		for _, node in ipairs(nodes) do
			rows[#rows + 1] = node
			if expanded[node] then Add(node.children) end
		end
	end
	Add(Tree())
	return rows
end

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
	if FilterValue("PoorQuality") then
		-- The rarities lit (none lit: all of them), usable only when asked.
		local qualities = {}
		for _, quality in ipairs(QUALITIES) do
			local value = FilterValue(quality[1])
			if value and Filters()[value] then qualities[#qualities + 1] = value end
		end
		if not qualities[1] then
			for _, quality in ipairs(QUALITIES) do qualities[#qualities + 1] = FilterValue(quality[1]) end
		end
		for _, value in ipairs(qualities) do filters[#filters + 1] = value end
		local usable = FilterValue("UsableOnly")
		if usable and Filters()[usable] then filters[#filters + 1] = usable end
	else
		for filter, on in pairs(Filters()) do
			if on then filters[#filters + 1] = filter end
		end
	end
	if category and category.implicitFilter then filters[#filters + 1] = category.implicitFilter end
	local minimum, maximum = tonumber(detail.minLevel:GetText()), tonumber(detail.maxLevel:GetText())
	return { searchString = text, sorts = Sorts(), filters = filters, itemClassFilters = category and category.filters or {},
		minLevel = minimum and minimum > 0 and minimum or nil, maxLevel = maximum and maximum > 0 and maximum or nil }
end

-- Your recent searches (the words), the last first, for the whole account: 8 kept, one of them clicked to search
-- again, forgotten by a right click.
local RECENT_KEPT, RECENT_LETTERS = 8, 20
local recent = {} -- the buttons
local TOP, TOP_RECENT = 88, 116 -- where the table starts: under the filters, under your recent searches too
local function Recent()
	local db = ns.DB()
	db.searches = type(db.searches) == "table" and db.searches or {}
	return db.searches
end
ns.RecentSearches = Recent -- (tests)

local DrawRecent, Choose -- (below)
local function Remember(text)
	local searches, folded = Recent(), text:lower()
	for index = #searches, 1, -1 do
		if type(searches[index]) ~= "string" or searches[index]:lower() == folded then table.remove(searches, index) end
	end
	table.insert(searches, 1, text)
	while #searches > RECENT_KEPT do table.remove(searches) end
	DrawRecent()
end

local function Browse(text)
	text = strtrim(text or "")
	if text == "" and not category then return end
	if text ~= "" then Remember(text) end
	-- (a result chosen: the results' place given back, else the answer is never read, Ours)
	if chosen then Choose(nil) end
	if not Ready() then
		pendingSearch = text
		return
	end
	pendingSearch = nil
	Skin.Waiting(list.empty, L.SEARCHING)
	list.empty:Show()
	ns.browsing, again, unread = "buy", function() Browse(text) end, false
	Safe(AH.SendBrowseQuery, Query(text))
end

local function Favorites()
	if not Ready() then return end
	if chosen then Choose(nil) end
	Skin.Waiting(list.empty, L.SEARCHING)
	list.empty:Show()
	ns.browsing, again, unread = "buy", Favorites, false
	Safe(AH.SearchForFavorites, Sorts())
end

local asked = false -- the rest of the results asked, not come yet
local function DrawResults()
	if not (list and list:IsVisible()) then return end
	local offset = list:Clamp(#results)
	-- (no usual price for any of them, as for most searches of a buyer: the column left blank, not a wall of "-")
	local anyUsual = false
	for _, entry in ipairs(results) do
		if ns.Market(entry.id) then
			anyUsual = true
			break
		end
	end
	for index, row in ipairs(list.rows) do
		local entry = results[index + offset]
		local values
		if entry then
			if entry.name == "" then ns.Describe(entry) end
			local vendor = ns.Vendor(entry.link)
			local better = vendor > 0 and entry.minPrice and vendor > entry.minPrice
			-- (the price against its usual one: green well under it, red well over)
			local usual = ns.Market(entry.id)
			local price = entry.minPrice and U.Coins(entry.minPrice) or ""
			local tone = usual and entry.minPrice and (entry.minPrice <= usual * USUAL_GOOD and "good" or entry.minPrice >= usual * USUAL_DEAR and "bad")
			if tone then price = Skin.Colorize(price, tone) end
			values = {
				level = entry.level and entry.level > 1 and tostring(entry.level) or "",
				total = tostring(entry.total or ""),
				price = price,
				usual = usual and U.Coins(usual) or (anyUsual and Skin.Colorize("-", "muted") or ""),
				merchant = vendor > 0 and Skin.Colorize((better and "+ " or "") .. U.Coins(vendor), better and "good" or "muted") or "",
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
	asked, again, unread = false, nil, false
	results = {}
	local cheapest = {}
	local found = Safe(AH.GetBrowseResults)
	for _, result in ipairs(type(found) == "table" and found or {}) do
		local key = result.itemKey
		local id = type(key) == "table" and Clean(key.itemID)
		if id then
			local entry = { key = key, id = id, total = Clean(result.totalQuantity) or 0, minPrice = Clean(result.minPrice),
				name = "", quality = 1, favorite = Clean(Safe(AH.IsFavoriteItem, key)) and true or false,
				level = Clean(key.itemLevel) }
			if #results < 40 then ns.Describe(entry) end
			-- (one row per variant of an item: the cheapest of them remembered, below)
			if entry.minPrice and entry.minPrice > 0 then cheapest[id] = math.min(cheapest[id] or entry.minPrice, entry.minPrice) end
			results[#results + 1] = entry
		end
	end
	for id, price in pairs(cheapest) do ns.Remember(id, price) end
	Skin.Waiting(list.empty)
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
	pendingQuery, chosen.unread = false, nil
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
	local allButton = detail.amounts.buttons[#detail.amounts.buttons]
	allButton.text:SetText(L.ALL_COUNT:format(available))
	allButton:SetWidth(math.max(56, U.Measure(allButton.text, "GetStringWidth", 50) + 24))
	local barWidth = 3
	for _, button in ipairs(detail.amounts.buttons) do barWidth = barWidth + (button:GetWidth() or 56) + 3 end
	detail.amounts:SetWidth(barWidth)
	detail.total.label:SetText(L.TOTAL_FOR:format(quantity))
	detail.total.value:SetText(enough and U.Coins(total) or Skin.Colorize(L.NOT_ENOUGH, "bad"))
	detail.average.value:SetText(enough and U.Coins(math.floor(total / quantity)) or "")
	detail.top.value:SetText(enough and U.Coins(top) or "")
	buttons.buy:SetEnabled(enough and quantity > 0)
end

local function ShowCommodity()
	local first = Safe(AH.GetCommoditySearchResultInfo, chosen.id, 1)
	local unit = type(first) == "table" and Clean(first.unitPrice)
	if unit then ns.Remember(chosen.id, unit) end
	local onSale = Clean(Safe(AH.GetCommoditySearchResultsQuantity, chosen.id)) or 0
	Skin.Waiting(detail.sub)
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
			row.buyout:SetText(entry.buyout and U.Coins(entry.buyout) or Skin.Colorize(L.NO_BUYOUT, "muted"))
			row.bid:SetText(entry.minBid and U.Coins(entry.bid or entry.minBid) or "")
			row.time:SetText((entry.mine and (Skin.Colorize(L.YOURS, "gold") .. "  ") or "") .. ns.TimeLeft(entry.timeLeft))
		end
	end
	detail.noAuction:SetShown(#auctions == 0)
	if detail.auctionBar then detail.auctionBar:Set(#auctions, AUCTION_ROWS, auctionOffset) end
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
	Skin.Waiting(detail.sub)
	detail.sub:SetText(auctions[1] and L.ON_SALE:format(#auctions) or L.SEARCH_NONE)
	-- The one chosen, still there: kept; else the cheapest.
	local keep
	for _, entry in ipairs(auctions) do
		if auction and entry.id == auction.id then keep = entry end
	end
	ChooseAuction(keep or auctions[1])
end

-- A result's card (its right click, its "⋯"): a favorite (the game's own) or one no more, to the shopping list.
local function ResultCard(owner, entry, atCursor)
	Skin.ActionCard(owner, { title = entry.name ~= "" and entry.name or nil, atCursor = atCursor, rows = {
		{ text = entry.favorite and L.FAVORITE_OFF or L.FAVORITE_ON, glyph = "star", onClick = function()
			entry.favorite = not entry.favorite
			Safe(AH.SetFavoriteItem, entry.key, entry.favorite)
			DrawResults()
		end },
		{ text = L.TO_SHOPPING, glyph = "plus", onClick = function() ns.AskShopping(entry.id) end },
	} })
end

function Choose(entry, mouse)
	if mouse == "RightButton" then
		if entry then ResultCard(nil, entry, true) end
		return
	end
	chosen, auctions, auction, auctionOffset = entry, {}, nil, 0
	if not detail.frame then return end
	-- (the one chosen takes the results' place, as in the game's window; back: the results as they were)
	detail.frame:SetShown(entry ~= nil)
	list:SetShown(entry == nil)
	if entry then
		if not entry.described then ns.Describe(entry) end
		detail.icon:Set(entry.icon, entry.quality)
		detail.name:SetText(entry.name or "")
		Skin.Quality(detail.name, entry.quality)
		local vendor = ns.Vendor(entry.link)
		local usual = ns.Market(entry.id)
		local _, age = ns.Price(entry.id)
		detail.usual.value:SetText(usual and U.Coins(usual) or Skin.Colorize(L.NEVER_SEEN, "muted"))
		detail.seen.value:SetText(age and (ns.Fresh(entry.id) .. ns.Age(age)) or "")
		detail.merchant.value:SetText(vendor > 0 and U.Coins(vendor) or L.NO_MERCHANT)
		Skin.Waiting(detail.sub, L.SEARCHING)
		detail.commodity:SetShown(entry.commodity)
		detail.item:SetShown(not entry.commodity)
		buttons.bid:SetShown(not entry.commodity)
		detail.want = 1
		detail.amounts:Select(1)
		detail.amount:SetText("")
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

-- The rail of categories: one row each (opened: its children under it, stepped right), the one chosen in gold
-- with a thin gold bar before it. A click chooses it (and opens or closes it), then searches within it.
local rail = {}

local function DrawRail()
	if not rail.rows then return end
	local rows = RailRows()
	rail.offset = math.max(0, math.min(rail.offset or 0, #rows - rail.count))
	rail.bar:Set(#rows, rail.count, rail.offset)
	for index, row in ipairs(rail.rows) do
		local node = rows[index + rail.offset]
		row.node = node
		row:SetShown(node ~= nil and index <= rail.count)
		if node then
			local chosenOne = node.all and category == nil or node == category
			row.text:SetText(node.all and L.ALL_CATEGORIES or node.name)
			row.text:SetFontObject(node.depth == 0 and Skin.FontFor("GameTooltipText") or Skin.FontFor("GameTooltipTextSmall"))
			local c = Skin.COLORS[chosenOne and "gold" or node.depth == 0 and "text" or "soft"]
			row.text:SetTextColor(c[1], c[2], c[3])
			row.mark:SetShown(chosenOne)
			row.ground:SetShown(chosenOne)
			local open = node.children and node.children[1] ~= nil
			row.sign:SetShown(open)
			if open then Skin.SetGlyph(row.sign, expanded[node] and "down" or "chevron") end
			local indent = 10 + node.depth * 12
			row.sign:ClearAllPoints()
			row.sign:SetPoint("LEFT", row, "LEFT", indent, 0)
			row.text:ClearAllPoints()
			row.text:SetPoint("LEFT", row, "LEFT", indent + 14, 0)
			row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
		end
	end
end

local function PickCategory(node)
	if node.all then
		category = nil
	else
		category = node
		-- (a category with children: opened when chosen, closed when chosen again)
		if node.children[1] then expanded[node] = not expanded[node] or nil end
	end
	DrawRail()
	if chosen then Choose(nil) end
	Browse(box:GetText())
end

local function BuildRail(page)
	local frame = CreateFrame("Frame", nil, page)
	frame:SetPoint("TOPLEFT")
	frame:SetPoint("BOTTOMLEFT")
	frame:SetWidth(RAIL_WIDTH)
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta)
		rail.offset = (rail.offset or 0) - delta * 3
		DrawRail()
	end)
	local caps = Skin.Caps(frame, L.CATEGORIES)
	caps:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -4)
	rail.frame, rail.rows, rail.count, rail.offset = frame, {}, RAIL_ROWS, 0
	for index = 1, RAIL_ROWS do
		local row = CreateFrame("Button", nil, frame)
		row:SetHeight(RAIL_ROW)
		row:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -22 - (index - 1) * RAIL_ROW)
		row:SetPoint("RIGHT", frame, "RIGHT", -Skin.SCROLL_WIDTH, 0)
		row.ground = row:CreateTexture(nil, "BACKGROUND")
		row.ground:SetAllPoints()
		row.ground:SetColorTexture(1, 0.82, 0, 0.07)
		row.mark = row:CreateTexture(nil, "ARTWORK")
		row.mark:SetPoint("TOPLEFT")
		row.mark:SetPoint("BOTTOMLEFT")
		row.mark:SetWidth(2)
		row.mark:SetColorTexture(1, 0.82, 0, 1)
		local hover = row:CreateTexture(nil, "HIGHLIGHT")
		hover:SetAllPoints()
		hover:SetColorTexture(1, 1, 1, 0.05)
		row.sign = Skin.Glyph(row, "chevron", 9)
		row.text = Skin.Text(row, "GameTooltipText", "text")
		if row.text.SetWordWrap then row.text:SetWordWrap(false) end
		row:SetScript("OnClick", function(self)
			if not self.node then return end
			Skin.Play("click")
			PickCategory(self.node)
		end)
		row:Hide()
		rail.rows[index] = row
	end
	rail.bar = Skin.ScrollBar(frame, function(offset)
		rail.offset = math.floor(offset + 0.5)
		DrawRail()
	end)
	rail.bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -22)
	rail.bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
	local rule = Skin.Rule(page, true, 0.12)
	rule:SetPoint("TOPLEFT", frame, "TOPRIGHT", 8, 0)
	rule:SetPoint("BOTTOM", page, "BOTTOM", 0, 0)
	function rail.Fit(height)
		rail.count = math.max(1, math.min(RAIL_ROWS, math.floor((height - 22) / RAIL_ROW)))
		DrawRail()
	end
end

-- The rarities shown and usable only, at the top: each a word in its rarity's color, lit when on.
local function PaintQuality(toggle)
	local on = Filters()[toggle.filter] and true or false
	local r, g, b = U.QualityColor(toggle.quality)
	toggle.caption:SetTextColor(r, g, b)
	toggle.caption:SetAlpha(on and 1 or 0.45)
	toggle.ground:SetColorTexture(1, 1, 1, on and 0.08 or 0.02)
end

local function BuildFilters(page, anchor)
	local x = anchor
	buttons.qualities = {}
	for _, quality in ipairs(QUALITIES) do
		local value = FilterValue(quality[1])
		if value then
			local toggle = Skin.SmallButton(page, _G["ITEM_QUALITY" .. quality[2] .. "_DESC"] or tostring(quality[2]), function(self)
				Filters()[self.filter] = not Filters()[self.filter] or nil
				PaintQuality(self)
				Browse(box:GetText())
			end, L.QUALITY_DESC, 24)
			toggle.filter, toggle.quality = value, quality[2]
			toggle:SetPoint("LEFT", x, "RIGHT", x == anchor and 16 or 4, 0)
			PaintQuality(toggle)
			buttons.qualities[#buttons.qualities + 1] = toggle
			x = toggle
		end
	end
	local usable = FilterValue("UsableOnly")
	if usable then
		buttons.usable = Skin.Check(page, L.USABLE_ONLY, function() return Filters()[usable] and true or false end, function(value)
			Filters()[usable] = value or nil
			Browse(box:GetText())
		end, L.USABLE_ONLY_DESC)
		buttons.usable:SetPoint("LEFT", x, "RIGHT", 14, 0)
	end
end

-- Your recent searches under the filters, a small button each (as many as the row holds); the table lower then.
local function Top() return Recent()[1] and TOP_RECENT or TOP end
local function Short(text)
	if #text <= RECENT_LETTERS then return text end
	-- (cut, never inside a letter of several bytes)
	local cut = text:sub(1, RECENT_LETTERS):gsub("[\192-\255][\128-\191]*$", "")
	return cut .. "..."
end
function DrawRecent()
	local page = detail.page
	if not page then return end
	local searches, x, room = Recent(), 0, list:GetWidth() or 0
	for index = 1, RECENT_KEPT do
		local text, button = searches[index], recent[index]
		if text and not button then
			button = Skin.SmallButton(page, "", function(self, mouse)
				if mouse == "RightButton" then
					for at, search in ipairs(Recent()) do
						if search == self.search then
							table.remove(Recent(), at)
							break
						end
					end
					return DrawRecent()
				end
				box:SetText(self.search)
				box:ClearFocus()
				Browse(self.search)
			end, L.RECENT_SEARCH_DESC, 20)
			button:RegisterForClicks("LeftButtonUp", "RightButtonUp") button.padRight = true
			recent[index] = button
		end
		if button then
			button.search = text
			if text then button:SetLabel(Short(text)) end
			button:ClearAllPoints()
			button:SetPoint("TOPLEFT", page, "TOPLEFT", detail.left + x, -84)
			x = x + (button:GetWidth() or 0) + 6
			button:SetShown(text ~= nil and x - 6 <= room)
		end
	end
	list:SetPoint("TOPLEFT", page, "TOPLEFT", detail.left, -Top())
	detail.frame:SetPoint("TOPLEFT", page, "TOPLEFT", detail.left, -Top())
	if page.height then page:Fit(page.height) end
end

local function Build(page)
	BuildRail(page)
	local left = RAIL_WIDTH + 18
	detail.page, detail.left = page, left
	-- The search: words within the category chosen, the button.
	buttons.search = Skin.Button(page, L.SEARCH_BUTTON, function() Browse(box:GetText()) end, "main", 110)
	buttons.search:SetHeight(32)
	buttons.search:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
	box = Skin.CreateInput(page, "WandererAuctionSearch", 60, {
		hint = L.SEARCH_HINT,
		onEnter = function(self)
			self:ClearFocus()
			Browse(self:GetText())
		end,
	})
	box:SetHeight(32)
	box:SetPoint("TOPLEFT", page, "TOPLEFT", left, 0)
	-- Your favorites, quiet, beside the search (the row under it holds the filters, long in some languages).
	buttons.favorites = Skin.SmallButton(page, L.FAVORITES, Favorites, L.FAVORITES_DESC, 32)
	buttons.favorites:SetPoint("RIGHT", buttons.search, "LEFT", -8, 0)
	box:SetPoint("RIGHT", buttons.favorites, "LEFT", -8, 0)
	-- Under it: the levels, the rarities, usable only.
	local levels = Skin.Text(page, "GameTooltipTextSmall", "muted")
	levels:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -16)
	levels:SetText(L.LEVELS)
	detail.minLevel = W.Skin.CreateInput(page, nil, 3)
	detail.minLevel:SetSize(40, 24)
	detail.minLevel:SetNumeric(true)
	detail.minLevel:SetPoint("LEFT", levels, "RIGHT", 6, 0)
	local dash = Skin.Text(page, "GameTooltipTextSmall", "muted")
	dash:SetPoint("LEFT", detail.minLevel, "RIGHT", 4, 0)
	dash:SetText(L.TO)
	detail.maxLevel = W.Skin.CreateInput(page, nil, 3)
	detail.maxLevel:SetSize(40, 24)
	detail.maxLevel:SetNumeric(true)
	detail.maxLevel:SetPoint("LEFT", dash, "RIGHT", 4, 0)
	for _, levelBox in ipairs({ detail.minLevel, detail.maxLevel }) do
		levelBox:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
			Browse(box:GetText())
		end)
	end
	BuildFilters(page, detail.maxLevel)
	-- The results: sorted by a click on a column's title.
	list = Skin.Table(page, {
		nameTitle = L.COL_ITEM,
		width = 780, rows = 26, onClick = Choose, onDraw = DrawResults, nameSort = "name",
		onSort = function(sort)
			Saved().sort = sort
			Browse(box:GetText())
			DrawResults()
		end,
		columns = {
			{ key = "level", title = L.COL_LEVEL, width = 48, sort = "level" },
			{ key = "total", title = L.COL_AVAILABLE, width = 64 },
			{ key = "price", title = L.COL_PRICE, width = 110, sort = "price" },
			{ key = "usual", title = L.COL_USUAL, width = 110 },
			{ key = "merchant", title = L.COL_MERCHANT, width = 96 },
		},
	})
	list:SetPoint("TOPLEFT", page, "TOPLEFT", left, -TOP)
	list:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	list.empty:SetText(L.SEARCH_START)
	-- (each result's "⋯", before its columns: its card, as its right click)
	for _, row in ipairs(list.rows) do
		row.menu = Skin.RowMore(row, function(owner) if owner.entry then ResultCard(owner.menu, owner.entry) end end, row.cells.level)
	end
	function page:Fit(height)
		self.height = height
		list:Fit(height - Top())
		rail.Fit(height)
	end
	list.empty:Show()
	-- The one chosen, in the results' place: back to them, the item, its auctions or how many, the buttons; the
	-- usual price and what a merchant gives beside.
	local frame = CreateFrame("Frame", nil, page)
	frame:SetPoint("TOPLEFT", page, "TOPLEFT", left, -TOP)
	frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	frame:Hide()
	detail.frame = frame
	local back = Skin.SmallButton(frame, L.BACK_TO_RESULTS, function()
		Choose(nil)
		DrawResults()
	end, L.BACK_TO_RESULTS_DESC)
	back:SetPoint("TOPLEFT")
	local main = CreateFrame("Frame", nil, frame)
	main:SetPoint("TOPLEFT", back, "BOTTOMLEFT", 0, -14)
	main:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
	main:SetWidth(470)
	detail.icon = Skin.Icon(main, 40)
	detail.icon:SetPoint("TOPLEFT")
	detail.name = W.Skin.CreateText(main, "GameFontNormalLarge")
	detail.name:SetPoint("TOPLEFT", detail.icon, "TOPRIGHT", 10, -2)
	detail.name:SetPoint("RIGHT", main, "RIGHT", 0, 0)
	detail.name:SetJustifyH("LEFT")
	detail.sub = Skin.Text(main, "GameTooltipTextSmall", "muted")
	detail.sub:SetPoint("TOPLEFT", detail.name, "BOTTOMLEFT", 0, -4)
	-- Beside: its usual price, when it was seen, what a merchant gives.
	local aside = Skin.Panel(frame)
	aside:SetPoint("TOPLEFT", main, "TOPRIGHT", ns.GAP, 0)
	aside:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	aside:SetHeight(104)
	local asideCaps = Skin.Caps(aside, L.MARKET)
	asideCaps:SetPoint("TOPLEFT", aside, "TOPLEFT", 14, -12)
	detail.usual = Skin.SummaryLine(aside, nil, L.USUAL_PRICE)
	detail.usual:ClearAllPoints()
	detail.usual:SetPoint("TOPLEFT", asideCaps, "BOTTOMLEFT", 0, -10)
	detail.usual:SetPoint("RIGHT", aside, "RIGHT", -14, 0)
	detail.seen = Skin.SummaryLine(aside, detail.usual, L.SEEN)
	detail.merchant = Skin.SummaryLine(aside, detail.seen, L.MERCHANT_LINE)
	-- The buttons, at the bottom: to your shopping list, a bid (an item), the purchase.
	buttons.buy = Skin.Button(main, L.BUY, Buy, "main", 130)
	buttons.buy:SetPoint("BOTTOMRIGHT")
	buttons.bid = Skin.Button(main, L.BID_BUTTON, Bid, nil, 100)
	buttons.bid:SetHeight(36)
	buttons.bid:SetPoint("RIGHT", buttons.buy, "LEFT", -8, 0)
	buttons.shopping = Skin.Button(main, L.TO_SHOPPING, ToShopping)
	buttons.shopping:SetHeight(36)
	buttons.shopping:SetPoint("BOTTOMLEFT")
	-- A commodity: how many, what it costs.
	local commodity = CreateFrame("Frame", nil, main)
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
	cost:SetHeight(118)
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
	local item = CreateFrame("Frame", nil, main)
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
	heads[2]:SetPoint("LEFT", heads[1], "LEFT", 170, 0)
	heads[3]:SetPoint("TOPRIGHT", item, "TOPRIGHT", -8 - Skin.SCROLL_WIDTH, -24)
	detail.auctionRows = {}
	for index = 1, AUCTION_ROWS do
		local row = CreateFrame("Button", nil, item)
		row:SetHeight(28)
		row:SetPoint("TOPLEFT", itsAuctions, "BOTTOMLEFT", 0, -26 - (index - 1) * 30)
		row:SetPoint("RIGHT", item, "RIGHT", -Skin.SCROLL_WIDTH, 0)
		row.ground = row:CreateTexture(nil, "BACKGROUND")
		row.ground:SetAllPoints()
		row.ground:SetColorTexture(1, 1, 1, 0.035)
		row.chosen = row:CreateTexture(nil, "BACKGROUND", nil, 1)
		row.chosen:SetAllPoints()
		row.chosen:SetColorTexture(1, 0.82, 0, 0.1)
		row.buyout = Skin.Text(row, "GameTooltipText", "text")
		row.buyout:SetPoint("LEFT", row, "LEFT", 8, 0)
		row.bid = Skin.Text(row, "GameTooltipTextSmall", "soft")
		row.bid:SetPoint("LEFT", row, "LEFT", 178, 0)
		row.time = Skin.Text(row, "GameTooltipTextSmall", "muted")
		row.time:SetPoint("RIGHT", row, "RIGHT", -8, 0)
		row:SetScript("OnClick", function(self) if self.entry then ChooseAuction(self.entry) end end)
		Skin.ItemTooltip(row, function(self) return self.entry and self.entry.link end)
		detail.auctionRows[index] = row
	end
	detail.auctionBar = Skin.ScrollBar(item, function(offset)
		auctionOffset = math.floor(offset + 0.5)
		DrawAuctions()
	end)
	detail.auctionBar:SetPoint("TOPRIGHT", item, "TOPRIGHT", 0, -26)
	detail.auctionBar:SetHeight(AUCTION_ROWS * 30 - 2)
	detail.noAuction = Skin.Text(item, "GameTooltipTextSmall", "muted")
	detail.noAuction:SetPoint("TOPLEFT", itsAuctions, "BOTTOMLEFT", 0, -30)
	detail.noAuction:SetText(L.SEARCH_NONE)
	local bidCaps = Skin.Caps(item, L.YOUR_BID)
	bidCaps:SetPoint("BOTTOMLEFT", item, "BOTTOMLEFT", 0, 38)
	detail.bidMoney = ns.PriceBox(item, { width = 170, height = 28, onChange = function() UpdateItem() end, tip = L.PRICE_FIELD_DESC })
	detail.bidMoney:SetPoint("TOPLEFT", bidCaps, "BOTTOMLEFT", 0, -6)
	DrawRail()
	DrawRecent()
end

local function Shown()
	-- (the game's own categories, once its auction house is loaded)
	DrawRail()
	-- An answer come while the page was put away: read now; taken by another page's search: asked again. The
	-- one chosen, its auctions answered meanwhile: looked at again.
	if again and not chosen then
		if ns.browsing ~= "buy" then again() elseif unread then ReadResults() end
	end
	if chosen and chosen.unread then Look() end
	DrawResults()
	-- (with a controller nothing is typed: the keys stay on the buttons)
	if box and (box:GetText() or "") == "" and not category and not (U.UsingPad and U.UsingPad()) then box:SetFocus() end
end

local function Closed()
	Choose(nil)
	-- (a purchase still waiting for your word: let go with the auction house)
	if buying then Safe(AH.CancelCommoditiesPurchase) end
	results, buying, again, unread = {}, nil, nil, false
	if list then Skin.Waiting(list.empty) end
	if detail.sub then Skin.Waiting(detail.sub) end
	if list then
		list.empty:SetText(L.SEARCH_START)
		list.empty:Show()
	end
	pendingSearch, pendingQuery = nil, false
end

ns.AddPage("buy", L.BUY, Build, Shown, Closed)
ns.PageHelp("buy", L.HELP_BUY)

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
	-- (a search waiting or unanswered let go: this item takes its place)
	pendingSearch, again, unread = nil, nil, false
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
-- (the results of a browse this page sent: not those of the shopping list's or the selling page's)
local function Ours() return Visible() and ns.browsing == "buy" end

ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	if pendingSearch then Browse(pendingSearch) elseif pendingQuery then Look() end
end)
-- (the page put away meanwhile: read when it comes back)
local function Answer()
	if Ours() then ReadResults() elseif ns.browsing == "buy" then unread = true end
end
ns.Listen("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", Answer)
ns.Listen("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", Answer)
ns.Listen("AUCTION_HOUSE_BROWSE_FAILURE", function()
	if not Ours() then
		-- (the page put away: "none" said when it comes back)
		if ns.browsing == "buy" then unread = true end
		return
	end
	again = nil
	Skin.Waiting(list.empty)
	list.empty:SetText(L.SEARCH_NONE)
	list.empty:Show()
end)
local describeSoon = U.Debounce(0.2, function()
	if not Visible() then return end
	if chosen and not chosen.described then
		local wasCommodity = chosen.commodity and true or false
		if ns.Describe(chosen) then
			if (chosen.commodity and true or false) ~= wasCommodity then return Choose(chosen) end
			detail.icon:Set(chosen.icon, chosen.quality)
			detail.name:SetText(chosen.name or "")
			Skin.Quality(detail.name, chosen.quality)
		end
	end
	DrawResults()
end)
ns.Listen("ITEM_KEY_ITEM_INFO_RECEIVED", function(itemID)
	for _, entry in ipairs(results) do
		if entry.id == itemID then entry.asked = 0 end
	end
	if chosen and chosen.id == itemID then chosen.asked = 0 end
	describeSoon()
end)

-- The answer to a look tells the kind of the item chosen when its words never came: chosen again as that kind.
local function KindFromAnswer(commodity)
	if not chosen or chosen.described or chosen.kindAnswered or (chosen.commodity and true or false) == commodity then return false end
	chosen.commodity, chosen.kindAnswered = commodity, true
	Choose(chosen)
	return true
end
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
-- (the page put away meanwhile: its auctions looked at again when it comes back)
ns.Listen("COMMODITY_SEARCH_RESULTS_UPDATED", function(id)
	if chosen and id == chosen.id and KindFromAnswer(true) then return end
	if chosen and chosen.commodity and id == chosen.id then
		if detail.frame:IsVisible() then ShowCommodity() else chosen.unread = true end
	end
end)
ns.Listen("ITEM_SEARCH_RESULTS_UPDATED", function(key)
	if chosen and type(key) == "table" and key.itemID == chosen.id and KindFromAnswer(false) then return end
	if chosen and not chosen.commodity and type(key) == "table" and key.itemID == chosen.id then
		if detail.frame:IsVisible() then ShowItem() else chosen.unread = true end
	end
end)
-- A commodity's purchase let go: the game told (the price it holds for you released), nothing left waiting.
local function CancelPurchase(purchase)
	if not purchase or buying ~= purchase then return end
	buying = nil
	Safe(AH.CancelCommoditiesPurchase)
end

-- Its question no longer the one shown: answered, closed, or another asked in its place (which never answers
-- the first). Wanderer's kit says it.
local function Replaced(question)
	return not Skin.IsAsking(question)
end

-- A commodity: the game's final price, then your word. Another question asked in its place: the purchase let
-- go, as if refused (never left pending behind it).
ns.Listen("COMMODITY_PRICE_UPDATED", function(_, total)
	if not buying then return end
	local purchase = buying
	local text = L.CONFIRM_BUY:format(L.POST_WHAT:format(purchase.quantity, purchase.name), U.Coins(Clean(total) or 0))
	local answered = false
	local question = Skin.Ask(text,
		function()
			answered = true
			if buying == purchase then Safe(AH.ConfirmCommoditiesPurchase, purchase.id, purchase.quantity) end
		end,
		function()
			answered = true
			CancelPurchase(purchase)
		end)
	purchase.question = question
	local function Watch()
		-- (answered, or asked again for a new price: that question watched instead)
		if answered or buying ~= purchase or purchase.question ~= question then return end
		if Replaced(question) then return CancelPurchase(purchase) end
		C_Timer.After(0.5, Watch)
	end
	C_Timer.After(0.5, Watch)
end)
ns.Listen("COMMODITY_PRICE_UNAVAILABLE", function()
	buying = nil
	W.Print(L.BUY_UNAVAILABLE)
	Again()
end)
ns.Listen("COMMODITY_PURCHASE_SUCCEEDED", function()
	if buying then W.Print(L.BOUGHT:format(L.POST_WHAT:format(buying.quantity, buying.name))) end
	buying = nil
	Again()
end)
ns.Listen("COMMODITY_PURCHASE_FAILED", function()
	buying = nil
	W.Print(L.BUY_FAILED)
	Again()
end)
ns.Listen("ITEM_PURCHASED", function()
	if ns.Bought then W.Print(L.BOUGHT:format(ns.Bought)) end
	ns.Bought = nil
	Again()
end)
ns.Listen("BID_ADDED", function()
	if ns.BidOn then W.Print(L.BID_PLACED:format(ns.BidOn)) end
	ns.BidOn = nil
	Again()
end)
