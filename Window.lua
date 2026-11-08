local ADDON, ns = ...
local L = ns.L

-- The auction house, in Wanderer's window: five tabs (to sell, to buy, what
-- you follow, the prices' history, your shopping list), each a table on the
-- left and what is chosen on the right, one main button per page, a "Help"
-- word per page at the end of the tabs, keys while the pointer is over the
-- window (the page says which, its buttons show them). It opens and closes with the
-- auction house, the game's own window then out of sight; a link brings the
-- game's back (and one beside it, Wanderer's). Its pieces are Wanderer's own
-- (Wanderer.Skin): the windows of Wanderer and its extensions look alike.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin

ns.WIDTH, ns.HEIGHT = 1040, 660 -- at first; then as you leave it
local MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT = 1040, 640, 1700, 1150
ns.GAP = 20 -- between a table and what is chosen

-- The game's auction house functions, looked up when used.
-- (a debug session on: each one written down with its answer, see Debug.lua)
ns.AH = setmetatable({}, { __index = function(_, key)
	local fn = C_AuctionHouse and C_AuctionHouse[key]
	if ns.debugging and ns.DebugCall then return ns.DebugCall(key, fn) end
	return fn
end })

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

-- Wanderer's window in place of the game's. Auctionator or TradeSkillMaster there (they work in the game's
-- window): off, until you choose; your choice then kept whatever is loaded.
local function Yielded() return W.Yields and W.Yields("auctionWindow") ~= nil or false end
function ns.Replace()
	local settings = ns.Settings()
	if not settings then return false end
	if not settings.replaceChosen then settings.replace = not Yielded() end
	return settings.replace and true or false
end

-- A page: its name, its tab's label, how it is built (once), what it does when shown and closed, and a
-- count beside its tab (what waits for you there; nil: none) and that count's tone (red by default).
function ns.AddPage(name, label, build, onShow, onClose, badge, badgeTone)
	pages[name] = { label = label, build = build, onShow = onShow, onClose = onClose, badge = badge, badgeTone = badgeTone }
	order[#order + 1] = name
end

-- What a page says under the heading's "?" (what can be done there, its keys).
function ns.PageHelp(name, text) if pages[name] then pages[name].help = text end end

-- The keys a page answers while it is shown and the pointer is over the window: onKey(key) gives true when it
-- took the key (it then goes no further), false to leave it to the game.
function ns.PageKeys(name, onKey) if pages[name] then pages[name].onKey = onKey end end

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
	if not (window and window.tabs) then return end
	window.tabs:Select(current)
	for name, page in pairs(pages) do
		local count = page.badge and page.badge()
		window.tabs:SetBadge(name, count, page.badgeTone or "red")
	end
end

function ns.ShowPage(name)
	current = name
	if not window then return end
	for key, page in pairs(pages) do
		page.frame:SetShown(key == name)
		if page.helpLink then page.helpLink:SetShown(key == name) end
	end
	ns.RefreshTabs()
	if pages[name].onShow then pages[name].onShow() end
end

-- The game's window --------------------------------------------------------------------------------

-- Out of sight while Wanderer's is used (still open: the auction house with it), back in its place
-- otherwise.
local placeGame
local function PlaceGameWindow() if placeGame then placeGame() end end

local hooked = false
local function HookGameWindow()
	local frame = _G.AuctionHouseFrame
	if hooked or not frame then return end
	hooked = true
	placeGame = W.Skin.AsideGameWindow(frame, function() return atAuction and mode == "wanderer" end)
	-- An item of your bags right-clicked: chosen to sell, here.
	if frame.SetPostItem then
		hooksecurefunc(frame, "SetPostItem", function(_, location)
			-- (only while Wanderer's window is the one used here: never once Auction is switched off)
			if atAuction and mode == "wanderer" and ns.SellLocation then ns.SellLocation(location) end
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
	W.Skin.Sounds(window, W.Skin.SOUNDS.open, W.Skin.SOUNDS.close)
	W.Skin.Dress(window, { "TOPLEFT", UIParent, "TOPLEFT", 24, -110 }, "auctionPos")
	local saved = ns.Settings() and ns.Settings().size
	window:SetSize(Skin.Within(saved and saved[1] or ns.WIDTH, MIN_WIDTH, MAX_WIDTH), Skin.Within(saved and saved[2] or ns.HEIGHT, MIN_HEIGHT, MAX_HEIGHT))
	local _, _, margin = Skin.Header(window, "Wanderer", L.WINDOW_TITLE, { margin = 10, settings = "ext:auction" }, "GameFontNormalLarge")
	-- Your money, and the game's own window, on the right (the page's "?", the cog and the cross after them).
	local game = W.Skin.SmallButton(window, L.GAME_WINDOW, function()
		Skin.Play("click")
		ns.UseGame()
	end, L.GAME_WINDOW_DESC)
	game:SetPoint("TOPRIGHT", window, "TOPRIGHT", -(margin + 54), -margin + 2)
	money = Skin.Text(window, "GameTooltipText", "soft")
	money:SetPoint("RIGHT", game, "LEFT", -18, 0)
	-- The tabs, in a row, the one shown underlined.
	local rule = Skin.Rule(window)
	rule:SetPoint("TOPLEFT", window, "TOPLEFT", margin, -(margin + 68))
	rule:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
	local list = {}
	for _, name in ipairs(order) do list[#list + 1] = { name, pages[name].label } end
	window.tabs = Skin.Tabs(window, list, function(name) ns.ShowPage(name) end)
	window.tabs:SetPoint("BOTTOMLEFT", rule, "TOPLEFT", 0, 0)
	for _, name in ipairs(order) do
		local page = pages[name]
		page.frame = CreateFrame("Frame", nil, window)
		page.frame:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 0, -14)
		page.frame:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin)
		page.build(page.frame)
		-- What can be done on this page: the heading's "?" (the suite's one place for help), shown with its page.
		if page.help then
			page.helpLink = Skin.Help(window, page.help, "HEADING")
			page.helpLink:Hide()
		end
	end
	-- Keys: the page's, while the pointer is over the window (never a key taken from the game by surprise).
	window:SetScript("OnKeyDown", function(self, key) ns.OnKey(self, key) end)
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
			W.ChangeEverywhere(function() if ns.Settings() then ns.Settings().size = { width, height } end end)
		end,
	})
	window:HookScript("OnSizeChanged", function()
		local skin = Skin.Get(window)
		if skin then skin:Layout() end
		Fit()
	end)
	Fit()
	window:HookScript("OnShow", function(self)
		Fit()
		self:SetScale(W.Skin.FitScale(self))
		ns.ShowMoney()
		ns.ShowPage(current)
		ns.Keys(true)
	end)
	-- Closed by hand (its cross, Escape): the auction house with it, as the game's window does (not when
	-- the whole interface is hidden, Alt+Z: it is still shown then).
	window:HookScript("OnHide", function(self)
		ns.Keys(false)
		if switching or self:IsShown() or not atAuction or mode ~= "wanderer" then return end
		U.Safe(ns.AH.CloseAuctionHouse)
	end)
	W.Skin.Get(window):Layout()
end

-- Keys ------------------------------------------------------------------------------------------------------
-- The window hears the keys while it is shown, out of a fight (the game keeps them then): each one goes on to
-- the game unless the page shown takes it, and only while the pointer is over the window (a key pressed to
-- chat, jump or walk never posts anything).

function ns.Keys(on)
	if not window then return end
	on = on and window:IsShown() and not InCombatLockdown()
	if window.EnableKeyboard then pcall(window.EnableKeyboard, window, on and true or false) end
	if on and window.SetPropagateKeyboardInput then pcall(window.SetPropagateKeyboardInput, window, true) end
end

function ns.OnKey(self, key)
	-- (a key that could not be kept from the game does nothing here)
	if InCombatLockdown() then return end
	local page = pages[current]
	local take = false
	if page and page.onKey and self:IsMouseOver() and not Skin.Asking() then
		local ok, taken = pcall(page.onKey, key)
		take = ok and taken and true or false
	end
	if self.SetPropagateKeyboardInput then pcall(self.SetPropagateKeyboardInput, self, not take) end
end

-- A key's word inside a button, at its right (the gesture that also does it).
function ns.KeyLabel(button, word)
	local label = Skin.Text(button, "GameTooltipTextSmall", "text")
	label:SetPoint("RIGHT", button, "RIGHT", -12, 0)
	label:SetAlpha(0.6)
	label:SetText(word or "")
	button.keyLabel = label
	return label
end

-- A price to type ---------------------------------------------------------------------------------------------
-- One box for an amount: shown with its coins, typed as you like ("1.5" is 1g 50s; "1g50s", "75s", "30c" too,
-- see ns.ParseMoney); Enter keeps it, Escape gives the last one back. opts { width, height, big (the large
-- font), onChange(copper) (typed only), tip }. box:Set(copper) (never calls onChange), box:Get(), box.input.
function ns.PriceBox(parent, opts)
	opts = opts or {}
	local box = CreateFrame("Frame", nil, parent)
	box:SetSize(opts.width or 160, opts.height or 28)
	box.value = 0
	local input = Skin.CreateInput(box, nil, 24)
	input:SetAllPoints()
	if opts.big and Skin.FONT then input:SetFontObject(Skin.FONT.xl) end
	input:SetTextInsets(10, 10, 0, 0)
	box.input = input
	local shown = Skin.Text(box, opts.big and "GameTooltipHeaderText" or "GameTooltipText", "text")
	if opts.big and Skin.FONT and shown.SetFontObject then shown:SetFontObject(Skin.FONT.xl) end
	shown:SetPoint("LEFT", box, "LEFT", 10, 0)
	shown:SetPoint("RIGHT", box, "RIGHT", -10, 0)
	if shown.SetWordWrap then shown:SetWordWrap(false) end
	box.shown = shown
	local before -- (the amount when the box was taken: Escape gives it back)
	local function Show()
		shown:SetText(U.Coins(box.value))
		shown:SetShown(not input:HasFocus())
	end
	function box:Set(copper)
		self.value = math.max(0, math.floor(tonumber(copper) or 0))
		if input:HasFocus() then input:SetText(ns.MoneyText(self.value)) end
		Show()
	end
	function box:Get() return self.value end
	input:HookScript("OnEditFocusGained", function(self)
		before = box.value
		shown:Hide()
		self:SetText(ns.MoneyText(box.value))
		self:HighlightText()
	end)
	input:HookScript("OnEditFocusLost", function(self)
		self:SetText("")
		self.edges.Color(1, 0.82, 0, 0.12)
		Show()
	end)
	input:SetScript("OnTextChanged", function(self, typed)
		if not typed then return end
		local copper = ns.ParseMoney(self:GetText())
		local bad = copper == nil and strtrim(self:GetText() or "") ~= ""
		local c = Skin.COLORS[bad and "bad" or "gold"]
		self.edges.Color(c[1], c[2], c[3], 0.55)
		if copper and copper ~= box.value then
			box.value = copper
			if opts.onChange then opts.onChange(copper) end
		end
	end)
	input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	input:SetScript("OnEscapePressed", function(self)
		if before and before ~= box.value then
			box.value = before
			if opts.onChange then opts.onChange(before) end
		end
		self:ClearFocus()
	end)
	if opts.tip then Skin.Tooltip(input, opts.tip, "ANCHOR_TOP") end
	Show()
	return box
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
	ns.SetCut(false)
	-- A question left open answers nothing once the auction house is gone.
	Skin.CancelAsk()
	ns.Hear(false)
	ns.browsing = nil
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
	reopen = W.Skin.SmallButton(UIParent, L.TITLE, function() ns.UseWanderer() end)
	reopen:SetFrameStrata("HIGH")
	reopen:SetPoint("TOPLEFT", _G.AuctionHouseFrame, "TOPRIGHT", 6, -4)
	reopen:Hide()
end

-- An item by its key: name, quality, icon, link (the game may send them a moment later: false then).
function ns.Describe(entry)
	entry.asked = (entry.asked or 0) + 1
	local info = entry.asked <= 4 and U.Safe(ns.AH.GetItemKeyInfo, entry.key) or nil
	if type(info) ~= "table" then
		if (entry.name or "") == "" then
			local name, link, quality = U.ItemInfo(entry.id)
			entry.name = name or U.LinkName(entry.link) or ""
			entry.link = entry.link or link
			entry.quality = quality or entry.quality or 1
			entry.icon = entry.icon or U.ItemIcon(entry.id)
		end
		return false
	end
	entry.name, entry.quality, entry.icon = U.Clean(info.itemName) or "", U.Clean(info.quality) or 1, U.Clean(info.iconFileID)
	entry.commodity = U.Clean(info.isCommodity) and true or false
	entry.described = true
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
-- The page whose browse query was sent last ("buy", "shopping", "sell"): the results it brings are its own.
ns.browsing = nil
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
		-- (the cut of this auction house: a neutral one takes more)
		ns.SetCut(ns.NeutralHouse())
		mode = ns.Replace() and "wanderer" or "game"
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
-- (in a fight the game keeps the keys: given back after)
ns.Listen("PLAYER_REGEN_DISABLED", function() ns.Keys(false) end)
ns.Listen("PLAYER_REGEN_ENABLED", function() ns.Keys(true) end)

function ns.Init()
	if not (W and W.RegisterExtension) then return end
	-- An older Wanderer: said once, nothing taken.
	if (W.API or 1) < 17 then return W.Print(L.NEEDS_WANDERER) end
	-- A character let go in Wanderer (its characters window): its shopping list and buying let go here too.
	W.OnCharacterForgotten(function(key)
		local characters = ns.DB().characters
		if type(characters) == "table" then characters[key] = nil end
	end)
	-- Your shopping list bought here (its purchase on arrival, this character's choice): Wanderer's provisions
	-- leave it to us then; that choice off, they restock it as before.
	W.AddBuyRule(function(id) return ns.On() and ns.AutoBuy() and ns.Shopping()[id] ~= nil end)
	-- What Auction made junk, uncommon or better: never sold at a merchant without your click.
	W.AddJunkRule(ns.JunkRule)
	W.RegisterExtension({
		key = "auction",
		addon = ADDON,
		slash = "/wauction",
		title = L.TITLE,
		news = L.NEWS_LINES,
		-- (autoBuy, buyCap: each character's now, kept with its list; read once as its start)
		defaults = { enabled = true, replace = true, replaceChosen = false, duration = "2", sellWay = "optimized", tooltip = true,
			autoBuy = false, buyCap = 5, toMerchant = true },
		-- Wanderer's menu: the shopping list, anywhere.
		launcher = { label = L.SHOPPING, open = function() ns.ToggleList() end },
		refresh = function()
			-- (switched off at the auction house, its window or the game's in use: let go, the link back with it)
			if (ns.IsShown() or atAuction) and not ns.On() then ns.Close() end
			ns.ListFollowsSwitch()
			-- (an open merchant's links and the profession's button follow at once)
			if ns.RefreshMerchant then ns.RefreshMerchant() end
			if ns.RefreshCrafting then ns.RefreshCrafting() end
		end,
		-- (as every page: the switch, the essentials, what is done for you)
		options = function(o)
			local enabled = o.Checkbox("auction", "enabled", L.ENABLE, L.ENABLE_DESC)
			local on = o.IsOn("auction", "enabled")
			-- (its default follows Auctionator and TradeSkillMaster until you choose: see ns.Replace)
			ns.Replace()
			o.Under(o.Checkbox("auction", "replace", L.REPLACE, L.REPLACE_DESC, function()
				if ns.Settings() then ns.Settings().replaceChosen = true end
			end), enabled, on)
			o.Under(o.Dropdown("AUCTION_DURATION", L.DURATION_DEFAULT, L.DURATION_DESC, "2",
				{ { "1", ns.DurationName(1) }, { "2", ns.DurationName(2) }, { "3", ns.DurationName(3) } },
				function() return ns.Settings() and ns.Settings().duration or "2" end,
				function(value) if ns.Settings() then ns.Settings().duration = value end end), enabled, on)
			-- The price offered to sell (each item's own price is still yours to change on the Sell page).
			o.Under(o.Dropdown("AUCTION_SELL_WAY", L.SELL_WAY, L.SELL_WAY_DESC, "optimized",
				{ { "optimized", L.MODE_OPTIMIZED }, { "fast", L.MODE_FAST }, { "market", L.MODE_MARKET } },
				function() return ns.Settings() and ns.Settings().sellWay or "optimized" end,
				function(value) if ns.Settings() then ns.Settings().sellWay = value end end), enabled, on)

			-- Over items, anywhere: the auction price in the tooltips.
			o.Header(L.SECTION_OVER_ITEMS)
			o.Under(o.Checkbox("auction", "tooltip", L.TOOLTIP, L.TOOLTIP_DESC), enabled, on)

			-- The shopping list: its window, and what is done for it at merchants and bankers (this character).
			o.Header(L.SHOPPING)
			o.Under(o.Button(L.SHOPPING, L.OPEN_LIST, L.OPEN_LIST_DESC, function() ns.ToggleList() end), enabled, on)
			-- At merchants: what the shopping list lacks, bought on arrival (off), for this character (its cap: in
			-- the shopping list's window).
			o.Under(o.Toggle("AUCTION_AUTOBUY", L.AUTOBUY .. " " .. L.THIS_CHARACTER, L.AUTOBUY_DESC, false, function() return ns.AutoBuy() end,
				function(value) ns.AutoBuy(value) end), enabled, on)
			-- At the banker: what the list lacks, taken from the bank first (off), for this character.
			o.Under(o.Toggle("AUCTION_FROMBANK", L.FROMBANK .. " " .. L.THIS_CHARACTER, L.FROMBANK_DESC, false, function() return ns.FromBank() end,
				function(value) ns.FromBank(value) end), enabled, on)

			o.Header(L.SECTION_AUTOMATIONS)
			-- (with Wanderer Bags: set aside for the auction house, but more at a merchant: junk, sold at the next one)
			local toMerchant = o.Under(o.Checkbox("auction", "toMerchant", L.TO_MERCHANT, L.TO_MERCHANT_DESC), enabled, on)
			-- (it works through Wanderer Bags' marks: greyed with the reason without it)
			o.Needs(toMerchant, ns.BagsLoaded, "Wanderer Bags")
		end,
	})
	pcall(events.RegisterEvent, events, "AUCTION_HOUSE_SHOW")
	pcall(events.RegisterEvent, events, "AUCTION_HOUSE_CLOSED")
	ns.InitTooltip()
	SLASH_WANDERERAUCTION1 = "/wauction"
	-- ("/wauction debug": a debug session on or off, "/wauction debug clear": emptied; see Debug.lua)
	SlashCmdList.WANDERERAUCTION = function(text)
		local word, rest = strtrim(text or ""):match("^(%S*)%s*(.-)$")
		if word and word:lower() == "debug" and ns.DebugCommand then return ns.DebugCommand(rest) end
		ns.ToggleList()
	end
end

-- (an older Wanderer, without it: said once)
if W and W.WhenLoaded then W.WhenLoaded(ADDON, ns.Init) elseif W and W.Print then W.Print(L.NEEDS_WANDERER) end
