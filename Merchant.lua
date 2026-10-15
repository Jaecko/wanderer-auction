local _, ns = ...
local L = ns.L

-- At a merchant: an item of your shopping list he sells says, beside it, how many the list still lacks
-- ("+12"); a click buys just that (in stacks, a moment apart, as the server expects). Only for gold: what
-- costs tokens or items is left to the game. Nothing runs away from a merchant.
-- An option (off): all of it bought on arrival, never above a cap per visit (said instead), Shift skipping it.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean

local BUY_DELAY = 0.25 -- seconds between two purchases
local links = {} -- the merchant's squares (1 to MERCHANT_ITEMS_PER_PAGE) -> their link

-- One of the merchant's items: its price (copper), the lot it is sold in, whether it asks more than gold.
local function Info(index)
	local api = C_MerchantFrame and C_MerchantFrame.GetItemInfo
	local info = api and Safe(api, index)
	if type(info) == "table" then return Clean(info.price), Clean(info.stackCount), Clean(info.hasExtendedCost) end
	local _, _, price, lot, _, _, _, extended = Safe(GetMerchantItemInfo, index)
	return Clean(price), Clean(lot), Clean(extended)
end

-- Buys count of the merchant's item index: in stacks (or in the lots he sells), one after the other. Each
-- purchase first checks it is still the item id there (another merchant opened meanwhile: nothing bought).
local function Still(index, id)
	return MerchantFrame and MerchantFrame:IsShown() and Clean(Safe(GetMerchantItemID, index)) == id
end
local function Buy(index, count, id)
	if not (id and Still(index, id)) then return end
	local _, lot = Info(index)
	lot = math.max(1, lot or 1)
	local most = math.max(1, Clean(Safe(GetMerchantItemMaxStack, index)) or 1)
	local steps = {}
	if lot > 1 then
		for _ = 1, math.ceil(count / lot) do steps[#steps + 1] = false end
	else
		while count > 0 do
			local take = math.min(count, most)
			steps[#steps + 1] = take
			count = count - take
		end
	end
	for step, quantity in ipairs(steps) do
		C_Timer.After((step - 1) * BUY_DELAY, function()
			if not Still(index, id) then return end
			if quantity then Safe(BuyMerchantItem, index, quantity) else Safe(BuyMerchantItem, index) end
		end)
	end
end

-- What one of the merchant's items costs you for count of it (gold only; nil: it asks something else).
local function Cost(index, count)
	local price, lot, extended = Info(index)
	lot = math.max(1, lot or 1)
	if extended or not price or price <= 0 then return nil end
	return price * math.ceil(count / lot)
end

-- On arrival: what the list lacks of everything he sells, bought in one go (after the junk is sold).
local open = false
local function BuyAll()
	local settings = ns.Settings()
	if not (open and ns.On() and settings and settings.autoBuy) then return end
	local list, lots, total = ns.Shopping(), {}, 0
	for index = 1, Clean(Safe(GetMerchantNumItems)) or 0 do
		local id = Clean(Safe(GetMerchantItemID, index))
		local lack = id and list[id] and ns.Lacking(id) or 0
		local cost = lack > 0 and Cost(index, lack)
		if cost then
			lots[#lots + 1] = { index = index, id = id, lack = lack }
			total = total + cost
		end
	end
	if not lots[1] then return end
	local cap = (settings.buyCap or 5) * 10000
	if total > cap then return W.Print(L.AUTOBUY_OVER:format(U.Coins(total), U.Coins(cap))) end
	if total > (Clean(Safe(GetMoney)) or 0) then return W.Print(L.AUTOBUY_NO_MONEY:format(U.Coins(total))) end
	local said = {}
	for step, lot in ipairs(lots) do
		C_Timer.After((step - 1) * 1.5, function() if open then Buy(lot.index, lot.lack, lot.id) end end)
		said[#said + 1] = ("%d %s"):format(lot.lack, U.ItemName(lot.id) or ("#" .. lot.id))
	end
	W.Print(L.AUTOBUY_DONE:format(table.concat(said, ", "), U.Coins(total)))
end

-- (the junk being sold first: waited for, a little at a time)
local function WhenSold(tries)
	if not open then return end
	if W.IsSellingJunk and W.IsSellingJunk() and tries < 60 then
		return C_Timer.After(0.5, function() WhenSold(tries + 1) end)
	end
	BuyAll()
end

local function Link(square)
	if links[square] then return links[square] end
	local frame = _G["MerchantItem" .. square]
	if not (frame and Skin and Skin.CreateLink) then return nil end
	local link = Skin.CreateLink(frame, "", function(self)
		if self.index and self.lack and self.lack > 0 then Buy(self.index, self.lack, self.id) end
	end)
	link:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
	link:SetFrameLevel(frame:GetFrameLevel() + 5)
	Skin.Tooltip(link, function()
		local cost = link.index and link.lack and Cost(link.index, link.lack)
		return L.MERCHANT_BUY_DESC:format(link.lack or 0, cost and U.Coins(cost) or "?")
	end, "ANCHOR_RIGHT")
	links[square] = link
	return link
end

function ns.RefreshMerchant()
	if not (MerchantFrame and MerchantFrame:IsShown()) then return end
	local list = ns.Shopping()
	local buying = (MerchantFrame.selectedTab or 1) == 1 and next(list) ~= nil
	local perPage = MERCHANT_ITEMS_PER_PAGE or 10
	local page = MerchantFrame.page or 1
	for square = 1, perPage do
		local index = (page - 1) * perPage + square
		local id = buying and Clean(Safe(GetMerchantItemID, index))
		local lack = id and list[id] and ns.Lacking(id) or 0
		local link = (lack > 0 or links[square]) and Link(square)
		if link then
			local buyable = lack > 0 and Cost(index, lack) ~= nil
			link.index, link.lack, link.id = index, lack, id
			if buyable then link:SetLabel(U.Colorize("+" .. lack, 1, 0.82, 0)) end
			link:SetShown(buyable)
		end
	end
end

do
	local events = CreateFrame("Frame")
	events:SetScript("OnEvent", function(_, event)
		if event == "MERCHANT_SHOW" then
			open = true
			events:RegisterEvent("BAG_UPDATE_DELAYED")
			events:RegisterEvent("MERCHANT_UPDATE")
			-- (Shift held on arrival: nothing bought, as for the junk and the repair)
			local settings = ns.Settings()
			if ns.On() and settings and settings.autoBuy and not U.IsSkipping() and next(ns.Shopping()) then
				C_Timer.After(1, function() WhenSold(0) end)
			end
		elseif event == "MERCHANT_CLOSED" then
			open = false
			events:UnregisterEvent("BAG_UPDATE_DELAYED")
			events:UnregisterEvent("MERCHANT_UPDATE")
			return
		end
		ns.RefreshMerchant()
	end)
	pcall(events.RegisterEvent, events, "MERCHANT_SHOW")
	pcall(events.RegisterEvent, events, "MERCHANT_CLOSED")
	-- Its pages and tabs turned: the links with them.
	if MerchantFrame_Update then hooksecurefunc("MerchantFrame_Update", function() ns.RefreshMerchant() end) end
end
