local _, ns = ...
local L = ns.L

-- Your shopping list anywhere, in a small Wanderer window: what you carry against what you want, what for.
-- A click changes how many, its link takes it off, a Shift+click on an item adds it (how many asked). At the
-- auction house, a button searches them all there. Opened from the bags' heading (Wanderer Bags), a tab on
-- the merchant's window, Wanderer's menu, a key of yours or /wauction list.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin

local WIDTH, HEIGHT = 560, 420
local ROWS = 12

local window, list, rows = nil, nil, {}
local tab -- the merchant's side tab

local Carried = U and U.ItemCount

-- How many items the list still lacks (those you carry enough of are leaving it).
function ns.ShoppingLack()
	local count = 0
	for id, entry in pairs(ns.Shopping()) do
		if Carried(id) < (entry.count or 1) then count = count + 1 end
	end
	return count
end

local function Draw()
	if not (list and window:IsShown()) then return end
	local offset = list:Clamp(#rows)
	for index, row in ipairs(list.rows) do
		local entry = rows[index + offset]
		local values
		if entry then
			values = {
				what = entry.note or (entry.keep and L.KEEP_NOTE) or L.YOUR_LIST,
				have = ns.HaveWant(entry.have, entry.want),
			}
		end
		-- (always on you: its chip, gold)
		row:Fill(entry, false, values, entry and entry.keep and L.CHIP_KEEP or nil, "gold", entry and L.REMOVE,
			entry and function() ns.RemoveFromShopping(entry.id) end)
	end
	list.empty:SetShown(#rows == 0)
end

local function Gather()
	rows = ns.ShoppingRows()
	Draw()
end

-- A name the game was fetching (heard only while the window is shown): drawn again.
local names = CreateFrame("Frame")
names:SetScript("OnEvent", U and U.Debounce and U.Debounce(0.3, function() if window and window:IsShown() then Gather() end end) or nil)

-- How many you want to carry, asked (a click on its row, an item Shift+clicked, Wanderer Bags' menu): what the
-- list wants already, else a stack. keep: always on you (true), once (false), as it is (nil).
local function Ask(id, keep)
	if not id then return end
	local entry = ns.Shopping()[id]
	local stack = U.ItemMaxStack(id)
	local default = entry and entry.count or (stack > 1 and stack or Carried(id) + 1)
	local prompt = keep and L.LIST_KEEP_HOW_MANY or L.LIST_HOW_MANY
	Skin.AskText(prompt:format(U.ItemName(id) or ("#" .. id)), tostring(default), function(text)
		local count = tonumber(text)
		if count and count > 0 then ns.SetShopping(id, math.floor(count), nil, keep) end
	end, 5)
end

local function Create()
	window = Skin.CreateWindow("WandererShoppingList", "MEDIUM")
	Skin.Dress(window, { "CENTER", UIParent, "CENTER", 260, 60 }, "shoppingListPos")
	window:SetSize(WIDTH, HEIGHT)
	local _, title, margin = Skin.Header(window, "Wanderer", L.SHOPPING)
	local intro = Skin.Text(window, "GameTooltipTextSmall", "muted")
	intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	intro:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
	intro:SetJustifyH("LEFT")
	intro:SetText(L.LIST_INTRO)
	list = Skin.Table(window, {
		nameTitle = L.COL_ITEM, width = WIDTH - margin * 2, rows = ROWS, action = 80,
		-- A click: how many; a right click: always on you, or once.
		onClick = function(entry, mouse)
			if mouse ~= "RightButton" then return Ask(entry.id) end
			local wanted = ns.Shopping()[entry.id]
			if wanted then ns.SetShopping(entry.id, wanted.count or 1, nil, not wanted.keep) end
		end, onDraw = Draw,
		columns = {
			{ key = "what", title = L.COL_FOR, width = 130, justify = "LEFT" },
			{ key = "have", title = L.COL_CARRIED, width = 70 },
		},
	})
	list:SetPoint("TOPLEFT", window, "TOPLEFT", margin, -(margin + 74))
	list.empty:SetText(L.LIST_EMPTY)
	list:Fit(HEIGHT - (margin + 74) - (margin + 64))
	-- At the auction house: all of them searched there (its own page).
	window.search = Skin.Button(window, L.SEARCH_ALL, function()
		window:Hide()
		ns.Open("shopping")
	end, "main")
	window.search:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin)
	-- Buying on arrival at merchants, for this character (the option of Wanderer's settings, here too), and
	-- its cap: a click changes it.
	window.autoBuy = Skin.Check(window, L.LIST_AUTOBUY, function() return ns.AutoBuy() end, function(value)
		ns.AutoBuy(value)
		window.cap:SetShown(value)
	end, L.AUTOBUY_DESC)
	window.autoBuy:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin + 30)
	-- Taking from the bank first, at the banker, for this character.
	window.fromBank = Skin.Check(window, L.LIST_FROMBANK, function() return ns.FromBank() end, function(value) ns.FromBank(value) end,
		L.FROMBANK_DESC)
	window.fromBank:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin + 6)
	window.cap = (Skin.SmallButton or Skin.CreateLink)(window, "", function()
		Skin.AskText(L.LIST_CAP_ASK, tostring(ns.BuyCap()), function(text)
			local gold = tonumber(text)
			if gold and gold >= 1 then
				ns.BuyCap(gold)
				window.cap:SetLabel(L.LIST_CAP:format(U.Coins(ns.BuyCap() * 10000)))
			end
		end, 3)
	end, L.LIST_CAP_DESC)
	window.cap:SetPoint("LEFT", window.autoBuy, "RIGHT", 6, 0)
	window:HookScript("OnHide", function() names:UnregisterEvent("GET_ITEM_INFO_RECEIVED") end)
	window:HookScript("OnShow", function(self)
		names:RegisterEvent("GET_ITEM_INFO_RECEIVED")
		self.autoBuy:Refresh()
		self.fromBank:Refresh()
		self.cap:SetLabel(L.LIST_CAP:format(U.Coins(ns.BuyCap() * 10000)))
		self.cap:SetShown(ns.AutoBuy())
		self:SetScale(Skin.Scale())
		self.search:SetShown(ns.IsShown and ns.IsShown() or false)
		list.offset = 0
		Gather()
	end)
	Skin.Get(window):Layout()
end

function ns.ToggleList()
	if not window then Create() end
	window:SetShown(not window:IsShown())
end

-- The merchant's side tab and the bags' link say how many items are still missing.
local function Badges()
	local lack = ns.ShoppingLack()
	if tab then
		tab.count:SetText(lack > 0 and lack or "")
	end
	if type(WandererBagsMarks) == "table" and WandererBagsMarks.Refresh then WandererBagsMarks.Refresh() end
end

-- The list changed: this window drawn again, the counts with it.
function ns.RefreshList()
	if window and window:IsShown() then Gather() end
	Badges()
end

-- On the merchant's window, a side tab (as the spellbook's): the list beside him.
local function MerchantTab()
	if tab or not MerchantFrame then return end
	tab = CreateFrame("Button", "WandererShoppingTab", MerchantFrame)
	tab:SetSize(32, 32)
	tab:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 0, -48)
	local ground = tab:CreateTexture(nil, "BACKGROUND")
	ground:SetSize(64, 64)
	ground:SetPoint("TOPLEFT", -3, 11)
	ground:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
	local icon = tab:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
	tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	tab.count = tab:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	tab.count:SetPoint("BOTTOMRIGHT", -2, 2)
	tab:SetScript("OnClick", function() ns.ToggleList() end)
	Skin.Tooltip(tab, function()
		local lack = ns.ShoppingLack()
		return L.SHOPPING .. "\n" .. (lack > 0 and L.LIST_LACK:format(lack) or L.LIST_NOTHING)
	end, "ANCHOR_RIGHT")
	Badges()
end

-- For the other addons (Wanderer Bags' heading): the window, how many items it still lacks.
if type(WandererAuction) == "table" then
	WandererAuction.ToggleList = function() ns.ToggleList() end
	WandererAuction.ShoppingLack = function() return ns.ShoppingLack() end
	WandererAuction.AskShopping = function(id, keep) Ask(tonumber(id), keep) end
end

-- Wanderer's key binding (the game's key options, "Wanderer Auction").
BINDING_HEADER_WANDERERAUCTION = "Wanderer Auction"
BINDING_NAME_WANDERERAUCTION_LIST = L.SHOPPING
function WandererAuction_ToggleList() ns.ToggleList() end

do
	local events = CreateFrame("Frame")
	pcall(events.RegisterEvent, events, "MERCHANT_SHOW")
	pcall(events.RegisterEvent, events, "BAG_UPDATE_DELAYED")
	events:SetScript("OnEvent", function(_, event)
		if event == "MERCHANT_SHOW" then
			MerchantTab()
			Badges()
		elseif window and window:IsShown() then
			Gather()
		end
	end)
end

-- A Shift+click on an item (your bags, a link) while the list is shown (here, or its page at the auction
-- house): added, how many asked.
if hooksecurefunc and ChatEdit_InsertLink then
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		local shown = (window and window:IsShown()) or (ns.ShoppingPageShown and ns.ShoppingPageShown())
		if shown then Ask(U.ItemID(link)) end
	end)
end
