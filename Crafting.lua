local _, ns = ...
local L = ns.L

-- In the profession's window, beside its buttons: the reagents you lack for the recipe shown (as many
-- times as asked to make it) sent to the shopping list in one click. Shown only when
-- something is missing; its tooltip says what. Nothing runs while the window is closed.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean

local button, page, recipe

local Carried = U and U.ItemCount

-- How many times the recipe is to be made (the game's box beside "Create"), at least once.
local function Times()
	local box = page and page.CreateMultipleInputBox
	local value = box and box.GetValue and Clean(Safe(box.GetValue, box))
	return math.max(1, tonumber(value) or 1)
end

-- What is missing: { { id, count = what the recipe needs in all, lack } }, in the recipe's order (the shopping
-- list weighs what you carry against the whole count).
local function Missing()
	local found = {}
	local ui = C_TradeSkillUI
	local id = recipe and Clean(recipe.recipeID)
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

local function Refresh()
	if not button then return end
	button:SetShown(Missing()[1] ~= nil)
end

local function Send()
	local missing = Missing()
	if not missing[1] then return end
	local note = recipe and Clean(recipe.name)
	for _, item in ipairs(missing) do ns.AddToShopping(item.id, item.count, note, true) end
	if W.Print then W.Print(L.CRAFT_SHOP_DONE:format(#missing)) end
	Refresh()
end

local function Build()
	local frame = ProfessionsFrame
	page = frame and frame.CraftingPage
	local form = page and page.SchematicForm
	if not (form and Skin and Skin.Button) or button then return end
	button = Skin.Button(page, L.CRAFT_SHOP, Send)
	if page.CreateAllButton then
		button:SetPoint("RIGHT", page.CreateAllButton, "LEFT", -12, 0)
	else
		button:SetPoint("BOTTOMLEFT", form, "BOTTOMLEFT", 10, 10)
	end
	Skin.Tooltip(button, function()
		local lines = { L.CRAFT_SHOP_DESC }
		for _, item in ipairs(Missing()) do
			lines[#lines + 1] = ("%d x %s"):format(item.lack, U.ItemName(item.id) or ("#" .. item.id))
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
	-- Your bags change while it is open (a reagent bought, looted, made): said again.
	local events = CreateFrame("Frame")
	events:SetScript("OnEvent", Refresh)
	frame:HookScript("OnShow", function() events:RegisterEvent("BAG_UPDATE_DELAYED") Refresh() end)
	frame:HookScript("OnHide", function() events:UnregisterEvent("BAG_UPDATE_DELAYED") end)
	if frame:IsShown() then events:RegisterEvent("BAG_UPDATE_DELAYED") end
end

-- The game's profession window comes with its own addon, loaded the first time it opens.
if W and W.API and W.API >= 4 then
	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded
	if loaded and Clean(Safe(loaded, "Blizzard_Professions")) then
		Build()
	elseif W.WhenLoaded then
		W.WhenLoaded("Blizzard_Professions", Build)
	end
end
