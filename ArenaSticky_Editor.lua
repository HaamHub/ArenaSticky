ArenaSticky = ArenaSticky or {}

local CLASS_ORDER = {
    "WARRIOR", "HUNTER", "ROGUE", "MAGE", "WARLOCK",
    "RET", "HPAL",
    "RSHAM", "ELE", "ENH",
    "DISC", "SHADOW",
    "RESTO", "BOOMY", "FERAL",
    -- Legacy/base tokens (for older saved comps/notes)
    "PALADIN", "SHAMAN", "PRIEST", "DRUID",
}

local COMP_SLOT_OPTIONS = {
    "WARRIOR", "HUNTER", "ROGUE", "MAGE", "WARLOCK",
    "RET", "HPAL",
    "RSHAM", "ELE", "ENH",
    "DISC", "SHADOW",
    "RESTO", "BOOMY", "FERAL",
    -- Legacy/base tokens (for older saved comps)
    "PALADIN", "SHAMAN", "PRIEST", "DRUID",
}

local function NormalizeCompFromParts(parts)
    local classes = {}
    for _, c in ipairs(parts or {}) do
        if c and c ~= "" and c ~= "NONE" then
            table.insert(classes, c)
        end
    end
    table.sort(classes)
    return table.concat(classes, "-")
end

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

local function GetCompSizeFromKey(key)
    local count = 0
    for _ in (key or ""):gmatch("[^-]+") do
        count = count + 1
    end
    return count
end

local function LoadCompIntoEditor(f, key)
    key = (key or ""):upper()
    f.compInput:SetText(key)
    if f.SetBracketFromKey then
        f:SetBracketFromKey(key)
    end
    if f.SetCompSlotsFromKey then
        f:SetCompSlotsFromKey(key)
    end
    if key == "" then
        f.status:SetText("Enter a comp key first.")
        return
    end

    local data = ArenaStickyDB.strategies[key]
    if not data then
        f.killInput:SetText("")
        f.ccInput:SetText("")
        if f.noteRows then
            for i = 1, 3 do
                f.noteRows[i].input:SetText("")
            end
        end
        f.status:SetText("No strategy exists. Fill and Save.")
        return
    end

    f.killInput:SetText((data.header and data.header.kill) or "")
    f.ccInput:SetText((data.header and data.header.cc) or "")
    if f.UpdateNoteRowsFromComp then
        f:UpdateNoteRowsFromComp()
    end
    f.status:SetText("Loaded " .. key)
end

local function RefreshCompDropdown(f)
    if not f.compDropdown then return end
    local allKeys = GetSortedCompKeys()
    local keys = {}
    local expectedSize = (f.selectedBracket == "2v2") and 2 or 3
    for _, key in ipairs(allKeys) do
        if GetCompSizeFromKey(key) == expectedSize then
            table.insert(keys, key)
        end
    end
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
        UIDropDownMenu_SetText(f.compDropdown, "No saved comps for " .. (f.selectedBracket or "this bracket"))
    end
end

local function EnsureEditor()
    if ArenaSticky.editor then return ArenaSticky.editor end

    local f = CreateFrame("Frame", "ArenaStickyEditorFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    f:SetSize(700, 480)
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
        else
            eb:SetMultiLine(false)
            eb:SetScript("OnEnterPressed", function(self)
                self:ClearFocus()
            end)
        end
        return eb
    end

    local function UpdateCompFromSlots()
        local keyParts
        if f.selectedBracket == "2v2" then
            keyParts = { f.compSlot1Value, f.compSlot2Value }
        else
            keyParts = { f.compSlot1Value, f.compSlot2Value, f.compSlot3Value }
        end
        local key = NormalizeCompFromParts(keyParts)
        f.compInput:SetText(key)
        if f.UpdateNoteRowsFromComp then
            f:UpdateNoteRowsFromComp()
        end
    end

    local function BuildCompSlotDropdown(dropdown, slotName)
        UIDropDownMenu_Initialize(dropdown, function(self, level)
            for _, classToken in ipairs(COMP_SLOT_OPTIONS) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = classToken
                info.arg1 = classToken
                info.func = function(_, selectedClass)
                    f[slotName] = selectedClass
                    UIDropDownMenu_SetSelectedName(dropdown, selectedClass)
                    UpdateCompFromSlots()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end

    f.SetCompSlotsFromKey = function(self, key)
        local parts = {}
        for p in (key or ""):gmatch("[^-]+") do
            table.insert(parts, p:upper())
        end
        self.compSlot1Value = parts[1] or "PRIEST"
        self.compSlot2Value = parts[2] or "ROGUE"
        self.compSlot3Value = parts[3] or "MAGE"
        UIDropDownMenu_SetSelectedName(self.compSlot1, self.compSlot1Value)
        UIDropDownMenu_SetSelectedName(self.compSlot2, self.compSlot2Value)
        UIDropDownMenu_SetSelectedName(self.compSlot3, self.compSlot3Value)
        if self.noteRows then
            self.noteRows[1].classValue = self.compSlot1Value
            self.noteRows[2].classValue = self.compSlot2Value
            self.noteRows[3].classValue = self.compSlot3Value
            UIDropDownMenu_SetSelectedName(self.noteRows[1].dropdown, self.noteRows[1].classValue)
            UIDropDownMenu_SetSelectedName(self.noteRows[2].dropdown, self.noteRows[2].classValue)
            UIDropDownMenu_SetSelectedName(self.noteRows[3].dropdown, self.noteRows[3].classValue)
        end
    end

    f.UpdateVisibleNoteRows = function(self)
        local count = (self.selectedBracket == "2v2") and 2 or 3
        for i = 1, 3 do
            if i <= count then
                self.noteRows[i].label:Show()
                self.noteRows[i].dropdown:Show()
                self.noteRows[i].input:Show()
            else
                self.noteRows[i].label:Hide()
                self.noteRows[i].dropdown:Hide()
                self.noteRows[i].input:Hide()
            end
        end
    end

    f.UpdateNoteRowsFromComp = function(self)
        local key = (self.compInput:GetText() or ""):upper()
        local data = ArenaStickyDB and ArenaStickyDB.strategies and ArenaStickyDB.strategies[key]
        for i = 1, 3 do
            local row = self.noteRows[i]
            local classToken = row.classValue or "PRIEST"
            row.input:SetText((data and data.roles and data.roles[classToken]) or "")
        end
    end

    f.SetBracketFromKey = function(self, key)
        local size = GetCompSizeFromKey(key)
        local bracket = (size >= 3) and "3v3" or "2v2"
        self.selectedBracket = bracket
        UIDropDownMenu_SetSelectedName(self.bracketDropdown, bracket)
        if bracket == "2v2" then
            self.compSlot3:Hide()
        else
            self.compSlot3:Show()
        end
        if self.UpdateVisibleNoteRows then
            self:UpdateVisibleNoteRows()
        end
    end

    MakeLabel("Comp Key (e.g. DRUID-WARLOCK-WARRIOR)", 12, -40)
    f.compInput = MakeInput(340, 24, 12, -58, false)
    MakeLabel("Or select saved comp", 370, -40)
    f.compDropdown = CreateFrame("Frame", "ArenaStickyCompDropdown", f, "UIDropDownMenuTemplate")
    f.compDropdown:SetPoint("TOPLEFT", 350, -54)
    UIDropDownMenu_SetWidth(f.compDropdown, 220)
    UIDropDownMenu_SetText(f.compDropdown, "Select existing comp...")

    MakeLabel("Bracket", 12, -90)
    f.bracketDropdown = CreateFrame("Frame", "ArenaStickyBracketDropdown", f, "UIDropDownMenuTemplate")
    f.bracketDropdown:SetPoint("TOPLEFT", 0, -102)
    UIDropDownMenu_SetWidth(f.bracketDropdown, 90)
    UIDropDownMenu_Initialize(f.bracketDropdown, function(self, level)
        for _, bracket in ipairs({ "2v2", "3v3" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = bracket
            info.arg1 = bracket
            info.func = function(_, selectedBracket)
                f.selectedBracket = selectedBracket
                UIDropDownMenu_SetSelectedName(f.bracketDropdown, selectedBracket)
                if selectedBracket == "2v2" then
                    f.compSlot3:Hide()
                else
                    f.compSlot3:Show()
                end
                if f.UpdateVisibleNoteRows then
                    f:UpdateVisibleNoteRows()
                end
                UpdateCompFromSlots()
                RefreshCompDropdown(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.selectedBracket = "3v3"
    UIDropDownMenu_SetSelectedName(f.bracketDropdown, f.selectedBracket)

    MakeLabel("Build Comp from Class Dropdowns", 185, -90)
    f.compSlot1 = CreateFrame("Frame", "ArenaStickyCompSlot1Dropdown", f, "UIDropDownMenuTemplate")
    f.compSlot1:SetPoint("TOPLEFT", 175, -102)
    UIDropDownMenu_SetWidth(f.compSlot1, 130)
    f.compSlot2 = CreateFrame("Frame", "ArenaStickyCompSlot2Dropdown", f, "UIDropDownMenuTemplate")
    f.compSlot2:SetPoint("TOPLEFT", 335, -102)
    UIDropDownMenu_SetWidth(f.compSlot2, 130)
    f.compSlot3 = CreateFrame("Frame", "ArenaStickyCompSlot3Dropdown", f, "UIDropDownMenuTemplate")
    f.compSlot3:SetPoint("TOPLEFT", 495, -102)
    UIDropDownMenu_SetWidth(f.compSlot3, 130)

    BuildCompSlotDropdown(f.compSlot1, "compSlot1Value")
    BuildCompSlotDropdown(f.compSlot2, "compSlot2Value")
    BuildCompSlotDropdown(f.compSlot3, "compSlot3Value")
    f.compSlot1Value = "PRIEST"
    f.compSlot2Value = "ROGUE"
    f.compSlot3Value = "MAGE"
    UIDropDownMenu_SetSelectedName(f.compSlot1, f.compSlot1Value)
    UIDropDownMenu_SetSelectedName(f.compSlot2, f.compSlot2Value)
    UIDropDownMenu_SetSelectedName(f.compSlot3, f.compSlot3Value)

    MakeLabel("Kill Target", 12, -146)
    f.killInput = MakeInput(170, 24, 12, -164, false)

    MakeLabel("CC Target", 200, -146)
    f.ccInput = MakeInput(170, 24, 200, -164, false)

    MakeLabel("Class Notes (per class in this comp)", 12, -196)
    f.noteRows = {}
    local rowY = { -216, -292, -368 }
    for i = 1, 3 do
        local row = {}
        row.label = MakeLabel(("Class %d"):format(i), 12, rowY[i])
        row.dropdown = CreateFrame("Frame", "ArenaStickyClassNoteDropdown" .. i, f, "UIDropDownMenuTemplate")
        row.dropdown:SetPoint("TOPLEFT", 0, rowY[i] - 12)
        UIDropDownMenu_SetWidth(row.dropdown, 130)
        row.input = MakeInput(500, 24, 190, rowY[i] - 12, false)
        row.classValue = (i == 1 and f.compSlot1Value) or (i == 2 and f.compSlot2Value) or f.compSlot3Value

        UIDropDownMenu_Initialize(row.dropdown, function(self, level)
            for _, classToken in ipairs(CLASS_ORDER) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = classToken
                info.arg1 = classToken
                info.func = function(_, selectedClass)
                    row.classValue = selectedClass
                    UIDropDownMenu_SetSelectedName(row.dropdown, selectedClass)
                    local key = (f.compInput:GetText() or ""):upper()
                    local data = ArenaStickyDB.strategies[key]
                    row.input:SetText((data and data.roles and data.roles[selectedClass]) or "")
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        UIDropDownMenu_SetSelectedName(row.dropdown, row.classValue)
        f.noteRows[i] = row
    end
    f:UpdateVisibleNoteRows()

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
    closeBtn:SetPoint("BOTTOMRIGHT", -12, 12)
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
        local rowCount = (f.selectedBracket == "2v2") and 2 or 3
        for i = 1, rowCount do
            local row = f.noteRows[i]
            local editClass = row.classValue
            if editClass and editClass ~= "" then
                ArenaStickyDB.strategies[key].roles[editClass] = row.input:GetText() or ""
            end
        end
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