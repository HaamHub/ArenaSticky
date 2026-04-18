local ADDON_NAME = ...
local PREFIX = "ARENASTICKY1"

ArenaSticky = ArenaSticky or {}
ArenaSticky.frame = CreateFrame("Frame")
ArenaSticky.enemyClasses = {}
ArenaSticky.currentCompKey = nil
ArenaSticky.lastPrintedCompKey = nil
ArenaSticky.lastDetectBurst = nil
ArenaSticky.specByGuid = ArenaSticky.specByGuid or {}
ArenaSticky.guidToUnit = ArenaSticky.guidToUnit or {}
-- If true, /as hide will not be overridden until next match or /as show
ArenaSticky.suppressAutoShow = false

local UpdateNotesForComp
local ApplyStickyMinimizedLayout

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

-- Spec/class icons (Interface\\Icons) for sticky header + editor dropdowns
ArenaSticky.SPEC_ICONS = {
    WARRIOR = "Interface\\Icons\\Ability_Warrior_DefensiveStance",
    HUNTER = "Interface\\Icons\\Ability_Hunter_SteadyShot",
    ROGUE = "Interface\\Icons\\Ability_BackStab",
    MAGE = "Interface\\Icons\\Spell_Frost_FrostBolt02",
    WARLOCK = "Interface\\Icons\\Spell_Shadow_RainOfFire",
    RET = "Interface\\Icons\\Spell_Holy_CrusaderStrike",
    HPAL = "Interface\\Icons\\Spell_Holy_HolyBolt",
    RSHAM = "Interface\\Icons\\Spell_Nature_HealingWaveLesser",
    ELE = "Interface\\Icons\\Spell_Nature_Lightning",
    ENH = "Interface\\Icons\\Spell_Shaman_Stormstrike",
    DISC = "Interface\\Icons\\Spell_Holy_PowerWordShield",
    SHADOW = "Interface\\Icons\\Spell_Shadow_ShadowWordPain",
    RESTO = "Interface\\Icons\\Spell_Nature_HealingTouch",
    BOOMY = "Interface\\Icons\\Spell_Nature_StarFall",
    FERAL = "Interface\\Icons\\Ability_Druid_CatForm",
    PALADIN = "Interface\\Icons\\Spell_Holy_SealOfMight",
    SHAMAN = "Interface\\Icons\\Spell_Nature_BloodLust",
    PRIEST = "Interface\\Icons\\INV_Staff_32",
    DRUID = "Interface\\Icons\\Ability_Druid_Maul",
}

function ArenaSticky.SpecIconTexture(token)
    if not token then return nil end
    return ArenaSticky.SPEC_ICONS[string.upper(tostring(token))]
end

function ArenaSticky.SpecIconInline(token, size)
    size = size or 16
    local tex = ArenaSticky.SpecIconTexture(token)
    if not tex then return "" end
    return "|T" .. tex .. ":" .. size .. ":" .. size .. "|t"
end

--- Comp key as menu row: icon+token per segment (space-separated).
function ArenaSticky.CompKeyMenuLabel(key)
    if not key or key == "" then return "" end
    local segs = {}
    for p in string.gmatch(key, "[^-]+") do
        local tok = string.upper(p)
        table.insert(segs, ArenaSticky.SpecIconInline(tok, 16) .. " " .. tok)
    end
    return table.concat(segs, " ")
end

--- Guess spec token from free-text kill/cc lines for header icons.
function ArenaSticky.BestSpecTokenForNoteText(str)
    if not str or str == "" or str == "TBD" then return nil end
    local l = string.lower(str)
    local ordered = {
        { "resto druid", "RESTO" }, { "resto sham", "RSHAM" }, { "resto shaman", "RSHAM" }, { "rsham", "RSHAM" },
        { "feral druid", "FERAL" }, { "feral", "FERAL" },
        { "balance druid", "BOOMY" }, { "boomkin", "BOOMY" }, { "moonkin", "BOOMY" }, { "balance", "BOOMY" },
        { "shadow priest", "SHADOW" },
        { "disc priest", "DISC" }, { "discipline", "DISC" }, { "disc", "DISC" },
        { "elemental", "ELE" }, { "enhancement", "ENH" },
        { "holy paladin", "HPAL" }, { "holy pal", "HPAL" },
        { "ret paladin", "RET" }, { "retribution", "RET" },
        { "warlock", "WARLOCK" }, { "mage", "MAGE" }, { "rogue", "ROGUE" }, { "hunter", "HUNTER" },
        { "priest", "DISC" }, { "druid", "RESTO" }, { "paladin", "HPAL" }, { "shaman", "RSHAM" },
        { "warrior", "WARRIOR" }, { "arms", "WARRIOR" }, { "fury", "WARRIOR" },
    }
    for _, pair in ipairs(ordered) do
        if string.find(l, pair[1], 1, true) then
            return pair[2]
        end
    end
    if string.find(l, "shadow", 1, true) and string.find(l, "priest", 1, true) then return "SHADOW" end
    if string.find(l, "holy", 1, true) then return "HPAL" end
    if string.find(l, "ret", 1, true) then return "RET" end
    for _, tok in ipairs(ROLE_TOKENS) do
        if string.find(l, string.lower(tok), 1, true) then
            return tok
        end
    end
    return nil
end

function ArenaSticky.FormatStickyHeaderKillCc(killText, ccText)
    killText = killText or "TBD"
    ccText = ccText or "TBD"
    local kt = ArenaSticky.BestSpecTokenForNoteText(killText)
    local ct = ArenaSticky.BestSpecTokenForNoteText(ccText)
    local ks = (kt and (ArenaSticky.SpecIconInline(kt, 18) .. " ") or "") .. killText
    local cs = (ct and (ArenaSticky.SpecIconInline(ct, 18) .. " ") or "") .. ccText
    return ("Kill: %s  |  CC: %s"):format(ks, cs)
end

--- Minimized sticky: labels + spec icons only (no kill/cc body text).
function ArenaSticky.FormatStickyHeaderKillCcCompact(killText, ccText)
    killText = killText or "TBD"
    ccText = ccText or "TBD"
    local kt = ArenaSticky.BestSpecTokenForNoteText(killText)
    local ct = ArenaSticky.BestSpecTokenForNoteText(ccText)
    local function iconOrMark(tok)
        if tok and ArenaSticky.SpecIconTexture(tok) then
            return ArenaSticky.SpecIconInline(tok, 20)
        end
        return "|cff888888?|r"
    end
    return ("Kill: %s  |  CC: %s"):format(iconOrMark(kt), iconOrMark(ct))
end

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
    -- Double healer + warrior (e.g. resto druid / rsham / arms)
    ["RESTO-RSHAM-WARRIOR"] = {
        header = { kill = "Warrior", cc = "Swap healers" },
        roles = {
            DISC = "Long game. Fear whichever healer is exposed on go. Dispel roots/sheep.",
            ROGUE = "Train warrior. Swap to sham if druid is CC’d. Kidney on healer CC.",
            MAGE = "Peel warrior. Sheep druid or sham on kill setups. CS cyclone/heals.",
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
    -- 2v2 Shadow + Rogue (detected as SHADOW / ROGUE tokens)
    ["ROGUE-SHADOW"] = {
        header = { kill = "Rogue or Shadow", cc = "other DPS" },
        roles = {
            DISC = "Respect opener. Fear shadow on kill setups. Dispel VT/sheep smart.",
            SHADOW = "Shadow mirror: silence/fear timing. PI if your rogue connects.",
            ROGUE = "Peel rogue first; swap priest if rogue overextends. Blind after trinket.",
            MAGE = "Slow rogue. Sheep shadow on full DR windows. CS fear/VT.",
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
        height = 218,
        scale = 1.0,
        alpha = 0.95,
    }

    -- Shared strategy pack (editable + synced)
    ArenaStickyDB.strategies = MergeMissingStrategies(ArenaStickyDB.strategies, DEFAULT_STRATEGIES)
end

--- Full vs compact Kill/CC line depending on minimized state (used by sticky + editor).
function ArenaSticky.FormatStickyHeaderKillCcForWindow(killText, ccText)
    EnsureDB()
    if ArenaStickyDB.window and ArenaStickyDB.window.minimized then
        return ArenaSticky.FormatStickyHeaderKillCcCompact(killText, ccText)
    end
    return ArenaSticky.FormatStickyHeaderKillCc(killText, ccText)
end

local function PickRandomStrategyCompKey()
    EnsureDB()
    local keys = {}
    for k, v in pairs(ArenaStickyDB.strategies or {}) do
        if type(k) == "string" and k ~= "" and type(v) == "table" then
            table.insert(keys, k)
        end
    end
    if #keys == 0 then
        return nil
    end
    table.sort(keys)
    -- WoW often omits math.randomseed (nil); math.random still works with built-in PRNG.
    local idx
    if math.random then
        idx = math.random(1, #keys)
    else
        idx = (math.floor((GetTime() or 0) * 1000000) % #keys) + 1
    end
    return keys[idx]
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
            local n = tonumber(points) or 0
            if n > bestPoints then
                bestPoints = n
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

--- Spec tokens must match unit class. Otherwise we mis-detect allied buffs/debuffs
--- (e.g. Earth Shield on a Warrior from an enemy RSham reads as RSHAM on the Warrior).
local function SpecTokenMatchesClass(token, class)
    if not token or not class then return false end
    if token == "RSHAM" or token == "ELE" or token == "ENH" then return class == "SHAMAN" end
    if token == "RET" or token == "HPAL" then return class == "PALADIN" end
    if token == "DISC" or token == "SHADOW" then return class == "PRIEST" end
    if token == "RESTO" or token == "BOOMY" or token == "FERAL" then return class == "DRUID" end
    if token == "WARRIOR" or token == "HUNTER" or token == "ROGUE" or token == "MAGE" or token == "WARLOCK" then
        return token == class
    end
    return true
end

local function DetectSpecFromAuras(unit)
    if not UnitExists(unit) then return nil end
    local _, class = UnitClass(unit)
    for i = 1, 40 do
        local name = UnitBuff(unit, i)
        if not name then break end
        local token = AURA_SPEC_TOKEN[name]
        if token and SpecTokenMatchesClass(token, class) then
            return token
        end
    end
    return nil
end

local function GetEnemyToken(unit)
    local _, class = UnitClass(unit)
    if not class then return nil end
    local guid = UnitGUID(unit)
    if guid and ArenaSticky.specByGuid[guid] then
        local cached = ArenaSticky.specByGuid[guid]
        if SpecTokenMatchesClass(cached, class) then
            return cached
        end
        ArenaSticky.specByGuid[guid] = nil
    end
    local auraToken = DetectSpecFromAuras(unit)
    if guid and auraToken then
        ArenaSticky.specByGuid[guid] = auraToken
        return auraToken
    end
    return DEFAULT_SPEC_TOKEN[class] or class
end

--- MotW / LotP on visible enemies help guess druid spec for stealthed teammates.
local function ScanUnitWildAndLotpHints(unit)
    if not UnitExists(unit) then return false, false end
    local hasMotw, hasLotp = false, false
    local i = 1
    while i <= 40 do
        local name, _, _, _, _, _, _, _, _, _, spellId
        if UnitAura then
            name, _, _, _, _, _, _, _, _, _, spellId = UnitAura(unit, i, "HELPFUL")
        else
            name = UnitBuff(unit, i)
        end
        if not name then break end
        local ln = string.lower(name)
        if ln:find("mark of the wild", 1, true) or ln:find("gift of the wild", 1, true) then
            hasMotw = true
        end
        if ln:find("leader of the pack", 1, true) then
            hasLotp = true
        end
        if spellId then
            if spellId == 24932 then
                hasLotp = true
            end
            if spellId == 48469 or spellId == 48470 or spellId == 26990 or spellId == 21849 or spellId == 21850
                or spellId == 1126 or spellId == 5232 or spellId == 6756 or spellId == 5234 or spellId == 8907 or spellId == 9884 or spellId == 9885 then
                hasMotw = true
            end
        end
        i = i + 1
    end
    return hasMotw, hasLotp
end

local function ApplyStealthInference(slots, teamMotw, teamLotp)
    local unkIdx = {}
    for i, s in ipairs(slots) do
        if not s.known then
            unkIdx[#unkIdx + 1] = i
        end
    end
    local nU = #unkIdx
    if nU == 0 then
        return
    end

    local feralHint = teamMotw and teamLotp
    local restoHint = teamMotw and not teamLotp

    if nU == 1 then
        local s = slots[unkIdx[1]]
        if feralHint then
            s.token = "FERAL"
        elseif restoHint then
            s.token = "RESTO"
        else
            s.token = "ROGUE"
        end
    elseif nU == 2 then
        local a, b = unkIdx[1], unkIdx[2]
        if feralHint then
            slots[a].token, slots[b].token = "ROGUE", "FERAL"
        elseif restoHint then
            slots[a].token, slots[b].token = "ROGUE", "RESTO"
        else
            slots[a].token, slots[b].token = "ROGUE", "RESTO"
        end
    else
        for _, idx in ipairs(unkIdx) do
            slots[idx].token = "ROGUE"
        end
        if feralHint then
            slots[unkIdx[1]].token = "FERAL"
        elseif teamMotw then
            slots[unkIdx[1]].token = "RESTO"
        else
            for _, idx in ipairs(unkIdx) do
                if select(1, ScanUnitWildAndLotpHints(slots[idx].unit)) then
                    slots[idx].token = "RESTO"
                    break
                end
            end
        end
    end
end

--- Single source for arena enemy tokens (stealth inference + normal detection).
local function CollectArenaEnemyEntries()
    local slots = {}
    for ai = 1, 3 do
        local unit = "arena" .. ai
        if UnitExists(unit) then
            local _, class = UnitClass(unit)
            local known = class and class ~= "" and string.upper(tostring(class)) ~= "UNKNOWN"
            local token
            if known then
                token = GetEnemyToken(unit)
                if not token then
                    token = DEFAULT_SPEC_TOKEN[class] or class
                end
            end
            slots[#slots + 1] = {
                unit = unit,
                known = known,
                class = class,
                token = token,
            }
        end
    end

    local teamMotw, teamLotp = false, false
    for _, s in ipairs(slots) do
        if s.known then
            local m, l = ScanUnitWildAndLotpHints(s.unit)
            teamMotw = teamMotw or m
            teamLotp = teamLotp or l
        end
    end

    ApplyStealthInference(slots, teamMotw, teamLotp)

    local out = {}
    for _, s in ipairs(slots) do
        local t = s.token
        if not t or t == "UNKNOWN" then
            t = "ROGUE"
        end
        out[#out + 1] = { unit = s.unit, token = t }
    end
    return out
end

local function CollectArenaEnemyTokens()
    local entries = CollectArenaEnemyEntries()
    local t = {}
    for i = 1, #entries do
        t[i] = entries[i].token
    end
    return t
end

local function InArenaWithOpponents()
    if IsActiveBattlefieldArena and IsActiveBattlefieldArena() then
        return true
    end
    -- Some clients report false during gates / prep; arena units still exist.
    for i = 1, 3 do
        if UnitExists("arena" .. i) then return true end
    end
    return false
end

local function UpdateEnemyDetectText()
    if not ArenaSticky.detectText then return end
    if not InArenaWithOpponents() then
        ArenaSticky.detectText:SetText("Detected: —")
        return
    end
    local parts = {}
    local entries = CollectArenaEnemyEntries()
    for _, e in ipairs(entries) do
        local name = UnitName(e.unit) or "?"
        table.insert(parts, ("%s (%s)"):format(name, e.token))
    end
    if #parts == 0 then
        ArenaSticky.detectText:SetText("Detected: waiting for opponents…")
    else
        ArenaSticky.detectText:SetText("Detected: " .. table.concat(parts, " · "))
    end
end

local function CreateMainFrame()
    if ArenaSticky.mainFrame then return end

    local f = CreateFrame("Frame", "ArenaStickyMainFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    f:SetSize(320, 218)
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
        EnsureDB()
        local _, _, _, x, y = self:GetPoint()
        ArenaStickyDB.window.x = x
        ArenaStickyDB.window.y = y
        if not ArenaStickyDB.window.minimized then
            ArenaStickyDB.window.width = self:GetWidth()
            ArenaStickyDB.window.height = self:GetHeight()
        end
    end)
    f:SetScript("OnSizeChanged", function(self, width, height)
        EnsureDB()
        if ArenaStickyDB.window.minimized then
            return
        end
        width = math.max(width or 320, 260)
        height = math.max(height or 218, 140)
        ArenaStickyDB.window.width = width
        ArenaStickyDB.window.height = height
        if ArenaSticky.detectText then
            ArenaSticky.detectText:SetWidth(width - 25)
        end
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

    local detect = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detect:SetPoint("TOPLEFT", 12, -32)
    detect:SetJustifyH("LEFT")
    detect:SetJustifyV("TOP")
    detect:SetWidth(295)
    detect:SetNonSpaceWrap(true)
    detect:SetText("Detected: —")

    local header = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", 12, -54)
    header:SetJustifyH("LEFT")
    header:SetWidth(295)
    header:SetText(ArenaSticky.FormatStickyHeaderKillCc("?", "?"))

    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", 12, -80)
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
            EnsureDB()
            if not ArenaStickyDB.window.minimized then
                ArenaStickyDB.window.width = f:GetWidth()
                ArenaStickyDB.window.height = f:GetHeight()
            end
        end)
    else
        footer:SetText("Type /as edit to modify.")
    end

    local minBtn = CreateFrame("Button", "ArenaStickyMinimizeButton", f)
    minBtn:SetSize(22, 22)
    minBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)
    minBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-SmallerButton-Up")
    minBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-SmallerButton-Down")
    minBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-SmallerButton-Highlight")
    minBtn:SetScript("OnClick", function()
        EnsureDB()
        local cfg = ArenaStickyDB.window
        if cfg.minimized then
            cfg.minimized = false
            local w = cfg.widthBeforeMin or cfg.width or 320
            local h = cfg.heightBeforeMin or cfg.height or 218
            cfg.width = w
            cfg.height = h
            f:SetSize(w, h)
        else
            cfg.widthBeforeMin = f:GetWidth()
            cfg.heightBeforeMin = f:GetHeight()
            cfg.width = cfg.widthBeforeMin
            cfg.height = cfg.heightBeforeMin
            cfg.minimized = true
            f:SetSize(200, 52)
        end
        ApplyStickyMinimizedLayout()
        if ArenaSticky.currentCompKey then
            UpdateNotesForComp(ArenaSticky.currentCompKey, true)
        else
            header:SetText(ArenaSticky.FormatStickyHeaderKillCcForWindow("TBD", "TBD"))
        end
    end)

    ArenaSticky.mainFrame = f
    ArenaSticky.titleText = title
    ArenaSticky.detectText = detect
    ArenaSticky.headerText = header
    ArenaSticky.bodyText = body
    ArenaSticky.footerText = footer
    ArenaSticky.resizeHandle = resize
    ArenaSticky.minimizeButton = minBtn
end

--- Show compact one-line mode vs full sticky (title, detect, notes, footer).
ApplyStickyMinimizedLayout = function()
    EnsureDB()
    local cfg = ArenaStickyDB.window
    if cfg.minimized == nil then
        cfg.minimized = false
    end
    local mini = cfg.minimized
    if not ArenaSticky.mainFrame then
        return
    end
    local f = ArenaSticky.mainFrame
    local minBtn = ArenaSticky.minimizeButton

    if mini then
        f:SetSize(200, 52)
        if ArenaSticky.titleText then ArenaSticky.titleText:Hide() end
        if ArenaSticky.detectText then ArenaSticky.detectText:Hide() end
        if ArenaSticky.bodyText then ArenaSticky.bodyText:Hide() end
        if ArenaSticky.footerText then ArenaSticky.footerText:Hide() end
        if ArenaSticky.resizeHandle then ArenaSticky.resizeHandle:Hide() end
        if ArenaSticky.headerText then
            ArenaSticky.headerText:ClearAllPoints()
            ArenaSticky.headerText:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -12)
            ArenaSticky.headerText:SetWidth(math.max(f:GetWidth() - 36, 80))
        end
        if minBtn then
            minBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-BiggerButton-Up")
            minBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-BiggerButton-Down")
            minBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-BiggerButton-Highlight")
        end
    else
        if ArenaSticky.titleText then ArenaSticky.titleText:Show() end
        if ArenaSticky.detectText then ArenaSticky.detectText:Show() end
        if ArenaSticky.bodyText then ArenaSticky.bodyText:Show() end
        if ArenaSticky.footerText then ArenaSticky.footerText:Show() end
        if ArenaSticky.resizeHandle then ArenaSticky.resizeHandle:Show() end
        if ArenaSticky.headerText then
            ArenaSticky.headerText:ClearAllPoints()
            ArenaSticky.headerText:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -54)
            local w = f:GetWidth() - 25
            ArenaSticky.headerText:SetWidth(math.max(w, 80))
        end
        if ArenaSticky.bodyText then
            ArenaSticky.bodyText:ClearAllPoints()
            ArenaSticky.bodyText:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -80)
            ArenaSticky.bodyText:SetWidth(math.max(f:GetWidth() - 25, 80))
        end
        if minBtn then
            minBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-SmallerButton-Up")
            minBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-SmallerButton-Down")
            minBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-SmallerButton-Highlight")
        end
    end
end

local function ApplyWindowSettings()
    if not ArenaSticky.mainFrame then return end
    EnsureDB()
    local cfg = ArenaStickyDB.window
    ArenaSticky.mainFrame:SetScale(cfg.scale or 1.0)
    ArenaSticky.mainFrame:SetAlpha(cfg.alpha or 0.95)
    ArenaSticky.mainFrame:SetSize(cfg.width or 320, cfg.height or 218)
    ArenaSticky.mainFrame:ClearAllPoints()
    ArenaSticky.mainFrame:SetPoint("CENTER", UIParent, "CENTER", cfg.x or 0, cfg.y or 0)
    if ApplyStickyMinimizedLayout then
        ApplyStickyMinimizedLayout()
    end
end

-- Must be defined before any function that calls it (Lua locals are not visible above their declaration).
local function EnsureInitialized()
    EnsureDB()
    if not ArenaSticky.mainFrame then
        CreateMainFrame()
        ApplyWindowSettings()
    end
end

local function ParseEnemyCompFromArenaUnits()
    wipe(ArenaSticky.enemyClasses)
    local tokens = CollectArenaEnemyTokens()
    if #tokens < 2 then
        return nil
    end
    for _, t in ipairs(tokens) do
        table.insert(ArenaSticky.enemyClasses, t)
    end
    return NormalizeCompKey(ArenaSticky.enemyClasses)
end

--- Paladin defaults to HPAL before we see casts; strategy DB often keys melee comps as RET.
local function CompKeyWithTokenSwap(compKey, fromToken, toToken)
    if not compKey then return nil end
    local parts = {}
    for p in compKey:gmatch("[^-]+") do
        if p == fromToken then
            table.insert(parts, toToken)
        else
            table.insert(parts, p)
        end
    end
    return NormalizeCompKey(parts)
end

local function FindStrategyForCompKey(compKey)
    if not compKey or compKey == "" then return nil end
    EnsureDB()
    local strat = ArenaStickyDB.strategies[compKey]
    if strat then return strat end
    local legacyKey = ToLegacyCompKey(compKey)
    if legacyKey and legacyKey ~= compKey then
        strat = ArenaStickyDB.strategies[legacyKey]
        if strat then return strat end
    end
    -- HPAL vs RET; DISC vs SHADOW (defaults / aura detection vs saved RMP-style keys)
    for _, pair in ipairs({
        { "HPAL", "RET" }, { "RET", "HPAL" },
        { "DISC", "SHADOW" }, { "SHADOW", "DISC" },
    }) do
        local alt = CompKeyWithTokenSwap(compKey, pair[1], pair[2])
        if alt then
            strat = ArenaStickyDB.strategies[alt]
            if strat then return strat end
        end
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

UpdateNotesForComp = function(compKey, allowFallbackRole, forcedRole)
    if not ArenaSticky.mainFrame or not ArenaSticky.headerText or not ArenaSticky.bodyText then
        EnsureInitialized()
    end
    if not ArenaSticky.headerText or not ArenaSticky.bodyText then
        return
    end
    ArenaSticky.currentCompKey = compKey
    local role = forcedRole or GetMyRole()

    local detectedKey = compKey
    local strat = FindStrategyForCompKey(compKey)
    if not strat then
        ArenaSticky.headerText:SetText(ArenaSticky.FormatStickyHeaderKillCcForWindow("TBD", "TBD"))
        ArenaSticky.bodyText:SetText("No strategy saved for: " .. tostring(detectedKey) .. "\nUse /as edit to add one.")
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

    ArenaSticky.headerText:SetText(ArenaSticky.FormatStickyHeaderKillCcForWindow(kill, cc))
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
                UpdateNotesForComp(ArenaSticky.currentCompKey, true)
            end
        end
    elseif cmd == "FULLSYNC" then
        -- A teammate pinged for data, push ours.
        ArenaSticky:PushFullSync()
    end
end

local function TryDetectAndUpdate()
    UpdateEnemyDetectText()
    local comp = ParseEnemyCompFromArenaUnits()
    if comp then
        if comp ~= ArenaSticky.lastPrintedCompKey then
            ArenaSticky.lastPrintedCompKey = comp
            print("|cff33ff99ArenaSticky|r: Enemy comp: " .. comp)
        end
        UpdateNotesForComp(comp, true)
        -- Unlike /as test, arena detection never called Show(); sticky stayed hidden after load.
        if InArenaWithOpponents() and (ArenaStickyDB.autoShowInArena ~= false) and not ArenaSticky.suppressAutoShow then
            EnsureInitialized()
            ArenaSticky.mainFrame:Show()
        end
    end
end

-- 2v2: arena2 often appears later than arena1; events can fire before both UnitExists.
local function ScheduleArenaDetectBurst()
    local t = GetTime()
    if ArenaSticky.lastDetectBurst and (t - ArenaSticky.lastDetectBurst) < 0.5 then
        return
    end
    ArenaSticky.lastDetectBurst = t
    local delays = { 0.05, 0.2, 0.5, 1.0, 2.0, 4.0, 8.0 }
    for _, d in ipairs(delays) do
        C_Timer.After(d, function()
            if InArenaWithOpponents() then
                TryDetectAndUpdate()
            end
        end)
    end
end

local arenaPollAccum = 0
local function EnsureArenaPollFrame()
    if ArenaSticky.pollFrame then return ArenaSticky.pollFrame end
    local f = CreateFrame("Frame")
    f:Hide()
    f:SetScript("OnUpdate", function(self, elapsed)
        if not InArenaWithOpponents() then
            arenaPollAccum = 0
            self:Hide()
            return
        end
        arenaPollAccum = arenaPollAccum + elapsed
        if arenaPollAccum >= 1.0 then
            arenaPollAccum = 0
            TryDetectAndUpdate()
        end
    end)
    ArenaSticky.pollFrame = f
    return f
end

local function StartArenaMatchupPolling()
    arenaPollAccum = 0
    EnsureArenaPollFrame():Show()
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
        local _, class = UnitClass(unit)
        if SpecTokenMatchesClass(token, class) then
            ArenaSticky.specByGuid[sourceGUID] = token
            TryDetectAndUpdate()
        end
    end
end

local function PrintArenaDebug()
    EnsureInitialized()
    print("|cff33ff99ArenaSticky|r debug:")
    print("  InArenaWithOpponents: " .. tostring(InArenaWithOpponents()))
    print("  IsActiveBattlefieldArena: " .. tostring(IsActiveBattlefieldArena and IsActiveBattlefieldArena() or nil))
    local numOpp = GetNumArenaOpponents and GetNumArenaOpponents() or "nil"
    print("  GetNumArenaOpponents: " .. tostring(numOpp))
    for i = 1, 3 do
        local u = "arena" .. i
        if UnitExists(u) then
            local _, c = UnitClass(u)
            local t = GetEnemyToken(u)
            print(("  %s: name=%s class=%s token=%s"):format(u, tostring(UnitName(u)), tostring(c), tostring(t)))
        else
            print("  " .. u .. ": (no unit)")
        end
    end
    EnsureDB()
    local comp = ParseEnemyCompFromArenaUnits()
    print("  Parsed comp key: " .. tostring(comp))
    if comp then
        local has = ArenaStickyDB.strategies[comp] and "yes" or "no"
        print("  Direct strategy match: " .. has)
        local alt = CompKeyWithTokenSwap(comp, "SHADOW", "DISC")
        if alt and alt ~= comp then
            print("  DISC/SHADOW alias key: " .. tostring(alt) .. " → " .. (ArenaStickyDB.strategies[alt] and "has strat" or "no strat"))
        end
        local strat = FindStrategyForCompKey(comp)
        print("  FindStrategyForCompKey (after aliases): " .. (strat and "found" or "nil"))
    end
end

local function PrintHelp()
    print("|cff33ff99ArenaSticky|r commands:")
    print("  /as help   (also: /arenasticky, /asticky — if /as is used by another addon)")
    print("  /asdebug   (prints diagnostics even when /as is taken)")
    print("  /as hide   (stops auto-opening the sticky until next match or /as show)")
    print("  /as test        (random comp)   |   /as test rmp   (named alias)")
    print("  /as debug")
    print("  /as edit | show | hide | resetwindow | sync | request")
end

local function ResetWindow()
    EnsureDB()
    ArenaStickyDB.window.x = 0
    ArenaStickyDB.window.y = 0
    ArenaStickyDB.window.width = 320
    ArenaStickyDB.window.height = 218
    ArenaStickyDB.window.scale = 1.0
    ArenaStickyDB.window.alpha = 0.95
    ArenaStickyDB.window.minimized = false
    ArenaStickyDB.window.widthBeforeMin = nil
    ArenaStickyDB.window.heightBeforeMin = nil
    EnsureInitialized()
    ApplyWindowSettings()
    ArenaSticky.mainFrame:Show()
end

local function ExecuteAsTest(alias, rawMsg, tokenA, tokenB)
    print("|cff33ff99ArenaSticky|r [test] ---------- begin ----------")
    print("|cff33ff99ArenaSticky|r [test] slash rawMsg=[" .. tostring(rawMsg) .. "] tokenA=[" .. tostring(tokenA) .. "] tokenB=[" .. tostring(tokenB) .. "]")
    print("|cff33ff99ArenaSticky|r [test] alias after trim=[" .. tostring(alias) .. "] len=" .. tostring(alias and #alias or 0))
    local ok, err = pcall(function()
        print("|cff33ff99ArenaSticky|r [test] (1) EnsureInitialized")
        EnsureInitialized()
        if not ArenaSticky.mainFrame then
            error("mainFrame still nil after EnsureInitialized")
        end
        print("|cff33ff99ArenaSticky|r [test] (2) EnsureDB / strategy count")
        EnsureDB()
        local stratCount = 0
        for _ in pairs(ArenaStickyDB.strategies or {}) do
            stratCount = stratCount + 1
        end
        print("|cff33ff99ArenaSticky|r [test] (2) strategies in DB: " .. tostring(stratCount))
        local compKey
        if alias == nil or alias == "" then
            print("|cff33ff99ArenaSticky|r [test] (3) random comp (PickRandomStrategyCompKey)")
            compKey = PickRandomStrategyCompKey()
            print("|cff33ff99ArenaSticky|r [test] (3) result key=" .. tostring(compKey))
            if not compKey then
                print("|cffff8800ArenaSticky|r [test] no keys — check SavedVariables / merge")
                return
            end
        else
            print("|cff33ff99ArenaSticky|r [test] (3) ResolveTestAlias(" .. tostring(alias) .. ")")
            compKey = ResolveTestAlias(alias)
            print("|cff33ff99ArenaSticky|r [test] (3) result key=" .. tostring(compKey))
            if not compKey then
                print("|cffff8800ArenaSticky|r [test] unknown alias")
                return
            end
        end
        print("|cff33ff99ArenaSticky|r [test] (4) UpdateNotesForComp(" .. tostring(compKey) .. ")")
        UpdateNotesForComp(compKey, true)
        print("|cff33ff99ArenaSticky|r [test] (5) mainFrame:Show()")
        ArenaSticky.mainFrame:Show()
        print("|cff33ff99ArenaSticky|r [test] ---------- success ----------")
    end)
    if not ok then
        print("|cffff4444ArenaSticky|r [test] LUA ERROR: " .. tostring(err))
        print("|cffff4444ArenaSticky|r [test] Turn on script errors (/console scriptErrors 1) for stack.")
    end
end

SLASH_ARENASTICKY1 = "/as"
SLASH_ARENASTICKY2 = "/arenasticky"
SLASH_ARENASTICKY3 = "/asticky"
SlashCmdList["ARENASTICKY"] = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$") or ""
    local lower = msg:lower()
    local a, b = lower:match("^(%S+)%s*(.*)$")

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
        ArenaSticky.suppressAutoShow = true
        ArenaSticky.mainFrame:Hide()
        return
    end

    if a == "show" then
        EnsureInitialized()
        ArenaSticky.suppressAutoShow = false
        ArenaSticky.mainFrame:Show()
        TryDetectAndUpdate()
        if InArenaWithOpponents() then
            ScheduleArenaDetectBurst()
            StartArenaMatchupPolling()
        end
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
        local alias = (b or ""):gsub("^%s+", ""):gsub("%s+$", "")
        ExecuteAsTest(alias, msg, a, b)
        return
    end

    if a == "debug" then
        local ok, err = pcall(PrintArenaDebug)
        if not ok then
            print("|cffff4444ArenaSticky|r debug failed: " .. tostring(err))
        end
        return
    end

    if a == "help" then
        PrintHelp()
        return
    end

    PrintHelp()
end

-- Dedicated command: always reaches this addon (another mod may own /as).
SLASH_ARENASTICKYDEBUG1 = "/asdebug"
SlashCmdList["ARENASTICKYDEBUG"] = function()
    local ok, err = pcall(PrintArenaDebug)
    if not ok then
        print("|cffff4444ArenaSticky|r debug failed: " .. tostring(err))
    end
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
        if not InArenaWithOpponents() then
            ArenaSticky.lastPrintedCompKey = nil
            ArenaSticky.suppressAutoShow = false
            UpdateEnemyDetectText()
        end
        -- Do not rely only on IsActiveBattlefieldArena(); it is often false during prep.
        C_Timer.After(1.0, function()
            if InArenaWithOpponents() then
                TryDetectAndUpdate()
                ScheduleArenaDetectBurst()
                StartArenaMatchupPolling()
            end
        end)

    elseif event == "ARENA_OPPONENT_UPDATE" then
        RebuildGuidUnitMap()
        C_Timer.After(0.2, TryDetectAndUpdate)
        ScheduleArenaDetectBurst()
        StartArenaMatchupPolling()

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
                    TryDetectAndUpdate()
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