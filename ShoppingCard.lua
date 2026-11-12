local _, ns = ...
local L = ns.L

-- A line of your shopping list, changed in one card beside the row clicked (the same on the Shopping list page
-- and in its small window): the item, what you carry against what you want and what for; four tiles, keys 1
-- to 4: how many (a stepper under them, the arrows too), always on you, your highest price (a price box under
-- them), off the list; then, at the auction house, the item searched at once, or what a merchant asks for it.
-- Each click is done at once, said on the card; Escape or a click elsewhere closes it. (Wanderer's card, Skin.Card.)

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin

local TILE_WIDTH, TILE_GAP, TILES = 62, 6, 4
local BODY_WIDTH, BODY_HEIGHT = TILES * TILE_WIDTH + (TILES - 1) * TILE_GAP, 28

local card -- made at its first use
local Fill -- (below)

local function Pad() return U.UsingPad and U.UsingPad() end

local function Entry() return card and card.id and ns.Shopping()[card.id] or nil end

-- How many a step moves: 1, 5 with Shift, 20 with Ctrl.
local function StepSize()
	if IsControlKeyDown() then return 20 end
	if IsShiftKeyDown() then return 5 end
	return 1
end

-- How many changed by this many (the steps, and a controller's moves).
local function Move(by)
	local entry = Entry()
	if not entry then return end
	ns.SetShoppingCount(card.id, (entry.count or 1) + by)
	Fill()
end

local function Step(direction) Move(direction * StepSize()) end

-- The highest price one step up or down (a controller's cross, ns.MoneyStep); never under nothing.
local function StepMax(direction)
	local entry = Entry()
	if not entry then return end
	ns.SetShoppingMax(card.id, ns.MoneyStep(entry.max or 0, direction))
	Fill()
end

-- The card's own keys: the arrows step how many (1 to 4 and Escape are the kit's).
local function OnKey(key)
	local step = (key == "UP" or key == "RIGHT") and 1 or (key == "DOWN" or key == "LEFT") and -1 or nil
	if not step then return false end
	Step(step)
	return true
end

local function Create()
	card = Skin.Card("WandererAuctionShoppingCard", true)
	-- Under the tiles, one of two: how many (a stepper), or your highest price (a price box).
	card.counter = CreateFrame("Frame", nil, card)
	card.counter:SetSize(BODY_WIDTH, BODY_HEIGHT)
	card.counter:Hide()
	local less = Skin.Button(card.counter, "-", function() Step(-1) end, nil, 32)
	less:SetHeight(26)
	less:SetPoint("LEFT")
	card.count = Skin.Text(card.counter, "GameFontNormal", "text")
	card.count:SetPoint("LEFT", less, "RIGHT", 6, 0)
	card.count:SetWidth(44)
	card.count:SetJustifyH("CENTER")
	local more = Skin.Button(card.counter, "+", function() Step(1) end, nil, 32)
	more:SetHeight(26)
	more:SetPoint("LEFT", card.count, "RIGHT", 6, 0)
	-- (a controller: the cross's left and right step one, its left button five more)
	for _, button in ipairs({ less, more }) do
		button.padAdjust = function(_, delta) Move(delta > 0 and 1 or -1) end
		button.padAlt, button.padAltWord = function() Move(5) end, L.PAD_FIVE_MORE
	end
	card.steps = Skin.Text(card.counter, "GameTooltipTextSmall", "muted")
	card.steps:SetPoint("LEFT", more, "RIGHT", 10, 0)
	card.steps:SetText(L.CARD_STEPS)
	card.highest = CreateFrame("Frame", nil, card)
	card.highest:SetSize(BODY_WIDTH, BODY_HEIGHT)
	card.highest:Hide()
	card.money = ns.PriceBox(card.highest, { width = 150, height = 26, tip = L.PRICE_FIELD_DESC, onChange = function(copper)
		if card.id then ns.SetShoppingMax(card.id, copper) end
	end })
	card.money:SetPoint("LEFT")
	-- (a controller: nothing typed, the cross's left and right step the price, said when it stops on it)
	card.money:EnableMouse(true)
	card.money.padTip = true
	card.money.padAdjust = function(_, delta) StepMax(delta > 0 and 1 or -1) end
	Skin.Tooltip(card.money, function() return Pad() and { L.TILE_HIGHEST, L.HIGHEST_STEPS_PAD } or nil end, "ANCHOR_TOP")
	card.noMax = Skin.SmallButton(card.highest, L.NO_MAX_BUTTON, function()
		if not card.id then return end
		ns.SetShoppingMax(card.id, nil)
		Fill()
	end, nil, 24)
	card.noMax:SetPoint("LEFT", card.money, "RIGHT", 8, 0)
	-- (your bags changed: what you carry said again; any other event is the kit's, a click elsewhere closes it)
	local kit = card:GetScript("OnEvent")
	card:SetScript("OnEvent", function(self, event, ...)
		if event == "BAG_UPDATE_DELAYED" then return Fill() end
		kit(self, event, ...)
	end)
	card:HookScript("OnShow", function(self) self:RegisterEvent("BAG_UPDATE_DELAYED") end)
	card.onHide = function(self) self.id, self.panel = nil, nil end
end

-- The tiles: how many (its number), always on you, your highest price, off the list.
local function Tiles(id, entry)
	return {
		{ sign = { text = entry.count or 1 }, label = L.TILE_HOW_MANY, tip = Pad() and L.TILE_HOW_MANY_DESC_PAD or L.TILE_HOW_MANY_DESC, on = card.panel == "count",
			stay = true, run = function()
				card.panel = "count"
				Fill()
			end },
		{ sign = { glyph = "check" }, label = L.TILE_ALWAYS, tip = L.TILE_ALWAYS_DESC, on = entry.keep and true or false,
			stay = true, run = function()
				ns.ToggleShoppingKeep(id)
				Fill()
			end },
		{ sign = { file = "Interface\\MoneyFrame\\UI-GoldIcon", size = 18 }, label = L.TILE_HIGHEST, tip = L.TILE_HIGHEST_DESC,
			on = card.panel == "max" or entry.max ~= nil, stay = true, run = function()
				card.panel = "max"
				Fill()
				-- (with a controller nothing is typed: the cross steps the price instead)
				if not (U.UsingPad and U.UsingPad()) then card.money.input:SetFocus() end
			end },
		{ sign = { glyph = "close" }, label = L.REMOVE, tip = L.TILE_REMOVE_DESC, run = function() ns.RemoveFromShopping(id) end },
	}
end

-- The card drawn for its line: the heading, the tiles, what is under them, the quiet line below.
function Fill()
	local entry = Entry()
	if not (card and entry) then return end
	local id = card.id
	local name, link, quality = U.ItemInfo(id)
	local have, want = U.ItemCount(id), entry.count or 1
	local now = L.CARD_CARRY:format(have, want)
	if have >= want then now = Skin.Colorize(now, "good") end
	if entry.note then now = now .. U.SEPARATOR .. L.CRAFT_SHOP_FOR:format(entry.note) end
	-- (what a merchant asks, when one was seen selling it: said in the heading, nothing to click)
	local merchant = ns.MerchantPrice and ns.MerchantPrice(id)
	if merchant and not ns.AtAuction() then now = now .. U.SEPARATOR .. L.CHIP_AT_MERCHANT:format(U.Coins(merchant)) end
	card.count:SetText(tostring(want))
	card.steps:SetText(Pad() and L.CARD_STEPS_PAD or L.CARD_STEPS)
	if not card.money.input:HasFocus() then card.money:Set(entry.max or 0) end
	-- At the auction house: searched now.
	local rows = {}
	if ns.AtAuction() then
		rows[1] = { text = L.CARD_SEARCH, main = true, run = function()
			if not ns.IsShown() then ns.UseWanderer("buy") end
			ns.BuyItem(id, U.ItemName(id))
		end }
	end
	card:Fill({ title = name or U.ItemName(id) or ("#" .. id), quality = quality, icon = U.ItemIcon(id), now = now,
		tiles = Tiles(id, entry), body = card.panel == "max" and card.highest or card.counter, bodyHeight = BODY_HEIGHT,
		bodyBelow = true, rows = rows, keys = L.CARD_KEYS, onKey = OnKey })
	if link == nil and not name then U.LoadItem(id) end
end

-- A line of the list clicked (owner: its row): its card, or closed when it was already its card.
function ns.OpenShoppingCard(owner, id)
	id = tonumber(id)
	if not (id and ns.Shopping()[id]) then return end
	if not card then Create() end
	if card:IsShown() and card.id == id and card.owner == owner then
		card:Hide()
		return
	end
	card.id, card.panel = id, "count"
	Fill()
	card:Present(owner)
	-- (its line off the list: it closes)
	card.valid = function() return Entry() ~= nil end
end
ns.ShoppingCard = function() return card end -- (tests)

-- The list changed elsewhere (a merchant, the bags): the card drawn again.
function ns.RefreshShoppingCard()
	if card and card:IsShown() then Fill() end
end
