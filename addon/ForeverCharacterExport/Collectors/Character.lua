local _, Addon = ...
-- luacheck: read globals C_Map RequestTimePlayed

-- Character identity, progress, location, vitals, guild, played time and combat stats.
-- Evidence (all under references/upstream/Interface/AddOns/):
--   Blizzard_APIDocumentationGenerated: UnitDocumentation, PlayerScriptDocumentation, ConnectionDocumentation,
--   ZoneScriptDocumentation, MapDocumentation, RestrictedActionsDocumentation, SystemDocumentation (TIME_PLAYED_MSG).
--   Blizzard_UIPanels_Game/Camelot: PaperDollFrameStats.lua, PaperDollFrame.lua, PaperDollFrameConstants.lua.

local floor = math.floor

local PLAYER = "player"

-- Primary stats in UnitStat index order. The UI uses LE_UNIT_STAT_* (PaperDollFrame.lua:131-143) and also uses the
-- same index into the stat list "must match UNITSTAT order" (PaperDollFrameConstants.lua, PaperDollFrameStats.lua:267),
-- so list position is the fallback when the constant is not a number.
local PRIMARY = {
    { key = "strength", const = "LE_UNIT_STAT_STRENGTH", fallback = 1 },
    { key = "agility", const = "LE_UNIT_STAT_AGILITY", fallback = 2 },
    { key = "stamina", const = "LE_UNIT_STAT_STAMINA", fallback = 3 },
    { key = "intellect", const = "LE_UNIT_STAT_INTELLECT", fallback = 4 },
    { key = "spirit", const = "LE_UNIT_STAT_SPIRIT", fallback = 5 },
}

local function num(value)
    if type(value) ~= "number" then return Addon:Fmt(value) end
    if value == floor(value) then return string.format("%d", value) end
    return string.format("%.2f", value)
end

local function pct(value)
    if type(value) ~= "number" then return Addon:Fmt(value) end
    return string.format("%.2f%%", value)
end

local function duration(seconds)
    if type(seconds) ~= "number" or seconds < 0 then return Addon:Fmt(seconds) end
    seconds = floor(seconds)
    local d = floor(seconds / 86400)
    local h = floor((seconds % 86400) / 3600)
    local m = floor((seconds % 3600) / 60)
    return string.format("%dd %dh %dm %ds (%d seconds)", d, h, m, seconds % 60, seconds)
end

local function hasAccess(value)
    return not issecretvalue(value) and canaccessvalue(value)
end

-- C_Map.GetPlayerMapPosition returns a Vector2DMixin object (MapDocumentation.lua:436). Probe cannot copy an object
-- that carries mixin functions, so read only .x/.y (HybridMinimap.lua:115-121; Minimap.lua:1444-1446 uses GetXY).
local function readPosition(self, mapID)
    local api = "C_Map.GetPlayerMapPosition"
    local function state(status, reason)
        local result = self:State(status, reason)
        result.api = api
        return result
    end
    if type(mapID) ~= "number" then
        return state("not_collected", "no map ID, so no position was requested")
    end
    if type(C_Map) ~= "table" or type(C_Map.GetPlayerMapPosition) ~= "function" then
        return state("unsupported", "function unavailable at runtime")
    end
    if type(issecretvalue) ~= "function" or type(canaccessvalue) ~= "function" then
        return state("not_collected", "access guards unavailable; value not read")
    end
    local ok, position = pcall(C_Map.GetPlayerMapPosition, mapID, PLAYER)
    if not ok then
        local failure = self:Failure(position)
        failure.api = api
        return failure
    end
    if position == nil then
        return state("not_collected", "no position returned (not available in this zone or instance)")
    end
    if not hasAccess(position) then
        return state("restricted", "API returned a secret or inaccessible value")
    end
    if type(position) ~= "table" then
        return state("error", "unexpected position type " .. type(position))
    end
    local x, y = position.x, position.y
    if (x == nil or y == nil) and type(position.GetXY) == "function" then
        local okXY, gx, gy = pcall(position.GetXY, position)
        if okXY then x, y = gx, gy end
    end
    if not hasAccess(x) or not hasAccess(y) then
        return state("restricted", "position coordinates are secret or inaccessible")
    end
    if type(x) ~= "number" or type(y) ~= "number" then
        return state("error", "position has no numeric x/y")
    end
    return { status = "ok", api = api, values = { n = 2, x, y } }
end

-- Played time arrives only by event. Never fabricate it; keep the last received values.
Addon:On("TIME_PLAYED_MSG", function(self, _, total, level)
    if type(total) ~= "number" or type(level) ~= "number" then return end
    local ok, safe = self:Sanitize({ total = total, level = level })
    if not ok then return end
    self.playedInfo = { total = safe.total, level = safe.level, receivedAt = self:Now() }
    local saved, reason = self:Persist("played", { total = safe.total, level = safe.level })
    self.playedPersist = saved and "saved" or tostring(reason)
end)

-- RequestTimePlayed is declared in PlayerScriptDocumentation.lua and used by SlashCommands.lua:905. It prints two chat
-- lines, which is accepted. Request once per session at login.
local requestedTimePlayed = false
Addon:On("PLAYER_LOGIN", function(self)
    if requestedTimePlayed then return end
    requestedTimePlayed = true
    if type(RequestTimePlayed) ~= "function" then
        self.playedRequest = "unavailable: RequestTimePlayed missing"
        return
    end
    local ok, err = pcall(RequestTimePlayed)
    self.playedRequest = ok and "requested at login" or ("failed: " .. tostring(err))
end)

local function ratingBonus(self, constName)
    local index = _G[constName]
    if type(index) ~= "number" then
        local result = self:State("not_collected", "constant " .. constName .. " is not defined")
        result.api = "GetCombatRatingBonus"
        return result
    end
    return self:Probe("GetCombatRatingBonus", index)
end

local function collect(self)
    local s = { id = {}, progress = {}, place = {}, vitals = {}, guild = {}, combat = {}, stats = {}, hit = {} }

    -- Identity (UnitDocumentation.lua UnitName/UnitRace/UnitClass/UnitSex/UnitFactionGroup/UnitLevel).
    local id = s.id
    self:Read(id, "name", "UnitName", PLAYER)
    self:Read(id, "realm", "GetRealmName")
    self:Read(id, "realmNormalized", "GetNormalizedRealmName")
    self:Read(id, "race", "UnitRace", PLAYER)
    self:Read(id, "class", "UnitClass", PLAYER)
    self:Read(id, "sex", "UnitSex", PLAYER)
    self:Read(id, "faction", "UnitFactionGroup", PLAYER)
    self:Read(id, "level", "UnitLevel", PLAYER)
    self:Read(id, "locale", "GetLocale")

    -- Experience and money.
    local p = s.progress
    self:Read(p, "xp", "UnitXP", PLAYER)
    self:Read(p, "xpMax", "UnitXPMax", PLAYER)
    local rested = self:Probe("GetXPExhaustion")
    if rested.status == "not_collected" and rested.values then
        -- Real nil return. The XP bar treats nil as no rested XP (StatusTrackingBar ExpBar.lua:134).
        rested.status = "empty"
        rested.reason = "nil return; the default XP bar treats this as no rested XP"
    end
    p.rested = rested
    self:Read(p, "resting", "IsResting")
    self:Read(p, "money", "GetMoney")

    -- Location.
    local pl = s.place
    self:Read(pl, "zone", "GetZoneText")
    self:Read(pl, "subZone", "GetSubZoneText")
    self:Read(pl, "realZone", "GetRealZoneText")
    local mapID = self:Read(pl, "mapID", "C_Map.GetBestMapForUnit", PLAYER)
    if type(mapID) == "number" then
        self:Read(pl, "mapInfo", "C_Map.GetMapInfo", mapID)
    else
        pl.mapInfo = self:State("not_collected", "no map ID, so map info was not requested")
        pl.mapInfo.api = "C_Map.GetMapInfo"
    end
    pl.mapPosition = readPosition(self, mapID)
    self:Read(pl, "bind", "GetBindLocation")

    -- Vitals. UnitHealth declares SecretReturns, so a restricted tag is expected and correct.
    local v = s.vitals
    self:Read(v, "health", "UnitHealth", PLAYER)
    self:Read(v, "healthMax", "UnitHealthMax", PLAYER)
    local powerType = self:Read(v, "powerType", "UnitPowerType", PLAYER)
    v.power = self:Probe("UnitPower", PLAYER, powerType)
    v.powerMax = self:Probe("UnitPowerMax", PLAYER, powerType)

    -- Guild: IsInGuild (PlayerScriptDocumentation.lua:1324) decides whether a nil GetGuildInfo means "none".
    -- GetGuildInfo has no generated declaration; it is called by TabardFrame.lua:91 and
    -- UnitPopupSharedButtonMixins.lua:980 (Mainline/Shared, not Camelot).
    local g = s.guild
    local inGuild = self:Read(g, "inGuild", "IsInGuild")
    if inGuild == false then
        g.info = self:State("empty", "IsInGuild returned false")
        g.info.api = "GetGuildInfo"
    elseif inGuild == true then
        g.info = self:Probe("GetGuildInfo", PLAYER)
        if g.info.status == "not_collected" and g.info.values then
            g.info.reason = "IsInGuild is true but GetGuildInfo returned nothing; guild data may not be loaded yet"
        end
    else
        g.info = self:Probe("GetGuildInfo", PLAYER)
        if g.info.status == "not_collected" and g.info.values then
            g.info.reason = "GetGuildInfo returned nothing and IsInGuild is unread; no guild or data not loaded"
        end
    end

    -- Combat state: while in combat the client may return secret values for other reads.
    self:Read(s.combat, "lockdown", "InCombatLockdown")
    self:Read(s.combat, "affecting", "UnitAffectingCombat", PLAYER)

    -- Played time (event based).
    local info = self.playedInfo
    if type(info) == "table" and type(info.total) == "number" and type(info.level) == "number" then
        s.played = { status = "ok", api = "event TIME_PLAYED_MSG", values = { n = 3, info.total, info.level,
            info.receivedAt } }
    else
        s.played = self:State("not_collected", "no TIME_PLAYED_MSG received this session")
        s.played.api = "event TIME_PLAYED_MSG"
        s.playedStale = self:Persisted("played")
    end
    s.playedRequest = self.playedRequest
    s.playedPersist = self.playedPersist

    -- Combat stats. Calls and return shapes follow PaperDollFrame.lua / PaperDollFrameStats.lua.
    local st = s.stats
    s.statIndex = {}
    for _, stat in ipairs(PRIMARY) do
        local constant = _G[stat.const]
        local index, source = stat.fallback, "UI stat list order"
        if type(constant) == "number" then
            index, source = constant, stat.const
        end
        s.statIndex[stat.key] = { index = index, source = source }
        st[stat.key] = self:Probe("UnitStat", PLAYER, index)
    end
    st.armor = self:Probe("UnitArmor", PLAYER)
    st.defense = self:Probe("UnitDefenseSkill", PLAYER)
    st.attackPower = self:Probe("UnitAttackPower", PLAYER)
    st.rangedAttackPower = self:Probe("UnitRangedAttackPower", PLAYER)
    st.meleeDamage = self:Probe("UnitDamage", PLAYER)
    st.rangedDamage = self:Probe("UnitRangedDamage", PLAYER)
    st.attackSpeed = self:Probe("UnitAttackSpeed", PLAYER)
    st.critMelee = self:Probe("GetCritChance")
    st.critRanged = self:Probe("GetRangedCritChance")
    st.critSpell = self:Probe("GetSpellCritChance")
    st.dodge = self:Probe("GetDodgeChance")
    st.parry = self:Probe("GetParryChance")
    st.block = self:Probe("GetBlockChance")
    st.hasteMelee = self:Probe("GetMeleeHaste")
    st.hasteRanged = self:Probe("GetRangedHaste")
    st.hasteSpell = self:Probe("UnitSpellHaste", PLAYER)
    st.expertise = self:Probe("GetExpertise")
    st.armorPenetration = self:Probe("GetArmorPenetration")
    st.spellHealing = self:Probe("GetSpellBonusHealing")
    st.spellPenetration = self:Probe("GetSpellPenetration")
    st.manaRegen = self:Probe("GetManaRegen")

    local h = s.hit
    h.meleeRating = ratingBonus(self, "CR_HIT_MELEE")
    h.meleeModifier = self:Probe("GetHitModifier")
    h.rangedRating = ratingBonus(self, "CR_HIT_RANGED")
    h.rangedModifier = self:Probe("GetRangedHitModifier")
    h.spellRating = ratingBonus(self, "CR_HIT_SPELL")
    h.spellModifier = self:Probe("GetSpellHitModifier")

    -- Spell power per school: the UI starts at the holy school (2) and runs to MAX_SPELL_SCHOOLS
    -- (PaperDollFrame.lua:1080-1092).
    local maxSchool = _G.MAX_SPELL_SCHOOLS
    s.spellDamage = {}
    if type(maxSchool) == "number" then
        for school = 2, floor(maxSchool) do
            s.spellDamage[school] = self:Probe("GetSpellBonusDamage", school)
        end
    else
        s.spellDamageState = self:State("not_collected", "constant MAX_SPELL_SCHOOLS is not defined")
    end
    return s
end

local function hitLine(self, out, label, rating, modifier)
    local ratingTag, modifierTag = self:Describe(rating), self:Describe(modifier)
    local r, m = self:Val(rating, 1), self:Val(modifier, 1)
    if not ratingTag and not modifierTag and type(r) == "number" and type(m) == "number" then
        out:Add(label .. ": " .. pct(r + m) .. " (rating bonus " .. pct(r) .. " + modifier " .. pct(m) .. ")")
    else
        out:Add(label .. ": rating bonus " .. (ratingTag or pct(r)) .. ", modifier " .. (modifierTag or pct(m)))
    end
end

local function format(self, s, out)
    local id, p, pl, v, g = s.id, s.progress, s.place, s.vitals, s.guild

    out:Add("-- identity")
    out:Result("name", id.name)
    out:Result("realm", id.realm)
    out:Result("realm (normalized)", id.realmNormalized)
    out:Result("race", id.race, function(_, values)
        return string.format("%s (token %s, id %s)", self:Fmt(values[1]), self:Fmt(values[2]), self:Fmt(values[3]))
    end)
    out:Result("class", id.class, function(_, values)
        return string.format("%s (token %s, id %s)", self:Fmt(values[1]), self:Fmt(values[2]), self:Fmt(values[3]))
    end)
    out:Result("sex", id.sex, function(value)
        return num(value) .. " (raw UnitSex; the declared enum is 0=Male 1=Female 2=None 3=Both 4=Neutral, "
            .. "older clients use 2=Male 3=Female; mapping unverified on this build)"
    end)
    out:Result("faction", id.faction, function(_, values)
        return string.format("%s (localized %s)", self:Fmt(values[1]), self:Fmt(values[2]))
    end)
    out:Result("level", id.level)
    out:Result("game locale", id.locale)

    out:Add("-- experience and money")
    local xp, xpMax = self:Val(p.xp, 1), self:Val(p.xpMax, 1)
    if type(xp) == "number" and type(xpMax) == "number" then
        if xpMax > 0 then
            out:Add("xp: " .. num(xp) .. " / " .. num(xpMax) .. " (" .. pct(xp / xpMax * 100) .. ")")
            out:Add("xp to next level: " .. num(xpMax - xp))
        else
            out:Add("xp: " .. num(xp) .. " / " .. num(xpMax) .. " (max is 0: no XP bar, e.g. max level; unverified)")
            out:Add("xp to next level: <not_collected: UnitXPMax returned 0>")
        end
    else
        out:Result("xp current", p.xp)
        out:Result("xp max", p.xpMax)
        out:Add("xp to next level: <not_collected: current or max XP unread>")
    end
    out:Result("rested xp", p.rested, function(value)
        if type(value) == "number" and type(xpMax) == "number" and xpMax > 0 then
            return num(value) .. " (" .. pct(value / xpMax * 100) .. " of this level)"
        end
        return num(value)
    end)
    out:Result("resting", p.resting)
    out:Result("money", p.money, function(copper)
        if type(copper) ~= "number" or copper < 0 then return self:Fmt(copper) end
        copper = floor(copper)
        return string.format("%dg %ds %dc", floor(copper / 10000), floor((copper % 10000) / 100), copper % 100)
    end)
    out:Result("money (raw copper)", p.money)

    out:Add("-- location")
    local function text(value)
        if value == "" then return "<empty string: none>" end
        return self:Fmt(value)
    end
    out:Result("zone", pl.zone, text)
    out:Result("subzone", pl.subZone, text)
    out:Result("real zone", pl.realZone, text)
    out:Result("map ID", pl.mapID)
    out:Result("map name", pl.mapInfo, function(_, values)
        local info = values[1]
        if type(info) ~= "table" then return self:Fmt(info) end
        return string.format("%s (type %s, parent map %s)", self:Fmt(info.name), self:Fmt(info.mapType),
            self:Fmt(info.parentMapID))
    end)
    out:Result("map position", pl.mapPosition, function(_, values)
        return string.format("x=%.2f y=%.2f (percent of the map above)", values[1] * 100, values[2] * 100)
    end)
    out:Result("bind location (hearthstone)", pl.bind)

    out:Add("-- vitals")
    out:Result("health", v.health)
    out:Result("health max", v.healthMax)
    out:Result("primary power type", v.powerType, function(value, values)
        return string.format("%s (token %s)", num(value), self:Fmt(values[2]))
    end)
    out:Result("primary power", v.power)
    out:Result("primary power max", v.powerMax)

    out:Add("-- guild")
    out:Result("in guild", g.inGuild)
    out:Result("guild", g.info, function(_, values)
        return string.format("%s | rank %s (rank index %s; 0 is the highest rank) | realm %s", self:Fmt(values[1]),
            self:Fmt(values[2]), self:Fmt(values[3]), self:Fmt(values[4]))
    end)

    out:Add("-- combat state")
    local c = s.combat
    out:Result("in combat (lockdown)", c.lockdown)
    out:Result("in combat (unit)", c.affecting)
    if self:Val(c.lockdown, 1) == true or self:Val(c.affecting, 1) == true then
        out:Add("note: in combat, so secret-value restrictions may hide stats below")
    end

    out:Add("-- played time")
    if not self:Describe(s.played) then
        local values = s.played.values
        local tail = "[live: TIME_PLAYED_MSG received this session, " .. self:Age(values[3]) .. "]"
        out:Add("played total: " .. duration(values[1]) .. " " .. tail)
        out:Add("played this level: " .. duration(values[2]) .. " " .. tail)
    else
        local data = out:Stale("played time", s.playedStale)
        if data then
            out:Add("played total: " .. duration(data.total))
            out:Add("played this level: " .. duration(data.level))
        else
            out:Add("played: " .. self:Describe(s.played))
        end
    end
    out:Add("played request: " .. tostring(s.playedRequest or "<not_collected: RequestTimePlayed not called yet>"))
    if s.playedPersist and s.playedPersist ~= "saved" then
        out:Add("played persist: <error: " .. s.playedPersist .. ">")
    end

    out:Add("-- primary stats (UnitStat: effective, base, posBuff, negBuff)")
    local st = s.stats
    for _, stat in ipairs(PRIMARY) do
        local index = s.statIndex[stat.key]
        out:Result(stat.key, st[stat.key], function(_, values)
            return string.format("effective=%s base=%s posBuff=%s negBuff=%s [UnitStat index %s via %s]",
                num(values[2]), num(values[1]), num(values[3]), num(values[4]), index.index, index.source)
        end)
    end

    out:Add("-- attack and armor")
    out:Result("armor", st.armor, function(_, values)
        return string.format("effective=%s baseline=%s real=%s bonus=%s", num(values[2]), num(values[1]),
            num(values[3]), num(values[4]))
    end)
    out:Result("defense skill", st.defense, function(_, values)
        return string.format("base=%s modifier=%s", num(values[1]), num(values[2]))
    end)
    local function attackPower(values)
        local total = values[1]
        if type(total) == "number" and type(values[2]) == "number" and type(values[3]) == "number" then
            total = values[1] + values[2] + values[3]
        end
        return string.format("effective=%s base=%s posBuff=%s negBuff=%s", num(total), num(values[1]),
            num(values[2]), num(values[3]))
    end
    out:Result("melee attack power", st.attackPower, function(_, values) return attackPower(values) end)
    out:Result("ranged attack power", st.rangedAttackPower, function(_, values) return attackPower(values) end)
    out:Result("melee damage", st.meleeDamage, function(_, values)
        return string.format("mainhand %s-%s, offhand %s-%s, physical bonus +%s/%s, multiplier %s",
            num(values[1]), num(values[2]), num(values[3]), num(values[4]), num(values[5]), num(values[6]),
            num(values[7]))
    end)
    out:Result("ranged damage", st.rangedDamage, function(_, values)
        return string.format("%s-%s, speed %s, bonus +%s/%s, multiplier %s", num(values[2]), num(values[3]),
            num(values[1]), num(values[4]), num(values[5]), num(values[6]))
    end)
    out:Result("attack speed", st.attackSpeed, function(_, values)
        return string.format("mainhand=%s offhand=%s ranged=%s", num(values[1]), num(values[2]), num(values[3]))
    end)

    out:Add("-- crit, hit, haste")
    out:Result("crit melee", st.critMelee, pct)
    out:Result("crit ranged", st.critRanged, pct)
    out:Result("crit spell", st.critSpell, pct)
    local h = s.hit
    hitLine(self, out, "hit melee", h.meleeRating, h.meleeModifier)
    hitLine(self, out, "hit ranged", h.rangedRating, h.rangedModifier)
    hitLine(self, out, "hit spell", h.spellRating, h.spellModifier)
    out:Result("haste melee", st.hasteMelee, pct)
    out:Result("haste ranged", st.hasteRanged, function(_, values)
        return string.format("%s (base %s + quiver %s)", pct(type(values[1]) == "number" and type(values[2]) == "number"
            and values[1] + values[2] or nil), pct(values[1]), pct(values[2]))
    end)
    out:Result("haste spell", st.hasteSpell, pct)
    out:Result("expertise", st.expertise, function(_, values)
        return string.format("mainhand=%s offhand=%s ranged=%s", pct(values[1]), pct(values[2]), pct(values[3]))
    end)
    out:Result("armor penetration", st.armorPenetration, num)

    out:Add("-- avoidance")
    out:Result("dodge", st.dodge, pct)
    out:Result("parry", st.parry, pct)
    out:Result("block", st.block, pct)

    out:Add("-- spell and mana")
    if s.spellDamageState then
        out:State("spell power by school", s.spellDamageState)
    else
        local parts = {}
        local school = 2
        while s.spellDamage[school] do
            local result = s.spellDamage[school]
            parts[#parts + 1] = school .. "=" .. (self:Describe(result) or num(self:Val(result, 1)))
            school = school + 1
        end
        out:Add("spell power by school (school index=bonus): " .. table.concat(parts, " "))
    end
    out:Result("spell healing", st.spellHealing, num)
    out:Result("spell penetration", st.spellPenetration, num)
    out:Result("mana regen", st.manaRegen, function(_, values)
        return string.format("base=%s casting=%s (per second)", num(values[1]), num(values[2]))
    end)
end

Addon:RegisterCollector("character", collect, format)
