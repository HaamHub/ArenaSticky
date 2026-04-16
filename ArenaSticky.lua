local ADDON_NAME = ...
local PREFIX = "ARENASTICKY1"

ArenaSticky = ArenaSticky or {}
ArenaSticky.frame = CreateFrame("Frame")
ArenaSticky.enemyClasses = {}
ArenaSticky.playerRole = nil
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
    wld = "RESTO-WARLOCK-WARRIOR",
    hpr = "DISC-HUNTER-ROGUE",
    thug = "DISC-HUNTER-ROGUE",
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

local function ResolveTestAlias(arg)
    if not arg or arg == "" then return nil, arg end
    local clean = arg:lower():gsub("%s+", "")
    if clean:find("-", 1, true) then
        local parts = {}
        for p in clean:gmatch("[^-]+") do
            table.insert(parts, p:upper())
        end
        if #parts >= 2 then
            return NormalizeCompKey(parts), clean
        end
    end
    local key = COMP_ALIASES[clean]
    if key then return key, clean end
    return nil, clean
end

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
    ArenaStickyDB.strategies = ArenaStickyDB.strategies or {
        ["DRUID-WARLOCK-WARRIOR"] = {
            header = {
                kill = "Warlock",
                cc = "Druid",
            },
            roles = {
                PRIEST = "Play max pillar. Call \"not safe\" before go. Dispel only kill windows and emergency CC breaks.",
                ROGUE = "Open lock. Kidney only with druid CC confirmed. Reset after failed go.",
                MAGE = "Sheep druid on go. Peel warrior reconnect after every push. No neutral overtrade.",
            },
        },
        ["HUNTER-PRIEST-ROGUE"] = {
            header = {
                kill = "Hunter",
                cc = "Priest",
            },
            roles = {
                PRIEST = "Avoid sap/fear path in opener. Save trinket for lethal rogue setups.",
                ROGUE = "Control enemy rogue early. Kidney hunter with priest cross-CC.",
                MAGE = "Peel rogue first when priest is in CC. Burst hunter only in clean windows.",
            },
        },
    }
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
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, _, x, y = self:GetPoint()
        ArenaStickyDB.window.x = x
        ArenaStickyDB.window.y = y
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
    footer:SetText("Type /as edit to modify")

    ArenaSticky.mainFrame = f
    ArenaSticky.titleText = title
    ArenaSticky.headerText = header
    ArenaSticky.bodyText = body
    ArenaSticky.footerText = footer
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

local function UpdateNotesForComp(compKey)
    ArenaSticky.currentCompKey = compKey
    local role = ArenaSticky.playerRole or GetMyRole()
    if not role then
        ArenaSticky.headerText:SetText("Kill: ?  |  CC: ?")
        ArenaSticky.bodyText:SetText("Unsupported class for role notes.")
        ArenaSticky.mainFrame:Show()
        return
    end

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
        ArenaSticky.mainFrame:Show()
        return
    end

    local kill = (strat.header and strat.header.kill) or "TBD"
    local cc = (strat.header and strat.header.cc) or "TBD"
    local roleText = (strat.roles and strat.roles[role]) or "No note saved for your class in this comp."

    ArenaSticky.headerText:SetText(("Kill: %s  |  CC: %s"):format(kill, cc))
    ArenaSticky.bodyText:SetText(roleText)
    ArenaSticky.mainFrame:Show()
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
    print("  /as test wld")
    print("  /as edit | show | hide | sync | request")
    print("  Works in 2v2 and 3v3 (auto-detect enemy comp size).")
    print("  Aliases: wld hpr thug rmp")
    print("  Or full key: /as test druid-warlock-warrior")
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
        ArenaSticky.mainFrame:Hide()
        return
    end

    if a == "show" then
        ArenaSticky.mainFrame:Show()
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
        UpdateNotesForComp(compKey)
        print("|cff33ff99ArenaSticky|r: Showing test strat " .. compKey)
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
        EnsureDB()
        ArenaSticky.playerRole = GetMyRole()
        CreateMainFrame()
        ApplyWindowSettings()
        ArenaSticky.mainFrame:Hide()

        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        ArenaSticky.playerRole = GetMyRole()
        if IsActiveBattlefieldArena() then
            C_Timer.After(1.0, TryDetectAndUpdate)
        else
            ArenaSticky.mainFrame:Hide()
        end

    elseif event == "ARENA_OPPONENT_UPDATE" then
        if IsActiveBattlefieldArena() then
            RebuildGuidUnitMap()
            C_Timer.After(0.2, TryDetectAndUpdate)
        end

    elseif event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(...)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if not IsActiveBattlefieldArena() then
            ArenaSticky.mainFrame:Hide()
        end
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