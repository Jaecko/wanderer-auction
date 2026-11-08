local _, ns = ...
local L = ns.L

-- Wanderer's town card (API 13): what your shopping list still lacks, and how much of it merchants sell; a
-- click opens the list.

local W = Wanderer
local U = W and W.Util

if W and W.TownLine and U then
	W.TownLine(function()
		if not ns.On() then return nil end
		local lack, atMerchant = 0, 0
		for id, entry in pairs(ns.Shopping()) do
			if U.ItemCount(id) < (entry.count or 1) then
				lack = lack + 1
				if ns.MerchantPrice(id) then atMerchant = atMerchant + 1 end
			end
		end
		if lack == 0 then return nil end
		return { text = atMerchant > 0 and L.TOWN_LINE_MERCHANT:format(lack, atMerchant) or L.TOWN_LINE:format(lack),
			hint = L.TOWN_LINE_HINT,
			onClick = function()
				local list = _G.WandererAuctionShoppingList
				if not (list and list:IsShown()) then ns.ToggleList() end
			end }
	end, "shopping")
end
