--[[
  ForeverXP 0.5.1

  A visual XP bar with an "aurora" design: teal-to-violet gradient fill,
  amber quest segment, mint rested segment, soft glow and a glass edge.

  Text ON the bar (three slots):
    LEFT   - XP per hour (leveling speed)
    CENTER - Completed & Rested segment percentages
    RIGHT  - Session time (resets at every login, survives /reload)
  Text UNDER the bar (left side):
    Estimated time to the next level, from XP/hour, XP left and bar total.

  CONTROLS:
  - Minimap button (XP icon): left-click = settings, right-click =
    lock/unlock the bar, drag = move the button.
  - Settings panel (ElvUI style): Options / Adjust / Info tabs.

  WHAT CHANGED IN 0.5.1
  - Settings could still be lost on /reload on beta clients with
    nonstandard SavedVariables timing (game injects the saved table after
    ADDON_LOADED, or swaps it in later). The DB now re-syncs with the
    game's ForeverXPDB global once per second: whatever table the game
    hands us is adopted (with our live edits moved into it), and if the
    game never provides one we publish ours so /reload has something to
    write.

  WHAT CHANGED IN 0.5.0
  - Settings now persist. SavedVariables are loaded by the game AFTER this
    file has run, so the old code kept writing into a table that was thrown
    away. The DB is now attached on ADDON_LOADED.
  - XP/hour no longer depends on the /played reply. Time on the level is
    tracked locally (and saved), /played is only used to correct it.
  - Settings panel was transparent because it lacked BackdropTemplate.
  - Played Time removed. Session Time starts from 0 at every login.
  - New: time-to-level estimate, text size + bold/normal, XP minimap icon.
]]

local ADDON_NAME = ...

--------------------------------------------------------------------
-- 1. Defaults + DB
--------------------------------------------------------------------

local DB_VERSION = 2

local defaults = {
	point = "TOP", relPoint = "TOP", x = 0, y = -150,
	width = 300, height = 20,
	locked = false,
	showQuestSegment = true,
	showRestedSegment = true,
	showBottomText = true,        -- center slot: completed & rested
	showLevelingText = true,      -- left slot: XP per hour
	showTimeLeftText = true,      -- under the bar: time to next level
	showSessionTimeText = true,   -- right slot: session time
	showBarAtMaxLevel = false,
	hideDefaultXPBar = false,
	autoQuest = false,            -- auto accept/turn-in quests
	autoSaveOnClose = true,       -- closing the settings panel after a change prints a /reload reminder
	fontSize = 11,
	fontBold = false,
	minimapPos = 225,             -- angle around the minimap
	chars = {},                   -- per-character level timing (for XP/hour)
	colors = {
		fillA   = { 0.14, 0.86, 0.80 },  -- aurora teal
		fillB   = { 0.52, 0.42, 0.98 },  -- aurora violet
		quest   = { 1.00, 0.74, 0.28 },  -- warm amber
		rested  = { 0.36, 0.90, 0.60 },  -- mint
		bg      = { 0.05, 0.06, 0.10, 0.92 },
		border  = { 0.45, 0.52, 0.90, 0.90 },
	},
}

local function deepCopy(src)
	local out = {}
	for k, v in pairs(src) do
		out[k] = type(v) == "table" and deepCopy(v) or v
	end
	return out
end

local function deepMergeDefaults(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			deepMergeDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

-- SAVED VARIABLES TIMING (why this looks paranoid):
-- On a normal client the game injects ForeverXPDB right before ADDON_LOADED.
-- 0.5.0 handled that - and it still wasn't enough here, because this beta
-- client can also (a) inject the saved table only AFTER ADDON_LOADED, or
-- (b) swap the global for its own stale copy later. In both cases we wrote
-- our settings into a table the game never serializes, and /reload brought
-- back old values (most visible on the Adjust sliders, since every other
-- setting defaults to "on").
--
-- So the DB is now self-healing: syncSavedVars() runs once a second and
-- whenever we init. If the game's table exists and isn't the one we're
-- writing to, we ADOPT it - moving our live edits over the stale values -
-- and from then on everything writes where the game actually saves. If the
-- game never provides a table, we publish ours under the global name.
local db = deepCopy(defaults)
local defaultsSnapshot = deepCopy(defaults) -- never mutated; dirty detector
local dbReady = false

local function deepEqual(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

-- SECOND COPY. Everything is also mirrored into a per-character saved file
-- (ForeverXPCharDB, see the .toc). If the account-wide file is not handed
-- back to us on this client, the newer of the two copies wins.
local everAdopted = false   -- the game gave us a saved table at some point
local restoredFromBackup = false
local needRefresh = false   -- UI must be repainted after a late restore

local function mirrorToBackup()
	if not dbReady then return end
	db.saveStamp = time()
	_G.ForeverXPCharDB = deepCopy(db)
end

local function restoreFromBackup()
	local c = rawget(_G, "ForeverXPCharDB")
	if type(c) ~= "table" or type(c.saveStamp) ~= "number" then return false end
	if c.saveStamp <= (tonumber(db.saveStamp) or 0) then return false end
	for k, v in pairs(deepCopy(c)) do db[k] = v end
	deepMergeDefaults(db, defaults)
	restoredFromBackup = true
	needRefresh = true
	return true
end

-- EXTRA COPIES in places that do not depend on SavedVariables at all (on this
-- client the saved file is written but never handed back). The user-adjustable
-- settings are packed into one short string, e.g.
--   b=1583;f=15;h=43;m=225;p=TOP;r=TOP;w=600;x=64.2;y=-10.0
-- and kept in (1) a custom CVar - survives /reload - and (2) a macro named
-- "ForeverXPData" - survives quitting the game, because macros are stored by
-- the game itself. Both are rewritten within a second of any change.
local CVAR_NAME  = "foreverxpSettings"
local MACRO_NAME = "ForeverXPData"
local MACRO_TAG  = "#fxp "
local cvarStatus, macroStatus = "not tried", "not tried"
local cvarLoaded, macroLoaded = false, false
local cvarLast, macroLast
local worldEntered, macroWait = false, 0

local CV_NUM = {
	w = { "width", 60, 600, "%.0f" }, h = { "height", 8, 60, "%.0f" }, f = { "fontSize", 8, 24, "%.0f" },
	x = { "x", -5000, 5000, "%.1f" }, y = { "y", -5000, 5000, "%.1f" }, m = { "minimapPos", -720, 720, "%.0f" },
}
local CV_STR  = { p = "point", r = "relPoint" }
local CV_BOOL = { "locked", "showQuestSegment", "showRestedSegment", "showBottomText", "showLevelingText",
	"showTimeLeftText", "showSessionTimeText", "showBarAtMaxLevel", "hideDefaultXPBar", "autoQuest", "fontBold", "autoSaveOnClose" }
local ANCHORS = { TOP = 1, BOTTOM = 1, LEFT = 1, RIGHT = 1, CENTER = 1, TOPLEFT = 1, TOPRIGHT = 1, BOTTOMLEFT = 1, BOTTOMRIGHT = 1 }

local function encodeSettings()
	local parts = {}
	for key, def in pairs(CV_NUM) do
		local v = db[def[1]]
		if type(v) == "number" then parts[#parts + 1] = key .. "=" .. string.format(def[4], v) end
	end
	for key, field in pairs(CV_STR) do
		if type(db[field]) == "string" then parts[#parts + 1] = key .. "=" .. db[field] end
	end
	local mask = 0
	for i, k in ipairs(CV_BOOL) do
		if db[k] then mask = mask + 2 ^ (i - 1) end
	end
	parts[#parts + 1] = "b=" .. string.format("%.0f", mask)
	table.sort(parts)
	return table.concat(parts, ";")
end

-- returns how many values were applied
local function applyEncoded(str)
	local n = 0
	for k, v in string.gmatch(str or "", "([^;=]+)=([^;]*)") do
		local def = CV_NUM[k]
		if def then
			local num = tonumber(v)
			if num and num >= def[2] and num <= def[3] then
				if def[4] == "%.0f" then num = math.floor(num + 0.5) end
				db[def[1]] = num
				n = n + 1
			end
		elseif CV_STR[k] then
			if ANCHORS[v] then db[CV_STR[k]] = v; n = n + 1 end
		elseif k == "b" then
			local mask = tonumber(v)
			if mask then
				for i, bk in ipairs(CV_BOOL) do
					db[bk] = (math.floor(mask / 2 ^ (i - 1)) % 2 == 1)
				end
				n = n + 1
			end
		end
	end
	return n
end

-- CVar ---------------------------------------------------------------
local function cvarGet()
	local f = (C_CVar and C_CVar.GetCVar) or GetCVar
	if not f then return nil end
	local ok, v = pcall(f, CVAR_NAME)
	if ok and type(v) == "string" then return v end
	return nil
end

local function cvarInit()
	local reg = (C_CVar and C_CVar.RegisterCVar) or RegisterCVar
	if reg then pcall(reg, CVAR_NAME, "") end
	local raw = cvarGet()
	if raw == nil then
		cvarStatus = "unavailable"
		return
	end
	if raw == "" then
		cvarStatus = "empty"
	else
		cvarStatus = string.format("loaded %d values", applyEncoded(raw))
	end
	cvarLast = raw
	cvarLoaded = true
end

local function cvarWrite()
	if not cvarLoaded or not dbReady then return end
	local enc = encodeSettings()
	if enc == cvarLast then return end
	local set = (C_CVar and C_CVar.SetCVar) or SetCVar
	if set and pcall(set, CVAR_NAME, enc) then cvarLast = enc end
end

-- Macro --------------------------------------------------------------
local function macroRead()
	if not GetMacroInfo then return nil end
	local ok, name, _, body = pcall(GetMacroInfo, MACRO_NAME)
	if ok and name then return body or "" end
	return nil
end

-- Called from the 1s ticker until it has run once after login.
local function macroLoad()
	if macroLoaded or not dbReady or not worldEntered then return false end
	macroWait = macroWait + 1
	if macroWait < 3 then return false end -- give the game time to load macros
	if not GetMacroInfo then
		macroStatus = "unavailable"
		macroLoaded = true
		return false
	end
	local body = macroRead()
	local changed = false
	if body and string.sub(body, 1, #MACRO_TAG) == MACRO_TAG then
		local enc = string.sub(body, #MACRO_TAG + 1)
		local before = encodeSettings()
		local n = applyEncoded(enc)
		macroStatus = string.format("loaded %d values", n)
		macroLast = enc
		changed = (encodeSettings() ~= before)
	else
		macroStatus = body and "found, unreadable" or "none yet"
	end
	macroLoaded = true
	return changed
end

local function macroWrite()
	if not macroLoaded or not dbReady or not CreateMacro then return end
	if InCombatLockdown and InCombatLockdown() then return end
	local enc = encodeSettings()
	if enc == macroLast then return end
	local body = MACRO_TAG .. enc
	local ok, id
	if macroRead() ~= nil then
		ok, id = pcall(EditMacro, MACRO_NAME, MACRO_NAME, nil, body)
	else
		ok, id = pcall(CreateMacro, MACRO_NAME, "INV_Misc_QuestionMark", body, false)
		if not (ok and id) then ok, id = pcall(CreateMacro, MACRO_NAME, 134400, body, false) end
		if not (ok and id) then ok, id = pcall(CreateMacro, MACRO_NAME, "INV_Misc_QuestionMark", body, true) end
	end
	if ok and id then
		macroLast = enc
		macroStatus = "saved"
	else
		macroStatus = "could not write (macro slots full or blocked)"
	end
end

local function syncSavedVars()
	local g = rawget(_G, "ForeverXPDB")
	if g == nil then g = _G.ForeverXPDB end
	if type(g) ~= "table" then
		-- The game hasn't handed us a saved table (yet). Do NOT publish ours
		-- here: some clients only inject the saved data when the global is
		-- still empty, and an early publish would block it for good. Ours is
		-- published at logout (and as a late fallback, see the ticker).
		return
	end
	if g == db then return end
	-- adopt the game's table, keeping our live edits (anything that no
	-- longer equals the defaults) over the stale saved copy
	for k, v in pairs(db) do
		if g[k] == nil or not deepEqual(v, defaultsSnapshot[k]) then
			g[k] = v
		end
	end
	db = g
	everAdopted = true
	if dbReady then
		deepMergeDefaults(db, defaults)
		restoreFromBackup()
	end
end

local function initDB()
	syncSavedVars() -- adopt the injected table if the game already gave it
	if (db.dbVersion or 0) < DB_VERSION then
		db.colors = nil             -- new palette
		db.showPlayedTimeText = nil -- feature removed
		db.sessionStart = nil       -- session is no longer stored that way
		db.dbVersion = DB_VERSION
	end
	deepMergeDefaults(db, defaults)
	dbReady = true
	restoreFromBackup()
	cvarInit() -- freshest source: overrides both saved files
end

--------------------------------------------------------------------
-- 2. Safe API wrappers
--------------------------------------------------------------------

local function safe(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c = pcall(fn, ...)
	if not ok then return nil end
	return a, b, c
end

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function printMsg(msg)
	if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff8ee6deForeverXP|r " .. msg) end
end

local function getQuestLogPendingXP()
	if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then
		return 0
	end
	local ok, total = pcall(function()
		local sum = 0
		local numEntries = C_QuestLog.GetNumQuestLogEntries()
		for i = 1, (numEntries or 0) do
			local info = C_QuestLog.GetInfo(i)
			if info and not info.isHeader and info.questID then
				local complete = false
				if C_QuestLog.IsComplete then
					local c = C_QuestLog.IsComplete(info.questID)
					complete = c and c ~= 0
				elseif info.isComplete then
					complete = info.isComplete and info.isComplete ~= 0
				end
				if complete and GetQuestLogRewardXP then
					local xp = GetQuestLogRewardXP(info.questID)
					if type(xp) == "number" then sum = sum + xp end
				end
			end
		end
		return sum
	end)
	if ok and type(total) == "number" then return total end
	return 0
end

--------------------------------------------------------------------
-- 3. Formatting helpers
--------------------------------------------------------------------

local function formatDuration(seconds)
	seconds = math.floor((seconds or 0) + 0.5)
	if seconds < 0 then seconds = 0 end
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	local s = seconds % 60
	return string.format("%d:%02d:%02d", h, m, s)
end

local function formatXPAmount(v)
	if not v then return "--" end
	if v >= 1000000 then
		return string.format("%.2fm", v / 1000000)
	elseif v >= 1000 then
		return string.format("%.1fk", v / 1000)
	end
	return tostring(math.floor(v + 0.5))
end

-- "<1m", "42m", "3h 05m", "2d 4h"
local function formatETA(seconds)
	if not seconds or seconds ~= seconds or seconds == math.huge then return nil end
	if seconds < 60 then return "<1m" end
	local totalMin = math.floor(seconds / 60 + 0.5)
	local d = math.floor(totalMin / 1440)
	if d > 99 then return ">99d" end
	local h = math.floor((totalMin % 1440) / 60)
	local m = totalMin % 60
	if d > 0 then return string.format("%dd %dh", d, h) end
	if h > 0 then return string.format("%dh %02dm", h, m) end
	return string.format("%dm", m)
end

--------------------------------------------------------------------
-- 4. XP/hour tracking + session
--
-- We keep our own "time spent on this level" counter (saved per
-- character) instead of relying on the /played reply, which sometimes
-- never arrives. /played, when it does arrive, just corrects the counter.
--------------------------------------------------------------------

local track          -- record for the current character/level
local charKey
local lastTickAt
local playedStamp = 0

local function ensureTrack()
	if not dbReady then return nil end
	local level = safe(UnitLevel, "player") or 0
	if level <= 0 then return nil end
	if not charKey then
		local name = safe(UnitName, "player")
		if not name then return nil end
		charKey = name .. "-" .. (safe(GetRealmName) or "")
	end
	local rec = db.chars[charKey]
	if not rec or rec.level ~= level then
		-- new level (or first run): start counting; keep the last known
		-- speed so the display never falls back to "--" after a level-up
		rec = {
			level = level,
			secs = 0,
			baseXP = safe(UnitXP, "player") or 0,
			rate = rec and rec.rate or nil,
		}
		db.chars[charKey] = rec
	end
	track = rec
	return rec
end

local function tickTrack()
	if not dbReady then return end
	local now = GetTime()
	local dt = lastTickAt and (now - lastTickAt) or 0
	lastTickAt = now
	local rec = ensureTrack()
	if rec and dt > 0 and dt < 300 then rec.secs = rec.secs + dt end
	db.lastSeen = time()
end

local function onPlayed(total, levelSecs)
	playedStamp = playedStamp + 1
	local rec = ensureTrack()
	if rec and type(levelSecs) == "number" and levelSecs > 0 then
		rec.secs = levelSecs
		rec.baseXP = 0
	end
end

local function requestPlayed(retries)
	local before = playedStamp
	safe(RequestTimePlayed)
	if retries and retries > 0 and C_Timer and C_Timer.After then
		C_Timer.After(10, function()
			if playedStamp == before then requestPlayed(retries - 1) end
		end)
	end
end

local function getXPPerHour(xp)
	local rec = track
	if not rec then return nil end
	local gained = xp - (rec.baseXP or 0)
	if rec.secs >= 60 and gained > 0 then
		rec.rate = gained / rec.secs * 3600
	end
	return rec.rate
end

local function sessionSeconds()
	local now = time()
	return now - (db.sessionStart or now)
end

--------------------------------------------------------------------
-- 5. Frame construction (aurora design)
--------------------------------------------------------------------

local PAD = 4
local update, relayout, toggleOptions

local main = CreateFrame("Frame", "ForeverXPMainFrame", UIParent, "BackdropTemplate")
main:SetSize(db.width + PAD * 2, db.height + PAD * 2)
main:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
main:SetMovable(true)
main:EnableMouse(true)
main:RegisterForDrag("LeftButton")
main:SetClampedToScreen(true)

if main.SetBackdrop then
	main:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Buttons\\WHITE8x8",
		edgeSize = 1,
	})
	main:SetBackdropColor(0, 0, 0, 0)
	local bc = db.colors.border
	main:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])
end

local bar = CreateFrame("Frame", "ForeverXPBarFrame", main)
bar:SetSize(db.width, db.height)
bar:SetPoint("TOP", main, "TOP", 0, -PAD)

-- Soft outer glow behind the bar
local glow = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
glow:SetPoint("CENTER", bar, "CENTER", 0, 0)
glow:SetSize(db.width + 8, db.height + 8)
glow:SetColorTexture(1, 1, 1, 1)
local function paintGlow()
	local a, b = db.colors.fillA, db.colors.fillB
	local ok = pcall(function()
		glow:SetGradient("HORIZONTAL",
			CreateColor(a[1], a[2], a[3], 0.16),
			CreateColor(b[1], b[2], b[3], 0.16))
	end)
	if not ok then
		glow:SetColorTexture(a[1], a[2], a[3], 0.16)
	end
end

-- Background (the "remaining" portion)
local bg = bar:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(bar)
bg:SetColorTexture(unpack(db.colors.bg))

-- Gradient fill (current XP)
local fill = bar:CreateTexture(nil, "ARTWORK", nil, 1)
fill:SetPoint("LEFT", bar, "LEFT", 0, 0)
fill:SetHeight(db.height)
fill:SetWidth(1)
local function paintFill()
	local a, b = db.colors.fillA, db.colors.fillB
	local ok = pcall(function()
		fill:SetColorTexture(1, 1, 1, 1)
		fill:SetGradient("HORIZONTAL", CreateColor(a[1], a[2], a[3], 1), CreateColor(b[1], b[2], b[3], 1))
	end)
	if not ok then
		fill:SetColorTexture(a[1], a[2], a[3], 1)
	end
end

-- Amber segment (unclaimed quest XP)
local quest = bar:CreateTexture(nil, "ARTWORK", nil, 2)
quest:SetPoint("LEFT", fill, "RIGHT", 0, 0)
quest:SetHeight(db.height)
quest:SetWidth(0.001)
quest:SetColorTexture(unpack(db.colors.quest))

-- Mint segment (rested bonus)
local rested = bar:CreateTexture(nil, "ARTWORK", nil, 3)
rested:SetPoint("LEFT", quest, "RIGHT", 0, 0)
rested:SetHeight(db.height)
rested:SetWidth(0.001)
rested:SetColorTexture(unpack(db.colors.rested))

-- Glass sheen + bottom shadow
local sheen = bar:CreateTexture(nil, "ARTWORK", nil, 5)
sheen:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
sheen:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
sheen:SetHeight(2)
sheen:SetColorTexture(1, 1, 1, 0.14)

local shadow = bar:CreateTexture(nil, "ARTWORK", nil, 5)
shadow:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
shadow:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
shadow:SetHeight(2)
shadow:SetColorTexture(0, 0, 0, 0.30)

-- Thin separators so segments read distinctly
local function makeDivider(anchorTo)
	local d = bar:CreateTexture(nil, "ARTWORK", nil, 4)
	d:SetPoint("LEFT", anchorTo, "RIGHT", -1, 0)
	d:SetSize(1, db.height)
	d:SetColorTexture(0.02, 0.03, 0.06, 0.55)
	return d
end
local divQuest = makeDivider(fill)
local divRested = makeDivider(quest)

--------------------------------------------------------------------
-- 6. Bar text (three slots on the bar + time-to-level under it)
--------------------------------------------------------------------

local BAR_FONT = "Fonts\\FRIZQT__.TTF"
local barTexts = {}

local function fontFlags()
	return db.fontBold and "THICKOUTLINE" or "OUTLINE"
end

local function barFont(parent)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFont(BAR_FONT, db.fontSize, fontFlags())
	fs:SetTextColor(1, 1, 1, 1)
	barTexts[#barTexts + 1] = fs
	return fs
end

local function applyFonts()
	local size = clamp(db.fontSize or 11, 8, 24)
	for _, fs in ipairs(barTexts) do
		fs:SetFont(BAR_FONT, size, fontFlags())
	end
end

-- LEFT: XP per hour
local leftText = barFont(bar)
leftText:SetPoint("LEFT", bar, "LEFT", 7, 0)
leftText:SetJustifyH("LEFT")

-- CENTER: Completed & Rested
local centerText = barFont(bar)
centerText:SetPoint("CENTER", bar, "CENTER", 0, 0)

-- RIGHT: Session time
local rightText = barFont(bar)
rightText:SetPoint("RIGHT", bar, "RIGHT", -7, 0)
rightText:SetJustifyH("RIGHT")

-- UNDER THE BAR, LEFT: time to next level
local timeText = barFont(bar)
timeText:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 1, -5)
timeText:SetJustifyH("LEFT")

--------------------------------------------------------------------
-- 7. Update logic
--------------------------------------------------------------------

update = function()
	local level = safe(UnitLevel, "player") or 0
	local maxLevel = safe(GetMaxPlayerLevel) or level
	local xpDisabled = safe(IsXPUserDisabled)
	local atCap = (maxLevel and level >= maxLevel and maxLevel > 0)

	if xpDisabled or atCap then
		if not db.showBarAtMaxLevel then
			main:Hide()
			return
		end
		main:Show()
		fill:SetWidth(db.width)
		quest:SetWidth(0.001)
		rested:SetWidth(0.001)
		divQuest:Hide()
		divRested:Hide()
		leftText:SetText("")
		centerText:SetText(xpDisabled and "Experience Disabled" or ("Level " .. level .. " - Max Level"))
		rightText:SetText("")
		timeText:SetText("")
		return
	end
	main:Show()

	local xp = safe(UnitXP, "player") or 0
	local xpMax = safe(UnitXPMax, "player") or 0
	local restedXP = safe(GetXPExhaustion) or 0
	local questXP = db.showQuestSegment and getQuestLogPendingXP() or 0

	if xpMax <= 0 then
		leftText:SetText("")
		centerText:SetText("--")
		rightText:SetText("")
		timeText:SetText("")
		return
	end

	local fillFrac = clamp(xp / xpMax, 0, 1)
	local questFrac = db.showQuestSegment and clamp(questXP / xpMax, 0, 1 - fillFrac) or 0
	local restedFrac = db.showRestedSegment
		and clamp(restedXP / xpMax, 0, 1 - fillFrac - questFrac)
		or 0

	fill:SetWidth(math.max(0.001, db.width * fillFrac))
	quest:SetWidth(math.max(0.001, db.width * questFrac))
	rested:SetWidth(math.max(0.001, db.width * restedFrac))
	divQuest:SetShown(questFrac > 0)
	divRested:SetShown(restedFrac > 0)

	local xpPerHour = getXPPerHour(xp)

	-- LEFT: XP per hour
	if db.showLevelingText then
		leftText:SetText(xpPerHour and (formatXPAmount(xpPerHour) .. " XP/h") or "-- XP/h")
	else
		leftText:SetText("")
	end

	-- CENTER: Completed & Rested
	if db.showBottomText then
		local parts = {}
		if db.showQuestSegment then
			parts[#parts + 1] = string.format("|cffffbd47Completed: %.1f%%|r", questFrac * 100)
		end
		if db.showRestedSegment then
			parts[#parts + 1] = string.format("|cff5ce699Rested: %.1f%%|r", restedFrac * 100)
		end
		centerText:SetText(table.concat(parts, "  -  "))
	else
		centerText:SetText("")
	end

	-- RIGHT: Session time
	if db.showSessionTimeText then
		rightText:SetText("Session: " .. formatDuration(sessionSeconds()))
	else
		rightText:SetText("")
	end

	-- UNDER THE BAR: estimated time to the next level
	if db.showTimeLeftText then
		local xpLeft = math.max(0, xpMax - xp)
		local eta
		if xpPerHour and xpPerHour > 0 then
			eta = formatETA(xpLeft / xpPerHour * 3600)
		end
		timeText:SetText(string.format(
			"|cff8ee6deNext level:|r %s%s  |cffaaaaaa(%s XP left of %s)|r",
			eta and "~" or "", eta or "--", formatXPAmount(xpLeft), formatXPAmount(xpMax)))
	else
		timeText:SetText("")
	end
end

--------------------------------------------------------------------
-- 8. Layout refresh (after a toggle/resize)
--------------------------------------------------------------------

relayout = function()
	main:SetSize(db.width + PAD * 2, db.height + PAD * 2)
	main:ClearAllPoints()
	main:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	bar:SetSize(db.width, db.height)
	glow:SetSize(db.width + 8, db.height + 8)
	fill:SetHeight(db.height)
	quest:SetHeight(db.height)
	rested:SetHeight(db.height)
	divQuest:SetHeight(db.height)
	divRested:SetHeight(db.height)
	paintGlow()
	paintFill()
	applyFonts()
	update()
end

--------------------------------------------------------------------
-- 9. Hide the default Blizzard XP bar (best effort)
--------------------------------------------------------------------

local DEFAULT_XP_BAR_NAMES = {
	"StatusTrackingBarManager", -- Covers modern/beta client layouts
	"MainStatusTrackingBarContainer",
	"MainMenuBarXPBar",
	"MainMenuExpBar",
	"MainMenuBarExpBar",
	"MainMenuBarMaxLevelBar",
	"ReputationWatchBar",
}

local function applyHideDefaultXP()
	local hide = db.hideDefaultXPBar
	for _, name in ipairs(DEFAULT_XP_BAR_NAMES) do
		local f = _G[name]
		if f and type(f.Hide) == "function" and type(f.Show) == "function" then
			pcall(function()
				if hide then f:Hide() else f:Show() end
				
				-- Hook the Show method so Blizzard can't force it back open
				if not f.fxpHooked then
					f.fxpHooked = true
					hooksecurefunc(f, "Show", function(self)
						if db.hideDefaultXPBar then self:Hide() end
					end)
				end
			end)
		end
	end
end

--------------------------------------------------------------------
-- 10. Dragging the bar
--------------------------------------------------------------------

main:SetScript("OnDragStart", function(self)
	if db.locked then return end
	self:StartMoving()
end)
main:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint()
	db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end)

--------------------------------------------------------------------
-- 11. Minimap button (XP icon drawn from textures, no icon file needed)
--------------------------------------------------------------------

local minimapBtn = CreateFrame("Button", "ForeverXPMinimapButton", Minimap)
minimapBtn:SetSize(31, 31)
minimapBtn:SetFrameStrata("MEDIUM")
minimapBtn:SetFrameLevel(Minimap:GetFrameLevel() + 6)
minimapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapBtn:RegisterForDrag("LeftButton")
pcall(minimapBtn.SetHighlightTexture, minimapBtn, "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local mmBack = minimapBtn:CreateTexture(nil, "BACKGROUND")
mmBack:SetSize(20, 20)
mmBack:SetPoint("TOPLEFT", 7, -5)
mmBack:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

-- icon body: dark plate, "XP" label and a tiny aurora bar
local mmPlate = minimapBtn:CreateTexture(nil, "ARTWORK")
mmPlate:SetSize(17, 17)
mmPlate:SetPoint("TOPLEFT", 8, -6)
mmPlate:SetColorTexture(0.05, 0.06, 0.10, 1)

local mmTrack = minimapBtn:CreateTexture(nil, "ARTWORK", nil, 1)
mmTrack:SetSize(13, 4)
mmTrack:SetPoint("BOTTOM", mmPlate, "BOTTOM", 0, 2)
mmTrack:SetColorTexture(0.20, 0.22, 0.32, 1)

local mmFill = minimapBtn:CreateTexture(nil, "ARTWORK", nil, 2)
mmFill:SetSize(9, 4)
mmFill:SetPoint("LEFT", mmTrack, "LEFT", 0, 0)
do
	local ok = pcall(function()
		mmFill:SetColorTexture(1, 1, 1, 1)
		mmFill:SetGradient("HORIZONTAL", CreateColor(0.14, 0.86, 0.80, 1), CreateColor(0.52, 0.42, 0.98, 1))
	end)
	if not ok then mmFill:SetColorTexture(0.14, 0.86, 0.80, 1) end
end

local mmLabel = minimapBtn:CreateFontString(nil, "OVERLAY")
mmLabel:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
mmLabel:SetPoint("BOTTOM", mmTrack, "TOP", 0, 1)
mmLabel:SetTextColor(0.56, 0.90, 0.87, 1)
mmLabel:SetText("XP")

local mmBorder = minimapBtn:CreateTexture(nil, "OVERLAY")
mmBorder:SetSize(53, 53)
mmBorder:SetPoint("TOPLEFT")
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local function minimapBtnUpdatePosition()
	local angle = math.rad(db.minimapPos or 225)
	local cosA, sinA = math.cos(angle), math.sin(angle)
	local w = (Minimap:GetWidth() / 2) + 5
	local h = (Minimap:GetHeight() / 2) + 5
	local x, y
	local shape = safe(GetMinimapShape)
	if shape == "SQUARE" then
		-- square minimaps (ElvUI): slide the button along the edge
		x = clamp(cosA * w * 1.4142, -w, w)
		y = clamp(sinA * h * 1.4142, -h, h)
	else
		x, y = cosA * w, sinA * h
	end
	minimapBtn:ClearAllPoints()
	minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end
minimapBtnUpdatePosition()

local lastDragEnd = 0
minimapBtn:SetScript("OnDragStart", function(self) self.dragging = true end)
minimapBtn:SetScript("OnDragStop", function(self)
	self.dragging = false
	lastDragEnd = GetTime()
end)
minimapBtn:SetScript("OnUpdate", function(self)
	if not self.dragging then return end
	local cx, cy = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	local mx, my = Minimap:GetCenter()
	if not (cx and cy and mx and my) then return end
	db.minimapPos = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
	minimapBtnUpdatePosition()
end)

minimapBtn:SetScript("OnClick", function(_, button)
	if GetTime() - lastDragEnd < 0.25 then return end -- release after a drag
	if button == "RightButton" then
		db.locked = not db.locked
		printMsg("bar " .. (db.locked and "locked." or "unlocked - drag to move."))
		if toggleOptions and _G.ForeverXPOptionsFrame and _G.ForeverXPOptionsFrame.Refresh then
			_G.ForeverXPOptionsFrame:Refresh()
		end
	else
		toggleOptions()
	end
end)

minimapBtn:SetScript("OnEnter", function(self)
	if not self.dragging then
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("ForeverXP")
		GameTooltip:AddLine("Left-click: settings", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("Right-click: lock/unlock bar", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end
end)
minimapBtn:SetScript("OnLeave", function()
	if GameTooltip then GameTooltip:Hide() end
end)

--------------------------------------------------------------------
-- 12. Settings panel (ElvUI look: flat dark boxes, 1px black borders,
--     value-colored accents). Built on first open so ElvUI's colors
--     and font are available; if ElvUI is loaded we borrow them.
--------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8x8"

local theme = {
	font   = "Fonts\\ARIALN.TTF",
	bg     = { 0.06, 0.06, 0.06, 0.96 },
	box    = { 0.10, 0.10, 0.10, 1 },
	line   = { 0.22, 0.22, 0.22, 1 },
	border = { 0, 0, 0, 1 },
	value  = { 0.09, 0.52, 0.82 },   -- ElvUI default blue
	text   = { 0.90, 0.90, 0.90 },
	dim    = { 0.60, 0.60, 0.60 },
}

local function resolveTheme()
	pcall(function()
		if not (ElvUI and type(ElvUI) == "table") then return end
		local E = unpack(ElvUI)
		local m = E and E.media
		if type(m) ~= "table" then return end
		if type(m.rgbvaluecolor) == "table" then theme.value = { m.rgbvaluecolor[1], m.rgbvaluecolor[2], m.rgbvaluecolor[3] } end
		if type(m.backdropcolor) == "table" then theme.box = { m.backdropcolor[1], m.backdropcolor[2], m.backdropcolor[3], 1 } end
		if type(m.backdropfadecolor) == "table" then
			theme.bg = { m.backdropfadecolor[1], m.backdropfadecolor[2], m.backdropfadecolor[3], 0.96 }
		end
		if type(m.bordercolor) == "table" then theme.border = { m.bordercolor[1], m.bordercolor[2], m.bordercolor[3], 1 } end
		if type(m.normFont) == "string" and m.normFont ~= "" then theme.font = m.normFont end
	end)
end

local function setFont(fs, size, flags)
	local ok, res = pcall(fs.SetFont, fs, theme.font, size, flags or "")
	if not ok or res == false then
		fs:SetFont("Fonts\\FRIZQT__.TTF", size, flags or "")
	end
end

local function hex(c)
	return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

local function newBox(parent, bg, border, frameType, name)
	local f = CreateFrame(frameType or "Frame", name, parent, "BackdropTemplate")
	if f.SetBackdrop then
		f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
		f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
		f:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
	end
	return f
end

local function setBorder(f, c)
	if f.SetBackdropBorderColor then f:SetBackdropBorderColor(c[1], c[2], c[3], c[4] or 1) end
end

local function label(parent, text, size, color, flags)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	setFont(fs, size or 12, flags)
	local c = color or theme.text
	fs:SetTextColor(c[1], c[2], c[3], 1)
	fs:SetText(text or "")
	return fs
end

local optionsPanel

-- An addon cannot write its save file itself, and this client also blocks
-- addons from calling ReloadUI ("Interface action failed because of an
-- AddOn"). The game writes the file on /reload or a clean logout/exit, so all
-- we can do is make sure our table is the one it will write, and tell you.
local function saveNow()
	if not dbReady then return end
	_G.ForeverXPDB = db
	mirrorToBackup()
	printMsg("settings changed - type /reload now to write them to disk.")
end

local function settingsSnapshot()
	local t = deepCopy(db)
	t.chars, t.lastSeen, t.sessionStart, t.saveStamp = nil, nil, nil, nil
	return t
end

local function buildOptions()
	resolveTheme()
	local T = theme
	local PANEL_W, PANEL_H = 340, 360
	local CONTENT_W = PANEL_W - 24
	local TRACK_W = CONTENT_W - 4

	local panel = newBox(UIParent, T.bg, T.border, "Frame", "ForeverXPOptionsFrame")
	optionsPanel = panel
	panel:SetSize(PANEL_W, PANEL_H)
	panel:SetPoint("CENTER")
	panel:SetFrameStrata("DIALOG")
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
	panel:SetClampedToScreen(true)
	if UISpecialFrames then table.insert(UISpecialFrames, "ForeverXPOptionsFrame") end

	-- header strip + title
	local head = panel:CreateTexture(nil, "ARTWORK")
	head:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
	head:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -1)
	head:SetHeight(26)
	head:SetColorTexture(T.box[1], T.box[2], T.box[3], 1)

	local title = label(panel, hex(T.value) .. "XP|r Bar  " .. hex(T.dim) .. "0.5.1|r", 13)
	title:SetPoint("LEFT", head, "LEFT", 10, 0)

	local closeBtn = newBox(panel, T.bg, T.border, "Button")
	closeBtn:SetSize(18, 18)
	closeBtn:SetPoint("RIGHT", head, "RIGHT", -4, 0)
	local closeX = label(closeBtn, "X", 12)
	closeX:SetPoint("CENTER", 0, 0)
	closeBtn:SetScript("OnClick", function() panel:Hide() end)
	closeBtn:SetScript("OnEnter", function() closeX:SetTextColor(1, 0.25, 0.25, 1) setBorder(closeBtn, { 1, 0.25, 0.25, 1 }) end)
	closeBtn:SetScript("OnLeave", function() closeX:SetTextColor(T.text[1], T.text[2], T.text[3], 1) setBorder(closeBtn, T.border) end)

	-- pages + tabs -------------------------------------------------
	local pages, tabs = {}, {}
	local function newPage(key)
		local p = CreateFrame("Frame", nil, panel)
		p:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -62)
		p:SetSize(CONTENT_W, PANEL_H - 74)
		p:Hide()
		pages[key] = p
		return p
	end

	local function switchTab(key)
		for k, p in pairs(pages) do p:SetShown(k == key) end
		for k, b in pairs(tabs) do
			local on = (k == key)
			setBorder(b, on and T.value or T.border)
			local c = on and T.value or T.dim
			b.text:SetTextColor(c[1], c[2], c[3], 1)
		end
	end
	panel.SwitchTab = switchTab

	local TAB_W = (CONTENT_W - 8) / 3
	local function makeTab(key, text, index)
		local b = newBox(panel, T.box, T.border, "Button")
		b:SetSize(TAB_W, 22)
		b:SetPoint("TOPLEFT", panel, "TOPLEFT", 12 + (index - 1) * (TAB_W + 4), -34)
		b.text = label(b, text, 12)
		b.text:SetPoint("CENTER", 0, 0)
		b:SetScript("OnClick", function() switchTab(key) end)
		tabs[key] = b
	end
	makeTab("options", "Options", 1)
	makeTab("adjust", "Adjust", 2)
	makeTab("info", "Info", 3)

	-- widgets ------------------------------------------------------
	local checks, sliders, choices = {}, {}, {}

	local function newStack(page) return { page = page, y = 0 } end

	local function addHeader(s, text)
		local fs = label(s.page, text, 12, T.value)
		fs:SetPoint("TOPLEFT", s.page, "TOPLEFT", 2, s.y - 3)
		local line = s.page:CreateTexture(nil, "ARTWORK")
		line:SetPoint("TOPLEFT", s.page, "TOPLEFT", 0, s.y - 20)
		line:SetSize(CONTENT_W, 1)
		line:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
		s.y = s.y - 26
	end

	local function addCheck(s, text, get, set, after)
		local row = CreateFrame("Button", nil, s.page)
		row:SetSize(CONTENT_W, 20)
		row:SetPoint("TOPLEFT", s.page, "TOPLEFT", 0, s.y)
		local box = newBox(row, T.box, T.border)
		box:SetSize(14, 14)
		box:SetPoint("LEFT", row, "LEFT", 2, 0)
		local tick = box:CreateTexture(nil, "OVERLAY")
		tick:SetPoint("TOPLEFT", box, "TOPLEFT", 3, -3)
		tick:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 3)
		tick:SetColorTexture(T.value[1], T.value[2], T.value[3], 1)
		local fs = label(row, text, 12)
		fs:SetPoint("LEFT", box, "RIGHT", 8, 0)

		local function refresh() tick:SetShown(get() and true or false) end
		row:SetScript("OnClick", function()
			set(not get())
			refresh()
			if after then after() end
			relayout()
		end)
		row:SetScript("OnEnter", function() setBorder(box, T.value) end)
		row:SetScript("OnLeave", function() setBorder(box, T.border) end)
		checks[#checks + 1] = refresh
		refresh()
		s.y = s.y - 22
	end

	local function addSlider(s, text, minV, maxV, get, set)
		local holder = CreateFrame("Frame", nil, s.page)
		holder:SetSize(CONTENT_W, 38)
		holder:SetPoint("TOPLEFT", s.page, "TOPLEFT", 0, s.y)

		local lab = label(holder, text, 12)
		lab:SetPoint("TOPLEFT", holder, "TOPLEFT", 2, -1)
		local val = label(holder, "", 12, T.value)
		val:SetPoint("TOPRIGHT", holder, "TOPRIGHT", -2, -1)

		local track = newBox(holder, T.box, T.border)
		track:SetSize(TRACK_W, 8)
		track:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 2, 5)
		local trackFill = track:CreateTexture(nil, "ARTWORK")
		trackFill:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -1)
		trackFill:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", 1, 1)
		trackFill:SetColorTexture(T.value[1], T.value[2], T.value[3], 0.85)

		local thumb = newBox(holder, { 0.78, 0.78, 0.78, 1 }, T.border)
		thumb:SetSize(8, 16)
		thumb:SetFrameLevel(holder:GetFrameLevel() + 3)

		local dragging, last = false, nil

		local function position(frac)
			thumb:ClearAllPoints()
			thumb:SetPoint("CENTER", track, "LEFT", 4 + frac * (TRACK_W - 8), 0)
			trackFill:SetWidth(math.max(1, frac * (TRACK_W - 2)))
		end

		local function applyValue(v)
			v = clamp(math.floor(v + 0.5), minV, maxV)
			val:SetText(tostring(v))
			position((v - minV) / (maxV - minV))
			if v ~= last then
				last = v
				set(v)
				relayout()
			end
		end

		local function cursorValue()
			local cx = GetCursorPosition()
			local left = track:GetLeft()
			if not (cx and left) then return nil end
			cx = cx / holder:GetEffectiveScale()
			local frac = clamp((cx - left - 4) / (TRACK_W - 8), 0, 1)
			return minV + frac * (maxV - minV)
		end

		holder:EnableMouse(true)
		holder:SetScript("OnMouseDown", function(_, button)
			if button ~= "LeftButton" then return end
			dragging = true
			local v = cursorValue()
			if v then applyValue(v) end
		end)
		holder:SetScript("OnMouseUp", function() dragging = false end)
		holder:SetScript("OnUpdate", function()
			if not dragging then return end
			if not IsMouseButtonDown("LeftButton") then dragging = false return end
			local v = cursorValue()
			if v then applyValue(v) end
		end)
		holder:EnableMouseWheel(true)
		holder:SetScript("OnMouseWheel", function(_, delta)
			local step = (IsShiftKeyDown and IsShiftKeyDown()) and 10 or 1
			applyValue(get() + delta * step)
		end)

		local function refresh()
			local v = clamp(get() or minV, minV, maxV)
			last = v
			val:SetText(tostring(v))
			position((v - minV) / (maxV - minV))
		end
		sliders[#sliders + 1] = refresh
		refresh()
		s.y = s.y - 42
	end

	local function addChoice(s, text, opts, get, set)
		local holder = CreateFrame("Frame", nil, s.page)
		holder:SetSize(CONTENT_W, 24)
		holder:SetPoint("TOPLEFT", s.page, "TOPLEFT", 0, s.y)
		local lab = label(holder, text, 12)
		lab:SetPoint("LEFT", holder, "LEFT", 2, 0)

		local btns = {}
		local function refresh()
			local cur = get() and true or false
			for i, b in ipairs(btns) do
				local on = (cur == opts[i].value)
				setBorder(b, on and T.value or T.border)
				local c = on and T.value or T.dim
				b.text:SetTextColor(c[1], c[2], c[3], 1)
			end
		end
		for i, o in ipairs(opts) do
			local b = newBox(holder, T.box, T.border, "Button")
			b:SetSize(72, 20)
			b:SetPoint("RIGHT", holder, "RIGHT", -2 - (#opts - i) * 76, 0)
			b.text = label(b, o.text, 12)
			b.text:SetPoint("CENTER", 0, 0)
			b:SetScript("OnClick", function()
				set(o.value)
				refresh()
				relayout()
			end)
			btns[i] = b
		end
		choices[#choices + 1] = refresh
		refresh()
		s.y = s.y - 28
	end

	-- Options tab --------------------------------------------------
	local so = newStack(newPage("options"))
	addHeader(so, "Bar text")
	addCheck(so, "Completed & Rested (center)",
		function() return db.showBottomText end,
		function(v) db.showBottomText = v and true or false end)
	addCheck(so, "XP / Hour (left)",
		function() return db.showLevelingText end,
		function(v) db.showLevelingText = v and true or false end)
	addCheck(so, "Session Time (right)",
		function() return db.showSessionTimeText end,
		function(v) db.showSessionTimeText = v and true or false end)
	addCheck(so, "Time to Next Level (under bar)",
		function() return db.showTimeLeftText end,
		function(v) db.showTimeLeftText = v and true or false end)
	addHeader(so, "Bar")
	addCheck(so, "Show Quest XP Segment",
		function() return db.showQuestSegment end,
		function(v) db.showQuestSegment = v and true or false end)
	addCheck(so, "Show Rested Segment",
		function() return db.showRestedSegment end,
		function(v) db.showRestedSegment = v and true or false end)
	addCheck(so, "Show Bar at Max Level",
		function() return db.showBarAtMaxLevel end,
		function(v) db.showBarAtMaxLevel = v and true or false end)
	addCheck(so, "Hide Default Experience Bar",
		function() return db.hideDefaultXPBar end,
		function(v) db.hideDefaultXPBar = v and true or false end,
		function() applyHideDefaultXP() end)
	addCheck(so, "Lock Bar (no dragging)",
		function() return db.locked end,
		function(v) db.locked = v and true or false end)
	addCheck(so, "Auto Accept/Turn-in (Hold Shift to pause)",
		function() return db.autoQuest end,
		function(v) db.autoQuest = v and true or false end)
	addCheck(so, "Remind me to /reload after changes",
		function() return db.autoSaveOnClose end,
		function(v) db.autoSaveOnClose = v and true or false end)

	-- Adjust tab ---------------------------------------------------
	local sa = newStack(newPage("adjust"))
	addHeader(sa, "Adjust Bar")
	addSlider(sa, "Bar Width", 60, 600,
		function() return db.width end,
		function(v) db.width = v end)
	addSlider(sa, "Bar Height", 8, 60,
		function() return db.height end,
		function(v) db.height = v end)
	addHeader(sa, "Text")
	addSlider(sa, "Text Size", 8, 24,
		function() return db.fontSize end,
		function(v) db.fontSize = v end)
	addChoice(sa, "Text Style", {
		{ text = "Normal", value = false },
		{ text = "Bold", value = true },
	}, function() return db.fontBold end, function(v) db.fontBold = v end)
	local hint = label(sa.page, "Bold = thick outline. Mouse wheel on a slider = fine tune (Shift = x10).", 10, T.dim)
	hint:SetPoint("TOPLEFT", sa.page, "TOPLEFT", 2, sa.y - 4)
	hint:SetWidth(CONTENT_W - 4)
	hint:SetJustifyH("LEFT")

	-- Info tab -----------------------------------------------------
	local infoPage = newPage("info")
	local infoLines = {
		hex(T.value) .. "Slash commands|r",
		"/foreverxp menu | lock | unlock | reset",
		"/foreverxp quest | rested | text on/off",
		"/foreverxp leveling on/off   (XP per hour)",
		"/foreverxp session on/off",
		"/foreverxp timeleft on/off   (time to level)",
		"/foreverxp maxlevel | hideblizzard | autoquest on/off",
		"/foreverxp width <n> | height <n>",
		"/foreverxp fontsize <n> | bold on/off",
		"",
		hex(T.value) .. "Bar text|r",
		"LEFT: XP per hour     CENTER: Completed & Rested",
		"RIGHT: Session time (resets every login)",
		"UNDER BAR: estimated time to next level",
		"",
		hex(T.value) .. "Minimap button|r",
		"Left-click: settings    Right-click: lock/unlock",
		"Drag: move the button",
	}
	for i, line in ipairs(infoLines) do
		local fs = label(infoPage, line, 11)
		fs:SetPoint("TOPLEFT", infoPage, "TOPLEFT", 2, -2 - (i - 1) * 14)
		fs:SetJustifyH("LEFT")
	end

	function panel:Refresh()
		for _, f in ipairs(checks) do f() end
		for _, f in ipairs(sliders) do f() end
		for _, f in ipairs(choices) do f() end
	end

	switchTab("options")

	-- Closing the panel (X button, ESC or /foreverxp) after a change saves.
	local openSnapshot
	panel:HookScript("OnShow", function() openSnapshot = settingsSnapshot() end)
	panel:HookScript("OnHide", function()
		local before = openSnapshot
		openSnapshot = nil
		if not before or not db.autoSaveOnClose then return end
		if not deepEqual(before, settingsSnapshot()) then saveNow() end
	end)
	panel:Hide()
end

toggleOptions = function()
	if not optionsPanel then buildOptions() end
	if optionsPanel:IsShown() then
		optionsPanel:Hide()
	else
		optionsPanel:Refresh()
		optionsPanel.SwitchTab("options")
		optionsPanel:Show()
	end
end

local function refreshOptions()
	if optionsPanel then optionsPanel:Refresh() end
end

--------------------------------------------------------------------
-- 13. Events (every registration guarded - an unknown event throws)
--------------------------------------------------------------------

local watcher = CreateFrame("Frame")
local EVENTS = {
	"ADDON_LOADED", "PLAYER_LOGOUT",
	"PLAYER_ENTERING_WORLD", "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP",
	"UPDATE_EXHAUSTION", "QUEST_LOG_UPDATE", "QUEST_TURNED_IN",
	"ENABLE_XP_GAIN", "DISABLE_XP_GAIN", "TIME_PLAYED_MSG",
}
for _, e in ipairs(EVENTS) do
	pcall(watcher.RegisterEvent, watcher, e)
end

watcher:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON_NAME then return end
		watcher:UnregisterEvent("ADDON_LOADED")
		initDB()
		minimapBtnUpdatePosition()
		relayout()
		return
	end

	if event == "PLAYER_LOGOUT" then
		-- The file the game writes now must contain OUR live table, in both
		-- saved files.
		if dbReady then
			_G.ForeverXPDB = db
			mirrorToBackup()
			cvarWrite()
			macroWrite()
		end
		return
	end

	if not dbReady then return end
	syncSavedVars()

	if event == "TIME_PLAYED_MSG" then
		onPlayed(arg1, arg2)
		update()
		return
	end

	if event == "PLAYER_ENTERING_WORLD" then
		worldEntered = true
		-- arg1 = isInitialLogin, arg2 = isReloadingUi. Zoning fires this
		-- event too (both false), so only a real login resets the session.
		local now = time()
		local fresh = (arg1 == true)
			or (arg1 == nil and arg2 == nil and (not db.lastSeen or now - db.lastSeen > 60))
		if fresh or not db.sessionStart then db.sessionStart = now end
		db.lastSeen = now
		ensureTrack()
		if arg1 or arg2 or playedStamp == 0 then
			if C_Timer and C_Timer.After then
				C_Timer.After(2, function() requestPlayed(2) end)
			else
				requestPlayed(0)
			end
		end
		if (arg1 or arg2) and C_Timer and C_Timer.After then
			C_Timer.After(6, function()
				local bk = rawget(_G, "ForeverXPCharDB")
				printMsg(string.format(
					"settings check: game gave saved table=%s (type %s) | backup copy=%s | cvar=%s | macro=%s | width=%s height=%s size=%s",
					tostring(everAdopted), type(_G.ForeverXPDB), type(bk) == "table" and "yes" or "no",
					cvarStatus, macroStatus, tostring(db.width), tostring(db.height), tostring(db.fontSize)))
			end)
		end
		if C_Timer and C_Timer.After then
			C_Timer.After(1, applyHideDefaultXP)
		else
			applyHideDefaultXP()
		end
	elseif event == "PLAYER_LEVEL_UP" then
		ensureTrack()
		if C_Timer and C_Timer.After then
			C_Timer.After(2, function() requestPlayed(1) end)
		end
		applyHideDefaultXP()
	end
	update()
end)

-- 1s ticker: counts time on the level, keeps time-based text fresh and
-- catches quest-log changes that fire no dedicated event on some clients.
if C_Timer and C_Timer.NewTicker then
	local tickCount = 0
	C_Timer.NewTicker(1, function()
		syncSavedVars()
		tickCount = tickCount + 1
		-- start mirroring only after the game has had ample time to hand us
		-- the saved table, so a stale default copy never overwrites the backup
		if tickCount >= 20 and tickCount % 10 == 0 then mirrorToBackup() end
		cvarWrite()
		if macroLoad() then needRefresh = true end
		macroWrite()
		if tickCount == 45 and rawget(_G, "ForeverXPDB") == nil then
			_G.ForeverXPDB = db -- late fallback: game never gave us a table
		end
		if needRefresh then
			needRefresh = false
			relayout()
			applyHideDefaultXP()
			refreshOptions()
		end
		tickTrack()
		update()
	end)
end

--------------------------------------------------------------------
-- 14. Slash commands
--------------------------------------------------------------------

SLASH_FOREVERXP1 = "/foreverxp"
SlashCmdList["FOREVERXP"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, arg = msg:match("^(%S*)%s*(.-)$")
	local on = (arg ~= "off")

	if cmd == "" or cmd == "menu" or cmd == "options" then
		toggleOptions()
	elseif cmd == "lock" then
		db.locked = true
		refreshOptions()
		printMsg("locked.")
	elseif cmd == "unlock" then
		db.locked = false
		refreshOptions()
		printMsg("unlocked - drag to move.")
	elseif cmd == "quest" then
		db.showQuestSegment = on
		relayout(); refreshOptions()
		printMsg("quest segment " .. (on and "on" or "off"))
	elseif cmd == "rested" then
		db.showRestedSegment = on
		relayout(); refreshOptions()
		printMsg("rested segment " .. (on and "on" or "off"))
	elseif cmd == "text" then
		db.showBottomText = on
		relayout(); refreshOptions()
		printMsg("center text " .. (on and "on" or "off"))
	elseif cmd == "session" then
		db.showSessionTimeText = on
		relayout(); refreshOptions()
		printMsg("session time text " .. (on and "on" or "off"))
	elseif cmd == "leveling" then
		db.showLevelingText = on
		relayout(); refreshOptions()
		printMsg("XP/hour text " .. (on and "on" or "off"))
	elseif cmd == "timeleft" then
		db.showTimeLeftText = on
		relayout(); refreshOptions()
		printMsg("time-to-level text " .. (on and "on" or "off"))
	elseif cmd == "maxlevel" then
		db.showBarAtMaxLevel = on
		relayout(); refreshOptions()
		printMsg("show at max level " .. (on and "on" or "off"))
	elseif cmd == "hideblizzard" then
		db.hideDefaultXPBar = on
		applyHideDefaultXP()
		relayout(); refreshOptions()
		printMsg("hide default XP bar " .. (on and "on" or "off"))
	elseif cmd == "autoquest" then
		db.autoQuest = on
		relayout(); refreshOptions()
		printMsg("auto quest " .. (on and "on" or "off"))
	elseif cmd == "save" then
		saveNow()
	elseif cmd == "autosave" then
		db.autoSaveOnClose = on
		refreshOptions()
		printMsg("reload reminder after changes " .. (on and "on" or "off"))
	elseif cmd == "bold" then
		db.fontBold = on
		relayout(); refreshOptions()
		printMsg("bold text " .. (on and "on" or "off"))
	elseif cmd == "fontsize" and tonumber(arg) then
		db.fontSize = clamp(math.floor(tonumber(arg) + 0.5), 8, 24)
		relayout(); refreshOptions()
		printMsg("text size set to " .. db.fontSize)
	elseif cmd == "width" and tonumber(arg) then
		db.width = clamp(math.floor(tonumber(arg) + 0.5), 60, 600)
		relayout(); refreshOptions()
		printMsg("width set to " .. db.width)
	elseif cmd == "height" and tonumber(arg) then
		db.height = clamp(math.floor(tonumber(arg) + 0.5), 8, 60)
		relayout(); refreshOptions()
		printMsg("height set to " .. db.height)
	elseif cmd == "reset" then
		db.point, db.relPoint, db.x, db.y = defaults.point, defaults.relPoint, defaults.x, defaults.y
		db.width, db.height = defaults.width, defaults.height
		relayout(); refreshOptions()
		printMsg("position and size reset.")
	else
		printMsg("commands: menu | lock | unlock | quest | rested | text | leveling | session | timeleft | maxlevel | hideblizzard | autoquest (on/off) | bold (on/off) | fontsize <n> | width <n> | height <n> | reset")
	end
end

--------------------------------------------------------------------
-- 15. Auto Quest Feature
--------------------------------------------------------------------

local questWatcher = CreateFrame("Frame")
questWatcher:RegisterEvent("QUEST_GREETING")
questWatcher:RegisterEvent("GOSSIP_SHOW")
questWatcher:RegisterEvent("QUEST_DETAIL")
questWatcher:RegisterEvent("QUEST_ACCEPT_CONFIRM")
questWatcher:RegisterEvent("QUEST_PROGRESS")
questWatcher:RegisterEvent("QUEST_COMPLETE")

questWatcher:SetScript("OnEvent", function(_, event)
	if not dbReady or not db.autoQuest then return end
	if IsShiftKeyDown() then return end -- Pause automation if shift is held down

	if event == "QUEST_GREETING" then
		if GetNumActiveQuests then
			for i = 1, GetNumActiveQuests() do SelectActiveQuest(i) end
		end
		if GetNumAvailableQuests then
			for i = 1, GetNumAvailableQuests() do SelectAvailableQuest(i) end
		end
	elseif event == "GOSSIP_SHOW" then
		if C_GossipInfo and C_GossipInfo.GetActiveQuests then
			for _, q in ipairs(C_GossipInfo.GetActiveQuests() or {}) do
				if q.isComplete then C_GossipInfo.SelectActiveQuest(q.questID) end
			end
			for _, q in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
				if not q.isTrivial then C_GossipInfo.SelectAvailableQuest(q.questID) end
			end
		else
			if GetNumGossipActiveQuests then
				for i = 1, GetNumGossipActiveQuests() do SelectGossipActiveQuest(i) end
			end
			if GetNumGossipAvailableQuests then
				for i = 1, GetNumGossipAvailableQuests() do SelectGossipAvailableQuest(i) end
			end
		end
	elseif event == "QUEST_DETAIL" then
		if AcceptQuest then 
			AcceptQuest() 
			if HideUIPanel then HideUIPanel(QuestFrame) end
		end
	elseif event == "QUEST_ACCEPT_CONFIRM" then
		if ConfirmAcceptQuest then
			ConfirmAcceptQuest()
			if StaticPopup_Hide then StaticPopup_Hide("QUEST_ACCEPT") end
		end
	elseif event == "QUEST_PROGRESS" then
		if IsQuestCompletable and IsQuestCompletable() then
			if CompleteQuest then CompleteQuest() end
		end
	elseif event == "QUEST_COMPLETE" then
		if GetNumQuestChoices and GetNumQuestChoices() <= 1 then
			if GetQuestReward then GetQuestReward(1) end
		end
	end
end)

-- first paint with the placeholder DB; ADDON_LOADED repaints with the real one
relayout()