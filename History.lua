local _, ns = ...
local L = ns.L

-- The prices' history. On the left, every item whose prices were seen (those
-- in your bags first): its market's value over the last days, today's against
-- it, and a chip saying whether now is a good time to sell. On the right, the
-- item chosen: its figures, its last 14 days drawn as bars (today in gold),
-- and the advice in plain words, as TradeSkillMaster's sellers judge it:
-- today's value against the days before (see Prices.lua). The days fill in
-- as you look at prices: each look adds to its day.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe = U and U.Safe

local DAYS = 14
local DAY = 86400
local ADVICE = { -- chip, its tone, the words on the right
	good = { "CHIP_SELL_NOW", "green", "ADVICE_GOOD" }, usual = { "CHIP_USUAL", "gold", "ADVICE_USUAL" },
	wait = { "CHIP_WAIT", "red", "ADVICE_WAIT" }, merchant = { "CHIP_MERCHANT", "red", "ADVICE_MERCHANT" },
	few = { "CHIP_FEW_DAYS", "grey", "ADVICE_FEW" },
}

local list, rows, chosen = nil, {}, nil
local detail = {}

local function Icon(id)
	local get = C_Item and C_Item.GetItemIconByID or GetItemIcon
	return get and U.Clean(Safe(get, id)) or nil
end

-- Every item with prices seen: { id, name, link, quality, icon, market, ratio, advice, carried }.
local function Gather()
	local carried = {}
	U.EachBagItem(function(_, _, info)
		local id = U.Clean(info.itemID)
		if id then carried[id] = true end
	end)
	rows = {}
	for id, seen in pairs(ns.DB().prices) do
		-- (followed: an item of yours whose prices were looked up to sell; a price only passing by is not)
		if seen.days and seen.days[1] then
			rows[#rows + 1] = id
		end
	end
	local ids = rows
	rows = {}
	for _, id in ipairs(ids) do
		local name, link, quality = U.ItemInfo(id)
		if not name then U.LoadItem(id) end
		local advice, ratio = ns.Advice(id, ns.Vendor(link))
		rows[#rows + 1] = { id = id, name = name or ("#" .. id), link = link, quality = quality or 1, icon = Icon(id),
			market = ns.Market(id), ratio = ratio, advice = advice, carried = carried[id] or false }
	end
	table.sort(rows, function(a, b)
		if a.carried ~= b.carried then return a.carried end
		return a.name < b.name
	end)
end

-- "+12 %" against the days before (green above, orange below).
local function Trend(ratio)
	if not ratio then return "" end
	local percent = math.floor((ratio - 1) * 100 + 0.5)
	if percent > 0 then return "|cff8fe0a2+" .. percent .. " %|r" end
	if percent < 0 then return "|cffe0a040" .. percent .. " %|r" end
	return "0 %"
end

local function Draw()
	if not (list and list:IsVisible()) then return end
	local offset = list:Clamp(#rows)
	for index, row in ipairs(list.rows) do
		local entry = rows[index + offset]
		local values, chip, tone
		if entry then
			values = { market = entry.market and U.Coins(entry.market) or "|cff8f8676" .. L.NEVER_SEEN .. "|r",
				trend = Trend(entry.ratio) }
			local advice = ADVICE[entry.advice] or ADVICE.few
			chip, tone = L[advice[1]], advice[2]
		end
		row:Fill(entry, entry ~= nil and entry == chosen, values, chip, tone)
	end
	list.empty:SetShown(#rows == 0)
end

-- The chosen item, on the right: its figures, its days as bars, the advice.
local function Show(entry)
	chosen = entry
	detail.frame:SetShown(entry ~= nil)
	detail.pick:SetShown(entry == nil)
	Draw()
	if not entry then return end
	detail.icon:Set(entry.icon, entry.quality)
	detail.name:SetText(entry.name)
	Skin.Quality(detail.name, entry.quality)
	local days = ns.Days(entry.id)
	local today = math.floor(time() / DAY)
	local todayDay = days[#days] and days[#days][1] == today and days[#days] or nil
	local low, high, valued = nil, nil, 0
	for _, day in ipairs(days) do
		if day[2] then
			valued = valued + 1
			low, high = math.min(low or day[2], day[2]), math.max(high or day[2], day[2])
		end
	end
	local function Money(value) return value and U.Coins(math.floor(value + 0.5)) or "|cff8f8676" .. L.NEVER_SEEN .. "|r" end
	detail.market.value:SetText(Money(entry.market))
	detail.today.value:SetText(Money(todayDay and todayDay[2]))
	detail.cheapest.value:SetText(Money(todayDay and todayDay[4]))
	detail.range.value:SetText(low and (U.Coins(math.floor(low + 0.5)) .. "  -  " .. U.Coins(math.floor(high + 0.5))) or Money(nil))
	detail.count.value:SetText(tostring(valued))
	-- The bars: one per day of the last 14, as high as its value against the highest (today in gold).
	for index, bar in ipairs(detail.bars) do
		local dayNumber = today - (DAYS - index)
		local value
		for _, day in ipairs(days) do if day[1] == dayNumber then value = day[2] end end
		local height = value and high and high > 0 and math.max(2, detail.chartHeight * value / high) or 2
		bar:SetHeight(height)
		if value then
			local gold = dayNumber == today
			bar:SetColorTexture(gold and 1 or 0.62, gold and 0.82 or 0.58, gold and 0 or 0.5, gold and 0.9 or 0.7)
		else
			bar:SetColorTexture(1, 1, 1, 0.06)
		end
	end
	-- The advice, in words.
	local advice = ADVICE[entry.advice] or ADVICE.few
	local percent = entry.ratio and math.floor(math.abs(entry.ratio - 1) * 100 + 0.5) or 0
	local color = advice[2] == "green" and "|cff8fe0a2" or advice[2] == "red" and "|cffe0a040" or advice[2] == "gold" and "|cffffd100"
		or "|cff9a948a"
	detail.advice:SetText(color .. L[advice[1]] .. "|r")
	detail.why:SetText(entry.advice == "few" and L.ADVICE_FEW:format(valued) or L[advice[3]]:format(percent))
end
ns.HistoryRows = function() return rows end -- (tests)

local function Build(page)
	list = Skin.Table(page, {
		nameTitle = L.COL_ITEM,
		width = 520, rows = 26, onDraw = Draw, onClick = function(entry) Show(entry) end,
		columns = {
			{ key = "market", title = L.COL_MARKET_DAYS, width = 120 },
			{ key = "trend", title = L.COL_TODAY, width = 80 },
		},
	})
	list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	list.empty:SetText(L.HISTORY_EMPTY)
	function page:Fit(height) list:Fit(height) end
	local rule = Skin.Rule(page, true, 0.12)
	rule:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP / 2, 0)
	rule:SetPoint("BOTTOM", page, "BOTTOM", 0, 0)
	detail.pick = Skin.Text(page, "GameTooltipText", "muted")
	detail.pick:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, -60)
	detail.pick:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	detail.pick:SetJustifyH("LEFT")
	detail.pick:SetText(L.HISTORY_PICK)
	local frame = CreateFrame("Frame", nil, page)
	frame:SetPoint("TOPLEFT", list, "TOPRIGHT", ns.GAP, 0)
	frame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	frame:Hide()
	detail.frame = frame
	detail.icon = Skin.Icon(frame, 40)
	detail.icon:SetPoint("TOPLEFT")
	detail.name = W.Skin.CreateText(frame, "GameFontNormalLarge")
	detail.name:SetPoint("LEFT", detail.icon, "RIGHT", 10, 0)
	detail.name:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	detail.name:SetJustifyH("LEFT")
	-- The advice, first: what to do, then why.
	detail.advice = W.Skin.CreateText(frame, "GameFontNormalLarge")
	detail.advice:SetPoint("TOPLEFT", detail.icon, "BOTTOMLEFT", 0, -18)
	detail.why = Skin.Text(frame, "GameTooltipTextSmall", "soft")
	detail.why:SetPoint("TOPLEFT", detail.advice, "BOTTOMLEFT", 0, -6)
	detail.why:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	detail.why:SetJustifyH("LEFT")
	-- The figures.
	local figures = Skin.Panel(frame)
	figures:SetPoint("TOPLEFT", detail.why, "BOTTOMLEFT", 0, -16)
	figures:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	figures:SetHeight(128)
	detail.market = Skin.SummaryLine(figures, nil, L.HISTORY_MARKET, true)
	detail.today = Skin.SummaryLine(figures, detail.market, L.HISTORY_TODAY)
	detail.cheapest = Skin.SummaryLine(figures, detail.today, L.HISTORY_CHEAPEST)
	detail.range = Skin.SummaryLine(figures, detail.cheapest, L.HISTORY_RANGE)
	detail.count = Skin.SummaryLine(figures, detail.range, L.HISTORY_DAYS)
	-- The last 14 days, as bars.
	local caps = Skin.Caps(frame, L.HISTORY_CHART)
	caps:SetPoint("TOPLEFT", figures, "BOTTOMLEFT", 0, -18)
	local chart = Skin.Panel(frame)
	chart:SetPoint("TOPLEFT", caps, "BOTTOMLEFT", 0, -6)
	chart:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	chart:SetHeight(120)
	detail.chartHeight = 92
	detail.bars = {}
	for index = 1, DAYS do
		local bar = chart:CreateTexture(nil, "ARTWORK")
		bar:SetWidth(14)
		bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 12 + (index - 1) * 22, 18)
		detail.bars[index] = bar
	end
	local oldest = Skin.Text(chart, "GameTooltipTextSmall", "muted")
	oldest:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 10, 4)
	oldest:SetText(L.HISTORY_DAYS_AGO:format(DAYS - 1))
	local newest = Skin.Text(chart, "GameTooltipTextSmall", "muted")
	newest:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 12 + (DAYS - 1) * 22 - 30, 4)
	newest:SetText(L.HISTORY_TODAY_SHORT)
end

local function Shown()
	list.offset = 0
	Gather()
	-- (the chosen one kept, its figures read again)
	local again
	for _, entry in ipairs(rows) do if chosen and entry.id == chosen.id then again = entry end end
	Show(again)
end

local function Closed() chosen = nil end

-- A name the game was fetching: the list drawn again (once, a moment after).
local again = U and U.Debounce and U.Debounce(0.3, function()
	if list and list:IsVisible() then
		Gather()
		Draw()
	end
end)
if again then ns.Listen("GET_ITEM_INFO_RECEIVED", again) end

ns.AddPage("history", L.HISTORY, Build, Shown, Closed)
