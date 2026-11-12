local _, ns = ...
local L = ns.L

-- At a merchant: an item of your shopping list he sells says, beside it, how many the list still lacks
-- ("+12"); a click buys just that (in stacks, a moment apart, as the server expects). Only for gold: what
-- costs tokens or items is left to the game. Nothing runs away from a merchant.
-- An option (off): all of it bought on arrival, never above a cap per visit (said instead), Shift skipping it.
-- What merchants sell for gold and without end (thread, flux, vials...) is learned while you look at them, for
-- the whole account: the shopping list then says "at a merchant" and the auction house is not asked for it.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean

local links = {} -- the merchant's squares (1 to MERCHANT_ITEMS_PER_PAGE) -> their link

-- (the purchases themselves are Wanderer's: whole lots, stacks, no more than he has, a moment apart, the item
-- checked each time)
local Cost = U.MerchantCost

-- What merchants sell -----------------------------------------------------------------------------------------

local CLASS_REAGENT, CLASS_TRADE_GOODS = 5, 7

-- (crafting reagents and trade goods only, and what your list wants: not a merchant's whole stock)
local function Learnable(id)
	if ns.Shopping()[id] then return true end
	local reagents = W.Reagents and W.Reagents()
	if type(reagents) == "table" and reagents[id] then return true end
	local class = select(6, U.ItemInstant(id))
	return class == CLASS_REAGENT or class == CLASS_TRADE_GOODS
end

local function Sold()
	local db = ns.DB()
	db.merchantSold = type(db.merchantSold) == "table" and db.merchantSold or {}
	return db.merchantSold
end

-- The merchant shown: what he sells for gold, without end, learned (the price of one, the lowest seen).
local function Learn()
	local sold = Sold()
	for index = 1, Clean(Safe(GetMerchantNumItems)) or 0 do
		local id = Clean(Safe(GetMerchantItemID, index))
		local price, lot, available, forGold = U.MerchantOffer(index)
		if id and forGold and price and (available == nil or available < 0) and Learnable(id) then
			local each = math.max(1, math.floor(price / lot + 0.5))
			sold[id] = math.min(tonumber(sold[id]) or each, each)
		end
	end
end

-- What one costs at a merchant (copper), nil when no merchant was seen selling it.
function ns.MerchantPrice(id)
	local price = id and Sold()[id]
	return tonumber(price)
end

-- On arrival: what the list lacks of everything he sells, bought in one go (after the junk is sold).
local open = false
local overSaid = {} -- merchants told this session that the list costs more than your cap (said once each)
-- Each arrival counted (a wait for the junk belongs to its own visit), and the purchases under way: never two
-- rounds at once (a merchant closed and opened again: the lacking ones are not bought twice).
local visit, buyingAll = 0, false
local function BuyAll()
	if not (open and ns.On() and ns.AutoBuy()) or buyingAll then return end
	local list, lots, total = ns.Shopping(), {}, 0
	for index = 1, Clean(Safe(GetMerchantNumItems)) or 0 do
		local id = Clean(Safe(GetMerchantItemID, index))
		local lack = id and list[id] and math.min(ns.Lacking(id), U.MerchantMost(index)) or 0
		local cost = lack > 0 and Cost(index, lack)
		if cost then
			lots[#lots + 1] = { index = index, id = id, count = lack }
			total = total + cost
		end
	end
	if not lots[1] then return end
	local cap = ns.BuyCap() * 10000
	if total > cap then
		local who = Clean(Safe(UnitGUID, "npc")) or "?"
		if overSaid[who] then return end
		overSaid[who] = true
		return W.Print(L.AUTOBUY_OVER:format(U.Coins(total), U.Coins(cap)))
	end
	if total > (Clean(Safe(GetMoney)) or 0) then return W.Print(L.AUTOBUY_NO_MONEY:format(U.Coins(total))) end
	local said = {}
	for _, lot in ipairs(lots) do said[#said + 1] = L.POST_WHAT:format(lot.count, U.ItemName(lot.id) or ("#" .. lot.id)) end
	-- (one after the other, each once the last one is asked: Wanderer's purchases; said once all are asked,
	-- the merchant still there: none was cut short)
	buyingAll = true
	U.BuyQueue(lots, function()
		-- (a moment more: the bags count the last purchase)
		C_Timer.After(1, function() buyingAll = false end)
		if open then W.Print(L.AUTOBUY_DONE:format(table.concat(said, ", "), U.Coins(total))) end
	end)
end

-- (the junk being sold first, or the last visit's purchases still under way: waited for, a little at a time)
local function WhenSold(tries, mine)
	if not open or mine ~= visit then return end
	if (buyingAll or W.IsSellingJunk and W.IsSellingJunk()) and tries < 60 then
		return C_Timer.After(0.5, function() WhenSold(tries + 1, mine) end)
	end
	BuyAll()
end

local function Link(square)
	if links[square] then return links[square] end
	local frame = _G["MerchantItem" .. square]
	if not frame then return nil end
	local link = Skin.SmallButton(frame, "", function(self)
		if ns.On() and self.index and self.lack and self.lack > 0 then U.BuyFromMerchant(self.index, self.lack, self.id) end
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
	if not (U.BuyFromMerchant and MerchantFrame and MerchantFrame:IsShown()) then return end
	local list = ns.Shopping()
	-- (the addon switched off: no link, those made hidden)
	local buying = ns.On() and (MerchantFrame.selectedTab or 1) == 1 and next(list) ~= nil
	local perPage = MERCHANT_ITEMS_PER_PAGE or 10
	local page = MerchantFrame.page or 1
	for square = 1, perPage do
		local index = (page - 1) * perPage + square
		local id = buying and Clean(Safe(GetMerchantItemID, index))
		local lack = id and list[id] and math.min(ns.Lacking(id), U.MerchantMost(index)) or 0
		local link = (lack > 0 or links[square]) and Link(square)
		if link then
			local buyable = lack > 0 and Cost(index, lack) ~= nil
			link.index, link.lack, link.id = index, lack, id
			if buyable then link:SetLabel(Skin.Colorize("+" .. lack, "gold")) end
			link:SetShown(buyable)
		end
	end
end

ns.AtStart(function()
	local events = CreateFrame("Frame")
	-- (his list learned on arrival, then once after a run of changes: each purchase or sale sends one)
	local learnLater = U and U.Debounce and U.Debounce(1, function() if open and ns.On() then Learn() end end)
	events:SetScript("OnEvent", function(_, event)
		-- (an older Wanderer, without the purchases: Auction says it needs a newer one)
		if not U.BuyFromMerchant then return end
		if event == "MERCHANT_SHOW" and ns.On() then
			Learn()
		elseif event == "MERCHANT_UPDATE" and learnLater then
			learnLater()
		end
		if event == "MERCHANT_SHOW" then
			open, visit = true, visit + 1
			events:RegisterEvent("BAG_UPDATE_DELAYED")
			events:RegisterEvent("MERCHANT_UPDATE")
			-- (Shift held on arrival: nothing bought, as for the junk and the repair)
			if ns.On() and ns.AutoBuy() and not U.IsSkipping() and next(ns.Shopping()) then
				local mine = visit
				C_Timer.After(1, function() WhenSold(0, mine) end)
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
end)
