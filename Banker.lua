local _, ns = ...
local L = ns.L

-- At the banker (option, for each character, off at first): what the shopping list lacks is taken from the
-- bank first, your character's then the account's, exactly what is missing (a stack split when it is more),
-- then said in the chat; only what is still missing is left to buy. One move at a time, as the game allows
-- them; Shift held on arrival: nothing taken, as for the junk and the repair; the bags full: it stops, said.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean

local STEP = 0.3 -- seconds between two moves (the game confirms each one)
local MAX_STEPS = 60

local taken -- item id -> how many, this visit
local steps = 0
local atBank = false

-- An empty slot of your bags that takes the item (a profession's bag only for its own goods; nil: none).
local function EmptySlot(id)
	local container = C_Container or {}
	local family = C_Item and C_Item.GetItemFamily and Clean(Safe(C_Item.GetItemFamily, id)) or 0
	for _, bag in ipairs(U.BagIDs()) do
		local _, kind = Safe(container.GetContainerNumFreeSlots, bag)
		kind = Clean(kind) or 0
		if bag == 0 or kind == 0 or bit.band(family, kind) ~= 0 then
			for slot = 1, Clean(Safe(container.GetContainerNumSlots, bag)) or 0 do
				if not Safe(container.GetContainerItemInfo, bag, slot) then return bag, slot end
			end
		end
	end
end

-- The next move: an item the list lacks, found in the bank, brought to the bags. true: one was made (or one
-- waits for the game), false: nothing more to do, "full": no room.
local function Move()
	local container = C_Container or {}
	local list = ns.Shopping()
	-- (something already in hand, yours: never touched; wait for it to go, the step cap ends the wait)
	if CursorHasItem and CursorHasItem() then return true end
	-- (a move not confirmed yet by the game: its items locked, the counts not updated; wait for it)
	local waiting = false
	U.EachBagItem(function(_, _, info) if Clean(info.isLocked) then waiting = true end end)
	if waiting then return true end
	for _, bag in ipairs(U.BankIDs()) do
		for slot = 1, Clean(Safe(container.GetContainerNumSlots, bag)) or 0 do
			local info = Safe(container.GetContainerItemInfo, bag, slot)
			local id = type(info) == "table" and Clean(info.itemID)
			local lack = id and list[id] and ns.Lacking(id) or 0
			if lack > 0 then
				if Clean(info.isLocked) then return true end
				local toBag, toSlot = EmptySlot(id)
				if not toBag then return "full" end
				local count = Clean(info.stackCount) or 1
				local moved = math.min(count, lack)
				if moved < count then
					Safe(container.SplitContainerItem, bag, slot, moved)
				else
					Safe(container.PickupContainerItem, bag, slot)
				end
				Safe(container.PickupContainerItem, toBag, toSlot)
				-- (still in hand: the game refused it; given back, and no more tried)
				if CursorHasItem and CursorHasItem() then
					if ClearCursor then ClearCursor() end
					return false
				end
				taken[id] = (taken[id] or 0) + moved
				return true
			end
		end
	end
	return false
end

local function Said()
	local words = {}
	for id, count in pairs(taken or {}) do
		words[#words + 1] = L.POST_WHAT:format(count, U.ItemName(id) or ("#" .. id))
	end
	if words[1] then W.Print(L.FROMBANK_DONE:format(table.concat(words, ", "))) end
end

local function Step()
	-- (Auction or this choice switched off meanwhile: nothing more taken)
	if not (atBank and taken and ns.On() and ns.FromBank()) then
		taken = nil
		return
	end
	-- (Wanderer Bags putting your marked items in: waited for, without spending a step)
	if type(WandererBags) == "table" and WandererBags.Moving and WandererBags.Moving() then return C_Timer.After(STEP, Step) end
	steps = steps + 1
	local result = steps <= MAX_STEPS and Move() or false
	if result == true then
		C_Timer.After(STEP, Step)
		return
	end
	if result == "full" then W.Print(L.FROMBANK_FULL) end
	Said()
	taken = nil
	if ns.RefreshShopping then ns.RefreshShopping() end
end

do
	local events = CreateFrame("Frame")
	pcall(events.RegisterEvent, events, "BANKFRAME_OPENED")
	pcall(events.RegisterEvent, events, "BANKFRAME_CLOSED")
	events:SetScript("OnEvent", function(_, event)
		if event == "BANKFRAME_CLOSED" then
			atBank, taken = false, nil
			return
		end
		atBank = true
		-- (Shift held on arrival: nothing taken)
		if not (ns.On() and ns.FromBank() and next(ns.Shopping())) or U.IsSkipping() or InCombatLockdown() then return end
		taken, steps = {}, 0
		C_Timer.After(0.5, Step)
	end)
end
