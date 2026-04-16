local ADDON_NAME = ...
local PREFIX = "ARENASTICKY1"

ArenaSticky = ArenaSticky or {}
ArenaSticky.frame = CreateFrame("Frame")
ArenaSticky.enemyClasses = {}
ArenaSticky.currentCompKey = nil
ArenaSticky.specByGuid = ArenaSticky.specByGuid or {}
ArenaSticky.guidToUnit = ArenaSticky.guidToUnit or {}

local ROLE_TOKENS = {
    "WARRIOR", "HUNTER", "ROGUE", "MAGE", "WARLOCK",
    "RET", "HPAL",
    "RSHAM", "ELE", "ENH",
    "DISC", "SHADOW",
    "RESTO", "BOOMY", "FERAL",
    -- Legacy/base tokens
    "PALADIN", "SHAMAN", "PRIEST", "DRUID",
}

local DEFAULT_SPEC_TOKEN = {
    DRUID = "RESTO",
    SHAMAN = "RSHAM",
    PRIEST = "DISC",
    PALADIN = "HPAL",
}

local AURA_SPEC_TOKEN = {
    ["Shadowform"] = "SHADOW",
    ["Vampiric Embrace"] = "SHADOW",
    ["Tree of Life"] = "RESTO",
    ["Moonkin Form"] = "BOOMY",
    ["Earth Shield"] = "RSHAM",
    ["Crusader Strike"] = "RET", -- debuff name in some builds; harmless if absent
}

local SPELL_SPEC_TOKEN = {
    ["Shadowform"] = "SHADOW",
    ["Vampiric Touch"] = "SHADOW",
    ["Tree of Life"] = "RESTO",
    ["Moonkin Form"] = "BOOMY",
    ["Earth Shield"] = "RSHAM",
    ["Elemental Mastery"] = "ELE",
    ["Stormstrike"] = "ENH",
    ["Shamanistic Rage"] = "ENH",
    ["Crusader Strike"] = "RET",
    ["Divine Storm"] = "RET",
    ["Holy Shock"] = "HPAL",
}

local COMP_ALIASES = {
    rmp = "DISC-MAGE-ROGUE",
}

local function DeepCopy(tbl)
    if type(tbl) ~= "table" then return tbl end
    local copy = {}
    for k, v in pairs(tbl) do
        copy[k] = DeepCopy(v)
    end
    return copy
end

local function NormalizeCompKey(classes)
    table.sort(classes)
    return table.concat(classes, "-")
end

local function MergeMissingStrategies(dest, src)
    if not src then return dest end
    dest = dest or {}
    for key, strat in pairs(src) do
        if dest[key] == nil then
            dest[key] = DeepCopy(strat)
        end
    end
    return dest
end

local function ToLegacyClassToken(token)
    if token == "RET" or token == "HPAL" then return "PALADIN" end
    if token == "RSHAM" or token == "ELE" or token == "ENH" then return "SHAMAN" end
    if token == "DISC" or token == "SHADOW" then return "PRIEST" end
    if token == "RESTO" or token == "BOOMY" or token == "FERAL" then return "DRUID" end
    return token
end

local function ToLegacyCompKey(compKey)
    if not compKey or compKey == "" then return compKey end
    local parts = {}
    for p in compKey:gmatch("[^-]+") do
        table.insert(parts, ToLegacyClassToken(p))
    end
    return NormalizeCompKey(parts)
end

local function FromLegacyClassToken(token)
    token = token and token:upper() or token
    if token == "DRUID" then return "RESTO" end
    if token == "SHAMAN" then return "RSHAM" end
    if token == "PRIEST" then return "DISC" end
    if token == "PALADIN" then return "HPAL" end
    return token
end

local function FromLegacyCompKey(compKey)
    if not compKey or compKey == "" then return compKey end
    local parts = {}
    for p in compKey:gmatch("[^-]+") do
        table.insert(parts, FromLegacyClassToken(p))
    end
    return NormalizeCompKey(parts)
end

local function ResolveTestAlias(arg)
    if not arg or arg == "" then return nil, arg end
    local clean = arg:lower():gsub("%s+", "")
    if clean:find("-", 1, true) then
        local parts = {}
        for p in clean:gmatch("[^-]+") do
            table.insert(parts, p:upper())
        end
        if #parts >= 2 then
            local key = NormalizeCompKey(parts)
            return FromLegacyCompKey(key), clean
        end
    end
    local key = COMP_ALIASES[clean]
    if key then return key, clean end
    return nil, clean
end

local DEFAULT_STRATEGIES = {
    -- 3v3: RMP (you) vs common TBC comps
    ["RESTO-WARLOCK-WARRIOR"] = {
        header = { kill = "Warlock", cc = "Resto Druid" },
        roles = {
            DISC = "Max pillar. Dispel fear only. Trinket real cross, then reset/drink.",
            ROGUE = "Open lock. Kidney only on druid CC. Missed go = full reset.",
            MAGE = "Sheep druid on go. Peel warrior. CS fear/heals on setup.",
        },
    },
    ["DISC-MAGE-ROGUE"] = {
        header = { kill = "Mage or Disc", cc = "whoever is not kill target" },
        roles = {
            DISC = "No early trinket overlap. Fear off sheep. PI only real goes.",
            ROGUE = "Sap disc if free. Stop their opener. Save vanish for re-go.",
            MAGE = "Win poly race. Counter-go only on full disc CC. Peel after.",
        },
    },
    ["DISC-HUNTER-ROGUE"] = {
        header = { kill = "Hunter", cc = "Disc" },
        roles = {
            DISC = "Avoid sap-trap line. Trinket kill setups only. Dispel trap smart.",
            ROGUE = "Control rogue first, then go hunter with disc CC.",
            MAGE = "Peel first. Poly disc on go. Burst only if hunter is stuck.",
        },
    },
    ["RESTO-ROGUE-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Resto Druid" },
        roles = {
            DISC = "Respect rogue swap. Dispel coil/fear only. If rogue resets, drink.",
            ROGUE = "Open lock. Kidney on druid CC. Blind druid after trinket.",
            MAGE = "Sheep druid. Peel rogue. CS lock on kill go.",
        },
    },
    ["RSHAM-ROGUE-WARLOCK"] = {
        header = { kill = "Warlock", cc = "RSham" },
        roles = {
            DISC = "Pre-shield purge swap. Fear shaman on go. Conserve mana.",
            ROGUE = "Open lock. Kick fear/heals. Blind shaman on trinket.",
            MAGE = "Sheep shaman on go. Peel rogue. CS lock on setup.",
        },
    },
    ["RSHAM-SHADOW-WARLOCK"] = {
        header = { kill = "Warlock", cc = "RSham" },
        roles = {
            DISC = "Respect rot. Drink fast. Dispel VT/fear only when needed.",
            ROGUE = "Go lock. Kick fear. Kidney on shaman CC. Reset often.",
            MAGE = "Sheep shaman on go. CS lock. Peel shadow between goes.",
        },
    },
    ["RSHAM-WARLOCK-WARRIOR"] = {
        header = { kill = "Warlock", cc = "RSham" },
        roles = {
            DISC = "Live first bridge. Trinket lethal overlap only. Fear shaman on go.",
            ROGUE = "Open lock. Force CDs early. Reset if warrior gets free uptime.",
            MAGE = "Sheep shaman on go. Peel warrior all game. CS fear/heals.",
        },
    },
    ["ELE-RESTO-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Resto Druid/Shaman" },
        roles = {
            DISC = "Never play open. Fear healer on go. Dispel key CC only.",
            ROGUE = "Open lock. Short goes. Swap ele only if overextended.",
            MAGE = "Peel and line first. CS lock/healer on go. Keep ele slowed.",
        },
    },
    ["DISC-RESTO-WARRIOR"] = {
        header = { kill = "Warrior", cc = "Disc" },
        roles = {
            DISC = "Live warrior go. Fear disc on setup. Save trinket for real swap.",
            ROGUE = "Go warrior. Kidney on disc CC. Reset if warrior sticks.",
            MAGE = "Peel warrior. Poly disc on go. Slow all game.",
        },
    },
    ["DISC-RESTO-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Disc" },
        roles = {
            DISC = "Line dots. Fear disc on go. Dispel fear/dots only when needed.",
            ROGUE = "Go lock. Kick fear. Kidney on disc CC. Reset after go.",
            MAGE = "Poly disc on go. CS lock. Line dots between goes.",
        },
    },
    ["DISC-ROGUE-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Disc" },
        roles = {
            DISC = "Respect rogue swap. Fear disc on go. Dispel fear smart.",
            ROGUE = "Open lock. Stop rogue first if needed. Blind disc on trinket.",
            MAGE = "Peel rogue. Poly disc on go. CS lock on setup.",
        },
    },
    ["RET-RSHAM-WARRIOR"] = {
        header = { kill = "Warrior", cc = "RSham" },
        roles = {
            DISC = "Respect burst. Fear sham on go. Trinket only real overlap.",
            ROGUE = "Go warrior. Kidney on sham CC. Reset after cooldowns.",
            MAGE = "Peel warrior/ret. Sheep sham on go. Keep warrior slowed.",
        },
    },
    ["MAGE-RESTO-WARRIOR"] = {
        header = { kill = "Mage", cc = "Resto Druid" },
        roles = {
            DISC = "Do not overtrade on mage go. Fear druid on setup.",
            ROGUE = "Open mage often. Kidney on druid CC. Peel warrior after.",
            MAGE = "Win poly race. Sheep druid on go. Slow warrior all game.",
        },
    },
    ["ENH-HPAL-WARRIOR"] = {
        header = { kill = "Warrior", cc = "HPal" },
        roles = {
            DISC = "Respect double melee burst. Fear pal on go. Save trinket.",
            ROGUE = "Go warrior. Kidney on pal CC. Reset after wall/freedom.",
            MAGE = "Peel both melee. Poly pal on go. Root warrior often.",
        },
    },
    ["ENH-RESTO-WARRIOR"] = {
        header = { kill = "Warrior", cc = "Resto Druid" },
        roles = {
            DISC = "Play pillar. Fear druid on go. Trinket enh+warrior overlap.",
            ROGUE = "Go warrior. Kidney on druid CC. Reset if train is free.",
            MAGE = "Peel enh/warrior. Sheep druid on go. Slow both melee.",
        },
    },
    ["ENH-RSHAM-WARRIOR"] = {
        header = { kill = "Warrior", cc = "RSham" },
        roles = {
            DISC = "Respect purge burst. Fear sham on go. Save trinket for kill.",
            ROGUE = "Go warrior. Kidney on sham CC. Reset after burst.",
            MAGE = "Peel both melee. Sheep sham on go. Keep warrior slowed.",
        },
    },

    -- 2v2: Disc/Mage, Rogue/Mage, Disc/Rogue vs common TBC comps
    ["DISC-ROGUE"] = {
        header = { kill = "Disc or Rogue" , cc = "off-target" },
        roles = {
            DISC = "Live opener. Fear off rogue control. Reset early if needed.",
            ROGUE = "Disc if free, rogue if not. Force CDs fast. Save vanish.",
            MAGE = "Peel rogue first. Burst only on disc control.",
        },
    },
    ["DISC-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Disc" },
        roles = {
            DISC = "Dispel key dots/fears only. Stay active; don’t rot.",
            ROGUE = "Go lock. Kick fear. Force disc trinket, then blind.",
            MAGE = "Sheep disc on go. Line dots. CS lock when exposed.",
        },
    },
    ["HPAL-WARRIOR"] = {
        header = { kill = "Warrior", cc = "HPal" },
        roles = {
            DISC = "Do not panic trinket. Fear pal on go. Make warrior overextend.",
            ROGUE = "Control warrior first. Kidney on pal CC. Reset often.",
            MAGE = "Perma-slow warrior. Poly pal on go. Drink if fully kited.",
        },
    },
    ["RESTO-WARRIOR"] = {
        header = { kill = "Warrior", cc = "Resto Druid" },
        roles = {
            DISC = "Don’t get dragged. Fear druid on real go. Save trinket for bash.",
            ROGUE = "Kidney warrior on druid CC. Reset often. Don’t chase druid.",
            MAGE = "Perma-slow warrior. Sheep druid only when ready to go.",
        },
    },
    ["RSHAM-WARRIOR"] = {
        header = { kill = "Warrior", cc = "RSham" },
        roles = {
            DISC = "Mana matters. Fear shaman on go. Watch warrior swap.",
            ROGUE = "Usually go warrior. Kidney on shaman CC. Reset if trained.",
            MAGE = "Peel warrior forever. Sheep shaman on go. CS heals/reconnect.",
        },
    },
    ["DISC-HUNTER"] = {
        header = { kill = "Hunter", cc = "Disc" },
        roles = {
            DISC = "Respect trap. Trinket kill chain only. Fear disc on go.",
            ROGUE = "Stick hunter. Step-kick/blind disc. Reset if hunter kites free.",
            MAGE = "Pin hunter. Control disc every go. Slow/nova matter.",
        },
    },
    ["MAGE-ROGUE"] = {
        header = { kill = "Mage or Rogue", cc = "off-target" },
        roles = {
            DISC = "Live opener. Trinket lethal only. Dispel + fear to break reset.",
            ROGUE = "Opener decides game. Control rogue first unless mage is free.",
            MAGE = "Live first. Win CC war. CS real go. Block early if needed.",
        },
    },
    ["RESTO-ROGUE"] = {
        header = { kill = "Rogue", cc = "Resto Druid" },
        roles = {
            DISC = "Live opener. Fear druid after. Save CDs for rogue all-in.",
            ROGUE = "Go rogue. Control druid after trinket. Don’t chase druid.",
            MAGE = "Peel rogue always. Only hit druid on real go windows.",
        },
    },
}

local function EnsureDB()
    ArenaStickyDB = ArenaStickyDB or {}
    ArenaStickyDB.version = ArenaStickyDB.version or 1
    ArenaStickyDB.lastUpdated = ArenaStickyDB.lastUpdated or time()
    ArenaStickyDB.playerRoleOverride = ArenaStickyDB.playerRoleOverride or nil
    ArenaStickyDB.window = ArenaStickyDB.window or {
        x = 0,
        y = 0,
        width = 320,
        height = 200,
        scale = 1.0,
        alpha = 0.95,
    }

    -- Shared strategy pack (editable + synced)
    ArenaStickyDB.strategies = MergeMissingStrategies(ArenaStickyDB.strategies, DEFAULT_STRATEGIES)
end

local function GetMyRole()
    if ArenaStickyDB and ArenaStickyDB.playerRoleOverride then
        return ArenaStickyDB.playerRoleOverride
    end
    local _, class = UnitClass("player")
    if not class then return nil end

    if GetTalentTabInfo then
        local bestTab, bestPoints = nil, -1
        for i = 1, 3 do
            local _, _, points = GetTalentTabInfo(i)
            if (points or 0) > bestPoints then
                bestPoints = points or 0
                bestTab = i
            end
        end

        if class == "PRIEST" then
            if bestTab == 3 then return "SHADOW" end
            return "DISC"
        elseif class == "DRUID" then
            if bestTab == 1 then return "BOOMY" end
            if bestTab == 2 then return "FERAL" end
            return "RESTO"
        elseif class == "SHAMAN" then
            if bestTab == 1 then return "ELE" end
            if bestTab == 2 then return "ENH" end
            return "RSHAM"
        elseif class == "PALADIN" then
            if bestTab == 3 then return "RET" end
            return "HPAL"
        end
    end

    -- Fallback to class token
    return class
end

local function DetectSpecFromAuras(unit)
    if not UnitExists(unit) then return nil end
    for i = 1, 40 do
        local name = UnitBuff(unit, i)
        if not name then break end
        local token = AURA_SPEC_TOKEN[name]
        if token then return token end
    end
    return nil
end

local function GetEnemyToken(unit)
    local _, class = UnitClass(unit)
    if not class then return nil end
    local guid = UnitGUID(unit)
    if guid and ArenaSticky.specByGuid[guid] then
        return ArenaSticky.specByGuid[guid]
    end
    local auraToken = DetectSpecFromAuras(unit)
    if guid and auraToken then
        ArenaSticky.specByGuid[guid] = auraToken
        return auraToken
    end
    return DEFAULT_SPEC_TOKEN[class] or class
end

local function CreateMainFrame()
    if ArenaSticky.mainFrame then return end

    local f = CreateFrame("Frame", "ArenaStickyMainFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    f:SetSize(320, 200)
    f:SetPoint("CENTER")
    if f.SetClampedToScreen then
        f:SetClampedToScreen(true)
    end
    f:SetMovable(true)
    if f.SetResizable then
        f:SetResizable(true)
    end
    if f.SetMinResize then
        f:SetMinResize(260, 140)
    end
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint()
        ArenaStickyDB.window.x = x
        ArenaStickyDB.window.y = y
        ArenaStickyDB.window.width = self:GetWidth()
        ArenaStickyDB.window.height = self:GetHeight()
    end)
    f:SetScript("OnSizeChanged", function(self, width, height)
        width = math.max(width or 320, 260)
        height = math.max(height or 200, 140)
        ArenaStickyDB.window.width = width
        ArenaStickyDB.window.height = height
        if ArenaSticky.headerText then
            ArenaSticky.headerText:SetWidth(width - 25)
        end
        if ArenaSticky.bodyText then
            ArenaSticky.bodyText:SetWidth(width - 25)
        end
    end)

    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Arena Sticky")

    local header = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", 12, -36)
    header:SetJustifyH("LEFT")
    header:SetWidth(295)
    header:SetText("Kill: ?  |  CC: ?")

    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", 12, -62)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetWidth(295)
    body:SetText("Waiting for arena comp...")
    body:SetNonSpaceWrap(true)

    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", 12, 8)
    footer:SetText("Type /as edit to modify. Drag bottom-right to resize.")

    local resize = nil
    if f.StartSizing and f.StopMovingOrSizing then
        resize = CreateFrame("Button", nil, f)
        resize:SetPoint("BOTTOMRIGHT", -6, 6)
        resize:SetSize(16, 16)
        resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
        resize:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
        resize:SetScript("OnMouseDown", function()
            f:StartSizing("BOTTOMRIGHT")
        end)
        resize:SetScript("OnMouseUp", function()
            f:StopMovingOrSizing()
            ArenaStickyDB.window.width = f:GetWidth()
            ArenaStickyDB.window.height = f:GetHeight()
        end)
    else
        footer:SetText("Type /as edit to modify.")
    end

    ArenaSticky.mainFrame = f
    ArenaSticky.titleText = title
    ArenaSticky.headerText = header
    ArenaSticky.bodyText = body
    ArenaSticky.footerText = footer
    ArenaSticky.resizeHandle = resize
end

local function ApplyWindowSettings()
    if not ArenaSticky.mainFrame then return end
    local cfg = ArenaStickyDB.window
    ArenaSticky.mainFrame:SetScale(cfg.scale or 1.0)
    ArenaSticky.mainFrame:SetAlpha(cfg.alpha or 0.95)
    ArenaSticky.mainFrame:SetSize(cfg.width or 320, cfg.height or 200)
    ArenaSticky.mainFrame:ClearAllPoints()
    ArenaSticky.mainFrame:SetPoint("CENTER", UIParent, "CENTER", cfg.x or 0, cfg.y or 0)
end

local function ParseEnemyCompFromArenaUnits()
    wipe(ArenaSticky.enemyClasses)
    for i = 1, 3 do
        local unit = "arena" .. i
        if UnitExists(unit) then
            local token = GetEnemyToken(unit)
            if token then
                table.insert(ArenaSticky.enemyClasses, token)
            end
        end
    end
    local expectedSize = GetNumArenaOpponents and GetNumArenaOpponents() or 0
    if expectedSize and expectedSize >= 2 then
        if #ArenaSticky.enemyClasses == expectedSize then
            return NormalizeCompKey(ArenaSticky.enemyClasses)
        end
    elseif #ArenaSticky.enemyClasses >= 2 then
        return NormalizeCompKey(ArenaSticky.enemyClasses)
    end
    return nil
end

local function GetFallbackRoleAndText(strat)
    if not strat or not strat.roles then return nil, nil end
    for _, token in ipairs(ROLE_TOKENS) do
        local text = strat.roles[token]
        if text and text ~= "" then
            return token, text
        end
    end
    for token, text in pairs(strat.roles) do
        if text and text ~= "" then
            return token, text
        end
    end
    return nil, nil
end

local function UpdateNotesForComp(compKey, allowFallbackRole, forcedRole)
    ArenaSticky.currentCompKey = compKey
    local role = forcedRole or GetMyRole()

    local strat = ArenaStickyDB.strategies[compKey]
    if not strat then
        local legacyKey = ToLegacyCompKey(compKey)
        if legacyKey and legacyKey ~= compKey then
            strat = ArenaStickyDB.strategies[legacyKey]
            if strat then
                compKey = legacyKey
            end
        end
    end
    if not strat then
        ArenaSticky.headerText:SetText("Kill: TBD  |  CC: TBD")
        ArenaSticky.bodyText:SetText("No strategy saved for: " .. compKey .. "\nUse /as edit to add one.")
        return
    end

    local kill = (strat.header and strat.header.kill) or "TBD"
    local cc = (strat.header and strat.header.cc) or "TBD"
    local roleText = role and strat.roles and strat.roles[role]
    if (not roleText or roleText == "") and allowFallbackRole then
        local fallbackRole, fallbackText = GetFallbackRoleAndText(strat)
        if fallbackText then
            role = fallbackRole
            roleText = ("[%s] %s"):format(fallbackRole, fallbackText)
        end
    end
    if not roleText and not role then
        roleText = "Unsupported class for role notes."
    end
    roleText = roleText or "No note saved for your class in this comp."

    ArenaSticky.headerText:SetText(("Kill: %s  |  CC: %s"):format(kill, cc))
    ArenaSticky.bodyText:SetText(roleText)
end

function ArenaSticky:BroadcastStrategies()
    if not C_ChatInfo then return end
    local payloadTable = {
        version = ArenaStickyDB.version,
        lastUpdated = ArenaStickyDB.lastUpdated,
        strategies = ArenaStickyDB.strategies,
    }
    local payload = "FULLSYNC|" .. C_Serialization and "" or ""
    -- Fallback lightweight serializer:
    payload = "FULLSYNC#" .. ArenaStickyDB.version .. "#" .. ArenaStickyDB.lastUpdated

    -- Send a lightweight ping; receiver can request full sync via whisper/party message.
    C_ChatInfo.SendAddonMessage(PREFIX, payload, IsInGroup(2) and "INSTANCE_CHAT" or (IsInRaid() and "RAID" or "PARTY"))
end

local function SerializeStrategiesSimple()
    -- Stable custom format:
    -- comp~kill~cc~<ROLE_TOKENS...> ; ...
    -- (Values are escaped for "~" and ";" using backticks.)
    local function esc(s)
        s = s or ""
        s = s:gsub("`", "``")
        s = s:gsub("~", "`t")
        s = s:gsub(";", "`s")
        return s
    end
    local parts = {}
    for comp, data in pairs(ArenaStickyDB.strategies) do
        local h = data.header or {}
        local r = data.roles or {}
        local segParts = { esc(comp), esc(h.kill), esc(h.cc) }
        for _, token in ipairs(ROLE_TOKENS) do
            table.insert(segParts, esc(r[token]))
        end
        local seg = table.concat(segParts, "~")
        table.insert(parts, seg)
    end
    return table.concat(parts, ";")
end

local function DeserializeStrategiesSimple(str)
    local function unesc(s)
        s = s or ""
        s = s:gsub("``", "`0")
        s = s:gsub("`t", "~")
        s = s:gsub("`s", ";")
        s = s:gsub("`0", "`")
        return s
    end
    local out = {}
    for seg in string.gmatch(str or "", "([^;]+)") do
        local fields = { strsplit("~", seg) }
        local a = fields[1]
        local b = fields[2]
        local c = fields[3]
        if a and a ~= "" then
            local roles = {}
            for i, token in ipairs(ROLE_TOKENS) do
                roles[token] = unesc(fields[3 + i])
            end
            local compKey = unesc(a)
            out[compKey] = {
                header = { kill = unesc(b), cc = unesc(c) },
                roles = roles,
            }
        end
    end
    return out
end

function ArenaSticky:PushFullSync()
    if not C_ChatInfo then return end
    local blob = SerializeStrategiesSimple()
    local msg = ("STRATSYNC#%d#%d#%s"):format(ArenaStickyDB.version, ArenaStickyDB.lastUpdated, blob)
    C_ChatInfo.SendAddonMessage(PREFIX, msg, IsInGroup(2) and "INSTANCE_CHAT" or (IsInRaid() and "RAID" or "PARTY"))
end

local function HandleAddonMessage(prefix, msg, channel, sender)
    if prefix ~= PREFIX or sender == UnitName("player") then return end
    if not msg then return end

    local cmd, v, ts, blob = strsplit("#", msg, 4)
    if cmd == "STRATSYNC" and v and ts and blob then
        local incomingVersion = tonumber(v) or 0
        local incomingTs = tonumber(ts) or 0
        local currentVersion = ArenaStickyDB.version or 0
        local currentTs = ArenaStickyDB.lastUpdated or 0

        if incomingVersion > currentVersion or (incomingVersion == currentVersion and incomingTs > currentTs) then
            ArenaStickyDB.strategies = DeserializeStrategiesSimple(blob)
            ArenaStickyDB.version = incomingVersion
            ArenaStickyDB.lastUpdated = incomingTs
            print("|cff33ff99ArenaSticky|r: Received updated strategies from " .. sender)

            if ArenaSticky.currentCompKey then
                UpdateNotesForComp(ArenaSticky.currentCompKey)
            end
        end
    elseif cmd == "FULLSYNC" then
        -- A teammate pinged for data, push ours.
        ArenaSticky:PushFullSync()
    end
end

local function TryDetectAndUpdate()
    local comp = ParseEnemyCompFromArenaUnits()
    if comp then
        UpdateNotesForComp(comp)
    end
end

local function RebuildGuidUnitMap()
    wipe(ArenaSticky.guidToUnit)
    for i = 1, 3 do
        local unit = "arena" .. i
        if UnitExists(unit) then
            local guid = UnitGUID(unit)
            if guid then
                ArenaSticky.guidToUnit[guid] = unit
            end
        end
    end
end

local function HandleCombatLog()
    local _, subevent, _, sourceGUID, _, _, _, _, _, _, _, spellName = CombatLogGetCurrentEventInfo()
    if not sourceGUID or not spellName then return end
    local unit = ArenaSticky.guidToUnit[sourceGUID]
    if not unit then return end
    local token = SPELL_SPEC_TOKEN[spellName]
    if token then
        ArenaSticky.specByGuid[sourceGUID] = token
    end
end

local function PrintHelp()
    print("|cff33ff99ArenaSticky|r commands:")
    print("  /as help")
    print("  /as test rmp")
    print("  /as edit | show | hide | resetwindow | sync | request")
end

local function EnsureInitialized()
    EnsureDB()
    if not ArenaSticky.mainFrame then
        CreateMainFrame()
        ApplyWindowSettings()
    end
end

local function ResetWindow()
    EnsureDB()
    ArenaStickyDB.window.x = 0
    ArenaStickyDB.window.y = 0
    ArenaStickyDB.window.width = 320
    ArenaStickyDB.window.height = 200
    ArenaStickyDB.window.scale = 1.0
    ArenaStickyDB.window.alpha = 0.95
    EnsureInitialized()
    ApplyWindowSettings()
    ArenaSticky.mainFrame:Show()
end

SLASH_ARENASTICKY1 = "/as"
SlashCmdList["ARENASTICKY"] = function(msg)
    msg = msg or ""
    local lower = msg:lower()
    local a, b = lower:match("^%s*(%S+)%s*(.*)$")

    if a == "edit" then
        if ArenaSticky.OpenEditor then
            ArenaSticky.OpenEditor()
        else
            print("ArenaSticky editor not loaded.")
        end
        return
    end

    if a == "hide" then
        EnsureInitialized()
        ArenaSticky.mainFrame:Hide()
        return
    end

    if a == "show" then
        EnsureInitialized()
        ArenaSticky.mainFrame:Show()
        return
    end

    if a == "resetwindow" then
        ResetWindow()
        print("|cff33ff99ArenaSticky|r: Window reset to center.")
        return
    end

    if a == "sync" then
        ArenaSticky:PushFullSync()
        print("|cff33ff99ArenaSticky|r: Strategy sync pushed.")
        return
    end

    if a == "request" then
        C_ChatInfo.SendAddonMessage(PREFIX, "FULLSYNC#0#0#", IsInGroup(2) and "INSTANCE_CHAT" or (IsInRaid() and "RAID" or "PARTY"))
        print("|cff33ff99ArenaSticky|r: Requested strategy sync.")
        return
    end

    if a == "test" then
        EnsureInitialized()
        local alias = (b or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if alias == "" then
            print("|cff33ff99ArenaSticky|r: Usage: |cff00ccff/as test <alias>|r")
            print("  Try |cff00ccff/as help|r for full command list.")
            return
        end
        local compKey = ResolveTestAlias(alias)
        if not compKey then
            print("|cff33ff99ArenaSticky|r: Unknown alias: " .. tostring(alias))
            return
        end
        print("|cff33ff99ArenaSticky|r: Test resolved to " .. tostring(compKey))
        UpdateNotesForComp(compKey, true, "DISC")
        ArenaSticky.mainFrame:Show()
        print("|cff33ff99ArenaSticky|r: Showing test strat " .. compKey .. " [DISC]")
        return
    end

    if a == "help" then
        PrintHelp()
        return
    end

    PrintHelp()
end

ArenaSticky.frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local addon = ...
        if addon ~= ADDON_NAME then return end
        EnsureInitialized()
        ArenaSticky.mainFrame:Hide()

        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        EnsureInitialized()
        if IsActiveBattlefieldArena() then
            C_Timer.After(1.0, TryDetectAndUpdate)
        end

    elseif event == "ARENA_OPPONENT_UPDATE" then
        if IsActiveBattlefieldArena() then
            RebuildGuidUnitMap()
            C_Timer.After(0.2, TryDetectAndUpdate)
        end

    elseif event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(...)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        -- Intentionally do not auto-show/hide on zone changes.
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        HandleCombatLog()

    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit and unit:match("^arena%d$") then
            local guid = UnitGUID(unit)
            if guid then
                local auraToken = DetectSpecFromAuras(unit)
                if auraToken then
                    ArenaSticky.specByGuid[guid] = auraToken
                end
            end
        end
    end
end)

ArenaSticky.frame:RegisterEvent("ADDON_LOADED")
ArenaSticky.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
ArenaSticky.frame:RegisterEvent("ARENA_OPPONENT_UPDATE")
ArenaSticky.frame:RegisterEvent("CHAT_MSG_ADDON")
ArenaSticky.frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
ArenaSticky.frame:RegisterEvent("UNIT_AURA")
ArenaSticky.frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")