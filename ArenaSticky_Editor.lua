ArenaSticky = ArenaSticky or {}

local CLASS_ORDER = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE",
    "WARLOCK", "DRUID",
}

local function GetSortedCompKeys()
    local keys = {}
    if ArenaStickyDB and ArenaStickyDB.strategies then
        for compKey in pairs(ArenaStickyDB.strategies) do
            table.insert(keys, compKey)
        end
    end
    table.sort(keys)
    return keys
end

local function LoadCompIntoEditor(f, key)
    key = (key or ""):upper()
    f.compInput:SetText(key)
    if key == "" then
        f.status:SetText("Enter a comp key first.")
        return
    end

    local data = ArenaStickyDB.strategies[key]
    if not data then
        f.killInput:SetText("")
        f.ccInput:SetText("")
        f.classNoteInput:SetText("")
        f.status:SetText("No strategy exists. Fill and Save.")
        return
    end

    f.killInput:SetText((data.header and data.header.kill) or "")
    f.ccInput:SetText((data.header and data.header.cc) or "")
    local selectedClass = f.selectedClass or "PRIEST"
    f.classNoteInput:SetText((data.roles and data.roles[selectedClass]) or "")
    f.status:SetText("Loaded " .. key)
end

local function RefreshCompDropdown(f)
    if not f.compDropdown then return end
    local keys = GetSortedCompKeys()
    f.compKeys = keys
    UIDropDownMenu_Initialize(f.compDropdown, function(self, level)
        for _, key in ipairs(keys) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = key
            info.arg1 = key
            info.func = function(_, selectedKey)
                UIDropDownMenu_SetSelectedName(f.compDropdown, selectedKey)
                LoadCompIntoEditor(f, selectedKey)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    if #keys > 0 then
        UIDropDownMenu_SetText(f.compDropdown, "Select existing comp...")
    else
        UIDropDownMenu_SetText(f.compDropdown, "No saved comps yet")
    end
end

local function EnsureEditor()
    if ArenaSticky.editor then return ArenaSticky.editor end

    local f = CreateFrame("Frame", "ArenaStickyEditorFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    f:SetSize(620, 430)
    f:SetPoint("CENTER", 120, 0)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("ArenaSticky Strategy Editor")

    local function MakeLabel(text, x, y)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetText(text)
        return fs
    end

    local function MakeInput(w, h, x, y, multiLine)
        local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        eb:SetSize(w, h)
        eb:SetPoint("TOPLEFT", x, y)
        eb:SetAutoFocus(false)
        eb:SetTextInsets(6, 6, 6, 6)
        if multiLine then
            eb:SetMultiLine(true)
            eb:SetFontObject("GameFontHighlightSmall")
        end
        return eb
    end

    MakeLabel("Comp Key (e.g. DRUID-WARLOCK-WARRIOR)", 12, -40)
    f.compInput = MakeInput(340, 24, 12, -58, false)
    MakeLabel("Or select saved comp", 370, -40)
    f.compDropdown = CreateFrame("Frame", "ArenaStickyCompDropdown", f, "UIDropDownMenuTemplate")
    f.compDropdown:SetPoint("TOPLEFT", 350, -54)
    UIDropDownMenu_SetWidth(f.compDropdown, 220)
    UIDropDownMenu_SetText(f.compDropdown, "Select existing comp...")

    MakeLabel("Kill Target", 12, -90)
    f.killInput = MakeInput(170, 24, 12, -108, false)

    MakeLabel("CC Target", 200, -90)
    f.ccInput = MakeInput(170, 24, 200, -108, false)

    MakeLabel("Class Note (dynamic by your class)", 12, -140)
    f.classDropdown = CreateFrame("Frame", "ArenaStickyClassDropdown", f, "UIDropDownMenuTemplate")
    f.classDropdown:SetPoint("TOPLEFT", 220, -146)
    UIDropDownMenu_SetWidth(f.classDropdown, 150)
    f.selectedClass = select(2, UnitClass("player")) or "PRIEST"

    UIDropDownMenu_Initialize(f.classDropdown, function(self, level)
        for _, classToken in ipairs(CLASS_ORDER) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = classToken
            info.arg1 = classToken
            info.func = function(_, selectedClass)
                f.selectedClass = selectedClass
                UIDropDownMenu_SetSelectedName(f.classDropdown, selectedClass)
                local key = (f.compInput:GetText() or ""):upper()
                local data = ArenaStickyDB.strategies[key]
                f.classNoteInput:SetText((data and data.roles and data.roles[selectedClass]) or "")
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetSelectedName(f.classDropdown, f.selectedClass)

    f.classNoteInput = MakeInput(590, 248, 12, -172, true)

    local loadBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    loadBtn:SetSize(80, 24)
    loadBtn:SetPoint("BOTTOMLEFT", 12, 12)
    loadBtn:SetText("Load")

    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetSize(80, 24)
    saveBtn:SetPoint("LEFT", loadBtn, "RIGHT", 8, 0)
    saveBtn:SetText("Save")

    local pushBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    pushBtn:SetSize(110, 24)
    pushBtn:SetPoint("LEFT", saveBtn, "RIGHT", 8, 0)
    pushBtn:SetText("Push to Team")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn:SetSize(80, 24)
    closeBtn:SetPoint("RIGHT", -12, 12)
    closeBtn:SetText("Close")

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.status:SetPoint("BOTTOMLEFT", pushBtn, "TOPLEFT", 0, 6)
    f.status:SetText("")

    loadBtn:SetScript("OnClick", function()
        LoadCompIntoEditor(f, f.compInput:GetText())
    end)

    saveBtn:SetScript("OnClick", function()
        local key = (f.compInput:GetText() or ""):upper()
        if key == "" then
            f.status:SetText("Comp key required.")
            return
        end

        ArenaStickyDB.strategies[key] = {
            header = {
                kill = f.killInput:GetText() or "",
                cc = f.ccInput:GetText() or "",
            },
            roles = (ArenaStickyDB.strategies[key] and ArenaStickyDB.strategies[key].roles) or {},
        }
        local editClass = f.selectedClass or "PRIEST"
        ArenaStickyDB.strategies[key].roles[editClass] = f.classNoteInput:GetText() or ""
        ArenaStickyDB.version = (ArenaStickyDB.version or 1) + 1
        ArenaStickyDB.lastUpdated = time()
        RefreshCompDropdown(f)
        UIDropDownMenu_SetSelectedName(f.compDropdown, key)

        f.status:SetText("Saved " .. key .. " (v" .. ArenaStickyDB.version .. ")")

        if ArenaSticky.currentCompKey == key and ArenaSticky.mainFrame and ArenaSticky.mainFrame:IsShown() then
            local role = ArenaSticky.playerRole
            local strat = ArenaStickyDB.strategies[key]
            ArenaSticky.headerText:SetText(("Kill: %s  |  CC: %s"):format(strat.header.kill or "TBD", strat.header.cc or "TBD"))
            ArenaSticky.bodyText:SetText((strat.roles and strat.roles[role]) or "No note for your class.")
        end
    end)

    pushBtn:SetScript("OnClick", function()
        if ArenaSticky.PushFullSync then
            ArenaSticky:PushFullSync()
            f.status:SetText("Pushed strategy pack to team.")
        end
    end)

    closeBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    ArenaSticky.editor = f
    RefreshCompDropdown(f)
    return f
end

function ArenaSticky.OpenEditor()
    local f = EnsureEditor()
    RefreshCompDropdown(f)
    f:Show()
end