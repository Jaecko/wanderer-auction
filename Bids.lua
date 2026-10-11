local _, ns = ...
local L = ns.L

-- Your bids: on each, whether yours is still the best (outbid said in red),
-- the current bid, the next one possible, the time left. One chosen: a new
-- bid (the least it can be offered first) or its buyout, both asked first.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean
local AH = ns.AH

local ROWS = ns.ROWS

local list, entries, chosen = nil, {}, nil
local detail = {}
local waiting = false -- a query asked while the auction house was busy

local function Query()
	waiting = not Clean(Safe(AH.IsThrottledMessageSystemReady))
	if waiting then return end
	Safe(AH.QueryBids, { { sortOrder = Enum.AuctionHouseSortOrder.TimeRemaining, reverseSort = false } }, {})
end

local function Draw()
	if not (list and list:IsVisible()) then return end
	local offset = list:Clamp(#entries)
	for index, row in ipairs(list.rows) do
		local entry = entries[index + offset]
		local state = entry and (entry.outbid and ("|cffff6060" .. L.OUTBID .. "|r") or ("|cff66dd66" .. L.WINNING .. "|r"))
		row:Fill(entry, entry ~= nil and entry == chosen, state, entry and entry.bid and U.Coins(entry.bid))
	end
	list.empty:SetShown(#entries == 0)
end

local function Update()
	local entry = chosen
	local amount = detail.money:Get()
	detail.bid:SetEnabled(entry ~= nil and entry.minBid ~= nil and amount >= entry.minBid)
	detail.buy:SetEnabled(entry ~= nil and entry.buyout ~= nil)
end

local function ShowChosen()
	local entry = chosen
	detail.frame:SetShown(entry ~= nil)
	detail.pick:SetShown(entry == nil)
	if not entry then return end
	detail.icon:SetTexture(entry.icon)
	detail.name:SetText(entry.link or entry.name)
	local lines = {}
	lines[#lines + 1] = entry.outbid and ("|cffff6060" .. L.OUTBID_LONG .. "|r") or ("|cff66dd66" .. L.WINNING_LONG .. "|r")
	if entry.bid then lines[#lines + 1] = L.BID_LINE:format(U.Coins(entry.bid)) end
	if entry.buyout then lines[#lines + 1] = L.BUYOUT_LINE:format(U.Coins(entry.buyout)) end
	lines[#lines + 1] = L.TIME_LINE:format(ns.TimeLeft(entry.timeLeft))
	detail.status:SetText(table.concat(lines, "\n"))
	detail.money:ShowCopper(ns.CopperOnly())
	detail.money:Set(entry.minBid or 0)
	Update()
end

local function Choose(entry)
	chosen = entry
	if detail.frame then ShowChosen() end
	Draw()
end

local function Read()
	entries = {}
	local me = Clean(Safe(UnitGUID, "player"))
	local bids = Safe(AH.GetBids)
	for _, info in ipairs(type(bids) == "table" and bids or {}) do
		local key = info.itemKey
		local id = type(key) == "table" and Clean(key.itemID)
		if id then
			local bidder = Clean(info.bidder)
			local entry = { auctionID = Clean(info.auctionID), key = key, id = id, link = Clean(info.itemLink), name = "", quality = 1,
				bid = Clean(info.bidAmount), minBid = Clean(info.minBid), buyout = Clean(info.buyoutAmount),
				timeLeft = Clean(info.timeLeft), outbid = bidder ~= nil and me ~= nil and bidder ~= me }
			ns.Describe(entry)
			entries[#entries + 1] = entry
		end
	end
	-- Outbid first: they are the ones to look at.
	table.sort(entries, function(a, b)
		if a.outbid ~= b.outbid then return a.outbid end
		return (a.timeLeft or 0) < (b.timeLeft or 0)
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

local function Bid()
	local entry = chosen
	if not entry then return end
	local amount = detail.money:Get()
	if amount < (entry.minBid or 0) then return end
	ns.Ask(L.CONFIRM_BID:format(U.Coins(amount), entry.link or entry.name), function()
		ns.BidOn = entry.link or entry.name
		Safe(AH.PlaceBid, entry.auctionID, amount)
	end)
end

local function Buyout()
	local entry = chosen
	if not (entry and entry.buyout) then return end
	ns.Ask(L.CONFIRM_BUY:format(entry.link or entry.name, U.Coins(entry.buyout)), function()
		ns.Bought = entry.link or entry.name
		Safe(AH.PlaceBid, entry.auctionID, entry.buyout)
	end)
end

local function Build(page)
	list = ns.NewList(page, ROWS, Choose, Draw)
	list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	list.empty = W.Skin.CreateText(page, "GameTooltipText", 0.6, 0.6, 0.6)
	list.empty:SetPoint("TOP", list, "TOP", 0, -20)
	list.empty:SetText(L.BIDS_EMPTY)
	local frame = ns.NewDetail(page, list, L.PICK_BID, detail)
	local label = W.Skin.CreateText(frame, "GameTooltipTextSmall", 0.75, 0.68, 0.5)
	label:SetPoint("TOPLEFT", detail.status, "BOTTOMLEFT", 0, -14)
	label:SetText(L.YOUR_BID)
	detail.money = ns.NewMoney(frame, Update)
	detail.money:SetPoint("LEFT", label, "LEFT", ns.VALUE_LEFT, 0)
	detail.buy = ns.Button(frame, L.BUY_BUTTON, Buyout)
	detail.buy:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
	detail.bid = ns.Button(frame, L.BID_BUTTON, Bid)
	detail.bid:SetPoint("RIGHT", detail.buy, "LEFT", -6, 0)
end

local function Shown()
	list.offset = 0
	Draw()
	Query()
end

local function Closed()
	chosen, entries = nil, {}
end

ns.AddPage("bids", L.BIDS, Build, Shown, Closed)

local function Visible() return list and list:IsVisible() end

ns.Listen("BIDS_UPDATED", function() if Visible() then Read() end end)
ns.Listen("BID_ADDED", function() if Visible() then Query() end end)
ns.Listen("ITEM_PURCHASED", function() if Visible() then Query() end end)
ns.Listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() if waiting and Visible() then Query() end end)
