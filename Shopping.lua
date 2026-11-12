local _, ns = ...
local L = ns.L

-- Your shopping list: what you want to buy (added from Wanderer Quests, a profession's window, the
-- reminders, a result of the buying page, or a Shift+click on an item here),
-- searched all at once. Each says what for, how many you carry against how
-- many you want, your highest price (yours to set, a right click), the best
-- price now and where it stands (under your highest, dearer, not on sale). A
-- click opens its card beside it (ShoppingCard.lua: how many, always on you,
-- your highest price, off the list, searched now), the same as in the small
-- window; what you already carry enough of leaves the list when it is
-- searched. What a merchant sells (Merchant.lua) says so, and is not searched
-- here.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local list, rows = nil, {}
local best = {} -- item id -> the cheapest now (searched this visit), false: not on sale
local searched = false
local asked = {} -- item ids a search of this visit asked (one added since: searched again)
local sent = {} -- those of the search waiting for its answer
local covered = {} -- those the last answer covered (the others: no chip yet)
local searching, pending = false, false
-- (the empty list's words: how to add an item, the pad's left button under the pad)
local function EmptyWords()
	return (U and U.UsingPad and U.UsingPad()) and L.LIST_EMPTY_PAD or L.LIST_EMPTY
end
local detail = {}

local Ready = ns.Ready

local Carried = U.ItemCount

-- What one costs at a merchant, when one was seen selling it (Merchant.lua).
local function AtMerchant(id) return ns.MerchantPrice and ns.MerchantPrice(id) or nil end

-- Where it stands: a chip and its tone.
local function State(entry)
	if entry.have >= entry.want then return L.CHIP_ENOUGH, "green" end
	local merchant = AtMerchant(entry.id)
	if merchant then return L.CHIP_AT_MERCHANT:format(U.Coins(merchant)), "gold" end
	if not covered[entry.id] then return nil end
	local price = best[entry.id]
	if not price then return L.CHIP_NOT_ON_SALE, "grey" end
	if entry.max then
		if price <= entry.max then return L.CHIP_UNDER_MAX, "green" end
		return L.CHIP_OVER_MAX, "gold"
	end
	return L.CHIP_ON_SALE, "grey"
end

local function Draw()
	if not (list and list:IsVisible()) then return end
	local offset = list:Clamp(#rows)
	for index, row in ipairs(list.rows) do
		local entry = rows[index + offset]
		local values, chip, tone
		if entry then
			local price = best[entry.id]
			values = {
				what = ns.ShoppingWhat(entry),
				have = ns.HaveWant(entry.have, entry.want),
				max = entry.max and U.Coins(entry.max) or Skin.Colorize(L.NO_MAX, "muted"),
				best = price and U.Coins(price) or (covered[entry.id] and Skin.Colorize("-", "muted") or ""),
			}
			chip, tone = State(entry)
			-- (always on you: said first, as on the list's own window)
			if entry.keep then chip = chip and (L.CHIP_KEEP .. U.SEPARATOR .. chip) or L.CHIP_KEEP; tone = tone or "gold" end
		end
		local card = ns.ShoppingCard and ns.ShoppingCard()
		local open = card and card:IsShown() and entry ~= nil and card.id == entry.id
		-- (taken off the list on its card only: one place)
		row:Fill(entry, open and true or false, values, chip, tone)
	end
	list.empty:SetShown(#rows == 0)
end

-- The rows, from your list (what you carry read now).
local function Gather()
	rows = ns.ShoppingRows()
	Draw()
end

-- An item the list lacks that no search of this visit asked (added since), a merchant's left aside.
local function Unsearched()
	for id, wanted in pairs(ns.Shopping()) do
		if Carried(id) < (wanted.count or 1) and not asked[id] and not AtMerchant(id) then return true end
	end
	return false
end

-- All of them searched at once (what you carry enough of leaves the list first).
local function Search()
	-- (asked before the list is pruned: drawn again then, it does not search again)
	for id, wanted in pairs(ns.Shopping()) do
		if Carried(id) < (wanted.count or 1) then asked[id] = true end
	end
	ns.PruneShopping()
	local keys, ids = {}, {}
	for id, wanted in pairs(ns.Shopping()) do
		-- (sold by a merchant: cheaper there, not asked here)
		if Carried(id) < (wanted.count or 1) and not AtMerchant(id) then
			local key = Safe(AH.MakeItemKey, id)
			if key then
				keys[#keys + 1] = key
				ids[id] = true
			end
		end
	end
	Gather()
	if ns.RefreshTabs then ns.RefreshTabs() end
	if not keys[1] then return end
	if not Ready() then
		pending = true
		return
	end
	pending, searching, sent = false, true, ids
	Skin.Waiting(list.empty, L.SEARCHING)
	local order = Enum.AuctionHouseSortOrder
	ns.browsing = "shopping"
	Safe(AH.SearchForItemKeys, keys, { { sortOrder = order.Price, reverseSort = false } })
end

local function ReadResults()
	if not searching then return end
	best = {}
	-- (one row per variant of an item: the cheapest of them kept, remembered once)
	local found = Safe(AH.GetBrowseResults)
	for _, result in ipairs(type(found) == "table" and found or {}) do
		local id = type(result.itemKey) == "table" and Clean(result.itemKey.itemID)
		local price = Clean(result.minPrice)
		if id and price and price > 0 then best[id] = math.min(best[id] or price, price) end
	end
	for id, price in pairs(best) do ns.Remember(id, price) end
	searched, searching, covered = true, false, sent
	Skin.Waiting(list.empty)
	list.empty:SetText(EmptyWords())
	Draw()
end

-- A search failed, or left unanswered (the page put away: its answer is read only while shown): let go, the
-- next visit searches again.
local function LetGo()
	if not searching then return end
	searching = false
	wipe(asked)
	Skin.Waiting(list.empty)
	list.empty:SetText(EmptyWords())
end

-- A click (left or right): its card beside its row.
local function Click(entry)
	local owner
	for _, row in ipairs(list.rows) do if row.entry == entry then owner = row end end
	ns.OpenShoppingCard(owner, entry.id)
	Draw()
end

local function Build(page)
	local intro = Skin.Text(page, "GameTooltipText", "soft")
	intro:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -8)
	intro:SetText(L.SHOPPING_INTRO)
	detail.search = Skin.Button(page, L.SEARCH_ALL, Search, "main", 140)
	detail.search:SetHeight(32)
	detail.search:SetPoint("TOPRIGHT")
	list = Skin.Table(page, {
		nameTitle = L.COL_ITEM,
		width = 1040, rows = 24, onClick = Click, onDraw = Draw,
		columns = {
			{ key = "what", title = L.COL_FOR, width = 210, justify = "LEFT" },
			{ key = "have", title = L.COL_CARRIED, width = 90 },
			{ key = "max", title = L.COL_MAX, width = 110 },
			{ key = "best", title = L.COL_BEST, width = 120 },
		},
	})
	list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -44)
	list:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	function page:Fit(height) list:Fit(height - 44) end
	page:HookScript("OnHide", LetGo)
	Skin.Waiting(list.empty)
	list.empty:SetText(EmptyWords())
end

local function Shown()
	list.offset = 0
	if not searching then list.empty:SetText(EmptyWords()) end
	Gather()
	-- Searched by itself the first time it is shown at this visit, and again for an item added since.
	if not searching and (not searched or Unsearched()) then Search() end
end

local function Closed()
	best, searched, searching, pending = {}, false, false, false
	asked, sent, covered = {}, {}, {}
end

-- (what the list still lacks, as the merchant's tab and the town line count it)
local function Badge()
	local lack = ns.ShoppingLack and ns.ShoppingLack() or 0
	return lack > 0 and lack or nil
end

ns.AddPage("shopping", L.SHOPPING, Build, Shown, Closed, Badge, "gold")
ns.PageHelp("shopping", L.HELP_SHOPPING, L.HELP_SHOPPING_PAD)

-- The list changed (an item added or taken off): drawn again, the tab's count with it.
function ns.RefreshShopping()
	if list and list:IsVisible() then
		-- (an item added since the last search: searched too)
		if searched and not searching and Unsearched() then Search() else Gather() end
	end
	if ns.RefreshTabs then ns.RefreshTabs() end
	if ns.RefreshList then ns.RefreshList() end
	if ns.RefreshShoppingCard then ns.RefreshShoppingCard() end
end

-- This page shown (a Shift+click on an item then adds it: ShoppingList.lua).
function ns.ShoppingPageShown() return list ~= nil and list:IsVisible() end

ns.Listen("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function() if list and list:IsVisible() then ReadResults() end end)
ns.Listen("AUCTION_HOUSE_BROWSE_FAILURE", function() if list then LetGo() end end)
ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() if pending and list and list:IsVisible() then Search() end end)
ns.Listen("GET_ITEM_INFO_RECEIVED", function() if list and list:IsVisible() then Gather() end end)
ns.Listen("BAG_UPDATE_DELAYED", function() if list and list:IsVisible() then Gather() end end)
