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

-- STRATSYNC reassembly (multi-part; addon messages are capped at 255 bytes)
local stratSyncBuffers = {}

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
    ELE = "Interface\\Icons\\Spell_Nature_LightningBolt",
    ENH = "Interface\\Icons\\Ability_Shaman_Stormstrike",
    DISC = "Interface\\Icons\\Spell_Holy_PowerWordShield",
    SHADOW = "Interface\\Icons\\Spell_Shadow_ShadowWordPain",
    RESTO = "Interface\\Icons\\Spell_Nature_HealingTouch",
    BOOMY = "Interface\\Icons\\Spell_Nature_StarFall",
    FERAL = "Interface\\Icons\\Ability_Druid_CatForm",
    PALADIN = "Interface\\Icons\\Spell_Holy_SealOfMight",
    SHAMAN = "Interface\\Icons\\Spell_Nature_LightningShield",
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
--- Keys are class tokens only (e.g. DISC-MAGE = 2v2, DISC-MAGE-ROGUE = 3v3); bracket is not encoded in the key.
function ArenaSticky.CompKeyMenuLabel(key)
    if not key or key == "" then return "" end
    local body = key:match("^%d%-(.+)$") or key
    local segs = {}
    for p in string.gmatch(body, "[^-]+") do
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

--- Profile names: letters, numbers, spaces, hyphen, underscore (safe for export lines).
local function ValidateProfileName(raw)
    local name = (raw or ""):match("^%s*(.-)%s*$") or ""
    if name == "" then
        return nil, "Profile name is required."
    end
    if #name > 40 then
        return nil, "Profile name is too long (40 characters max)."
    end
    if not name:match("^[%w%s%-_]+$") then
        return nil, "Use only letters, numbers, spaces, hyphen, and underscore."
    end
    return name
end

local function SyncActiveProfilePointers()
    if not ArenaStickyDB or type(ArenaStickyDB.profiles) ~= "table" then
        return
    end
    local n = ArenaStickyDB.activeProfile or "Default"
    if not ArenaStickyDB.profiles[n] then
        ArenaStickyDB.profiles[n] = { version = 1, lastUpdated = time(), strategies = {} }
    end
    local p = ArenaStickyDB.profiles[n]
    if type(p.strategies) ~= "table" then
        p.strategies = {}
    end
    p.version = tonumber(p.version) or 1
    p.lastUpdated = tonumber(p.lastUpdated) or time()
    ArenaStickyDB.strategies = p.strategies
    ArenaStickyDB.version = p.version
    ArenaStickyDB.lastUpdated = p.lastUpdated
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
    local body = compKey:match("^%d%-(.+)$") or compKey
    local parts = {}
    for p in body:gmatch("[^-]+") do
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
    local body = compKey:match("^%d%-(.+)$") or compKey
    local parts = {}
    for p in body:gmatch("[^-]+") do
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
        -- e.g. "2-disc-mage" → DISC-MAGE (ignore leading bracket digit in tests)
        if #parts >= 3 and parts[1]:match("^%d$") then
            table.remove(parts, 1)
            if #parts >= 2 then
                local bareKey = NormalizeCompKey(parts)
                return FromLegacyCompKey(bareKey), clean
            end
        elseif #parts >= 2 then
            local key = NormalizeCompKey(parts)
            return FromLegacyCompKey(key), clean
        end
    end
    local key = COMP_ALIASES[clean]
    if key then return key, clean end
    return nil, clean
end

local DEFAULT_STRATEGIES = {
    -- Role lines: aim ~5–12 words each (sticky / glance).
    ["RESTO-WARLOCK-WARRIOR"] = {
        header = { kill = "Warlock", cc = "Resto Druid" },
        roles = {
            DISC = "Pillar. Dispel fear. Trinket cross; reset.",
            ROGUE = "Open lock. Kidney druid CC. Bad go reset.",
            MAGE = "Sheep druid go. Peel war. CS fear.",
        },
    },
    ["DISC-MAGE-ROGUE"] = {
        header = { kill = "Mage", cc = "Disc" },
        roles = {
            DISC = "No trinket stack. Fear sheep. PI real goes.",
            ROGUE = "Sap disc. Stop open. Vanish re-go.",
            MAGE = "Poly race. Counter if enemy disc locked.",
        },
    },
    ["DISC-MAGE"] = {
        header = { kill = "Mage", cc = "Disc" },
        roles = {
            DISC = "PI goes. Fear/sheep. MD their go.",
            MAGE = "Race poly. CS if disc locked.",
        },
    },
    ["DISC-HUNTER-ROGUE"] = {
        header = { kill = "Hunter", cc = "Disc" },
        roles = {
            DISC = "No sap-trap. Trinket chains. Dispel trap.",
            ROGUE = "Rogue first, then hunter.",
            MAGE = "Peel. Poly disc go.",
        },
    },
    ["RESTO-ROGUE-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Resto Druid" },
        roles = {
            DISC = "Dispel coil/fear. Drink if rogue resets you.",
            ROGUE = "Open lock. Kidney druid. Blind trinket.",
            MAGE = "Sheep druid. Peel rogue. CS lock.",
        },
    },
    ["RSHAM-ROGUE-WARLOCK"] = {
        header = { kill = "Warlock", cc = "RSham" },
        roles = {
            DISC = "Shield purge. Fear sham go. Save mana.",
            ROGUE = "Open lock. Kick fear. Blind sham.",
            MAGE = "Sheep sham. Peel rogue. CS lock.",
        },
    },
    ["RSHAM-SHADOW-WARLOCK"] = {
        header = { kill = "Warlock", cc = "RSham" },
        roles = {
            DISC = "Drink. Dispel VT/fear smart.",
            ROGUE = "Lock. Kick fear. Kidney sham. Reset.",
            MAGE = "Sheep sham. CS lock. Peel shadow.",
        },
    },
    ["RSHAM-WARLOCK-WARRIOR"] = {
        header = { kill = "Warlock", cc = "RSham" },
        roles = {
            DISC = "Bridge. Trinket stacks. Fear sham go.",
            ROGUE = "Open lock. Force CDs. Reset if war free.",
            MAGE = "Sheep sham. Peel war. CS fear.",
        },
    },
    ["ELE-RESTO-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Resto" },
        roles = {
            DISC = "Pillar. Fear healer go. Dispel key CC.",
            ROGUE = "Lock. Short goes. Swap ele if out.",
            MAGE = "Peel. CS lock/healer. Slow ele.",
        },
    },
    ["DISC-RESTO-WARRIOR"] = {
        header = { kill = "Warrior", cc = "Disc" },
        roles = {
            DISC = "Survive train. Fear disc setup. Trinket swap.",
            ROGUE = "War. Kidney disc CC. Reset.",
            MAGE = "Peel war. Poly disc. Slow.",
        },
    },
    ["DISC-RESTO-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Disc" },
        roles = {
            DISC = "Line dots. Fear disc go. Dispel smart.",
            ROGUE = "Lock. Kick fear. Kidney disc. Reset.",
            MAGE = "Poly disc. CS lock. Line.",
        },
    },
    ["DISC-ROGUE-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Disc" },
        roles = {
            DISC = "Fear disc go. Dispel fear.",
            ROGUE = "Lock. Rogue first if needed. Blind disc.",
            MAGE = "Peel rogue. Poly disc. CS lock.",
        },
    },
    ["RET-RSHAM"] = {
        header = { kill = "RSham", cc = "Ret" },
        roles = {
            DISC = "Fear sham. Purge/winds. Trinket wings.",
            ROGUE = "Kidney sham. Blind/CC ret. Reset.",
            MAGE = "Sheep ret peel. CS hex. Nova ret.",
        },
    },
    ["RET-RSHAM-WARRIOR"] = {
        header = { kill = "Warrior", cc = "RSham" },
        roles = {
            DISC = "Fear sham go. Trinket overlap.",
            ROGUE = "War. Kidney sham. Reset.",
            MAGE = "Peel war/ret. Sheep sham. Slow war.",
        },
    },
    ["MAGE-RESTO-WARRIOR"] = {
        header = { kill = "Mage", cc = "Resto Druid" },
        roles = {
            DISC = "Don't overtrade. Fear druid setup.",
            ROGUE = "Open mage. Kidney druid. Peel war.",
            MAGE = "Poly race. Sheep druid. Slow war.",
        },
    },
    ["ENH-HPAL-WARRIOR"] = {
        header = { kill = "Warrior", cc = "HPal" },
        roles = {
            DISC = "Fear pal go. Trinket smart.",
            ROGUE = "War. Kidney pal. Reset CDs.",
            MAGE = "Peel melee. Poly pal. Root war.",
        },
    },
    ["ENH-RESTO-WARRIOR"] = {
        header = { kill = "Warrior", cc = "Resto Druid" },
        roles = {
            DISC = "Pillar. Fear druid go. Trinket overlap.",
            ROGUE = "War. Kidney druid. Reset.",
            MAGE = "Peel enh/war. Sheep druid. Slow.",
        },
    },
    ["ENH-RSHAM-WARRIOR"] = {
        header = { kill = "Warrior", cc = "RSham" },
        roles = {
            DISC = "Fear sham go. Trinket kill.",
            ROGUE = "War. Kidney sham. Reset.",
            MAGE = "Peel melee. Sheep sham. Slow war.",
        },
    },
    ["RESTO-RSHAM-WARRIOR"] = {
        header = { kill = "Warrior", cc = "Druid or RSham" },
        roles = {
            DISC = "Fear open healer go. Dispel CC.",
            ROGUE = "Train war. Kidney healer CC.",
            MAGE = "Peel war. Sheep healer go. CS.",
        },
    },

    ["DISC-ROGUE"] = {
        header = { kill = "Rogue", cc = "Disc" },
        roles = {
            DISC = "Fear disc goes. No CC overlap. Trinket chains.",
            ROGUE = "Stick rogue. Kick/blind disc trinket.",
            MAGE = "Poly disc. Slow rogue. CS fear.",
        },
    },
    ["ROGUE-SHADOW"] = {
        header = { kill = "Shadow", cc = "Rogue" },
        roles = {
            DISC = "Fear shadow goes. Dispel VT/sheep.",
            SHADOW = "Silence/fear. PI on connect.",
            ROGUE = "Peel rogue. Blind trinket.",
            MAGE = "Slow rogue. Sheep shadow. CS.",
        },
    },
    ["DISC-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Disc" },
        roles = {
            DISC = "Dispel key dots/fear. Stay up.",
            ROGUE = "Lock. Kick fear. Blind disc.",
            MAGE = "Sheep disc go. Line. CS lock.",
        },
    },
    ["HPAL-WARRIOR"] = {
        header = { kill = "Warrior", cc = "HPal" },
        roles = {
            DISC = "Fear pal go. Bait war.",
            ROGUE = "War first. Kidney pal. Reset.",
            MAGE = "Slow war. Poly pal. Drink.",
        },
    },
    ["RESTO-WARRIOR"] = {
        header = { kill = "Warrior", cc = "Resto Druid" },
        roles = {
            DISC = "Don't get pulled. Fear druid go. Trinket bash.",
            ROGUE = "Kidney war druid CC. Reset.",
            MAGE = "Slow war. Sheep druid go.",
        },
    },
    ["RSHAM-WARRIOR"] = {
        header = { kill = "Warrior", cc = "RSham" },
        roles = {
            DISC = "Fear sham go. Mana game.",
            ROGUE = "War. Kidney sham. Reset.",
            MAGE = "Peel war. Sheep sham. CS.",
        },
    },
    ["DISC-HUNTER"] = {
        header = { kill = "Hunter", cc = "Disc" },
        roles = {
            DISC = "Trap respect. Trinket chains. Fear disc.",
            ROGUE = "Stick hunter. Kick/blind disc.",
            MAGE = "Pin hunter. Poly disc. Nova.",
        },
    },
    ["MAGE-ROGUE"] = {
        header = { kill = "Mage", cc = "Rogue" },
        roles = {
            DISC = "Fear rogue goes. MD CC. Trinket kills.",
            ROGUE = "Mage goes. Kick poly. Vanish re-go.",
            MAGE = "Sheep rogue DR. Nova. CS.",
        },
    },
    ["RESTO-ROGUE"] = {
        header = { kill = "Rogue", cc = "Resto Druid" },
        roles = {
            DISC = "Fear druid after open. Save CDs.",
            ROGUE = "Their rogue. CC druid trinket.",
            MAGE = "Peel rogue. Druid on goes only.",
        },
    },
    -- From SavedVariables / ArenaReplay comps not covered above (same short-line style).
    ["DISC-WARRIOR"] = {
        header = { kill = "Warrior", cc = "Disc" },
        roles = {
            DISC = "Fear disc setup. Dispel MC. Trinket swap.",
            ROGUE = "Train war. Kidney disc CC.",
            MAGE = "Poly disc peel. Slow war. CS.",
        },
    },
    ["ENH-ENH"] = {
        header = { kill = "Enh", cc = "Enh" },
        roles = {
            DISC = "Spread burst. Hex one go. Trinket wolves.",
            ROGUE = "Train one. Kick heals. Reset.",
            MAGE = "Slow both. Nova on peels.",
        },
    },
    ["HUNTER-ROGUE"] = {
        header = { kill = "Hunter", cc = "Rogue" },
        roles = {
            DISC = "Respect trap. Fear hunter goes.",
            ROGUE = "Hunter first. Kidney rogue.",
            MAGE = "Pin hunter. Poly rogue. Nova scatter.",
        },
    },
    ["MAGE-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Mage" },
        roles = {
            DISC = "Fear lock goes. Dispel dots. Trinket coil.",
            ROGUE = "Lock first. Kick fear. Kidney swap.",
            MAGE = "Sheep mage peel. CS fear. Line lock.",
        },
    },
    ["ROGUE-MAGE"] = {
        header = { kill = "Mage", cc = "Rogue" },
        roles = {
            DISC = "Fear rogue goes. MD CC. Trinket kills.",
            ROGUE = "Mage goes. Kick poly. Vanish re-go.",
            MAGE = "Sheep rogue DR. Nova. CS.",
        },
    },
    ["ROGUE-WARLOCK"] = {
        header = { kill = "Warlock", cc = "Rogue" },
        roles = {
            DISC = "Fear lock goes. Dispel fear smart.",
            ROGUE = "Train lock. Blind rogue on swap.",
            MAGE = "Sheep lock. Peel rogue. CS fear.",
        },
    },
}

--- One-time style migration: legacy "2-KEY"/"3-KEY" → "KEY" (same strategies, bare key wins if both exist).
local function MigrateBracketPrefixedKeysInStrategies(strategies)
    if type(strategies) ~= "table" then return end
    local remove = {}
    for k, v in pairs(strategies) do
        if type(k) == "string" then
            local bare = k:match("^%d%-(.+)$")
            if bare and bare ~= "" then
                if strategies[bare] == nil then
                    strategies[bare] = v
                end
                remove[#remove + 1] = k
            end
        end
    end
    for i = 1, #remove do
        strategies[remove[i]] = nil
    end
end

local function MigrateBracketPrefixedKeysAllProfiles()
    if not ArenaStickyDB or type(ArenaStickyDB.profiles) ~= "table" then return end
    for _, prof in pairs(ArenaStickyDB.profiles) do
        if type(prof) == "table" and type(prof.strategies) == "table" then
            MigrateBracketPrefixedKeysInStrategies(prof.strategies)
        end
    end
end

local function EnsureDB()
    ArenaStickyDB = ArenaStickyDB or {}
    ArenaStickyDB.playerRoleOverride = ArenaStickyDB.playerRoleOverride or nil
    ArenaStickyDB.window = ArenaStickyDB.window or {
        x = 0,
        y = 0,
        width = 320,
        height = 218,
        scale = 1.0,
        alpha = 0.95,
    }

    -- Named profiles: each has strategies + version + lastUpdated (teammate sync uses active profile).
    if type(ArenaStickyDB.profiles) ~= "table" then
        local oldStrat = ArenaStickyDB.strategies
        if type(oldStrat) ~= "table" then
            oldStrat = {}
        end
        ArenaStickyDB.profiles = {
            Default = {
                version = tonumber(ArenaStickyDB.version) or 1,
                lastUpdated = tonumber(ArenaStickyDB.lastUpdated) or time(),
                strategies = oldStrat,
            },
        }
        ArenaStickyDB.activeProfile = "Default"
    end

    ArenaStickyDB.activeProfile = ArenaStickyDB.activeProfile or "Default"
    if not ArenaStickyDB.profiles[ArenaStickyDB.activeProfile] then
        ArenaStickyDB.profiles[ArenaStickyDB.activeProfile] = {
            version = 1,
            lastUpdated = time(),
            strategies = {},
        }
    end

    SyncActiveProfilePointers()
    MigrateBracketPrefixedKeysAllProfiles()
    SyncActiveProfilePointers()
    -- New/blank profiles set skipDefaultStrategyMerge so they stay empty (no baked-in default comps).
    local ap = ArenaStickyDB.activeProfile or "Default"
    local prof = ArenaStickyDB.profiles and ArenaStickyDB.profiles[ap]
    if not prof or not prof.skipDefaultStrategyMerge then
        ArenaStickyDB.strategies = MergeMissingStrategies(ArenaStickyDB.strategies, DEFAULT_STRATEGIES)
    end
    SyncActiveProfilePointers()
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
    -- Class tokens only; 2 tokens = 2v2 and 3 = 3v3 (editor / UI infer bracket from count).
    return NormalizeCompKey(ArenaSticky.enemyClasses)
end

--- Paladin defaults to HPAL before we see casts; strategy DB often keys melee comps as RET.
local function CompKeyWithTokenSwap(compKey, fromToken, toToken)
    if not compKey then return nil end
    local body = compKey:match("^%d%-(.+)$") or compKey
    local parts = {}
    for p in body:gmatch("[^-]+") do
        if p == fromToken then
            table.insert(parts, toToken)
        else
            table.insert(parts, p)
        end
    end
    return NormalizeCompKey(parts)
end

local function FindStrategyDirect(compKey)
    if not compKey or compKey == "" then return nil end
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

local function FindStrategyForCompKey(compKey)
    if not compKey or compKey == "" then return nil end
    EnsureDB()
    local strat = FindStrategyDirect(compKey)
    if strat then return strat end
    local bare = compKey:match("^%d%-(.+)$")
    if bare and bare ~= "" then
        return FindStrategyDirect(bare)
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
    if compKey and type(compKey) == "string" and compKey ~= "" then
        EnsureDB()
        ArenaStickyDB.lastPlayedCompKey = compKey
    end
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

function ArenaSticky.SyncActiveProfileMeta()
    EnsureDB()
    local n = ArenaStickyDB.activeProfile or "Default"
    local p = ArenaStickyDB.profiles and ArenaStickyDB.profiles[n]
    if not p then
        return
    end
    p.version = ArenaStickyDB.version or p.version
    p.lastUpdated = ArenaStickyDB.lastUpdated or p.lastUpdated
end

function ArenaSticky.GetSortedProfileNames()
    EnsureDB()
    local t = {}
    for name in pairs(ArenaStickyDB.profiles or {}) do
        table.insert(t, name)
    end
    table.sort(t)
    return t
end

function ArenaSticky.CreateProfile(rawName)
    local name, err = ValidateProfileName(rawName)
    if not name then
        return false, err
    end
    EnsureDB()
    if ArenaStickyDB.profiles[name] then
        return false, "A profile named '" .. name .. "' already exists."
    end
    ArenaStickyDB.profiles[name] = {
        version = 1,
        lastUpdated = time(),
        strategies = {},
        skipDefaultStrategyMerge = true,
    }
    -- Second return is canonical profile name (for UI); on failure second return is error string.
    return true, name
end

--- Replace active profile's strategies with a deep copy of another profile's notes (comps + text).
function ArenaSticky.CopyNotesFromProfileToActive(rawSourceName)
    local srcName, err = ValidateProfileName(rawSourceName)
    if not srcName then
        return false, err
    end
    EnsureDB()
    local active = ArenaStickyDB.activeProfile or "Default"
    if srcName == active then
        return false, "Pick a profile other than the active one."
    end
    local srcP = ArenaStickyDB.profiles and ArenaStickyDB.profiles[srcName]
    if not srcP or type(srcP.strategies) ~= "table" then
        return false, "Unknown source profile."
    end
    local destP = ArenaStickyDB.profiles and ArenaStickyDB.profiles[active]
    if not destP then
        return false, "Active profile data missing."
    end
    destP.strategies = DeepCopy(srcP.strategies)
    destP.version = (destP.version or 1) + 1
    destP.lastUpdated = time()
    destP.skipDefaultStrategyMerge = true
    SyncActiveProfilePointers()
    ArenaStickyDB.version = destP.version
    ArenaStickyDB.lastUpdated = destP.lastUpdated
    if ArenaSticky.currentCompKey then
        UpdateNotesForComp(ArenaSticky.currentCompKey, true)
    end
    if ArenaSticky.EditorRefreshFromProfile then
        ArenaSticky.EditorRefreshFromProfile()
    end
    return true
end

function ArenaSticky.CopyProfile(rawFrom, rawTo)
    local fromName, e1 = ValidateProfileName(rawFrom)
    local toName, e2 = ValidateProfileName(rawTo)
    if not fromName then
        return false, e1
    end
    if not toName then
        return false, e2
    end
    EnsureDB()
    if not ArenaStickyDB.profiles[fromName] then
        return false, "Unknown source profile."
    end
    if ArenaStickyDB.profiles[toName] then
        return false, "Target profile already exists."
    end
    ArenaStickyDB.profiles[toName] = {
        version = ArenaStickyDB.profiles[fromName].version or 1,
        lastUpdated = time(),
        strategies = DeepCopy(ArenaStickyDB.profiles[fromName].strategies),
    }
    return true
end

function ArenaSticky.DeleteProfile(rawName)
    local name, err = ValidateProfileName(rawName)
    if not name then
        return false, err
    end
    EnsureDB()
    if not ArenaStickyDB.profiles[name] then
        return false, "Unknown profile."
    end
    local count = 0
    for _ in pairs(ArenaStickyDB.profiles) do
        count = count + 1
    end
    if count <= 1 then
        return false, "Cannot delete the only profile."
    end
    -- If we remove the active profile first, EnsureDB() (e.g. inside GetSortedProfileNames)
    -- would see activeProfile still pointing at a missing key and recreate an empty profile
    -- with that name — so "delete" would appear to do nothing. Switch active first.
    local wasActive = (ArenaStickyDB.activeProfile == name)
    if wasActive then
        local others = {}
        for n in pairs(ArenaStickyDB.profiles) do
            if n ~= name then
                table.insert(others, n)
            end
        end
        table.sort(others)
        ArenaStickyDB.activeProfile = others[1] or "Default"
        if not ArenaStickyDB.profiles[ArenaStickyDB.activeProfile] then
            ArenaStickyDB.profiles[ArenaStickyDB.activeProfile] = {
                version = 1,
                lastUpdated = time(),
                strategies = {},
            }
        end
    end
    ArenaStickyDB.profiles[name] = nil
    SyncActiveProfilePointers()
    EnsureDB()
    if wasActive then
        if ArenaSticky.currentCompKey then
            UpdateNotesForComp(ArenaSticky.currentCompKey, true)
        end
        if ArenaSticky.EditorRefreshFromProfile then
            ArenaSticky.EditorRefreshFromProfile()
        end
    end
    return true
end

function ArenaSticky.SwitchProfile(rawName)
    local name, err = ValidateProfileName(rawName)
    if not name then
        print("|cffff4444ArenaSticky|r: " .. tostring(err))
        return false
    end
    EnsureDB()
    if not ArenaStickyDB.profiles[name] then
        print("|cffff4444ArenaSticky|r: Unknown profile: " .. name)
        return false
    end
    ArenaStickyDB.activeProfile = name
    SyncActiveProfilePointers()
    if ArenaSticky.currentCompKey then
        UpdateNotesForComp(ArenaSticky.currentCompKey, true)
    end
    if ArenaSticky.EditorRefreshFromProfile then
        ArenaSticky.EditorRefreshFromProfile()
    end
    print("|cff33ff99ArenaSticky|r: Active profile: " .. name)
    return true
end

function ArenaSticky.GetPlayerRoleToken()
    return GetMyRole()
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

local function SerializeStrategiesSimple(strategiesTable)
    -- Stable custom format:
    -- comp~kill~cc~<ROLE_TOKENS...> ; ...
    -- (Values are escaped for "~" and ";" using backticks.)
    strategiesTable = strategiesTable or ArenaStickyDB.strategies
    local function esc(s)
        s = s or ""
        s = s:gsub("`", "``")
        s = s:gsub("|", "`p")
        s = s:gsub("~", "`t")
        s = s:gsub(";", "`s")
        return s
    end
    local parts = {}
    for comp, data in pairs(strategiesTable or {}) do
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
        s = s:gsub("`p", "|")
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

--- Hex-wrap raw serialized blob (AS2). No pipes/newlines in payload — survives chat/email paste reliably.
local function HexEncode(s)
    s = s or ""
    if s == "" then
        return ""
    end
    local t = {}
    for i = 1, #s do
        t[#t + 1] = string.format("%02x", s:byte(i))
    end
    return table.concat(t)
end

local function HexDecode(hex)
    hex = (hex or ""):gsub("%s+", "")
    if hex == "" then
        return ""
    end
    if #hex % 2 == 1 then
        return nil
    end
    local t = {}
    for i = 1, #hex, 2 do
        local b = tonumber(hex:sub(i, i + 1), 16)
        if not b then
            return nil
        end
        t[#t + 1] = string.char(b)
    end
    return table.concat(t)
end

--- Trim, normalize newlines, strip UTF-8 BOM / zero-width space (common when pasting from web/discord).
local function NormalizeImportedExportText(t)
    t = t or ""
    t = t:gsub("\r\n", "\n")
    t = t:gsub("\r", "\n")
    if #t >= 3 and t:byte(1) == 239 and t:byte(2) == 187 and t:byte(3) == 191 then
        t = t:sub(4)
    end
    if #t >= 3 and t:byte(1) == 226 and t:byte(2) == 128 and t:byte(3) == 139 then
        t = t:sub(4)
    end
    return t:gsub("^%s+", ""):gsub("%s+$", "")
end

local function TrimImportField(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

--- WoW FontStrings/edit status treat | as escape; || renders one literal vertical bar in UI text.
local function WowEscapePipeForUiString(s)
    if not s then
        return ""
    end
    return s:gsub("|", "||")
end

--- Discord / Word / web often paste U+FF5C (fullwidth |), U+2028/U+2029 line breaks inside the line, etc.
--- WoW multiline EditBoxes often paste field separators as doubled "||". AS2/ASPACK2 hex has no |, so collapsing runs is safe.
local function CollapseAsciiPipeRunsForHexPayload(s)
    return (s or ""):gsub("|+", "|")
end

local function NormalizeImportPipesAndSeparators(s)
    if not s then
        return ""
    end
    s = s:gsub("\239\188\156", "|")
    --- U+2502 (box drawings light vertical), U+00A6 broken bar — some apps use these instead of ASCII |
    s = s:gsub("\226\148\130", "|")
    s = s:gsub("\194\166", "|")
    s = s:gsub("\226\128\168", "")
    s = s:gsub("\226\128\169", "")
    return s
end

local function FindAsciiPipe(payload, startPos)
    startPos = startPos or 1
    for i = startPos, #payload do
        if payload:byte(i) == 124 then
            return i
        end
    end
    return nil
end

local function FindLastAsciiPipe(payload, startPos)
    startPos = startPos or 1
    for i = #payload, startPos, -1 do
        if payload:byte(i) == 124 then
            return i
        end
    end
    return nil
end

local function CountAsciiPipes(payload)
    local n = 0
    for i = 1, #payload do
        if payload:byte(i) == 124 then
            n = n + 1
        end
    end
    return n
end

--- AS2 export is name|ver|ts|hex (hex is [0-9a-f]*). Split from the right on the last three ASCII pipes so odd paste/join around the timestamp still parses.
local function SplitAs2ByLastThreePipes(payload)
    payload = TrimImportField(payload)
    payload = payload:gsub("^|+", "")
    payload = NormalizeImportPipesAndSeparators(payload)
    payload = payload:gsub("\226\128\139", "")
    if payload == "" then
        return nil
    end
    local p3 = FindLastAsciiPipe(payload)
    if not p3 then
        return nil
    end
    local hexChunk = TrimImportField(payload:sub(p3 + 1))
    hexChunk = hexChunk:gsub("%s+", "")
    if hexChunk ~= "" and not hexChunk:match("^[0-9a-fA-F]+$") then
        return nil
    end
    local beforeHex = payload:sub(1, p3 - 1)
    if beforeHex == "" then
        return nil
    end
    local p2 = FindLastAsciiPipe(beforeHex)
    if not p2 then
        return nil
    end
    local tsStr = TrimImportField(beforeHex:sub(p2 + 1)):gsub("\226\128\139", "")
    local beforeTs = beforeHex:sub(1, p2 - 1)
    if beforeTs == "" then
        return nil
    end
    local p1 = FindLastAsciiPipe(beforeTs)
    if not p1 then
        return nil
    end
    local verStr = TrimImportField(beforeTs:sub(p1 + 1)):gsub("\226\128\139", "")
    local name = TrimImportField(beforeTs:sub(1, p1 - 1)):gsub("\226\128\139", "")
    if name == "" or verStr == "" or tsStr == "" then
        return nil
    end
    local ver = tonumber(verStr:match("^(%d+)")) or tonumber(verStr)
    local ts = tonumber(tsStr:match("^(%d+)")) or tonumber(tsStr)
    if ver == nil or ts == nil then
        return nil
    end
    return name, ver, ts, hexChunk
end

--- AS1 / pack line: name|ver|tail where tail is timestamp|blob or timestamp blob (| in blob must not be used as 3rd delimiter).
local function SplitFourPipeFields(payload)
    payload = TrimImportField(payload)
    payload = payload:gsub("^|+", "")
    payload = NormalizeImportPipesAndSeparators(payload)
    if payload == "" then
        return nil
    end
    local i1 = FindAsciiPipe(payload, 1)
    if not i1 then
        return nil
    end
    local i2 = FindAsciiPipe(payload, i1 + 1)
    if not i2 then
        return nil
    end

    local a = TrimImportField(payload:sub(1, i1 - 1))
    local b = TrimImportField(payload:sub(i1 + 1, i2 - 1))
    local tail = payload:sub(i2 + 1)

    if a == "" or b == "" or tail == "" then
        return nil
    end

    local ver = tonumber(b:match("^(%d+)")) or tonumber(b)
    if ver == nil then
        return nil
    end

    tail = TrimImportField(tail)
    tail = tail:gsub("^|+", "")

    local ts
    local blob
    -- Allow spaces or invisible junk before the unix digit run (paste from web/discord)
    local tsPart, afterTs = tail:match("^[^%d]*(%d+)|(.*)$")
    if tsPart then
        ts = tonumber(tsPart)
        blob = afterTs or ""
    else
        local tsDigits, glued = tail:match("^[^%d]*(%d+)(.*)$")
        if not tsDigits then
            return nil
        end
        ts = tonumber(tsDigits)
        blob = glued or ""
    end
    if not ts then
        return nil
    end
    return a, ver, ts, blob
end

--- Payload after "AS1|": name|ver|ts|blob — blob may contain "|".
local function ParseAS1Payload(rest)
    return SplitFourPipeFields(rest)
end

--- One profile line inside ASPACK1 (no AS1 prefix): name|ver|ts|blob
local function ParsePackProfileLine(line)
    return SplitFourPipeFields(line)
end

--- First non-empty line, for format sniffing (ASPACK1 / AS1).
local function FirstLineOfPaste(fullText)
    fullText = NormalizeImportedExportText(fullText or "")
    for line in string.gmatch(fullText, "[^\n]+") do
        local s = TrimImportField(line)
        if s ~= "" then
            return s
        end
    end
    return TrimImportField(fullText)
end

function ArenaSticky.BuildExportStringActiveProfile()
    EnsureDB()
    local name = ArenaStickyDB.activeProfile or "Default"
    local blob = SerializeStrategiesSimple(ArenaStickyDB.strategies)
    return string.format("AS2|%s|%d|%d|%s", name, ArenaStickyDB.version or 1, ArenaStickyDB.lastUpdated or time(), HexEncode(blob))
end

function ArenaSticky.BuildExportStringAllProfiles()
    EnsureDB()
    local lines = { "ASPACK2" }
    for _, pname in ipairs(ArenaSticky.GetSortedProfileNames()) do
        local p = ArenaStickyDB.profiles[pname]
        local blob = SerializeStrategiesSimple(p and p.strategies or {})
        table.insert(lines, string.format("%s|%d|%d|%s", pname, p.version or 1, p.lastUpdated or time(), HexEncode(blob)))
    end
    return table.concat(lines, "\n")
end

local function ApplyImportedStrategiesToActive(strategies, ver, ts)
    EnsureDB()
    local activeName = ArenaStickyDB.activeProfile or "Default"
    local prof = ArenaStickyDB.profiles[activeName]
    if not prof then
        return false, "Internal error: no active profile."
    end
    prof.strategies = strategies
    prof.version = ver
    prof.lastUpdated = ts
    SyncActiveProfilePointers()
    if ArenaSticky.currentCompKey then
        UpdateNotesForComp(ArenaSticky.currentCompKey, true)
    end
    if ArenaSticky.EditorRefreshFromProfile then
        ArenaSticky.EditorRefreshFromProfile()
    end
    print("|cff33ff99ArenaSticky|r: Imported notes into profile |cff00ccff" .. activeName .. "|r (v" .. tostring(ver) .. ").")
    return true
end

--- One-line active-profile import. Prefer AS2 (hex blob); still accepts legacy AS1 (raw blob).
function ArenaSticky.ImportSingleLineIntoActive(line)
    line = NormalizeImportedExportText(line or "")
    line = NormalizeImportPipesAndSeparators(line)
    line = line:gsub("[\r\n]+", "")
    line = line:gsub("\226\128\139", "")
    local low = line:lower()

    local as2pos = low:find("as2|", 1, true)
    if as2pos then
        local rest = line:sub(as2pos + 4)
        rest = CollapseAsciiPipeRunsForHexPayload(rest)
        local _, ver, ts, hexblob = SplitAs2ByLastThreePipes(rest)
        if ver == nil or ts == nil then
            _, ver, ts, hexblob = SplitFourPipeFields(rest)
        end
        if ver == nil or ts == nil then
            local n = #rest
            local pipes = CountAsciiPipes(rest)
            local prev = rest:sub(1, math.min(120, n)) .. ((n > 120) and " …" or "")
            prev = prev:gsub("|", "/")
            return false, string.format(
                "Could not parse AS2 line (expected name, version, unix time, hex after AS2). Payload length=%d. ASCII bar count=%d (need 3). Snippet: %s",
                n,
                pipes,
                prev
            )
        end
        local raw = HexDecode(hexblob)
        if raw == nil then
            return false, "AS2 import: hex block is invalid (corrupted or incomplete paste)."
        end
        local strategies = DeserializeStrategiesSimple(raw)
        local ok, err = ApplyImportedStrategiesToActive(strategies, ver, ts)
        if not ok then
            return false, err
        end
        return true
    end

    local as1pos = low:find("as1|", 1, true)
    if not as1pos then
        return false, "Not a valid one-line import (expected a line starting with AS2 or legacy AS1 followed by delimited fields)."
    end
    local rest = line:sub(as1pos + 4)
    local _exportProfile, ver, ts, blob = ParseAS1Payload(rest)
    if ver == nil or ts == nil then
        local n = #rest
        local prev = rest:sub(1, math.min(220, n))
        if n > 220 then
            prev = prev .. " …"
        end
        return false, string.format(
            "Could not parse AS1 line (legacy format). length=%d. Start: %s",
            n,
            WowEscapePipeForUiString(prev)
        )
    end
    local strategies = DeserializeStrategiesSimple(blob)
    local ok, err = ApplyImportedStrategiesToActive(strategies, ver, ts)
    if not ok then
        return false, err
    end
    return true
end

function ArenaSticky.ImportPackText(fullText)
    fullText = NormalizeImportedExportText(fullText or "")
    local lines = {}
    for line in string.gmatch(fullText, "[^\n]+") do
        table.insert(lines, line)
    end
    local headerIdx, headerLine
    for i, line in ipairs(lines) do
        local s = TrimImportField(line)
        if s ~= "" then
            headerIdx = i
            headerLine = s
            break
        end
    end
    local h = headerLine and headerLine:upper() or ""
    if h ~= "ASPACK1" and h ~= "ASPACK2" then
        return false, "Expected ASPACK1 or ASPACK2 on the first non-empty line."
    end
    local packUsesHex = (h == "ASPACK2")
    local newProfiles = {}
    for i = headerIdx + 1, #lines do
        local line = lines[i]:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            if packUsesHex then
                line = CollapseAsciiPipeRunsForHexPayload(line)
            end
            local pname, ver, ts, blobField = ParsePackProfileLine(line)
            if not pname then
                return false, "Bad pack line " .. tostring(i) .. " (truncated or wrong format)."
            end
            local blobStr
            if packUsesHex then
                local decoded = HexDecode(blobField)
                if decoded == nil then
                    return false, "Bad hex in pack line " .. tostring(i) .. "."
                end
                blobStr = decoded
            else
                blobStr = blobField
            end
            newProfiles[pname] = {
                version = ver,
                lastUpdated = ts,
                strategies = DeserializeStrategiesSimple(blobStr),
            }
        end
    end
    if not next(newProfiles) then
        return false, "Pack contained no profiles."
    end
    EnsureDB()
    local prevActive = ArenaStickyDB.activeProfile
    ArenaStickyDB.profiles = newProfiles
    if newProfiles[prevActive] then
        ArenaStickyDB.activeProfile = prevActive
    elseif newProfiles.Default then
        ArenaStickyDB.activeProfile = "Default"
    else
        local names = ArenaSticky.GetSortedProfileNames()
        ArenaStickyDB.activeProfile = names[1]
    end
    SyncActiveProfilePointers()
    if ArenaSticky.currentCompKey then
        UpdateNotesForComp(ArenaSticky.currentCompKey, true)
    end
    if ArenaSticky.EditorRefreshFromProfile then
        ArenaSticky.EditorRefreshFromProfile()
    end
    local n = 0
    for _ in pairs(ArenaStickyDB.profiles or {}) do
        n = n + 1
    end
    print("|cff33ff99ArenaSticky|r: Imported full profile pack (" .. tostring(n) .. " profiles). Active: |cff00ccff" .. tostring(ArenaStickyDB.activeProfile) .. "|r.")
    return true
end

function ArenaSticky.ImportFromPaste(fullText)
    fullText = NormalizeImportedExportText(fullText or "")
    if fullText == "" then
        return false, "Paste was empty."
    end
    local first = FirstLineOfPaste(fullText)
    if first == "" then
        return false, "Paste was empty."
    end
    if first:upper() == "ASPACK1" or first:upper() == "ASPACK2" then
        return ArenaSticky.ImportPackText(fullText)
    end
    -- AS1/AS2 are one logical line — merge newlines so wrapped pastes work
    if first:lower():match("^as1|") or first:lower():match("^as2|") then
        local merged = fullText:gsub("[\r\n]+", "")
        return ArenaSticky.ImportSingleLineIntoActive(merged)
    end
    return false, "Not a valid ArenaSticky export (need AS2/AS1 line or ASPACK1/2 block)."
end

StaticPopupDialogs["ARENASTICKY_EXPORT_TEXT"] = {
    text = "Copy this string (Ctrl+C). One line = AS2 active profile; multi-line = ASPACK2 (all profiles).",
    button1 = OKAY,
    hasEditBox = 1,
    maxLetters = 9999999,
    wide = true,
    whileDead = true,
    timeout = 0,
    hideOnEscape = true,
    OnShow = function(self)
        local eb = self.GetEditBox and self:GetEditBox() or _G[self:GetName() .. "EditBox"]
        if eb then
            eb:SetMaxLetters(9999999)
            eb:SetText(ArenaSticky.lastExportString or "")
            eb:SetFocus()
            eb:HighlightText()
        end
    end,
}

StaticPopupDialogs["ARENASTICKY_IMPORT_TEXT"] = {
    text = "Paste AS2 (or legacy AS1) one-line export, or ASPACK1/2 multi-line pack. Then click Import.",
    button1 = "Import",
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 9999999,
    wide = true,
    whileDead = true,
    timeout = 0,
    hideOnEscape = true,
    OnShow = function(self)
        local eb = self.GetEditBox and self:GetEditBox() or _G[self:GetName() .. "EditBox"]
        if eb then
            eb:SetMaxLetters(9999999)
            eb:SetText("")
        end
    end,
    OnAccept = function(self)
        local eb = self.GetEditBox and self:GetEditBox() or _G[self:GetName() .. "EditBox"]
        local t = eb and eb:GetText() or ""
        local ok, err = ArenaSticky.ImportFromPaste(t)
        if ok then
            print("|cff33ff99ArenaSticky|r: Import finished.")
        else
            print("|cffff4444ArenaSticky|r: " .. tostring(err))
        end
    end,
}

local ADDON_MSG_MAX = 255

--- Split serialized blob into ≤255-char messages: STRATSYNC#ver#ts#idx#total#payload
local function BuildStratSyncPayloadMessages(ver, ts, blob)
    local lenB = #(blob or "")
    if lenB == 0 then
        return { string.format("STRATSYNC#%d#%d#%d#%d#", ver, ts, 1, 1) }
    end
    local n = math.max(1, math.ceil(lenB / 200))
    for _ = 1, 80 do
        local msgs = {}
        local offset = 1
        local i = 0
        while offset <= lenB do
            i = i + 1
            local hdr = string.format("STRATSYNC#%d#%d#%d#%d#", ver, ts, i, n)
            local room = ADDON_MSG_MAX - #hdr
            if room < 1 then
                return nil
            end
            local chunk = string.sub(blob, offset, offset + room - 1)
            if #chunk == 0 then
                return nil
            end
            table.insert(msgs, hdr .. chunk)
            offset = offset + #chunk
        end
        if i == n then
            return msgs
        end
        n = i
    end
    return nil
end

local function StratSyncBufferKey(sender, ver, ts)
    return tostring(sender) .. "\001" .. tostring(ver) .. "\001" .. tostring(ts)
end

local function ApplyIncomingStrategies(incomingVersion, incomingTs, blob, sender)
    EnsureDB()
    local currentVersion = ArenaStickyDB.version or 0
    local currentTs = ArenaStickyDB.lastUpdated or 0
    if incomingVersion < currentVersion or (incomingVersion == currentVersion and incomingTs <= currentTs) then
        return false
    end
    local strategies = DeserializeStrategiesSimple(blob)
    local activeName = ArenaStickyDB.activeProfile or "Default"
    local prof = ArenaStickyDB.profiles[activeName]
    if not prof then
        return false
    end
    prof.strategies = strategies
    ArenaStickyDB.strategies = strategies
    prof.version = incomingVersion
    prof.lastUpdated = incomingTs
    ArenaStickyDB.version = incomingVersion
    ArenaStickyDB.lastUpdated = incomingTs
    print("|cff33ff99ArenaSticky|r: Received updated strategies from " .. tostring(sender))

    if ArenaSticky.currentCompKey then
        UpdateNotesForComp(ArenaSticky.currentCompKey, true)
    end
    return true
end

local function HandleStratSyncChunked(sender, ver, ts, idx, total, payload)
    ver = tonumber(ver)
    ts = tonumber(ts)
    idx = tonumber(idx)
    total = tonumber(total)
    if not ver or not ts or not idx or not total or not payload then
        return
    end
    local key = StratSyncBufferKey(sender, ver, ts)
    local buf = stratSyncBuffers[key]
    if not buf or buf.total ~= total then
        buf = { total = total, parts = {}, ver = ver, ts = ts }
        stratSyncBuffers[key] = buf
    end
    buf.parts[idx] = payload

    local complete = true
    local blob = ""
    for j = 1, total do
        local p = buf.parts[j]
        if not p then
            complete = false
            break
        end
        blob = blob .. p
    end
    if not complete then
        return
    end
    stratSyncBuffers[key] = nil
    ApplyIncomingStrategies(ver, ts, blob, sender)
end

function ArenaSticky:PushFullSync()
    if not C_ChatInfo then return end
    local blob = SerializeStrategiesSimple()
    local ver = ArenaStickyDB.version or 0
    local ts = ArenaStickyDB.lastUpdated or 0
    local msgs = BuildStratSyncPayloadMessages(ver, ts, blob)
    if not msgs or #msgs == 0 then
        print("|cffff4444ArenaSticky|r: Could not package strategies for sync (try fewer / shorter notes).")
        return
    end
    local channel = IsInGroup(2) and "INSTANCE_CHAT" or (IsInRaid() and "RAID" or "PARTY")
    for i, m in ipairs(msgs) do
        local delay = (i - 1) * 0.06
        C_Timer.After(delay, function()
            C_ChatInfo.SendAddonMessage(PREFIX, m, channel)
        end)
    end
end

local function HandleAddonMessage(prefix, msg, channel, sender)
    if prefix ~= PREFIX then return end
    local myName = UnitName("player")
    if sender and myName and sender == myName then return end
    if not msg then return end

    local cmd = strsplit("#", msg, 2)
    if cmd == "STRATSYNC" then
        local v1, ts1, idx1, n1, payload = msg:match("^STRATSYNC#(%d+)#(%d+)#(%d+)#(%d+)#(.*)$")
        if v1 and ts1 and idx1 and n1 and payload ~= nil then
            HandleStratSyncChunked(sender or "?", v1, ts1, idx1, n1, payload)
            return
        end
        local v2, ts2, blob = msg:match("^STRATSYNC#(%d+)#(%d+)#(.*)$")
        if v2 and ts2 and blob ~= nil then
            ApplyIncomingStrategies(tonumber(v2) or 0, tonumber(ts2) or 0, blob, sender or "?")
        end
    elseif cmd == "FULLSYNC" then
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
    print("  /as help   (also: /ar, /arenasticky, /asticky — if /as is used by another addon)")
    print("  /asdebug   (prints diagnostics even when /as is taken)")
    print("  /as hide   (stops auto-opening the sticky until next match or /as show)")
    print("  /as test        (random comp)   |   /as test rmp   (named alias)")
    print("  /as debug")
    print("  /as edit | show | hide | resetwindow | sync | request")
    print("  /as export      (active profile)   |   /as export all   (all profiles, share/backup)")
    print("  /as import      (paste AS2 / ASPACK2 — legacy AS1 / ASPACK1 still work)")
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
SLASH_ARENASTICKY4 = "/ar"
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

    if a == "export" then
        EnsureInitialized()
        EnsureDB()
        local sub = ((b or ""):match("^(%S+)") or ""):lower()
        if sub == "all" or sub == "pack" then
            ArenaSticky.lastExportString = ArenaSticky.BuildExportStringAllProfiles()
            print("|cff33ff99ArenaSticky|r: Exporting |cff00ccffall profiles|r (multi-line). Copy from popup.")
        else
            ArenaSticky.lastExportString = ArenaSticky.BuildExportStringActiveProfile()
            print("|cff33ff99ArenaSticky|r: Exporting |cff00ccff" .. tostring(ArenaStickyDB.activeProfile or "Default") .. "|r (one line). Copy from popup.")
        end
        StaticPopup_Show("ARENASTICKY_EXPORT_TEXT")
        return
    end

    if a == "import" then
        EnsureInitialized()
        StaticPopup_Show("ARENASTICKY_IMPORT_TEXT")
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