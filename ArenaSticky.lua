local ADDON_NAME = ...
local PREFIX = "ARENASTICKY1"

ArenaSticky = ArenaSticky or {}
ArenaSticky.frame = CreateFrame("Frame")
ArenaSticky.enemyClasses = {}
ArenaSticky.playerRole = nil
ArenaSticky.currentCompKey = nil

local COMP_ALIASES = {
    wld = "DRUID-WARLOCK-WARRIOR",
    hpr = "HUNTER-PRIEST-ROGUE",
    thug = "HUNTER-PRIEST-ROGUE",
    rmp = "MAGE-PRIEST-ROGUE",
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
    return class
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
    footer:SetText("Type /asticky edit to modify")

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
            local _, class = UnitClass(unit)
            if class then
                table.insert(ArenaSticky.enemyClasses, class)
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
        ArenaSticky.headerText:SetText("Kill: TBD  |  CC: TBD")
        ArenaSticky.bodyText:SetText("No strategy saved for: " .. compKey .. "\nUse /asticky edit to add one.")
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
    -- Simple custom format: comp~kill~cc~priest~rogue~mage ; ...
    local parts = {}
    for comp, data in pairs(ArenaStickyDB.strategies) do
        local h = data.header or {}
        local r = data.roles or {}
        local seg = table.concat({
            comp,
            h.kill or "",
            h.cc or "",
            r.PRIEST or "",
            r.ROGUE or "",
            r.MAGE or "",
        }, "~")
        table.insert(parts, seg)
    end
    return table.concat(parts, ";")
end

local function DeserializeStrategiesSimple(str)
    local out = {}
    for seg in string.gmatch(str or "", "([^;]+)") do
        local a, b, c, d, e, f = strsplit("~", seg)
        if a and a ~= "" then
            out[a] = {
                header = { kill = b or "", cc = c or "" },
                roles = { PRIEST = d or "", ROGUE = e or "", MAGE = f or "" },
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

local function PrintHelp()
    print("|cff33ff99ArenaSticky|r commands:")
    print("  /asticky help")
    print("  /asticky test wld")
    print("  /asticky edit | show | hide | sync | request")
    print("  Works in 2v2 and 3v3 (auto-detect enemy comp size).")
    print("  Aliases: wld hpr thug rmp")
    print("  Or full key: /asticky test druid-warlock-warrior")
end

SLASH_ARENASTICKY1 = "/asticky"
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
            print("|cff33ff99ArenaSticky|r: Usage: |cff00ccff/asticky test <alias>|r")
            print("  Try |cff00ccff/asticky help|r for full command list.")
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
            C_Timer.After(0.2, TryDetectAndUpdate)
        end

    elseif event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(...)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if not IsActiveBattlefieldArena() then
            ArenaSticky.mainFrame:Hide()
        end
    end
end)

ArenaSticky.frame:RegisterEvent("ADDON_LOADED")
ArenaSticky.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
ArenaSticky.frame:RegisterEvent("ARENA_OPPONENT_UPDATE")
ArenaSticky.frame:RegisterEvent("CHAT_MSG_ADDON")
ArenaSticky.frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")