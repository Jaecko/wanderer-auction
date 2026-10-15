local _, ns = ...
local L = ns.L

-- What the auction house was seen asking for an item, remembered: the game
-- tells prices only there, so the ones shown elsewhere (Wanderer Bags, the
-- tooltips) are those of your last visit, with how long ago. For the whole
-- account and the realm's market, by item id.

local W = Wanderer
local U = W and W.Util

local HOUR, DAY = 3600, 86400
local KEPT = 30 * DAY -- a price older than this says nothing more: let go

local db
local function DB()
	if db then return db end
	WandererAuctionDB = WandererAuctionDB or {}
	WandererAuctionDB.prices = WandererAuctionDB.prices or {}
	db = WandererAuctionDB
	-- The old prices let go once a session (the file read at login stays small).
	local now = time()
	for id, seen in pairs(db.prices) do
		if type(seen) ~= "table" or now - (seen.time or 0) > KEPT then db.prices[id] = nil end
	end
	return db
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

-- The shopping list ------------------------------------------------------------------------------

-- What you want to buy: item id -> { count, note (what for), time }. For the whole account.
function ns.Shopping()
	local saved = DB()
	saved.shopping = type(saved.shopping) == "table" and saved.shopping or {}
	return saved.shopping
end

local function ItemName(id)
	local name = U.Clean(U.Safe(C_Item and C_Item.GetItemNameByID or GetItemInfo, id))
	return name or ("#" .. id)
end

-- An item added (or how many raised): said once.
function ns.AddToShopping(id, count, note)
	id, count = tonumber(id), math.max(1, tonumber(count) or 1)
	if not id then return false end
	local list = ns.Shopping()
	local entry = list[id]
	if entry then
		entry.count = math.max(entry.count or 1, count)
	else
		list[id] = { count = count, note = type(note) == "string" and note or nil, time = time() }
	end
	if W.Print then W.Print(L.SHOPPING_ADDED:format(ItemName(id))) end
	if ns.RefreshShopping then ns.RefreshShopping() end
	return true
end

function ns.RemoveFromShopping(id)
	local list = ns.Shopping()
	if not list[id] then return end
	list[id] = nil
	if W.Print then W.Print(L.SHOPPING_REMOVED:format(ItemName(id))) end
end

-- For the other addons (Wanderer Bags): the price of an item by its link, and its age in days.
WandererAuction = {
	Price = function(link)
		local price, age = ns.Price(ItemID(link))
		return price, age and math.floor(age / DAY) or nil
	end,
	-- A name searched at the auction house (open), in the window's buying page.
	Search = function(text) if ns.SearchFor then return ns.SearchFor(text) end end,
	-- The auction house open, in Wanderer's window.
	IsOpen = function() return ns.IsShown and ns.IsShown() or false end,
	-- The shopping list: an item to buy (how many, what for), one known.
	AddToShopping = function(id, count, note) return ns.AddToShopping(id, count, note) end,
	InShopping = function(id) return ns.Shopping()[tonumber(id) or -1] ~= nil end,
}

-- Over an item, its price at the auction house (only without Auctionator: it says it already).
function ns.InitTooltip()
	if not (TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item) then return end
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
		-- (the price first: most items have none, nothing more asked then)
		local price, age = ns.Price(type(data) == "table" and U.Clean(data.id))
		if not price then return end
		local settings = ns.Settings()
		if not (settings and settings.tooltip) or type(Auctionator) == "table" or InCombatLockdown() then return end
		local name = tooltip.GetName and U.Clean(U.Safe(tooltip.GetName, tooltip)) or ""
		if name:find("^ShoppingTooltip") or name:find("^ItemRefShoppingTooltip") then return end
		tooltip:AddLine(L.TOOLTIP_LINE:format(U.Coins(price), ns.Age(age)), 0.62, 0.74, 0.86)
		tooltip:Show()
	end)
end
