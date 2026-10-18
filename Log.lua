local _, ns = ...
local L = ns.L

-- The prices' journal: a small window beside the auction house's, what the looks for prices and the
-- sales did, one plain line each, the newest at the bottom, colored by what came of it (a price in green,
-- nobody selling it in grey, no answer or a refusal in orange). Opened by a look at the prices; brought
-- back by its button under the list. Kept for this visit only.

local W = Wanderer
local Skin = W and W.Skin

local WIDTH, HEIGHT = 340, 440
local KEEP = 300 -- lines kept
local TONES = { -- (the line's own color: an item's link inside it gives it back after its name)
	title = { 1, 0.82, 0 }, good = { 0.56, 0.88, 0.64 }, none = { 0.6, 0.58, 0.54 }, bad = { 0.88, 0.63, 0.25 },
	text = { 0.85, 0.82, 0.75 },
}

local window, box
local lines = {} -- this visit's lines, as written (for the tests too)

local function Create()
	window = Skin.CreateWindow("WandererAuctionLog", "MEDIUM")
	-- (beside the auction house's window, the first time; then where you put it)
	local main = ns.MainWindow and ns.MainWindow()
	Skin.Dress(window, main and { "TOPLEFT", main, "TOPRIGHT", 8, 0 } or nil, "auctionLog")
	-- (Escape closes the auction house's window, not only this one: left out of the game's list)
	for index = #(UISpecialFrames or {}), 1, -1 do
		if UISpecialFrames[index] == "WandererAuctionLog" then table.remove(UISpecialFrames, index) end
	end
	-- (put away with the auction house's window: the game's own one chosen, or closed)
	if main then main:HookScript("OnHide", function() window:Hide() end) end
	window:SetSize(WIDTH, HEIGHT)
	Skin.Get(window):Layout()
	local _, title, margin = Skin.Header(window, "Wanderer Auction", L.LOG_TITLE)
	box = CreateFrame("ScrollingMessageFrame", nil, window)
	box:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
	box:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin)
	box:SetFontObject("GameFontHighlightSmall")
	box:SetJustifyH("LEFT")
	box:SetFading(false)
	box:SetMaxLines(KEEP)
	box:SetSpacing(3)
	-- (the wheel goes back through what was written)
	box:EnableMouseWheel(true)
	box:SetScript("OnMouseWheel", function(self, delta)
		if delta > 0 then self:ScrollUp() else self:ScrollDown() end
	end)
	for _, line in ipairs(lines) do box:AddMessage(line[1], line[2], line[3], line[4]) end
end

-- A line written: tone "title", "good", "none", "bad" or "text".
function ns.Log(tone, text)
	local color = TONES[tone] or TONES.text
	local line = { text, color[1], color[2], color[3] }
	lines[#lines + 1] = line
	if #lines > KEEP then table.remove(lines, 1) end
	if box then box:AddMessage(text, color[1], color[2], color[3]) end
end

function ns.ShowLog()
	if not window then Create() end
	window:SetScale(Skin.Scale())
	window:Show()
end

-- The auction house closed: the journal put away and forgotten.
function ns.ClearLog()
	wipe(lines)
	if box then box:Clear() end
	if window then window:Hide() end
end

-- (tests: the lines' words)
function ns.LogLines()
	local words = {}
	for index, line in ipairs(lines) do words[index] = line[1] end
	return words
end
