local _, ns = ...
local L = ns.L

-- In the profession's window, beside its buttons: the reagents you lack for the recipe shown (as many
-- times as asked to make it) sent to the shopping list in one click, its tooltip saying what. When nothing is
-- missing, the same button only says what one making brings (its tooltip, the cost), nothing on a click; gone
-- when nothing is missing and a price is not known. Nothing runs while the window is closed.
-- Naowh Forever's professions window may take the game's place (the game's kept open, unseen, under it): the
-- button then hangs under that window, for the recipe last pointed at there (its rows show the recipe in a
-- tooltip), named in the button's own tooltip before the click. Neither window is changed.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean

local NAOWH = "NaowhForeverProfessions" -- its window's name
local SEEN = 0.05 -- an alpha under this: a window out of sight

local button, page, recipe
local naowhRecipe -- { recipeID, name }: the recipe last shown in a tooltip over Naowh's window
local onNaowh = false -- the button hung under Naowh's window

local Carried = U.ItemCount

-- Naowh's window, when it is the one shown (the game's under it, unseen).
local function NaowhWindow()
	local frame = _G[NAOWH]
	local game = ProfessionsFrame
	if not (frame and frame.IsShown and frame:IsShown() and game and game:IsShown()) then return nil end
	if (frame:GetAlpha() or 1) < SEEN or (game:GetAlpha() or 1) >= SEEN then return nil end
	return frame
end

-- The recipe the button is for: the game's form, or the one pointed at in Naowh's window.
local function Current()
	if onNaowh then return naowhRecipe end
	return recipe
end

-- How many times the recipe is to be made (the game's box beside "Create"), at least once.
local function Times()
	if onNaowh then return 1 end
	local box = page and page.CreateMultipleInputBox
	local value = box and box.GetValue and Clean(Safe(box.GetValue, box))
	return math.max(1, tonumber(value) or 1)
end

-- What is missing: { { id, count = what the recipe needs in all, lack } }, in the recipe's order (the shopping
-- list weighs what you carry against the whole count).
local function Missing()
	local found = {}
	local ui = C_TradeSkillUI
	local current = Current()
	local id = current and Clean(current.recipeID)
	if not (id and ui and ui.GetRecipeSchematic) then return found end
	local schematic = Safe(ui.GetRecipeSchematic, id, false)
	local slots = type(schematic) == "table" and schematic.reagentSlotSchematics
	local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
	local times = Times()
	for _, slot in ipairs(type(slots) == "table" and slots or {}) do
		local reagent = type(slot.reagents) == "table" and slot.reagents[1]
		local item = reagent and Clean(reagent.itemID)
		local need = (Clean(slot.quantityRequired) or 0) * times
		if item and need > 0 and (basic == nil or slot.reagentType == nil or slot.reagentType == basic) then
			local lack = need - Carried(item)
			if lack > 0 then found[#found + 1] = { id = item, count = need, lack = lack } end
		end
	end
	return found
end

-- What one making of a recipe costs and brings, by the prices remembered (the market's days, else the last one
-- seen): the reagents bought, the crafted item sold (once the cut taken), the difference. Nil when one of these
-- prices is not known: nothing is made up.
local function Remembered(id) return ns.Market(id) or ns.Price(id) end
function ns.RecipeWorth(schematic)
	local slots = type(schematic) == "table" and schematic.reagentSlotSchematics
	local made = type(schematic) == "table" and Clean(schematic.outputItemID)
	local value = made and Remembered(made)
	if not (value and type(slots) == "table") then return nil end
	local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
	local cost = 0
	for _, slot in ipairs(slots) do
		local reagent = type(slot.reagents) == "table" and slot.reagents[1]
		local item = reagent and Clean(reagent.itemID)
		local need = Clean(slot.quantityRequired) or 0
		if item and need > 0 and (basic == nil or slot.reagentType == nil or slot.reagentType == basic) then
			local price = Remembered(item)
			if not price then return nil end
			cost = cost + price * need
		end
	end
	local sold = ns.Net(value) * math.max(1, Clean(schematic.quantityMin) or 1)
	return { cost = cost, sold = sold, profit = sold - cost }
end

-- Where the button hangs: beside the game's buttons, or under Naowh's window when that one is shown (ours, only
-- placed against it: their window itself is only read).
local function Place()
	if not button then return end
	local naowh = NaowhWindow()
	if naowh and not onNaowh then
		onNaowh = true
		button:SetParent(UIParent)
		button:SetFrameStrata(naowh:GetFrameStrata() or "HIGH")
		button:SetFrameLevel((naowh:GetFrameLevel() or 1) + 10)
		button:ClearAllPoints()
		button:SetPoint("TOPRIGHT", naowh, "BOTTOMRIGHT", 0, -4)
	elseif not naowh and onNaowh then
		onNaowh = false
		naowhRecipe = nil
		button:SetParent(page)
		button:SetFrameStrata(page:GetFrameStrata() or "MEDIUM")
		button:SetFrameLevel((page:GetFrameLevel() or 1) + 5)
		button:ClearAllPoints()
		if page.CreateAllButton then
			button:SetPoint("RIGHT", page.CreateAllButton, "LEFT", -12, 0)
		else
			button:SetPoint("BOTTOMLEFT", page.SchematicForm, "BOTTOMLEFT", 10, 10)
		end
	end
end

-- What one making of the recipe the button is for costs and brings (ns.RecipeWorth), nil when not known.
local function Worth()
	local current = Current()
	local id = current and Clean(current.recipeID)
	local ui = C_TradeSkillUI
	if not (id and ui and ui.GetRecipeSchematic) then return nil end
	return ns.RecipeWorth(Safe(ui.GetRecipeSchematic, id, false))
end

local function WorthLine(worth)
	if worth.profit >= 0 then return L.CRAFT_PROFIT:format(U.Coins(worth.profit)) end
	return L.CRAFT_LOSS:format(U.Coins(-worth.profit))
end

-- Something missing: the button sends it; else it only says the profit (its tooltip, the cost), when known.
local function Refresh()
	if not button then return end
	Place()
	-- (the addon switched off: nothing of it in the profession's window)
	if ns.On and not ns.On() then return button:Hide() end
	local missing = Missing()[1] ~= nil
	local worth = not missing and Worth()
	button:SetText(worth and WorthLine(worth) or L.TO_SHOPPING)
	button:Fit()
	button:SetShown(missing or worth and true or false)
end
ns.RefreshCrafting = Refresh -- (Auction switched off or on: Window.lua)

local function Send()
	local missing = Missing()
	if not missing[1] then return end
	local current = Current()
	local note = current and Clean(current.name)
	for _, item in ipairs(missing) do ns.AddToShopping(item.id, item.count, note, true) end
	W.Print(L.CRAFT_SHOP_DONE:format(#missing))
	Refresh()
end

-- A tooltip over Naowh's window showing a recipe (one of its rows, its recipe's icon): that recipe remembered.
local function Within(frame, root)
	local depth = 0
	while frame and depth < 12 do
		if frame == root then return true end
		frame = frame.GetParent and frame:GetParent() or nil
		depth = depth + 1
	end
	return false
end

local function Pointed(tooltip, id)
	local naowh = NaowhWindow()
	id = Clean(id)
	if not (naowh and id and tooltip and tooltip.GetOwner and Within(tooltip:GetOwner(), naowh)) then return end
	local info = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and Safe(C_TradeSkillUI.GetRecipeInfo, id)
	if type(info) ~= "table" then return end
	naowhRecipe = { recipeID = id, name = Clean(info.name) }
	Refresh()
end

-- Naowh's window coming or going, looked at now and then while the profession's window is open (theirs is never
-- hooked): the button follows.
local WATCH_STEP = 0.25
local watch = CreateFrame("Frame")
watch:Hide()
watch.since = 0
watch:SetScript("OnUpdate", function(self, elapsed)
	self.since = self.since + elapsed
	if self.since < WATCH_STEP then return end
	self.since = 0
	if (NaowhWindow() ~= nil) ~= onNaowh then Refresh() end
end)

local function Build()
	local frame = ProfessionsFrame
	-- (a profession's window without the game's crafting page: nothing placed)
	page = frame and type(frame.CraftingPage) == "table" and frame.CraftingPage or nil
	local form = page and page.SchematicForm
	if type(form) ~= "table" or button then return end
	button = Skin.Button(page, L.TO_SHOPPING, Send)
	if page.CreateAllButton then
		button:SetPoint("RIGHT", page.CreateAllButton, "LEFT", -12, 0)
	else
		button:SetPoint("BOTTOMLEFT", form, "BOTTOMLEFT", 10, 10)
	end
	Skin.Tooltip(button, function()
		local lines = {}
		local current = Current()
		if onNaowh and current and current.name then lines[1] = L.CRAFT_SHOP_FOR:format(current.name) end
		local missing = Missing()
		if missing[1] then
			lines[#lines + 1] = L.CRAFT_SHOP_DESC
			for _, item in ipairs(missing) do
				lines[#lines + 1] = L.POST_WHAT:format(item.lack, U.ItemName(item.id) or ("#" .. item.id))
			end
		end
		-- (what one making costs and brings, when every price is known)
		local worth = Worth()
		if worth then
			if lines[1] then lines[#lines + 1] = "" end
			lines[#lines + 1] = L.CRAFT_WORTH:format(U.Coins(worth.cost), U.Coins(worth.sold))
			lines[#lines + 1] = WorthLine(worth)
		end
		return table.concat(lines, "\n")
	end, "ANCHOR_TOP")
	button:Hide()
	-- The recipe shown: read from the game's form each time it is filled.
	if form.Init then
		hooksecurefunc(form, "Init", function(self, info)
			recipe = type(info) == "table" and info or (self.GetRecipeInfo and Safe(self.GetRecipeInfo, self))
			Refresh()
		end)
	end
	local box = page.CreateMultipleInputBox
	if box and box.HookScript then pcall(box.HookScript, box, "OnTextChanged", Refresh) end
	-- (Naowh's window: the recipes its rows show in the game's tooltip)
	if GameTooltip then
		for _, method in ipairs({ "SetRecipeResultItem", "SetSpellByID" }) do
			if GameTooltip[method] then hooksecurefunc(GameTooltip, method, Pointed) end
		end
	end
	-- Your bags change while it is open (a reagent bought, looted, made): said again.
	local events = CreateFrame("Frame")
	events:SetScript("OnEvent", Refresh)
	frame:HookScript("OnShow", function()
		events:RegisterEvent("BAG_UPDATE_DELAYED")
		Refresh()
		-- (Naowh's window takes the game's place a moment after: looked at while it is open)
		watch.since = 0
		watch:Show()
	end)
	frame:HookScript("OnHide", function()
		events:UnregisterEvent("BAG_UPDATE_DELAYED")
		watch:Hide()
		naowhRecipe = nil
		-- (the button back beside the game's buttons, gone with them)
		Refresh()
	end)
	if frame:IsShown() then
		events:RegisterEvent("BAG_UPDATE_DELAYED")
		watch:Show()
	end
end

-- The game's profession window comes with its own addon, loaded the first time it opens. (Not with an older
-- Wanderer: Init takes nothing then, Window.lua.)
if (W.API or 1) >= 17 then
	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded
	if loaded and Clean(Safe(loaded, "Blizzard_Professions")) then
		Build()
	elseif W.WhenLoaded then
		W.WhenLoaded("Blizzard_Professions", Build)
	end
end
