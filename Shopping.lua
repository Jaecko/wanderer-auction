local _, ns = ...
local L = ns.L

-- Your shopping list: what you want to buy (added from Wanderer Quests, a profession's window, the
-- reminders, a result of the buying page, or a Shift+click on an item here),
-- searched all at once. Each says what for, how many you carry against how
-- many you want, your highest price (yours to set, a right click), the best
-- price now and where it stands (under your highest, dearer, not on sale). A
-- click shows it on the buying page; what you already carry enough of leaves
-- the list when it is searched.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local list, rows = nil, {}
local best = {} -- item id -> the cheapest now (searched this visit), false: not on sale
local searched = false
local searching, pending = false, false
local editing -- the item whose highest price is being set
local detail = {}

local Ready = ns.Ready

local Carried = U and U.ItemCount

-- Where it stands: a chip and its tone.
local function State(entry)
	if entry.have >= entry.want then return L.CHIP_ENOUGH, "green" end
	if not searched then return nil end
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
				what = entry.note or L.YOUR_LIST,
				have = ns.HaveWant(entry.have, entry.want),
				max = entry.max and U.Coins(entry.max) or "|cff8f8676" .. L.NO_MAX .. "|r",
				best = price and U.Coins(price) or (searched and "|cff8f8676-|r" or ""),
			}
			chip, tone = State(entry)
		end
		row:Fill(entry, entry ~= nil and editing ~= nil and entry.id == editing, values, chip, tone, entry and L.REMOVE, entry and function()
			ns.RemoveFromShopping(entry.id)
			ns.RefreshShopping()
		end)
	end
	list.empty:SetShown(#rows == 0)
end

-- The rows, from your list (what you carry read now).
local function Gather()
	rows = ns.ShoppingRows()
	Draw()
end

-- All of them searched at once (what you carry enough of leaves the list first).
local function Search()
	ns.PruneShopping()
	local keys = {}
	for id, wanted in pairs(ns.Shopping()) do
		if Carried(id) < (wanted.count or 1) then
			local key = Safe(AH.MakeItemKey, id)
			if key then keys[#keys + 1] = key end
		end
	end
	Gather()
	if ns.RefreshTabs then ns.RefreshTabs() end
	if not keys[1] then return end
	if not Ready() then
		pending = true
		return
	end
	pending, searching = false, true
	list.empty:SetText(L.SEARCHING)
	local order = Enum.AuctionHouseSortOrder
	Safe(AH.SearchForItemKeys, keys, { { sortOrder = order.Price, reverseSort = false } })
end

local function ReadResults()
	if not searching then return end
	best = {}
	local found = Safe(AH.GetBrowseResults)
	for _, result in ipairs(type(found) == "table" and found or {}) do
		local id = type(result.itemKey) == "table" and Clean(result.itemKey.itemID)
		local price = Clean(result.minPrice)
		if id and price and price > 0 then
			best[id] = price
			ns.Remember(id, price)
		end
	end
	searched, searching = true, false
	list.empty:SetText(L.SHOPPING_EMPTY)
	Draw()
end

-- Your highest price for one (a right click): set, or none.
local function Edit(entry)
	editing = entry and entry.id or nil
	detail.editor:SetShown(editing ~= nil)
	if entry then
		detail.editName:SetText(L.MAX_FOR:format(entry.name))
		detail.money:Set(entry.max or best[entry.id] or 0)
	end
	Draw()
end

local function SetMax(value)
	local wanted = editing and ns.Shopping()[editing]
	if wanted then wanted.max = value and value > 0 and value or nil end
	Edit(nil)
	Gather()
end

local function Click(entry, mouse)
	if mouse == "RightButton" then return Edit(entry) end
	if ns.BuyItem then ns.BuyItem(entry.id, entry.name) end
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
		width = 1040, rows = 24, action = 90, onClick = Click, onDraw = Draw,
		columns = {
			{ key = "what", title = L.COL_FOR, width = 210, justify = "LEFT" },
			{ key = "have", title = L.COL_CARRIED, width = 90 },
			{ key = "max", title = L.COL_MAX, width = 110 },
			{ key = "best", title = L.COL_BEST, width = 120 },
		},
	})
	list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -44)
	list:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	function page:Fit(height) list:Fit(height - 44 - 80) end
	list.empty:SetText(L.SHOPPING_EMPTY)
	-- Your highest price for one, set under the table.
	local editor = Skin.Panel(page)
	editor:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 24)
	editor:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	editor:SetHeight(48)
	editor:Hide()
	detail.editor = editor
	detail.editName = Skin.Text(editor, "GameTooltipText", "soft")
	detail.editName:SetPoint("LEFT", editor, "LEFT", 14, 0)
	detail.money = Skin.Money(editor)
	detail.money:SetPoint("LEFT", detail.editName, "RIGHT", 14, 0)
	local none = Skin.Button(editor, L.NO_MAX_BUTTON, function() SetMax(nil) end)
	none:SetPoint("RIGHT", editor, "RIGHT", -10, 0)
	local ok = Skin.Button(editor, OKAY or "OK", function() SetMax(detail.money:Get()) end, "main", 70)
	ok:SetHeight(30)
	ok:SetPoint("RIGHT", none, "LEFT", -8, 0)
	local note = Skin.Text(page, "GameTooltipTextSmall", "muted")
	note:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
	note:SetText(L.SHOPPING_NOTE)
end

local function Shown()
	list.offset = 0
	Gather()
	-- Searched by itself the first time it is shown at this visit.
	if not searched and not searching then Search() end
end

local function Closed()
	best, searched, searching, pending, editing = {}, false, false, false, nil
end

local function Badge()
	local count = 0
	for _ in pairs(ns.Shopping()) do count = count + 1 end
	return count
end

ns.AddPage("shopping", L.SHOPPING, Build, Shown, Closed, Badge, "gold")

-- The list changed (an item added or taken off): drawn again, the tab's count with it.
function ns.RefreshShopping()
	if list and list:IsVisible() then Gather() end
	if ns.RefreshTabs then ns.RefreshTabs() end
	if ns.RefreshList then ns.RefreshList() end
end

-- This page shown (a Shift+click on an item then adds it: ShoppingList.lua).
function ns.ShoppingPageShown() return list ~= nil and list:IsVisible() end

ns.Listen("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function() if list and list:IsVisible() then ReadResults() end end)
ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() if pending and list and list:IsVisible() then Search() end end)
ns.Listen("GET_ITEM_INFO_RECEIVED", function() if list and list:IsVisible() then Gather() end end)
ns.Listen("BAG_UPDATE_DELAYED", function() if list and list:IsVisible() then Gather() end end)
