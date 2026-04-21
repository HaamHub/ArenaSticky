ArenaSticky = ArenaSticky or {}

local CLASS_ORDER = {
    "WARRIOR", "HUNTER", "ROGUE", "MAGE", "WARLOCK",
    "RET", "HPAL",
    "RSHAM", "ELE", "ENH",
    "DISC", "SHADOW",
    "RDRUID", "BOOMY", "FERAL",
}

local COMP_SLOT_OPTIONS = {
    "WARRIOR", "HUNTER", "ROGUE", "MAGE", "WARLOCK",
    "RET", "HPAL",
    "RSHAM", "ELE", "ENH",
    "DISC", "SHADOW",
    "RDRUID", "BOOMY", "FERAL",
}

local BRACKET_ICONS = {
    ["2v2"] = "Interface\\Icons\\Ability_DualWield",
    ["3v3"] = "Interface\\Icons\\Spell_Nature_GroundingTotem",
}

local function DropdownSpecLabel(token)
    if not token or token == "" then
        return ""
    end
    return ArenaSticky.SpecIconInline(token, 16) .. " " .. token
end

local function BracketDropdownLabel(bracket)
    local path = BRACKET_ICONS[bracket]
    local icon = path and ("|T" .. path .. ":16:16|t ") or ""
    return icon .. (bracket or "")
end

local function GetPlayerDefaultNoteToken()
    if ArenaSticky.GetPlayerRoleToken then
        local role = ArenaSticky.GetPlayerRoleToken()
        if role and role ~= "" then
            return role
        end
    end
    local _, class = UnitClass("player")
    if class == "PRIEST" then return "DISC" end
    if class == "DRUID" then return "RDRUID" end
    if class == "SHAMAN" then return "RSHAM" end
    if class == "PALADIN" then return "HPAL" end
    return class
end

local function GetPartyDefaultNoteToken(unit)
    if not unit or not UnitExists(unit) then return nil end
    local _, class = UnitClass(unit)
    if class == "PRIEST" then return "DISC" end
    if class == "DRUID" then return "RDRUID" end
    if class == "SHAMAN" then return "RSHAM" end
    if class == "PALADIN" then return "HPAL" end
    return class
end

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

local function BuildTeamCompKeyFromRows(f)
    if not f or not f.noteRows then return nil end
    local count = (f.selectedBracket == "2v2") and 2 or 3
    local parts = {}
    for i = 1, count do
        local row = f.noteRows[i]
        local tok = row and row.classValue
        if tok and tok ~= "" and tok ~= "NONE" then
            table.insert(parts, string.upper(tok))
        end
    end
    if #parts < count then
        return nil
    end
    table.sort(parts)
    return table.concat(parts, "-")
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

--- Strip legacy "N-" prefix (old saves) so token count matches 2v2/3v3. Current keys are class tokens only.
local function GetArenaCompBody(key)
    if not key or key == "" then return "" end
    return (key:match("^%d%-(.+)$")) or key
end

local function GetCompSizeFromKey(key)
    local count = 0
    for _ in GetArenaCompBody(key):gmatch("[^-]+") do
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
        if f.cc2Input then
            f.cc2Input:SetText("")
        end
        if f.noteRows then
            for i = 1, 3 do
                f.noteRows[i].input:SetText("")
            end
        end
        f.status:SetText("No strategy exists. Fill and Save.")
        return
    end

    local teamKey = BuildTeamCompKeyFromRows(f)
    local v = data.teamVariants and teamKey and data.teamVariants[teamKey]
    local source = v or data
    f.killInput:SetText((source.header and source.header.kill) or "")
    f.ccInput:SetText((source.header and source.header.cc) or "")
    if f.UpdateNoteRowsFromComp then
        f:UpdateNoteRowsFromComp()
    end
    f.status:SetText("Loaded " .. key .. (teamKey and (" for " .. teamKey) or ""))
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
            info.text = ArenaSticky.CompKeyMenuLabel(key)
            info.arg1 = key
            info.func = function(_, selectedKey)
                UIDropDownMenu_SetSelectedName(f.compDropdown, selectedKey)
                UIDropDownMenu_SetText(f.compDropdown, ArenaSticky.CompKeyMenuLabel(selectedKey))
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

local BUTTON_W = 92
local BUTTON_H = 22
local PROFILE_BTN_W = 176

local function EnsureEditor()
    -- Rebuild when editor layout / profile controls change.
    if ArenaSticky.editor and (not ArenaSticky.editor.profileDropdown or not ArenaSticky.editor.copyFromDropdown) then
        ArenaSticky.editor = nil
    end
    if ArenaSticky.editor then return ArenaSticky.editor end

    local f = CreateFrame("Frame", "ArenaStickyEditorFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    f:SetSize(700, 640)
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

    local function MakeSectionHeader(text, x, y)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetText(text)
        return fs
    end

    local function MakeHint(text, x, y)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetText(text)
        return fs
    end

    MakeSectionHeader("Enemy team", 12, -34)

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
                info.icon = ArenaSticky.SpecIconTexture(classToken)
                info.func = function(_, selectedClass)
                    f[slotName] = selectedClass
                    UIDropDownMenu_SetSelectedName(dropdown, selectedClass)
                    UIDropDownMenu_SetText(dropdown, DropdownSpecLabel(selectedClass))
                    UpdateCompFromSlots()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end

    f.SetCompSlotsFromKey = function(self, key)
        local parts = {}
        for p in GetArenaCompBody(key or ""):gmatch("[^-]+") do
            table.insert(parts, p:upper())
        end
        self.compSlot1Value = parts[1] or "DISC"
        self.compSlot2Value = parts[2] or "ROGUE"
        self.compSlot3Value = parts[3] or "MAGE"
        UIDropDownMenu_SetSelectedName(self.compSlot1, self.compSlot1Value)
        UIDropDownMenu_SetSelectedName(self.compSlot2, self.compSlot2Value)
        UIDropDownMenu_SetSelectedName(self.compSlot3, self.compSlot3Value)
        UIDropDownMenu_SetText(self.compSlot1, DropdownSpecLabel(self.compSlot1Value))
        UIDropDownMenu_SetText(self.compSlot2, DropdownSpecLabel(self.compSlot2Value))
        UIDropDownMenu_SetText(self.compSlot3, DropdownSpecLabel(self.compSlot3Value))
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
        if self.cc2Label and self.cc2Input then
            if self.selectedBracket == "3v3" then
                self.cc2Label:Show()
                self.cc2Input:Show()
            else
                self.cc2Label:Hide()
                self.cc2Input:Hide()
            end
        end
    end

    f.UpdateNoteRowsFromComp = function(self)
        local key = (self.compInput:GetText() or ""):upper()
        local data = ArenaStickyDB and ArenaStickyDB.strategies and ArenaStickyDB.strategies[key]
        local teamKey = BuildTeamCompKeyFromRows(self)
        local v = data and data.teamVariants and teamKey and data.teamVariants[teamKey]
        local source = v or data
        if source then
            self.killInput:SetText((source.header and source.header.kill) or "")
            self.ccInput:SetText((source.header and source.header.cc) or "")
            if self.cc2Input then
                self.cc2Input:SetText((source.header and (source.header.swap or source.header.cc2)) or "")
            end
        else
            self.killInput:SetText("")
            self.ccInput:SetText("")
            if self.cc2Input then
                self.cc2Input:SetText("")
            end
        end
        for i = 1, 3 do
            local row = self.noteRows[i]
            local classToken = row.classValue or "DISC"
            row.input:SetText((source and source.roles and source.roles[classToken]) or "")
        end
    end

    f.SetBracketFromKey = function(self, key)
        local size = GetCompSizeFromKey(key)
        local bracket = (size >= 3) and "3v3" or "2v2"
        self.selectedBracket = bracket
        UIDropDownMenu_SetSelectedName(self.bracketDropdown, bracket)
        UIDropDownMenu_SetText(self.bracketDropdown, BracketDropdownLabel(bracket))
        if bracket == "2v2" then
            self.compSlot3:Hide()
        else
            self.compSlot3:Show()
        end
        if self.UpdateVisibleNoteRows then
            self:UpdateVisibleNoteRows()
        end
    end

    -- Tighter layout under title (reduces empty band below "ArenaSticky Strategy Editor")
    local Y0 = 34
    local KILL_CC_FIELD_SHIFT_X = 8
    MakeLabel("Enemy comp key (sorted specs: 2 = 2v2, 3 = 3v3)", 12, -82 + Y0)
    f.compInput = MakeInput(340, 24, 12 + KILL_CC_FIELD_SHIFT_X, -100 + Y0, false)
    MakeLabel("Or select saved comp", 370, -82 + Y0)
    f.compDropdown = CreateFrame("Frame", "ArenaStickyCompDropdown", f, "UIDropDownMenuTemplate")
    -- Align with Comp Key editbox (1px above compInput TOP so the dropdown isn’t a hair low)
    f.compDropdown:SetPoint("TOPLEFT", 350, -101 + Y0)
    UIDropDownMenu_SetWidth(f.compDropdown, 220)
    UIDropDownMenu_SetText(f.compDropdown, "Select existing comp...")

    -- Label→dropdown gap matches “Or select saved comp” row (19px: -82 → -101)
    local BRACKET_ROW_DD_Y = -151 + Y0
    MakeLabel("Bracket", 12, -132 + Y0)
    f.bracketDropdown = CreateFrame("Frame", "ArenaStickyBracketDropdown", f, "UIDropDownMenuTemplate")
    f.bracketDropdown:SetPoint("TOPLEFT", 0, BRACKET_ROW_DD_Y)
    UIDropDownMenu_SetWidth(f.bracketDropdown, 90)
    UIDropDownMenu_Initialize(f.bracketDropdown, function(self, level)
        for _, bracket in ipairs({ "2v2", "3v3" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = bracket
            info.arg1 = bracket
            info.icon = BRACKET_ICONS[bracket]
            info.func = function(_, selectedBracket)
                f.selectedBracket = selectedBracket
                UIDropDownMenu_SetSelectedName(f.bracketDropdown, selectedBracket)
                UIDropDownMenu_SetText(f.bracketDropdown, BracketDropdownLabel(selectedBracket))
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
    UIDropDownMenu_SetText(f.bracketDropdown, BracketDropdownLabel(f.selectedBracket))

    MakeLabel("Enemy specs (build key)", 185, -132 + Y0)
    f.compSlot1 = CreateFrame("Frame", "ArenaStickyCompSlot1Dropdown", f, "UIDropDownMenuTemplate")
    f.compSlot1:SetPoint("TOPLEFT", 175, BRACKET_ROW_DD_Y)
    UIDropDownMenu_SetWidth(f.compSlot1, 130)
    f.compSlot2 = CreateFrame("Frame", "ArenaStickyCompSlot2Dropdown", f, "UIDropDownMenuTemplate")
    f.compSlot2:SetPoint("TOPLEFT", 335, BRACKET_ROW_DD_Y)
    UIDropDownMenu_SetWidth(f.compSlot2, 130)
    f.compSlot3 = CreateFrame("Frame", "ArenaStickyCompSlot3Dropdown", f, "UIDropDownMenuTemplate")
    f.compSlot3:SetPoint("TOPLEFT", 495, BRACKET_ROW_DD_Y)
    UIDropDownMenu_SetWidth(f.compSlot3, 130)

    BuildCompSlotDropdown(f.compSlot1, "compSlot1Value")
    BuildCompSlotDropdown(f.compSlot2, "compSlot2Value")
    BuildCompSlotDropdown(f.compSlot3, "compSlot3Value")
    f.compSlot1Value = "DISC"
    f.compSlot2Value = "ROGUE"
    f.compSlot3Value = "MAGE"
    UIDropDownMenu_SetSelectedName(f.compSlot1, f.compSlot1Value)
    UIDropDownMenu_SetSelectedName(f.compSlot2, f.compSlot2Value)
    UIDropDownMenu_SetSelectedName(f.compSlot3, f.compSlot3Value)
    UIDropDownMenu_SetText(f.compSlot1, DropdownSpecLabel(f.compSlot1Value))
    UIDropDownMenu_SetText(f.compSlot2, DropdownSpecLabel(f.compSlot2Value))
    UIDropDownMenu_SetText(f.compSlot3, DropdownSpecLabel(f.compSlot3Value))

    -- Visual split between enemy-comp setup and your-team notes.
    local sectionSep = f:CreateTexture(nil, "ARTWORK")
    sectionSep:SetColorTexture(1, 1, 1, 0.15)
    sectionSep:SetPoint("TOPLEFT", 12, -196 + Y0)
    sectionSep:SetSize(670, 1)

    MakeSectionHeader("Your team", 12, -216 + Y0)
    MakeHint("Your lineup vs. this enemy matchup — pick your spec and write the note for your role.", 12, -234 + Y0)
    MakeLabel("Kill target (enemy)", 12, -258 + Y0)
    f.killInput = MakeInput(170, 24, 12 + KILL_CC_FIELD_SHIFT_X, -276 + Y0, false)

    MakeLabel("CC target (enemy)", 200, -258 + Y0)
    f.ccInput = MakeInput(170, 24, 200 + KILL_CC_FIELD_SHIFT_X, -276 + Y0, false)
    f.cc2Label = MakeLabel("Swap target (enemy)", 390, -258 + Y0)
    f.cc2Input = MakeInput(170, 24, 390 + KILL_CC_FIELD_SHIFT_X, -276 + Y0, false)
    f.noteRows = {}
    local rowY = { -306 + Y0, -372 + Y0, -438 + Y0 }
    for i = 1, 3 do
        local row = {}
        local rowNames = { "You", "Teammate 1", "Teammate 2" }
        row.label = MakeLabel(rowNames[i] or ("Teammate " .. tostring(i - 1)), 12, rowY[i])
        row.dropdown = CreateFrame("Frame", "ArenaStickyClassNoteDropdown" .. i, f, "UIDropDownMenuTemplate")
        row.dropdown:SetPoint("TOPLEFT", 0, rowY[i] - 12)
        UIDropDownMenu_SetWidth(row.dropdown, 130)
        row.input = MakeInput(500, 24, 190, rowY[i] - 12, false)
        row.classValue =
            (i == 1 and (GetPlayerDefaultNoteToken() or "DISC")) or
            (i == 2 and (GetPartyDefaultNoteToken("party1") or f.compSlot2Value)) or
            (GetPartyDefaultNoteToken("party2") or f.compSlot3Value)

        UIDropDownMenu_Initialize(row.dropdown, function(self, level)
            for _, classToken in ipairs(CLASS_ORDER) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = classToken
                info.arg1 = classToken
                info.icon = ArenaSticky.SpecIconTexture(classToken)
                info.func = function(_, selectedClass)
                    row.classValue = selectedClass
                    UIDropDownMenu_SetSelectedName(row.dropdown, selectedClass)
                    UIDropDownMenu_SetText(row.dropdown, DropdownSpecLabel(selectedClass))
                    if f.UpdateNoteRowsFromComp then
                        f:UpdateNoteRowsFromComp()
                    end
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        UIDropDownMenu_SetSelectedName(row.dropdown, row.classValue)
        UIDropDownMenu_SetText(row.dropdown, DropdownSpecLabel(row.classValue))
        f.noteRows[i] = row
    end
    f:UpdateVisibleNoteRows()

    local bottomY = 12
    local PUSH_GAP = 10
    local ROW_GAP = 5
    -- Profile stack: bottom-right of frame, tight vertical spacing
    local PROFILE_STACK_V_GAP = 4
    local PROFILE_LABEL_GAP = 3
    -- Space between profile dropdown bottom and “Copy notes from” label (smaller = tighter)
    local PROFILE_TO_COPY_LBL_GAP = 2
    -- Slightly lower than Load/Save row so the control lines up visually with Push to Team
    local COPY_FROM_DD_BOTTOM_INSET = bottomY - 4

    -- Bottom row: Load / Save. Above them: Import / Export (per user layout).
    local loadBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    loadBtn:SetPoint("BOTTOMLEFT", 12, bottomY)
    loadBtn:SetText("Load")
    loadBtn:SetSize(BUTTON_W, BUTTON_H)

    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetPoint("LEFT", loadBtn, "RIGHT", 8, 0)
    saveBtn:SetText("Save")
    saveBtn:SetSize(BUTTON_W, BUTTON_H)

    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetSize(BUTTON_W, BUTTON_H)
    importBtn:SetText("Import")
    importBtn:SetPoint("BOTTOMLEFT", loadBtn, "TOPLEFT", 0, ROW_GAP)

    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(BUTTON_W, BUTTON_H)
    exportBtn:SetText("Export")
    exportBtn:SetPoint("BOTTOMLEFT", saveBtn, "TOPLEFT", 0, ROW_GAP)

    local pushBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    pushBtn:SetPoint("LEFT", saveBtn, "RIGHT", PUSH_GAP, 0)
    pushBtn:SetText("Push to Team")
    pushBtn:SetSize(118, BUTTON_H)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -10)
    closeBtn:SetText("Close")
    closeBtn:SetSize(80, BUTTON_H)

    local profileHeaderLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    profileHeaderLbl:SetText("Active profile")

    local profileDD = CreateFrame("Frame", nil, f, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(profileDD, math.max(PROFILE_BTN_W, 168))
    if UIDropDownMenu_JustifyText then
        UIDropDownMenu_JustifyText(profileDD, "LEFT")
    end

    local copyFromHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    copyFromHeader:SetText("Copy notes from...")

    local copyFromDD = CreateFrame("Frame", nil, f, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(copyFromDD, math.max(PROFILE_BTN_W, 168))
    if UIDropDownMenu_JustifyText then
        UIDropDownMenu_JustifyText(copyFromDD, "LEFT")
    end

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.status:SetJustifyH("RIGHT")
    f.status:SetJustifyV("MIDDLE")
    f.status:SetText("")

    local function DropDownSetText(dd, text)
        if UIDropDownMenu_SetText then
            UIDropDownMenu_SetText(dd, text)
        elseif dd and dd.Text then
            dd.Text:SetText(text)
        end
    end

    local function LayoutBottomChrome()
        loadBtn:SetSize(BUTTON_W, BUTTON_H)
        saveBtn:SetSize(BUTTON_W, BUTTON_H)
        exportBtn:SetSize(BUTTON_W, BUTTON_H)
        importBtn:SetSize(BUTTON_W, BUTTON_H)
        pushBtn:SetSize(118, BUTTON_H)
        closeBtn:SetSize(80, BUTTON_H)
        UIDropDownMenu_SetWidth(profileDD, math.max(PROFILE_BTN_W, 168))
        UIDropDownMenu_SetWidth(copyFromDD, math.max(PROFILE_BTN_W, 168))

        -- Stack (bottom → top): copy dropdown, “Copy notes from” (centered on dd), profile dd, “Active profile” (centered on dd) — bottom-right
        copyFromDD:ClearAllPoints()
        copyFromDD:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, COPY_FROM_DD_BOTTOM_INSET)
        copyFromDD:SetFrameLevel((closeBtn:GetFrameLevel() or 0) + 5)

        copyFromHeader:ClearAllPoints()
        copyFromHeader:SetPoint("BOTTOM", copyFromDD, "TOP", 0, PROFILE_STACK_V_GAP)
        copyFromHeader:SetPoint("LEFT", copyFromDD, "LEFT", 0, 0)
        copyFromHeader:SetPoint("RIGHT", copyFromDD, "RIGHT", 0, 0)
        copyFromHeader:SetJustifyH("CENTER")

        profileDD:ClearAllPoints()
        profileDD:SetPoint("BOTTOMRIGHT", copyFromHeader, "TOPRIGHT", 0, PROFILE_TO_COPY_LBL_GAP)
        profileDD:SetFrameLevel((closeBtn:GetFrameLevel() or 0) + 5)

        profileHeaderLbl:ClearAllPoints()
        profileHeaderLbl:SetPoint("BOTTOM", profileDD, "TOP", 0, PROFILE_LABEL_GAP)
        profileHeaderLbl:SetPoint("LEFT", profileDD, "LEFT", 0, 0)
        profileHeaderLbl:SetPoint("RIGHT", profileDD, "RIGHT", 0, 0)
        profileHeaderLbl:SetJustifyH("CENTER")

        -- Status above Import/Export only (Loaded/Saved/etc.), not centered under the profile stack
        f.status:ClearAllPoints()
        f.status:SetPoint("BOTTOMLEFT", importBtn, "TOPLEFT", 0, 6)
        f.status:SetPoint("BOTTOMRIGHT", exportBtn, "TOPRIGHT", 0, 6)
        f.status:SetJustifyH("LEFT")
    end

    local function RefreshProfileDropdown()
        if not profileDD or not ArenaSticky.GetSortedProfileNames or not ArenaSticky.SwitchProfile then
            return
        end
        UIDropDownMenu_Initialize(profileDD, function()
            local names = ArenaSticky.GetSortedProfileNames()
            for _, pname in ipairs(names) do
                local name = pname
                local info = UIDropDownMenu_CreateInfo()
                info.text = name
                info.func = function()
                    ArenaSticky.SwitchProfile(name)
                end
                info.checked = (name == ((ArenaStickyDB and ArenaStickyDB.activeProfile) or "Default"))
                UIDropDownMenu_AddButton(info)
            end
            local delInfo = UIDropDownMenu_CreateInfo()
            delInfo.text = "Delete selected profile"
            delInfo.notCheckable = true
            delInfo.func = function()
                local cur = (ArenaStickyDB and ArenaStickyDB.activeProfile) or "Default"
                StaticPopupDialogs["ARENASTICKY_EDITOR_DELETE_PROFILE"].text =
                    'Delete profile "' .. cur .. '"? This cannot be undone.'
                StaticPopup_Show("ARENASTICKY_EDITOR_DELETE_PROFILE")
            end
            UIDropDownMenu_AddButton(delInfo)

            local newInfo = UIDropDownMenu_CreateInfo()
            newInfo.text = "Create new profile"
            newInfo.notCheckable = true
            newInfo.func = function()
                StaticPopup_Show("ARENASTICKY_EDITOR_NEW_PROFILE")
            end
            UIDropDownMenu_AddButton(newInfo)
        end)
        DropDownSetText(profileDD, (ArenaStickyDB and ArenaStickyDB.activeProfile) or "Default")
        LayoutBottomChrome()
    end

    local function RefreshCopyFromDropdown()
        if not copyFromDD or not ArenaSticky.CopyNotesFromProfileToActive or not ArenaSticky.GetSortedProfileNames then
            return
        end
        UIDropDownMenu_Initialize(copyFromDD, function()
            local active = (ArenaStickyDB and ArenaStickyDB.activeProfile) or "Default"
            local titleInfo = UIDropDownMenu_CreateInfo()
            titleInfo.text = "Copy into active profile:"
            titleInfo.isTitle = true
            titleInfo.notCheckable = true
            UIDropDownMenu_AddButton(titleInfo)
            local others = false
            for _, pname in ipairs(ArenaSticky.GetSortedProfileNames()) do
                if pname ~= active then
                    others = true
                    local name = pname
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = name
                    info.func = function()
                        local ok, err = ArenaSticky.CopyNotesFromProfileToActive(name)
                        if ok then
                            f.status:SetText("Copied notes from: " .. name)
                        else
                            f.status:SetText(tostring(err or "Could not copy notes."))
                        end
                        DropDownSetText(copyFromDD, "Copy notes from...")
                    end
                    UIDropDownMenu_AddButton(info)
                end
            end
            if not others then
                local emptyInfo = UIDropDownMenu_CreateInfo()
                emptyInfo.text = "(no other profiles)"
                emptyInfo.disabled = true
                emptyInfo.notCheckable = true
                UIDropDownMenu_AddButton(emptyInfo)
            end
        end)
        DropDownSetText(copyFromDD, "Copy notes from...")
        LayoutBottomChrome()
    end

    if not StaticPopupDialogs["ARENASTICKY_EDITOR_DELETE_PROFILE"] then
        StaticPopupDialogs["ARENASTICKY_EDITOR_DELETE_PROFILE"] = {
            text = "Delete this profile?",
            button1 = DELETE or "Delete",
            button2 = CANCEL,
            OnAccept = function()
                local cur = ArenaStickyDB and ArenaStickyDB.activeProfile
                if not cur or not ArenaSticky.DeleteProfile then
                    return
                end
                local ok, err = ArenaSticky.DeleteProfile(cur)
                if ok then
                    if ArenaSticky.editor and ArenaSticky.editor.status then
                        ArenaSticky.editor.status:SetText("Deleted profile: " .. tostring(cur))
                    end
                elseif ArenaSticky.editor and ArenaSticky.editor.status then
                    ArenaSticky.editor.status:SetText(tostring(err or "Could not delete profile."))
                end
                if ArenaSticky.editor and ArenaSticky.editor.RefreshProfileDropdown then
                    ArenaSticky.editor:RefreshProfileDropdown()
                end
                if ArenaSticky.editor and ArenaSticky.editor.RefreshCopyFromDropdown then
                    ArenaSticky.editor:RefreshCopyFromDropdown()
                end
            end,
            timeout = 0,
            whileDead = 1,
            hideOnEscape = 1,
            preferredIndex = 3,
        }
    end

    if not StaticPopupDialogs["ARENASTICKY_EDITOR_NEW_PROFILE"] then
        StaticPopupDialogs["ARENASTICKY_EDITOR_NEW_PROFILE"] = {
            text = "Name for the new profile:",
            button1 = ACCEPT or OKAY,
            button2 = CANCEL,
            hasEditBox = 1,
            maxLetters = 40,
            OnShow = function(self)
                local eb = self.GetEditBox and self:GetEditBox() or _G[self:GetName() .. "EditBox"]
                if eb then
                    eb:SetText("")
                    eb:SetFocus()
                end
            end,
            OnAccept = function(self)
                local eb = self.GetEditBox and self:GetEditBox() or _G[self:GetName() .. "EditBox"]
                local raw = eb and eb:GetText() or ""
                local ok, nameOrErr = ArenaSticky.CreateProfile(raw)
                if ok then
                    ArenaSticky.SwitchProfile(nameOrErr)
                    if ArenaSticky.editor and ArenaSticky.editor.status then
                        ArenaSticky.editor.status:SetText("Created profile: " .. tostring(nameOrErr))
                    end
                    if ArenaSticky.editor and ArenaSticky.editor.RefreshProfileDropdown then
                        ArenaSticky.editor:RefreshProfileDropdown()
                    end
                    if ArenaSticky.editor and ArenaSticky.editor.RefreshCopyFromDropdown then
                        ArenaSticky.editor:RefreshCopyFromDropdown()
                    end
                else
                    if ArenaSticky.editor and ArenaSticky.editor.status then
                        ArenaSticky.editor.status:SetText(tostring(nameOrErr or "Could not create profile."))
                    end
                end
            end,
            EditBoxOnEnterPressed = function(self)
                local p = self:GetParent()
                if p and p.button1 then
                    p.button1:Click()
                end
            end,
            timeout = 0,
            whileDead = 1,
            hideOnEscape = 1,
            preferredIndex = 3,
        }
    end

    f.profileDropdown = profileDD
    f.copyFromDropdown = copyFromDD
    f.RefreshProfileDropdown = RefreshProfileDropdown
    f.RefreshCopyFromDropdown = RefreshCopyFromDropdown

    loadBtn:SetScript("OnClick", function()
        LoadCompIntoEditor(f, f.compInput:GetText())
    end)

    saveBtn:SetScript("OnClick", function()
        local key = (f.compInput:GetText() or ""):upper()
        if key == "" then
            f.status:SetText("Comp key required.")
            return
        end

        local existing = ArenaStickyDB.strategies[key] or {}
        local teamKey = BuildTeamCompKeyFromRows(f)
        local rootHeader = existing.header or {}
        local rootRoles = existing.roles or {}
        ArenaStickyDB.strategies[key] = {
            header = rootHeader,
            roles = rootRoles,
            teamVariants = existing.teamVariants or {},
        }
        local rowCount = (f.selectedBracket == "2v2") and 2 or 3
        local variantRoles = {}
        for i = 1, rowCount do
            local row = f.noteRows[i]
            local editClass = row.classValue
            if editClass and editClass ~= "" then
                variantRoles[editClass] = row.input:GetText() or ""
            end
        end
        local variantHeader = {
            kill = f.killInput:GetText() or "",
            cc = f.ccInput:GetText() or "",
            swap = ((f.selectedBracket == "3v3") and (f.cc2Input:GetText() or "") or ""),
        }
        if teamKey and teamKey ~= "" then
            ArenaStickyDB.strategies[key].teamVariants[teamKey] = {
                header = variantHeader,
                roles = variantRoles,
            }
            -- Keep top-level values usable as a generic fallback.
            ArenaStickyDB.strategies[key].header = ArenaStickyDB.strategies[key].header or {}
            ArenaStickyDB.strategies[key].header.kill = ArenaStickyDB.strategies[key].header.kill or variantHeader.kill
            ArenaStickyDB.strategies[key].header.cc = ArenaStickyDB.strategies[key].header.cc or variantHeader.cc
            ArenaStickyDB.strategies[key].header.swap = ArenaStickyDB.strategies[key].header.swap or variantHeader.swap
            ArenaStickyDB.strategies[key].roles = ArenaStickyDB.strategies[key].roles or {}
            for roleToken, txt in pairs(variantRoles) do
                if ArenaStickyDB.strategies[key].roles[roleToken] == nil then
                    ArenaStickyDB.strategies[key].roles[roleToken] = txt
                end
            end
        else
            ArenaStickyDB.strategies[key].header = variantHeader
            ArenaStickyDB.strategies[key].roles = variantRoles
        end
        ArenaStickyDB.version = (ArenaStickyDB.version or 1) + 1
        ArenaStickyDB.lastUpdated = time()
        if ArenaSticky.SyncActiveProfileMeta then
            ArenaSticky.SyncActiveProfileMeta()
        end
        RefreshCompDropdown(f)
        UIDropDownMenu_SetSelectedName(f.compDropdown, key)
        UIDropDownMenu_SetText(f.compDropdown, ArenaSticky.CompKeyMenuLabel(key))

        f.status:SetText("Saved " .. key .. (teamKey and (" / " .. teamKey) or "") .. " (v" .. ArenaStickyDB.version .. ")")

        if ArenaSticky.currentCompKey == key and ArenaSticky.mainFrame and ArenaSticky.mainFrame:IsShown() then
            local role = ArenaSticky.GetPlayerRoleToken and ArenaSticky.GetPlayerRoleToken() or nil
            local strat = ArenaStickyDB.strategies[key]
            ArenaSticky.headerText:SetText(ArenaSticky.FormatStickyHeaderKillCcForWindow(strat.header.kill or "TBD", strat.header.cc or "TBD", (strat.header and (strat.header.swap or strat.header.cc2)) or ""))
            ArenaSticky.bodyText:SetText((strat.roles and strat.roles[role]) or "No note for your class.")
        end
    end)

    local pushScopeOverlay = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
    pushScopeOverlay:SetFrameStrata("DIALOG")
    pushScopeOverlay:SetFrameLevel((f:GetFrameLevel() or 0) + 96)
    pushScopeOverlay:SetSize(420, 116)
    pushScopeOverlay:SetPoint("CENTER", f, "CENTER", 0, -44)
    pushScopeOverlay:EnableMouse(true)
    pushScopeOverlay:Hide()
    if pushScopeOverlay.SetBackdrop then
        pushScopeOverlay:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 14,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end
    local pushScopeTitle = pushScopeOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pushScopeTitle:SetPoint("TOP", 0, -12)
    pushScopeTitle:SetText("Push which strategies to team?")

    local function DoScopedPush(scope)
        if not ArenaSticky.PushFullSync then return end
        ArenaSticky:PushFullSync(scope)
        pushScopeOverlay:Hide()
        f.status:SetText("Pushed " .. tostring(scope) .. " strategy pack to team.")
    end

    local p2 = CreateFrame("Button", nil, pushScopeOverlay, "UIPanelButtonTemplate")
    p2:SetSize(96, 24)
    p2:SetText("2v2")
    p2:SetPoint("BOTTOMLEFT", 16, 14)
    p2:SetScript("OnClick", function() DoScopedPush("2v2") end)

    local p3 = CreateFrame("Button", nil, pushScopeOverlay, "UIPanelButtonTemplate")
    p3:SetSize(96, 24)
    p3:SetText("3v3")
    p3:SetPoint("LEFT", p2, "RIGHT", 10, 0)
    p3:SetScript("OnClick", function() DoScopedPush("3v3") end)

    local pAll = CreateFrame("Button", nil, pushScopeOverlay, "UIPanelButtonTemplate")
    pAll:SetSize(112, 24)
    pAll:SetText("All (2v2+3v3)")
    pAll:SetPoint("LEFT", p3, "RIGHT", 10, 0)
    pAll:SetScript("OnClick", function() DoScopedPush("all") end)

    local pCancel = CreateFrame("Button", nil, pushScopeOverlay, "UIPanelButtonTemplate")
    pCancel:SetSize(90, 22)
    pCancel:SetText(CANCEL or "Cancel")
    pCancel:SetPoint("TOPRIGHT", -10, -8)
    pCancel:SetScript("OnClick", function() pushScopeOverlay:Hide() end)

    pushBtn:SetScript("OnClick", function()
        pushScopeOverlay:Show()
    end)

    local exportScopeOverlay = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
    exportScopeOverlay:SetFrameStrata("DIALOG")
    exportScopeOverlay:SetFrameLevel((f:GetFrameLevel() or 0) + 95)
    exportScopeOverlay:SetSize(420, 116)
    exportScopeOverlay:SetPoint("CENTER", f, "CENTER", 0, -8)
    exportScopeOverlay:EnableMouse(true)
    exportScopeOverlay:Hide()
    if exportScopeOverlay.SetBackdrop then
        exportScopeOverlay:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 14,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end
    local exportScopeTitle = exportScopeOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    exportScopeTitle:SetPoint("TOP", 0, -12)
    exportScopeTitle:SetText("Export which strategies from active profile?")

    local function DoScopedExport(scope)
        if not ArenaSticky.BuildExportStringActiveProfile then return end
        ArenaSticky.lastExportString = ArenaSticky.BuildExportStringActiveProfile(scope)
        exportScopeOverlay:Hide()
        if StaticPopup_Show then
            StaticPopup_Show("ARENASTICKY_EXPORT_TEXT")
        end
        f.status:SetText("Export " .. tostring(scope) .. ": copy the string from the popup.")
    end

    local ex2 = CreateFrame("Button", nil, exportScopeOverlay, "UIPanelButtonTemplate")
    ex2:SetSize(96, 24)
    ex2:SetText("2v2")
    ex2:SetPoint("BOTTOMLEFT", 16, 14)
    ex2:SetScript("OnClick", function() DoScopedExport("2v2") end)

    local ex3 = CreateFrame("Button", nil, exportScopeOverlay, "UIPanelButtonTemplate")
    ex3:SetSize(96, 24)
    ex3:SetText("3v3")
    ex3:SetPoint("LEFT", ex2, "RIGHT", 10, 0)
    ex3:SetScript("OnClick", function() DoScopedExport("3v3") end)

    local exAll = CreateFrame("Button", nil, exportScopeOverlay, "UIPanelButtonTemplate")
    exAll:SetSize(112, 24)
    exAll:SetText("All (2v2+3v3)")
    exAll:SetPoint("LEFT", ex3, "RIGHT", 10, 0)
    exAll:SetScript("OnClick", function() DoScopedExport("all") end)

    local exCancel = CreateFrame("Button", nil, exportScopeOverlay, "UIPanelButtonTemplate")
    exCancel:SetSize(90, 22)
    exCancel:SetText(CANCEL or "Cancel")
    exCancel:SetPoint("TOPRIGHT", -10, -8)
    exCancel:SetScript("OnClick", function() exportScopeOverlay:Hide() end)

    exportBtn:SetScript("OnClick", function()
        exportScopeOverlay:Show()
    end)

    -- Multiline scroll box: long AS2/ASPACK2 strings + line breaks
    local importOverlay = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
    importOverlay:SetFrameStrata("DIALOG")
    importOverlay:SetFrameLevel((f:GetFrameLevel() or 0) + 100)
    importOverlay:SetSize(660, 228)
    importOverlay:SetPoint("CENTER", f, "CENTER", 0, 20)
    importOverlay:EnableMouse(true)
    importOverlay:Hide()
    if importOverlay.SetBackdrop then
        importOverlay:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 24,
            insets = { left = 8, right = 8, top = 8, bottom = 8 }
        })
    end

    local importOverlayTitle = importOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    importOverlayTitle:SetPoint("TOP", 0, -14)
    importOverlayTitle:SetText("Import — AS3/AS2/ASPACK2 (legacy AS1 / ASPACK1 OK)")

    local importScroll = CreateFrame("ScrollFrame", nil, importOverlay, "UIPanelScrollFrameTemplate")
    importScroll:SetPoint("TOPLEFT", 20, -44)
    importScroll:SetSize(618, 118)

    local importEdit = CreateFrame("EditBox", nil, importScroll)
    importEdit:SetMultiLine(true)
    importEdit:SetMaxLetters(9999999)
    importEdit:SetFontObject("GameFontHighlightSmall")
    importEdit:SetWidth(600)
    importEdit:SetHeight(3000)
    importEdit:SetAutoFocus(false)
    importEdit:SetTextInsets(6, 6, 6, 6)
    importScroll:SetScrollChild(importEdit)

    local importOverlayOk = CreateFrame("Button", nil, importOverlay, "UIPanelButtonTemplate")
    importOverlayOk:SetSize(120, 24)
    importOverlayOk:SetText("Import")
    importOverlayOk:SetPoint("BOTTOMRIGHT", -16, 14)

    local importOverlayCancel = CreateFrame("Button", nil, importOverlay, "UIPanelButtonTemplate")
    importOverlayCancel:SetSize(120, 24)
    importOverlayCancel:SetText(CANCEL or "Cancel")
    importOverlayCancel:SetPoint("RIGHT", importOverlayOk, "LEFT", -10, 0)

    importOverlayOk:SetScript("OnClick", function()
        local t = importEdit:GetText() or ""
        importOverlay:Hide()
        if ArenaSticky.ImportFromPaste then
            local ok, err = ArenaSticky.ImportFromPaste(t)
            if ok then
                print("|cff33ff99ArenaSticky|r: Import finished.")
                f.status:SetText("Import finished.")
            else
                print("|cffff4444ArenaSticky|r: " .. tostring(err))
                f.status:SetText(tostring(err or "Import failed."))
            end
        end
    end)

    importOverlayCancel:SetScript("OnClick", function()
        importOverlay:Hide()
    end)

    importBtn:SetScript("OnClick", function()
        importEdit:SetText("")
        importOverlay:Show()
        importEdit:SetFocus()
        f.status:SetText("Paste in the box, then Import (long strings & line breaks OK).")
    end)

    closeBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    f:SetScript("OnHide", function()
        pushScopeOverlay:Hide()
        exportScopeOverlay:Hide()
        importOverlay:Hide()
    end)

    f:SetScript("OnShow", function()
        RefreshProfileDropdown()
        RefreshCopyFromDropdown()
    end)

    f.RunRefreshFromProfileChange = function()
        RefreshCompDropdown(f)
        local k = (f.compInput:GetText() or ""):upper()
        if k ~= "" then
            LoadCompIntoEditor(f, k)
        end
    end

    ArenaSticky.editor = f
    RefreshCompDropdown(f)
    RefreshProfileDropdown()
    RefreshCopyFromDropdown()
    return f
end

function ArenaSticky.EditorRefreshFromProfile()
    local fr = ArenaSticky.editor
    if not fr then
        return
    end
    if fr.RunRefreshFromProfileChange then
        fr:RunRefreshFromProfileChange()
    end
    if fr.RefreshProfileDropdown then
        fr:RefreshProfileDropdown()
    end
    if fr.RefreshCopyFromDropdown then
        fr:RefreshCopyFromDropdown()
    end
end

function ArenaSticky.OpenEditor()
    local f = EnsureEditor()

    local lastKey = ArenaSticky.currentCompKey
    if (not lastKey or lastKey == "") and ArenaStickyDB and ArenaStickyDB.lastPlayedCompKey then
        lastKey = ArenaStickyDB.lastPlayedCompKey
    end
    if type(lastKey) == "string" then
        lastKey = lastKey:upper():match("^%s*(.-)%s*$")
    end
    if lastKey == "" then
        lastKey = nil
    end

    if lastKey then
        LoadCompIntoEditor(f, lastKey)
    end

    RefreshCompDropdown(f)

    if lastKey and f.compDropdown then
        UIDropDownMenu_SetSelectedName(f.compDropdown, lastKey)
        UIDropDownMenu_SetText(f.compDropdown, ArenaSticky.CompKeyMenuLabel(lastKey))
    end

    -- Class note rows = your team (player + party), not enemy comp tokens from the key above.
    if f.noteRows and f.noteRows[1] then
        local playerToken = GetPlayerDefaultNoteToken() or "DISC"
        f.noteRows[1].classValue = playerToken
        UIDropDownMenu_SetSelectedName(f.noteRows[1].dropdown, playerToken)
        UIDropDownMenu_SetText(f.noteRows[1].dropdown, DropdownSpecLabel(playerToken))
        if f.noteRows[2] then
            local party1Token = GetPartyDefaultNoteToken("party1") or f.compSlot2Value
            f.noteRows[2].classValue = party1Token
            UIDropDownMenu_SetSelectedName(f.noteRows[2].dropdown, party1Token)
            UIDropDownMenu_SetText(f.noteRows[2].dropdown, DropdownSpecLabel(party1Token))
        end
        if f.noteRows[3] then
            local party2Token = GetPartyDefaultNoteToken("party2") or f.compSlot3Value
            f.noteRows[3].classValue = party2Token
            UIDropDownMenu_SetSelectedName(f.noteRows[3].dropdown, party2Token)
            UIDropDownMenu_SetText(f.noteRows[3].dropdown, DropdownSpecLabel(party2Token))
        end
        if f.UpdateNoteRowsFromComp then
            f:UpdateNoteRowsFromComp()
        end
    end
    f:Show()
end