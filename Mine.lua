local _, ns = ...
local L = ns.L

-- Your auctions: those for sale (said undercut when a lower price was seen
-- since), those sold (their gold on its way by mail). One chosen: its prices,
-- its time left, a link to the current prices, and its cancel, its cost said
-- and asked first.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local ROWS = ns.ROWS
local SOLD = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1

local list, entries, chosen = nil, {}, nil
local detail = {}
local canceling -- the name of the auction being canceled, for its message
local waiting = false -- a query asked while the auction house was busy

local function Query()
	waiting = not Clean(Safe(AH.IsThrottledMessageSystemReady))
	if waiting then return end
	Safe(AH.QueryOwnedAuctions, { { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } })
end

-- A lower price seen since than yours (each).
local function Undercut(entry)
	if entry.sold or not entry.buyout then return false end
	local lowest = ns.Price(entry.id)
	return lowest ~= nil and lowest < math.floor(entry.buyout / math.max(1, entry.quantity))
end

local function Draw()
	if not (list and list:IsVisible()) then return end
	local offset = list:Clamp(#entries)
	for index, row in ipairs(list.rows) do
		local entry = entries[index + offset]
		local state
		if entry then
			if entry.sold then
				state = "|cff66dd66" .. L.SOLD .. "|r"
			elseif Undercut(entry) then
				state = "|cffff6060" .. L.UNDERCUT .. "|r"
			else
				state = ns.TimeLeft(entry.timeLeft)
			end
			if entry.quantity > 1 then state = "x" .. entry.quantity .. "  " .. state end
		end
		row:Fill(entry, entry ~= nil and entry == chosen, state, entry and U.Coins(entry.buyout or entry.bid or 0))
	end
	local active, sold, gold = 0, 0, 0
	for _, entry in ipairs(entries) do
		if entry.sold then
			sold, gold = sold + 1, gold + (entry.buyout or entry.bid or 0)
		else
			active = active + 1
		end
	end
	detail.summary:SetText(L.MINE_SUMMARY:format(active, sold, U.Coins(gold)))
	list.empty:SetShown(#entries == 0)
end

local function ShowChosen()
	local entry = chosen
	detail.frame:SetShown(entry ~= nil)
	detail.pick:SetShown(entry == nil)
	if not entry then return end
	detail.icon:SetTexture(entry.icon)
	detail.name:SetText(entry.link or entry.name)
	local lines = {}
	if entry.buyout then lines[#lines + 1] = L.BUYOUT_LINE:format(U.Coins(entry.buyout)) end
	if entry.bid then lines[#lines + 1] = L.BID_LINE:format(U.Coins(entry.bid)) .. (entry.bidderName and (" (" .. entry.bidderName .. ")") or "") end
	if entry.sold then
		lines[#lines + 1] = "|cff66dd66" .. L.SOLD_MAIL .. "|r"
	else
		lines[#lines + 1] = L.TIME_LINE:format(ns.TimeLeft(entry.timeLeft))
		local lowest = ns.Price(entry.id)
		if lowest then
			lines[#lines + 1] = (Undercut(entry) and "|cffff6060" or "|cff9ab8d8") .. L.LOWEST:format(U.Coins(lowest)) .. "|r"
			-- Undercut below what a merchant gives: not worth following.
			local vendor = ns.Vendor(entry.link)
			if Undercut(entry) and vendor > 0 and ns.Net(lowest) <= vendor then
				lines[#lines + 1] = "|cffe0a040" .. L.DONT_FOLLOW .. "|r"
			end
		end
	end
	detail.status:SetText(table.concat(lines, "\n"))
	local cost = not entry.sold and Clean(Safe(AH.GetCancelCost, entry.auctionID))
	detail.cost:SetText(cost and cost > 0 and L.CANCEL_COST:format(U.Coins(cost)) or "")
	detail.cancel:SetEnabled(not entry.sold and Clean(Safe(AH.CanCancelAuction, entry.auctionID)) and true or false)
end

local function Choose(entry)
	chosen = entry
	if detail.frame then ShowChosen() end
	Draw()
end

-- A bidder's name (the game gives who it is, not how they are called).
local function Bidder(guid)
	guid = Clean(guid)
	if not (guid and GetPlayerInfoByGUID) then return nil end
	local _, _, _, _, _, name = Safe(GetPlayerInfoByGUID, guid)
	return Clean(name)
end

local function Read()
	entries = {}
	local owned = Safe(AH.GetOwnedAuctions)
	for _, info in ipairs(type(owned) == "table" and owned or {}) do
		local key = info.itemKey
		local id = type(key) == "table" and Clean(key.itemID)
		if id then
			local entry = { auctionID = Clean(info.auctionID), key = key, id = id, link = Clean(info.itemLink), name = "",
				quality = 1, quantity = Clean(info.quantity) or 1, buyout = Clean(info.buyoutAmount), bid = Clean(info.bidAmount),
				bidderName = Bidder(info.bidder), timeLeft = Clean(info.timeLeft), sold = Clean(info.status) == SOLD }
			ns.Describe(entry)
			entries[#entries + 1] = entry
		end
	end
	-- Sold last; then by name.
	table.sort(entries, function(a, b)
		if a.sold ~= b.sold then return not a.sold end
		return (a.name or "") < (b.name or "")
	end)
	if chosen then
		local still
		for _, entry in ipairs(entries) do
			if entry.auctionID == chosen.auctionID then still = entry end
		end
		chosen = still
	end
	if detail.frame then ShowChosen() end
	Draw()
end

local function Cancel()
	local entry = chosen
	if not entry then return end
	local cost = Clean(Safe(AH.GetCancelCost, entry.auctionID)) or 0
	ns.Ask(L.CONFIRM_CANCEL:format(entry.link or entry.name, U.Coins(cost)), function()
		canceling = entry.link or entry.name
		Safe(AH.CancelAuction, entry.auctionID)
	end)
end

local function Build(page)
	detail.summary = W.Skin.CreateText(page, "GameTooltipTextSmall", 0.65, 0.65, 0.65)
	detail.summary:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	list = ns.NewList(page, ROWS - 1, Choose, Draw)
	list:SetPoint("TOPLEFT", detail.summary, "BOTTOMLEFT", 0, -8)
	list.empty = W.Skin.CreateText(page, "GameTooltipText", 0.6, 0.6, 0.6)
	list.empty:SetPoint("TOP", list, "TOP", 0, -20)
	list.empty:SetText(L.MINE_EMPTY)
	local frame = ns.NewDetail(page, list, L.PICK_MINE, detail)
	-- Its current prices, in the buying page.
	detail.prices = W.Skin.CreateLink(frame, L.SEE_PRICES, function()
		if chosen and ns.SearchFor then ns.SearchFor(chosen.name) end
	end)
	detail.prices:SetPoint("TOPLEFT", detail.status, "BOTTOMLEFT", -5, -8)
	detail.cost = W.Skin.CreateText(frame, "GameTooltipTextSmall", 0.6, 0.6, 0.6)
	detail.cost:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 6)
	detail.cancel = ns.Button(frame, L.CANCEL_BUTTON, Cancel, 130)
	detail.cancel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
end

local function Shown()
	list.offset = 0
	Draw()
	Query()
end

local function Closed()
	chosen, entries, canceling = nil, {}, nil
end

ns.AddPage("mine", L.MINE, Build, Shown, Closed)

local function Visible() return list and list:IsVisible() end

ns.Listen("OWNED_AUCTIONS_UPDATED", function() if Visible() then Read() end end)
ns.Listen("AUCTION_CANCELED", function()
	if canceling and W.Print then W.Print(L.CANCELED:format(canceling)) end
	canceling = nil
	if Visible() then Query() end
end)
ns.Listen("AUCTION_HOUSE_AUCTION_CREATED", function() if Visible() then Query() end end)
ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() if waiting and Visible() then Query() end end)
