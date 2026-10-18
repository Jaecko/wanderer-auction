local ADDON, ns = ...
local L = ns.L

-- The auction house, in Wanderer's window: four tabs (to sell, to buy, what
-- you follow, your shopping list), each a table on the left and what is
-- chosen on the right, one main button per page. It opens and closes with the
-- auction house, the game's own window then out of sight; a link brings the
-- game's back (and one beside it, Wanderer's). Its pieces are Wanderer's own
-- (Wanderer.Skin): the windows of Wanderer and its extensions look alike.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin

ns.WIDTH, ns.HEIGHT = 1080, 680 -- at first; then as you leave it
local MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT = 1080, 600, 1700, 1150
ns.ROW = 34 -- a table's row
ns.GAP = 20 -- between a table and what is chosen

-- The game's auction house functions, looked up when used.
ns.AH = setmetatable({}, { __index = function(_, key) return C_AuctionHouse and C_AuctionHouse[key] end })

-- The auction house takes one query at a time: ready for the next one.
function ns.Ready() return U.Clean(U.Safe(ns.AH.IsThrottledMessageSystemReady)) and true or false end

local window, reopen, money
local pages, order = {}, {}
local current = "sell"
local atAuction = false -- the auction house open
local mode = "wanderer" -- this visit: "wanderer" (the game's window out of sight) or "game"
local switching = false -- Wanderer's window hidden to show the game's (the auction house stays open)

function ns.On()
	local settings = ns.Settings()
	return settings and settings.enabled and true or false
end

-- A page: its name, its tab's label, how it is built (once), what it does when shown and closed, and a
-- count beside its tab (what waits for you there; nil: none) and that count's tone (red by default).
function ns.AddPage(name, label, build, onShow, onClose, badge, badgeTone)
	pages[name] = { label = label, build = build, onShow = onShow, onClose = onClose, badge = badge, badgeTone = badgeTone }
	order[#order + 1] = name
end

-- An auction's duration (1 to 3), as the game names it (its own words: the durations are its own).
local DURATION_KEYS, DURATION_HOURS = { "ONE", "TWO", "THREE" }, { 2, 8, 24 }
function ns.DurationName(index)
	local name = _G["AUCTION_DURATION_" .. (DURATION_KEYS[index] or "TWO")]
	return type(name) == "string" and name or L.DURATION:format(DURATION_HOURS[index] or 8)
end

function ns.IsShown() return window and window:IsShown() or false end
function ns.MainWindow() return window end
function ns.CurrentPage() return current end
function ns.AtAuction() return atAuction end

-- The tabs: the page shown underlined in gold; a count beside those where something waits.
function ns.RefreshTabs()
	if not window then return end
	for name, page in pairs(pages) do
		local tab = page.tab
		local shown = name == current
		local color = shown and Skin.COLORS.gold or { 0.72, 0.68, 0.61 }
		tab.text:SetTextColor(color[1], color[2], color[3])
		tab.line:SetShown(shown)
		local count = page.badge and page.badge()
		tab.badge:Set(count and count > 0 and tostring(count) or nil, page.badgeTone or "red")
		tab:SetWidth(U.Measure(tab.text, "GetStringWidth", 60) + (tab.badge:IsShown() and tab.badge:GetWidth() + 8 or 0))
	end
end

function ns.ShowPage(name)
	current = name
	if not window then return end
	for key, page in pairs(pages) do
		page.frame:SetShown(key == name)
	end
	ns.RefreshTabs()
	if pages[name].onShow then pages[name].onShow() end
end

-- The game's window --------------------------------------------------------------------------------

-- Out of sight while Wanderer's is used (still open: the auction house with it), back in its place
-- otherwise.
local function PlaceGameWindow()
	U.HideOffScreen(_G.AuctionHouseFrame, atAuction and mode == "wanderer")
end

-- The game places its windows again and again (another one opened, its tabs): out of sight each time.
local hooked = false
local function HookGameWindow()
	local frame = _G.AuctionHouseFrame
	if hooked or not frame then return end
	hooked = true
	frame:HookScript("OnShow", PlaceGameWindow)
	if UpdateUIPanelPositions then
		hooksecurefunc("UpdateUIPanelPositions", function()
			if atAuction and mode == "wanderer" then PlaceGameWindow() end
		end)
	end
	-- An item of your bags right-clicked: chosen to sell, here.
	if frame.SetPostItem then
		hooksecurefunc(frame, "SetPostItem", function(_, location)
			if mode == "wanderer" and ns.SellLocation then ns.SellLocation(location) end
		end)
	end
end

local Create

-- The game's window, Wanderer's out of sight (the auction house stays open).
function ns.UseGame()
	mode = "game"
	if window and window:IsShown() then
		switching = true
		window:Hide()
		switching = false
	end
	PlaceGameWindow()
	if reopen then reopen:Show() end
end

-- Wanderer's window, the game's out of sight (on a page, else the last one).
function ns.UseWanderer(page)
	mode = "wanderer"
	if reopen then reopen:Hide() end
	PlaceGameWindow()
	ns.Open(page)
end

-- The window ----------------------------------------------------------------------------------------

function Create()
	window = W.Skin.CreateWindow("WandererAuctionWindow", "MEDIUM") -- (not "WandererAuction": the prices shared with the other addons)
	W.Skin.Dress(window, { "TOPLEFT", UIParent, "TOPLEFT", 24, -110 }, "auctionWindow")
	local saved = ns.Settings() and ns.Settings().size
	window:SetSize(Skin.Within(saved and saved[1] or ns.WIDTH, MIN_WIDTH, MAX_WIDTH), Skin.Within(saved and saved[2] or ns.HEIGHT, MIN_HEIGHT, MAX_HEIGHT))
	local _, _, margin = Skin.Header(window, "Wanderer", L.WINDOW_TITLE, 10, "GameFontNormalLarge")
	-- Your money, and the game's own window, on the right (the cross after them).
	local game = (W.Skin.SmallButton or W.Skin.CreateLink)(window, L.GAME_WINDOW, function()
		if U.PlaySound then U.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON") end
		ns.UseGame()
	end, L.GAME_WINDOW_DESC)
	game:SetPoint("TOPRIGHT", window, "TOPRIGHT", -(margin + 26), -margin + 2)
	money = Skin.Text(window, "GameTooltipText", "soft")
	money:SetPoint("RIGHT", game, "LEFT", -18, 0)
	-- The tabs, in a row, the one shown underlined.
	local rule = Skin.Rule(window)
	rule:SetPoint("TOPLEFT", window, "TOPLEFT", margin, -(margin + 68))
	rule:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
	local previous
	for _, name in ipairs(order) do
		local page = pages[name]
		local tab = CreateFrame("Button", nil, window)
		tab:SetHeight(30)
		tab.text = W.Skin.CreateText(tab, "GameFontNormal")
		tab.text:SetPoint("LEFT")
		tab.text:SetText(page.label)
		tab.badge = Skin.Chip(tab)
		tab.badge:SetPoint("LEFT", tab.text, "RIGHT", 7, 0)
		tab.line = tab:CreateTexture(nil, "ARTWORK")
		tab.line:SetColorTexture(1, 0.82, 0, 1)
		tab.line:SetHeight(2)
		tab.line:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, -1)
		tab.line:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, -1)
		tab:SetScript("OnClick", function()
			if U.PlaySound then U.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON") end
			ns.ShowPage(name)
		end)
		if previous then tab:SetPoint("LEFT", previous, "RIGHT", 26, 0) else tab:SetPoint("BOTTOMLEFT", rule, "TOPLEFT", 0, 0) end
		page.tab = tab
		previous = tab
	end
	-- What is said under it all.
	local footer = Skin.Text(window, "GameTooltipTextSmall", "muted")
	footer:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin - 4)
	footer:SetText(L.FOOTER)
	for _, name in ipairs(order) do
		local page = pages[name]
		page.frame = CreateFrame("Frame", nil, window)
		page.frame:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 0, -14)
		page.frame:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin + 16)
		page.build(page.frame)
	end
	-- Its corner: dragged, the window grows or shrinks, each page's table with it (page.frame.Fit); its size kept.
	local function Fit()
		for _, page in pairs(pages) do
			local height = page.frame:GetHeight()
			if page.frame.Fit and height and height > 0 then page.frame:Fit(height) end
		end
	end
	Skin.Resizable(window, {
		minWidth = MIN_WIDTH, minHeight = MIN_HEIGHT, maxWidth = MAX_WIDTH, maxHeight = MAX_HEIGHT,
		onResized = function(width, height)
			if ns.Settings() then ns.Settings().size = { width, height } end
		end,
	})
	window:HookScript("OnSizeChanged", function()
		local skin = Skin.Get(window)
		if skin then skin:Layout() end
		Fit()
	end)
	Fit()
	window:HookScript("OnShow", function(self)
		self:SetScale(W.Skin.Scale())
		Fit()
		ns.ShowMoney()
		ns.ShowPage(current)
	end)
	-- Closed by hand (its cross, Escape): the auction house with it, as the game's window does (not when
	-- the whole interface is hidden, Alt+Z: it is still shown then).
	window:HookScript("OnHide", function(self)
		if switching or self:IsShown() or not atAuction or mode ~= "wanderer" then return end
		U.Safe(ns.AH.CloseAuctionHouse)
	end)
	W.Skin.Get(window):Layout()
end

-- Your money, at the top.
function ns.ShowMoney()
	if money then money:SetText(U.Coins(U.Clean(U.Safe(GetMoney)) or 0)) end
end

function ns.Open(page)
	if page then current = page end
	if not window then Create() end
	if window:IsShown() then ns.ShowPage(current) else window:Show() end
end

function ns.Close()
	atAuction = false
	-- A question left open answers nothing once the auction house is gone.
	Skin.CancelAsk()
	ns.Hear(false)
	if window then window:Hide() end
	PlaceGameWindow()
	if reopen then reopen:Hide() end
	for _, page in pairs(pages) do
		if page.onClose then page.onClose() end
	end
end

-- The link beside the game's window, back to Wanderer's.
local function Reopen()
	if reopen or not _G.AuctionHouseFrame then return end
	reopen = (W.Skin.SmallButton or W.Skin.CreateLink)(UIParent, L.TITLE, function() ns.UseWanderer() end)
	reopen:SetFrameStrata("HIGH")
	reopen:SetPoint("TOPLEFT", _G.AuctionHouseFrame, "TOPRIGHT", 6, -4)
	reopen:Hide()
end

-- An item by its key: name, quality, icon, link (the game may send them a moment later: false then).
function ns.Describe(entry)
	local info = U.Safe(ns.AH.GetItemKeyInfo, entry.key)
	if type(info) ~= "table" then return false end
	entry.name, entry.quality, entry.icon = U.Clean(info.itemName) or "", U.Clean(info.quality) or 1, U.Clean(info.iconFileID)
	entry.commodity = U.Clean(info.isCommodity) and true or false
	if not entry.link then
		local _, link = U.ItemInfo(entry.id)
		entry.link = link
	end
	return true
end

-- "Short", "Long"... (the game's words for the time left).
function ns.TimeLeft(band)
	return band and _G["AUCTION_TIME_LEFT" .. (band + 1)] or ""
end


-- Init ------------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
ns.Events = {} -- event -> handlers of the pages (heard only while the auction house is open)
function ns.Listen(event, handler)
	ns.Events[event] = ns.Events[event] or {}
	table.insert(ns.Events[event], handler)
end

-- The pages' events: heard at the auction house, let go when it closes.
function ns.Hear(on)
	for event in pairs(ns.Events) do
		pcall(on and events.RegisterEvent or events.UnregisterEvent, events, event)
	end
end

-- A page's handler: its error reported by the game without stopping the others (outside the game, raised).
local function Run(handler, ...)
	if not geterrorhandler then return handler(...) end
	xpcall(handler, geterrorhandler(), ...)
end

events:SetScript("OnEvent", function(_, event, ...)
	if event == "AUCTION_HOUSE_SHOW" then
		if not ns.On() then return end
		atAuction = true
		ns.Hear(true)
		mode = ns.Settings().replace and "wanderer" or "game"
		-- The game's window comes with this same event: placed now if it is there, else a moment later.
		local function Place()
			HookGameWindow()
			Reopen()
			PlaceGameWindow()
			if mode == "game" and reopen then reopen:Show() end
		end
		Place()
		C_Timer.After(0, function() if atAuction then Place() end end)
		if mode == "wanderer" then ns.Open() end
		-- (what you follow, looked at on arrival: the tabs say what waits)
		if ns.OnArrive then ns.OnArrive() end
		return
	elseif event == "AUCTION_HOUSE_CLOSED" then
		return ns.Close()
	end
	for _, handler in ipairs(ns.Events[event] or {}) do Run(handler, ...) end
end)

ns.Listen("PLAYER_MONEY", function() ns.ShowMoney() end)

function ns.Init()
	if not (W and W.RegisterExtension) then return end
	-- An older Wanderer: said once, nothing taken.
	if (W.API or 1) < 6 then return W.Print(L.NEEDS_WANDERER) end
	W.RegisterExtension({
		key = "auction",
		addon = ADDON,
		title = L.TITLE,
		news = L.NEWS_LINES,
		-- (autoBuy, buyCap: each character's now, kept with its list; read once as its start)
		defaults = { enabled = true, replace = true, duration = "2", tooltip = true, autoBuy = false, buyCap = 5, toMerchant = true },
		-- Wanderer's menu: the shopping list, anywhere.
		launcher = { label = L.SHOPPING, open = function() ns.ToggleList() end },
		refresh = function()
			if ns.IsShown() and not ns.On() then ns.Close() end
		end,
		options = function(o)
			o.Header(L.TITLE)
			local enabled = o.Checkbox("auction", "enabled", L.ENABLE, L.ENABLE_DESC)
			local on = o.IsOn("auction", "enabled")
			o.Under(o.Checkbox("auction", "replace", L.REPLACE, L.REPLACE_DESC), enabled, on)
			o.Under(o.Dropdown("AUCTION_DURATION", L.DURATION_DEFAULT, L.DURATION_DESC, "2",
				{ { "1", ns.DurationName(1) }, { "2", ns.DurationName(2) }, { "3", ns.DurationName(3) } },
				function() return ns.Settings() and ns.Settings().duration or "2" end,
				function(value) if ns.Settings() then ns.Settings().duration = value end end), enabled, on)
			o.Checkbox("auction", "tooltip", L.TOOLTIP, L.TOOLTIP_DESC)
			-- (with Wanderer Bags: set aside for the auction house, but more at a merchant: junk, sold at the next one)
			o.Under(o.Checkbox("auction", "toMerchant", L.TO_MERCHANT, L.TO_MERCHANT_DESC), enabled, on)
			-- At merchants: what the shopping list lacks, bought on arrival (off), for this character (its cap: in
			-- the shopping list's window).
			if o.Toggle then
				o.Under(o.Toggle("AUCTION_AUTOBUY", L.AUTOBUY, L.AUTOBUY_DESC, false, function() return ns.AutoBuy() end,
					function(value) ns.AutoBuy(value) end), enabled, on)
				-- At the banker: what the list lacks, taken from the bank first (off), for this character.
				o.Under(o.Toggle("AUCTION_FROMBANK", L.FROMBANK, L.FROMBANK_DESC, false, function() return ns.FromBank() end,
					function(value) ns.FromBank(value) end), enabled, on)
			end
		end,
	})
	pcall(events.RegisterEvent, events, "AUCTION_HOUSE_SHOW")
	pcall(events.RegisterEvent, events, "AUCTION_HOUSE_CLOSED")
	ns.InitTooltip()
	SLASH_WANDERERAUCTION1 = "/wauction"
	SlashCmdList.WANDERERAUCTION = function() ns.ToggleList() end
end

-- (an older Wanderer, without it: said once)
if W and W.WhenLoaded then W.WhenLoaded(ADDON, ns.Init) elseif W and W.Print then W.Print(L.NEEDS_WANDERER) end
