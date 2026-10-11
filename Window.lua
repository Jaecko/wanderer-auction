local ADDON, ns = ...
local L = ns.L

-- The auction house, in Wanderer's window: its pages (to sell, to buy, your
-- auctions, your bids), a link for each under its title; on each, a list on
-- the left and what is chosen on the right. It opens and closes with the
-- auction house, the game's own window then out of sight; a link brings the
-- game's back (and one beside it, Wanderer's). Here too: what the pages share
-- (a row of a list, an amount of money, an item described, a question asked
-- before acting).

local W = Wanderer
local U = W and W.Util

ns.WIDTH = 700
ns.ROW_HEIGHT = 22
ns.ROWS = 18 -- a page's height, in rows
ns.LIST_WIDTH = 360
local GAP = 24 -- between the list and what is chosen
local TABS_HEIGHT = 24
local OFF_SCREEN = -10000

-- The game's auction house functions, looked up when used.
ns.AH = setmetatable({}, { __index = function(_, key) return C_AuctionHouse and C_AuctionHouse[key] end })

local window, title, reopen
local pages, order = {}, {}
local current = "sell"
local atAuction = false -- the auction house open
local mode = "wanderer" -- this visit: "wanderer" (the game's window out of sight) or "game"
local switching = false -- Wanderer's window hidden to show the game's (the auction house stays open)

function ns.On()
	local settings = ns.Settings()
	return settings and settings.enabled and true or false
end

-- A page: its name, its title, how it is built (once) and what it does when shown and closed.
function ns.AddPage(name, label, build, onShow, onClose)
	pages[name] = { label = label, build = build, onShow = onShow, onClose = onClose }
	order[#order + 1] = name
end

function ns.IsShown() return window and window:IsShown() or false end

function ns.ShowPage(name)
	current = name
	if not window then return end
	for key, page in pairs(pages) do
		page.frame:SetShown(key == name)
		-- The page shown: its link in gold.
		page.tab:SetLabel(key == name and ("|cffffd100" .. page.label .. "|r") or page.label)
	end
	title:SetText(pages[name].label)
	if pages[name].onShow then pages[name].onShow() end
end

-- The game's window: out of sight while Wanderer's is used (still open: the auction house with it),
-- back in its place otherwise.
local function PlaceGameWindow()
	local frame = _G.AuctionHouseFrame
	if not frame then return end
	if atAuction and mode == "wanderer" then
		frame:SetAlpha(0)
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", OFF_SCREEN, 0)
	elseif (frame:GetAlpha() or 1) < 1 then
		frame:SetAlpha(1)
		if UpdateUIPanelPositions then pcall(UpdateUIPanelPositions, frame) end
	end
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

-- Wanderer's window, the game's out of sight.
function ns.UseWanderer()
	mode = "wanderer"
	if reopen then reopen:Hide() end
	PlaceGameWindow()
	ns.Open()
end

function Create()
	window = W.Skin.CreateWindow("WandererAuctionSell", "HIGH") -- (not "WandererAuction": the prices shared with the other addons)
	W.Skin.Dress(window, { "TOPLEFT", UIParent, "TOPLEFT", 24, -110 }, "auctionWindow")
	local margin = W.Skin.Margin() + 8
	window:SetSize(ns.WIDTH, 92 + TABS_HEIGHT + ns.ROWS * ns.ROW_HEIGHT)
	local kicker = W.Skin.CreateKicker(window, "Wanderer")
	kicker:SetPoint("TOPLEFT", window, "TOPLEFT", margin, -margin)
	title = W.Skin.CreateText(window, "GameTooltipHeaderText", 1, 0.82, 0)
	title:SetPoint("TOPLEFT", kicker, "BOTTOMLEFT", 0, -3)
	-- The pages' links, in a row under the title.
	local previous
	for _, name in ipairs(order) do
		local page = pages[name]
		page.tab = W.Skin.CreateLink(window, page.label, function()
			if U.PlaySound then U.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON") end
			ns.ShowPage(name)
		end)
		if previous then
			page.tab:SetPoint("LEFT", previous, "RIGHT", 4, 0)
		else
			page.tab:SetPoint("TOPLEFT", title, "BOTTOMLEFT", -5, -6)
		end
		previous = page.tab
	end
	-- The game's own window, on the right of the links.
	local game = W.Skin.CreateLink(window, L.GAME_WINDOW, function()
		if U.PlaySound then U.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON") end
		ns.UseGame()
	end, L.GAME_WINDOW_DESC)
	game:SetPoint("TOP", pages[order[1]].tab, "TOP", 0, 0)
	game:SetPoint("RIGHT", window, "RIGHT", -margin + 5, 0)
	for _, name in ipairs(order) do
		local page = pages[name]
		page.frame = CreateFrame("Frame", nil, window)
		page.frame:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -(10 + TABS_HEIGHT))
		page.frame:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin)
		page.build(page.frame)
	end
	window:HookScript("OnShow", function(self)
		self:SetScale(W.Skin.Scale())
		ns.ShowPage(current)
	end)
	-- Closed by hand (its cross, Escape): the auction house with it, as the game's window does.
	window:HookScript("OnHide", function()
		if switching or not atAuction or mode ~= "wanderer" then return end
		U.Safe(ns.AH.CloseAuctionHouse)
	end)
	W.Skin.Get(window):Layout()
end

function ns.Open(page)
	if page then current = page end
	if not window then Create() end
	if window:IsShown() then ns.ShowPage(current) else window:Show() end
end

function ns.Close()
	atAuction = false
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
	reopen = W.Skin.CreateLink(UIParent, L.TITLE, function() ns.UseWanderer() end)
	reopen:SetFrameStrata("HIGH")
	reopen:SetPoint("TOPLEFT", _G.AuctionHouseFrame, "TOPRIGHT", 6, -4)
	reopen:Hide()
end

-- Pieces -------------------------------------------------------------------------------------

-- A row of a list: icon, name, a count and a price on the right; or a title.
function ns.NewRow(list, index, onClick)
	local size = ns.ROW_HEIGHT
	local row = CreateFrame("Button", nil, list)
	row:SetHeight(size)
	row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(index - 1) * size)
	row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
	row.chosen = row:CreateTexture(nil, "BACKGROUND")
	row.chosen:SetAllPoints()
	row.chosen:SetColorTexture(1, 0.82, 0, 0.12)
	row.chosen:Hide()
	row.hover = row:CreateTexture(nil, "BACKGROUND", nil, 1)
	row.hover:SetAllPoints()
	row.hover:SetColorTexture(1, 1, 1, 0.05)
	row.hover:Hide()
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(size - 4, size - 4)
	row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	row.price = W.Skin.CreateText(row, "GameTooltipTextSmall", 0.85, 0.85, 0.85)
	row.price:SetPoint("RIGHT", row, "RIGHT", -2, 0)
	row.count = W.Skin.CreateText(row, "GameTooltipTextSmall", 0.6, 0.6, 0.6)
	row.count:SetPoint("RIGHT", row.price, "LEFT", -6, 0)
	row.name = W.Skin.CreateText(row, "GameTooltipText")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
	if row.name.SetWordWrap then row.name:SetWordWrap(false) end
	row.header = W.Skin.CreateKicker(row)
	row.header:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 3)
	row.star = row:CreateTexture(nil, "OVERLAY")
	row.star:SetSize(12, 12)
	row.star:SetPoint("TOPRIGHT", row.icon, "TOPRIGHT", 3, 3)
	if not pcall(row.star.SetAtlas, row.star, "auctionhouse-icon-favorite") then row.star:SetTexture("Interface\\Common\\FavoritesIcon") end
	row.star:Hide()
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetScript("OnClick", function(self, mouse)
		if self.entry and not self.entry.header then
			if U.PlaySound then U.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON") end
			onClick(self.entry, mouse)
		end
	end)
	row:SetScript("OnEnter", function(self)
		if not (self.entry and self.entry.link) then return end
		self.hover:Show()
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetHyperlink(self.entry.link)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function(self)
		self.hover:Hide()
		GameTooltip:Hide()
	end)
	-- Filled: a title, or an item (name in its quality's color).
	function row:Fill(entry, chosen, count, price)
		self.entry = entry
		self:SetShown(entry ~= nil)
		if not entry then return end
		self.star:Hide()
		local header = entry.header ~= nil
		self.header:SetShown(header)
		self.icon:SetShown(not header)
		self.name:SetShown(not header)
		self.count:SetShown(not header)
		self.price:SetShown(not header)
		self.chosen:SetShown(chosen or false)
		if header then
			self.header:SetText(U.Upper(entry.header))
			return
		end
		self.icon:SetTexture(entry.icon)
		self.name:SetText(entry.name or "")
		local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[entry.quality or 1]
		if color then self.name:SetTextColor(color.r, color.g, color.b) else self.name:SetTextColor(1, 1, 1) end
		self.count:SetText(count or "")
		self.price:SetText(price or "")
		self.star:SetShown(entry.favorite or false)
	end
	return row
end

-- A list of rows, the wheel scrolling it: list.offset, list.rows.
function ns.NewList(parent, rows, onClick, onScroll)
	local list = CreateFrame("Frame", nil, parent)
	list:SetSize(ns.LIST_WIDTH, rows * ns.ROW_HEIGHT)
	list:EnableMouseWheel(true)
	list.offset, list.rows = 0, {}
	list:SetScript("OnMouseWheel", function(self, delta)
		self.offset = math.max(0, self.offset - delta * 3)
		onScroll()
	end)
	for index = 1, rows do list.rows[index] = ns.NewRow(list, index, onClick) end
	-- The offset kept within what there is to show.
	function list:Clamp(total)
		self.offset = math.max(0, math.min(self.offset, total - #self.rows))
		return self.offset
	end
	return list
end

-- An amount of money: gold, silver, copper (copper only where the auction house takes it).
function ns.NewMoney(parent, onChange)
	local money = CreateFrame("Frame", nil, parent)
	money:SetSize(170, 22)
	local function Box(width, icon, anchor)
		local box = W.Skin.CreateInput(money, nil, 7)
		box:SetSize(width, 22)
		box:SetNumeric(true)
		box:SetJustifyH("RIGHT")
		box.coin = money:CreateTexture(nil, "ARTWORK")
		box.coin:SetSize(13, 13)
		box.coin:SetTexture(icon)
		box.coin:SetPoint("LEFT", box, "RIGHT", 2, 0)
		if anchor then box:SetPoint("LEFT", anchor, "RIGHT", 6, 0) else box:SetPoint("LEFT") end
		box:SetScript("OnTextChanged", function() if onChange then onChange() end end)
		box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
		box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		return box
	end
	money.gold = Box(54, "Interface\\MoneyFrame\\UI-GoldIcon")
	money.silver = Box(34, "Interface\\MoneyFrame\\UI-SilverIcon", money.gold.coin)
	money.copper = Box(34, "Interface\\MoneyFrame\\UI-CopperIcon", money.silver.coin)
	function money:Set(copper)
		copper = math.max(0, math.floor(copper or 0))
		self.gold:SetText(tostring(math.floor(copper / 10000)))
		self.silver:SetText(tostring(math.floor(copper / 100) % 100))
		self.copper:SetText(tostring(copper % 100))
	end
	function money:Get()
		local copper = self.copper:IsShown() and (tonumber(self.copper:GetText()) or 0) or 0
		return (tonumber(self.gold:GetText()) or 0) * 10000 + (tonumber(self.silver:GetText()) or 0) * 100 + copper
	end
	function money:ShowCopper(shown)
		self.copper:SetShown(shown)
		self.copper.coin:SetShown(shown)
	end
	return money
end

-- A question before acting (a purchase, a bid, a cancel, a low price): yes does it, no lets it go.
local asking
function ns.Ask(text, accept, refuse)
	asking = { accept = accept, refuse = refuse }
	if StaticPopup_Show then StaticPopup_Show("WANDERER_AUCTION_ASK", text) end
end

if StaticPopupDialogs then
	StaticPopupDialogs.WANDERER_AUCTION_ASK = {
		text = "%s",
		button1 = YES or "Yes",
		button2 = NO or "No",
		OnAccept = function()
			local question = asking
			asking = nil
			if question and question.accept then question.accept() end
		end,
		OnCancel = function()
			local question = asking
			asking = nil
			if question and question.refuse then question.refuse() end
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
	}
end

-- An item by its key: name, quality, icon, link (the game may send them a moment later: false then).
function ns.Describe(entry)
	local info = U.Safe(ns.AH.GetItemKeyInfo, entry.key)
	if type(info) ~= "table" then return false end
	entry.name, entry.quality, entry.icon = U.Clean(info.itemName) or "", U.Clean(info.quality) or 1, U.Clean(info.iconFileID)
	entry.commodity = U.Clean(info.isCommodity) and true or false
	if not entry.link then
		local _, link = U.Safe(C_Item and C_Item.GetItemInfo or GetItemInfo, entry.id)
		entry.link = U.Clean(link)
	end
	return true
end

-- "Short", "Long"... (the game's words for the time left).
function ns.TimeLeft(band)
	return band and _G["AUCTION_TIME_LEFT" .. (band + 1)] or ""
end

-- Whether the auction house takes copper (else prices in silver).
function ns.CopperOnly() return U.Clean(U.Safe(ns.AH.SupportsCopperValues)) and true or false end

-- On the right of a list: a rule, a hint while nothing is chosen, then the detail of what is: its
-- icon, its name, its status (lines of text). Fills the given table; returns the detail's frame.
function ns.NewDetail(page, list, hint, detail)
	local rule = page:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(1, 0.82, 0, 0.2)
	rule:SetWidth(1)
	rule:SetPoint("TOPLEFT", list, "TOPRIGHT", GAP / 2, 0)
	rule:SetPoint("BOTTOM", page, "BOTTOM", 0, 0)
	local frame = CreateFrame("Frame", nil, page)
	frame:SetPoint("TOPLEFT", list, "TOPRIGHT", GAP, 0)
	frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	detail.pick = W.Skin.CreateText(page, "GameTooltipText", 0.6, 0.6, 0.6)
	detail.pick:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -60)
	detail.pick:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	detail.pick:SetText(hint)
	frame:Hide()
	detail.frame = frame
	detail.icon = frame:CreateTexture(nil, "ARTWORK")
	detail.icon:SetSize(32, 32)
	detail.icon:SetPoint("TOPLEFT")
	detail.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	detail.name = W.Skin.CreateText(frame, "GameTooltipText")
	detail.name:SetPoint("TOPLEFT", detail.icon, "TOPRIGHT", 8, -1)
	detail.name:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	detail.status = W.Skin.CreateText(frame, "GameTooltipText", 0.9, 0.88, 0.82)
	detail.status:SetPoint("TOPLEFT", detail.icon, "BOTTOMLEFT", 0, -10)
	detail.status:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	detail.status:SetSpacing(3)
	return frame
end

-- One of the game's buttons, as wide as its words need (at least minimum).
function ns.Button(parent, text, onClick, minimum)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetText(text)
	button:SetSize(math.max(minimum or 100, U.Measure(button:GetFontString() or button, "GetStringWidth", 80) + 30), 24)
	button:SetScript("OnClick", onClick)
	return button
end

-- A label on the left of a line, its value at a fixed place.
function ns.Label(parent, text, anchor, gap)
	local label = W.Skin.CreateText(parent, "GameTooltipTextSmall", 0.75, 0.68, 0.5)
	label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(gap or 14))
	label:SetText(text)
	return label
end
ns.VALUE_LEFT = 96

-- Init ----------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
ns.Events = {} -- event -> handlers of the pages
function ns.Listen(event, handler)
	ns.Events[event] = ns.Events[event] or {}
	table.insert(ns.Events[event], handler)
	pcall(events.RegisterEvent, events, event)
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
		return
	elseif event == "AUCTION_HOUSE_CLOSED" then
		return ns.Close()
	end
	for _, handler in ipairs(ns.Events[event] or {}) do Run(handler, ...) end
end)

function ns.Init()
	if not (W and W.RegisterExtension) then return end
	-- An older Wanderer: said once, nothing taken.
	if (W.API or 1) < 2 then return W.Print(L.NEEDS_WANDERER) end
	W.RegisterExtension({
		key = "auction",
		title = L.TITLE,
		defaults = { enabled = true, replace = true, duration = "2", tooltip = true },
		refresh = function()
			if ns.IsShown() and not ns.On() then ns.Close() end
		end,
		options = function(o)
			o.Header(L.TITLE)
			local enabled = o.Checkbox("auction", "enabled", L.ENABLE, L.ENABLE_DESC)
			local on = o.IsOn("auction", "enabled")
			o.Under(o.Checkbox("auction", "replace", L.REPLACE, L.REPLACE_DESC), enabled, on)
			o.Under(o.Dropdown("AUCTION_DURATION", L.DURATION_DEFAULT, L.DURATION_DESC, "2",
				{ { "1", L.DURATION:format(12) }, { "2", L.DURATION:format(24) }, { "3", L.DURATION:format(48) } },
				function() return ns.Settings() and ns.Settings().duration or "2" end,
				function(value) if ns.Settings() then ns.Settings().duration = value end end), enabled, on)
			o.Checkbox("auction", "tooltip", L.TOOLTIP, L.TOOLTIP_DESC)
		end,
	})
	pcall(events.RegisterEvent, events, "AUCTION_HOUSE_SHOW")
	pcall(events.RegisterEvent, events, "AUCTION_HOUSE_CLOSED")
	ns.InitTooltip()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
	if name ~= ADDON then return end
	self:UnregisterEvent("ADDON_LOADED")
	ns.Init()
end)
