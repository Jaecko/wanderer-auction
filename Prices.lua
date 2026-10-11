local _, ns = ...
local L = ns.L

-- What the auction house was seen asking for an item, remembered: the game
-- tells prices only there, so the ones shown elsewhere (Wanderer Bags, the
-- tooltips) are those of your last visit, with how long ago. For the whole
-- account and the realm's market, by item id.

local W = Wanderer
local U = W and W.Util

local HOUR, DAY = 3600, 86400

local function DB()
	WandererAuctionDB = WandererAuctionDB or {}
	WandererAuctionDB.prices = WandererAuctionDB.prices or {}
	return WandererAuctionDB
end
ns.DB = DB

function ns.Settings()
	return W and W.Settings("auction")
end

-- The lowest price seen for an item, each (copper), now.
function ns.Remember(id, price)
	id, price = tonumber(id), tonumber(price)
	if not (id and price and price > 0) then return end
	DB().prices[id] = { price = price, time = time() }
end

-- The price remembered and its age in seconds, or nil.
function ns.Price(id)
	local seen = DB().prices[tonumber(id) or -1]
	if not seen then return nil end
	return seen.price, math.max(0, time() - (seen.time or time()))
end

-- "2 d ago"
function ns.Age(seconds)
	if not seconds or seconds < HOUR then return L.AGE_NOW end
	if seconds < DAY then return L.AGE_HOURS:format(math.floor(seconds / HOUR)) end
	return L.AGE_DAYS:format(math.floor(seconds / DAY))
end

-- Money ----------------------------------------------------------------------------------------

-- The auction house's cut on a sale (the game says it nowhere: 5 %, as it has long been).
ns.CUT = 0.05

-- What a sale at this price brings once the auction house has taken its cut (the deposit comes back).
function ns.Net(price)
	return math.floor((price or 0) * (1 - ns.CUT))
end

-- What a merchant gives for one (0: none buys it).
function ns.Vendor(link)
	local price = link and U.SellPrice(link)
	return price and price > 0 and price or 0
end

-- The least price worth asking, each: its net above the merchant's (in silver where copper is not
-- taken). 0 when no merchant buys it.
function ns.Floor(vendor)
	if not vendor or vendor <= 0 then return 0 end
	local price = math.ceil((vendor + 1) / (1 - ns.CUT))
	while ns.Net(price) <= vendor do price = price + 1 end
	if not (ns.CopperOnly and ns.CopperOnly()) then price = math.ceil(price / 100) * 100 end
	return price
end

-- Under an item to buy: what a merchant gives for it, in green when more than its price here.
function ns.MerchantLine(link, unit)
	local vendor = ns.Vendor(link)
	if vendor == 0 then return "" end
	local color = unit and unit < vendor and "|cff66dd66" or "|cff8c8070"
	return "\n" .. color .. L.MERCHANT_GIVES:format(U.Coins(vendor)) .. "|r"
end

local function ItemID(link)
	return link and tonumber(link:match("item:(%d+)"))
end

-- For the other addons (Wanderer Bags): the price of an item by its link, and its age in days.
WandererAuction = {
	Price = function(link)
		local price, age = ns.Price(ItemID(link))
		return price, age and math.floor(age / DAY) or nil
	end,
	-- A name searched at the auction house (open), in the window's buying page.
	Search = function(text) if ns.SearchFor then ns.SearchFor(text) end end,
}

-- Over an item, its price at the auction house (only without Auctionator: it says it already).
function ns.InitTooltip()
	if not (TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item) then return end
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
		local settings = ns.Settings()
		if not (settings and settings.tooltip) or type(Auctionator) == "table" or InCombatLockdown() then return end
		local name = tooltip.GetName and U.Clean(U.Safe(tooltip.GetName, tooltip)) or ""
		if name:find("^ShoppingTooltip") or name:find("^ItemRefShoppingTooltip") then return end
		local price, age = ns.Price(type(data) == "table" and U.Clean(data.id))
		if not price then return end
		tooltip:AddLine(L.TOOLTIP_LINE:format(U.Coins(price), ns.Age(age)), 0.62, 0.74, 0.86)
		tooltip:Show()
	end)
end
