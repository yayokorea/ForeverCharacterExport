-- Mocked contract tests for the character collector. Not a WoW runtime.
local Addon = AddonUnderTest

local function fullApis(overrides)
    local apis = {
        UnitName = function() return "Yayo", "" end,
        GetRealmName = function() return "Forever" end,
        GetNormalizedRealmName = function() return "Forever" end,
        UnitRace = function() return "Orc", "Orc", 2 end,
        UnitClass = function() return "Hunter", "HUNTER", 3 end,
        UnitSex = function() return 2 end,
        UnitFactionGroup = function() return "Horde", "Horde" end,
        UnitLevel = function() return 42 end,
        GetLocale = function() return "koKR" end,
        UnitXP = function() return 1500 end,
        UnitXPMax = function() return 6000 end,
        GetXPExhaustion = function() return 600 end,
        IsResting = function() return true end,
        GetMoney = function() return 123456 end,
        GetZoneText = function() return "Tanaris" end,
        GetSubZoneText = function() return "" end,
        GetRealZoneText = function() return "Tanaris" end,
        GetBindLocation = function() return "Orgrimmar" end,
        UnitHealth = function() return 2000 end,
        UnitHealthMax = function() return 2500 end,
        UnitPowerType = function() return 0, "MANA", 0, 0, 1 end,
        UnitPower = function() return 800 end,
        UnitPowerMax = function() return 1000 end,
        IsInGuild = function() return true end,
        GetGuildInfo = function() return "Guild", "Officer", 1, "Forever" end,
        InCombatLockdown = function() return false end,
        UnitAffectingCombat = function() return false end,
        UnitStat = function(_, index) return 100 + index, 120 + index, 20, -1 end,
        UnitArmor = function() return 100, 900, 800, 100 end,
        UnitDefenseSkill = function() return 210, 5 end,
        UnitAttackPower = function() return 100, 10, -2 end,
        UnitRangedAttackPower = function() return 300, 20, -5 end,
        UnitDamage = function() return 10, 20, 0, 0, 1, -1, 1 end,
        UnitRangedDamage = function() return 2.3, 50, 90, 0, 0, 1 end,
        UnitAttackSpeed = function() return 2.6, nil, 2.3 end,
        GetCritChance = function() return 5.5 end,
        GetRangedCritChance = function() return 12.25 end,
        GetSpellCritChance = function() return 3 end,
        GetDodgeChance = function() return 6.5 end,
        GetParryChance = function() return 4 end,
        GetBlockChance = function() return 0 end,
        GetMeleeHaste = function() return 1 end,
        GetRangedHaste = function() return 2, 3 end,
        UnitSpellHaste = function() return 0 end,
        GetExpertise = function() return 1, 2, 3 end,
        GetArmorPenetration = function() return 0 end,
        GetSpellBonusHealing = function() return 7 end,
        GetSpellPenetration = function() return 0 end,
        GetManaRegen = function() return 4, 2 end,
        GetCombatRatingBonus = function(index) return index end,
        GetHitModifier = function() return 1 end,
        GetRangedHitModifier = function() return 2 end,
        GetSpellHitModifier = function() return 3 end,
        GetSpellBonusDamage = function(school) return school * 10 end,
        CR_HIT_MELEE = 6, CR_HIT_RANGED = 7, CR_HIT_SPELL = 8, MAX_SPELL_SCHOOLS = 7,
        LE_UNIT_STAT_STRENGTH = 1, LE_UNIT_STAT_AGILITY = 2, LE_UNIT_STAT_STAMINA = 3,
        LE_UNIT_STAT_INTELLECT = 4, LE_UNIT_STAT_SPIRIT = 5,
        C_Map = {
            GetBestMapForUnit = function() return 1446 end,
            GetMapInfo = function() return { mapID = 1446, name = "Tanaris", mapType = 3, parentMapID = 12 } end,
            GetPlayerMapPosition = function() return { x = 0.5, y = 0.25 } end,
        },
    }
    for key, value in pairs(overrides or {}) do apis[key] = value end
    return apis
end

local function render(apis)
    local text
    WithGlobals(apis, function()
        local section = Addon.collectors.character(Addon)
        local out = Addon:NewWriter()
        Addon.formatters.character(Addon, section, out)
        text = out:Output()
    end)
    return text
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing: " .. needle .. "\n" .. text)
end

-- Isolate played-time state and the saved variables for one test.
local function isolated(fn)
    local info, db, request, persist = Addon.playedInfo, Addon.db, Addon.playedRequest, Addon.playedPersist
    Addon.playedInfo, Addon.db, Addon.playedRequest, Addon.playedPersist = nil, { snapshots = {} }, nil, nil
    local ok, err = pcall(fn)
    Addon.playedInfo, Addon.db, Addon.playedRequest, Addon.playedPersist = info, db, request, persist
    if not ok then error(err, 0) end
end

Tests["collector.character.normal"] = function()
    isolated(function()
        local text = render(fullApis())
        has(text, "name: Yayo")
        has(text, "realm: Forever")
        has(text, "race: Orc (token Orc, id 2)")
        has(text, "class: Hunter (token HUNTER, id 3)")
        has(text, "sex: 2 (raw UnitSex")
        has(text, "faction: Horde (localized Horde)")
        has(text, "level: 42")
        has(text, "game locale: koKR")
        has(text, "xp: 1500 / 6000 (25.00%)")
        has(text, "xp to next level: 4500")
        has(text, "rested xp: 600 (10.00% of this level)")
        has(text, "resting: true")
        has(text, "money: 12g 34s 56c")
        has(text, "money (raw copper): 123456")
        has(text, "zone: Tanaris")
        has(text, "subzone: <empty string: none>")
        has(text, "map ID: 1446")
        has(text, "map name: Tanaris (type 3, parent map 12)")
        has(text, "map position: x=50.00 y=25.00")
        has(text, "bind location (hearthstone): Orgrimmar")
        has(text, "health: 2000")
        has(text, "primary power type: 0 (token MANA)")
        has(text, "primary power: 800")
        has(text, "primary power max: 1000")
        has(text, "guild: Guild | rank Officer (rank index 1")
        has(text, "in combat (lockdown): false")
        -- Every primary stat is printed by name with its four returns, and the ranged stats are present.
        has(text, "strength: effective=121 base=101 posBuff=20 negBuff=-1 [UnitStat index 1 via LE_UNIT_STAT_STRENGTH]")
        has(text, "agility: effective=122 base=102")
        has(text, "stamina: effective=123")
        has(text, "intellect: effective=124")
        has(text, "spirit: effective=125")
        has(text, "armor: effective=900 baseline=100 real=800 bonus=100")
        has(text, "melee attack power: effective=108 base=100 posBuff=10 negBuff=-2")
        has(text, "ranged attack power: effective=315 base=300 posBuff=20 negBuff=-5")
        has(text, "ranged damage: 50-90, speed 2.30")
        has(text, "attack speed: mainhand=2.60 offhand=<nil> ranged=2.30")
        has(text, "crit melee: 5.50%")
        has(text, "crit ranged: 12.25%")
        has(text, "crit spell: 3.00%")
        has(text, "hit melee: 7.00% (rating bonus 6.00% + modifier 1.00%)")
        has(text, "hit ranged: 9.00% (rating bonus 7.00% + modifier 2.00%)")
        has(text, "hit spell: 11.00% (rating bonus 8.00% + modifier 3.00%)")
        has(text, "haste ranged: 5.00% (base 2.00% + quiver 3.00%)")
        has(text, "expertise: mainhand=1.00% offhand=2.00% ranged=3.00%")
        has(text, "dodge: 6.50%")
        has(text, "spell power by school (school index=bonus): 2=20 3=30 4=40 5=50 6=60 7=70")
        has(text, "mana regen: base=4 casting=2")
        assert(not string.find(text, "main stat", 1, true), "no main stat label may be printed")
    end)
end

Tests["collector.character.empty_values"] = function()
    isolated(function()
        local text = render(fullApis({
            GetXPExhaustion = function() end,
            IsInGuild = function() return false end,
            GetGuildInfo = function() error("must not be called when not in a guild") end,
            UnitXPMax = function() return 0 end,
        }))
        has(text, "rested xp: <empty: nil return; the default XP bar treats this as no rested XP")
        has(text, "in guild: false")
        has(text, "guild: <empty: IsInGuild returned false [GetGuildInfo]>")
        has(text, "max is 0")
    end)
end

Tests["collector.character.missing_apis_are_unsupported"] = function()
    isolated(function()
        local text = render({})
        has(text, "name: <unsupported: function unavailable at runtime [UnitName]>")
        has(text, "strength: <unsupported")
        has(text, "ranged attack power: <unsupported")
        has(text, "map position: <not_collected: no map ID")
        has(text, "xp to next level: <not_collected")
        has(text, "hit melee: rating bonus <not_collected: constant CR_HIT_MELEE is not defined")
        has(text, "spell power by school: <not_collected: constant MAX_SPELL_SCHOOLS is not defined>")
        local counts = Addon:Tally(Addon.collectors.character(Addon))
        assert(counts.ok == 0 and counts.unsupported > 20, "unsupported APIs must be counted")
    end)
end

Tests["collector.character.restricted_value_keeps_other_stats"] = function()
    isolated(function()
        local text = render(fullApis({
            UnitHealth = function() return FCE_SECRET end,
            UnitStat = function(_, index)
                if index == 2 then return FCE_DENIED end
                return 10, 11, 0, 0
            end,
            GetRangedCritChance = function() return FCE_SECRET end,
        }))
        has(text, "health: <restricted: API returned a secret or inaccessible value [UnitHealth]>")
        has(text, "agility: <restricted")
        has(text, "crit ranged: <restricted")
        has(text, "strength: effective=11 base=10")
        has(text, "crit melee: 5.50%")
        has(text, "armor: effective=900")
    end)
end

Tests["collector.character.nil_returns_stay_not_collected"] = function()
    isolated(function()
        local text = render(fullApis({
            UnitLevel = function() end,
            GetBindLocation = function() end,
            GetCritChance = function() end,
            GetGuildInfo = function() end,
            C_Map = {
                GetBestMapForUnit = function() return 1446 end,
                GetMapInfo = function() end,
                GetPlayerMapPosition = function() end,
            },
        }))
        has(text, "level: <not_collected: API returned no value; readiness/availability unresolved [UnitLevel]>")
        has(text, "bind location (hearthstone): <not_collected")
        has(text, "crit melee: <not_collected")
        has(text, "map position: <not_collected: no position returned (not available in this zone or instance)")
        has(text, "map name: <not_collected")
        has(text, "guild: <not_collected: IsInGuild is true but GetGuildInfo returned nothing")
        assert(not string.find(text, "crit melee: 0", 1, true))
    end)
end

Tests["collector.character.map_position_object_with_methods"] = function()
    isolated(function()
        local mixin = { x = 0.1, y = 0.9, GetXY = function(self) return self.x, self.y end }
        local text = render(fullApis({
            C_Map = {
                GetBestMapForUnit = function() return 1446 end,
                GetMapInfo = function() return { mapID = 1446, name = "Tanaris", mapType = 3, parentMapID = 12 } end,
                GetPlayerMapPosition = function() return mixin end,
            },
        }))
        has(text, "map position: x=10.00 y=90.00")
        -- Only GetXY (no plain fields) still works; a secret coordinate is restricted.
        local viaMethod = { GetXY = function() return 0.2, 0.3 end }
        text = render(fullApis({ C_Map = { GetBestMapForUnit = function() return 1 end,
            GetMapInfo = function() return nil end, GetPlayerMapPosition = function() return viaMethod end } }))
        has(text, "map position: x=20.00 y=30.00")
        text = render(fullApis({ C_Map = { GetBestMapForUnit = function() return 1 end,
            GetMapInfo = function() return nil end,
            GetPlayerMapPosition = function() return { x = FCE_SECRET, y = 0.5 } end } }))
        has(text, "map position: <restricted")
        text = render(fullApis({ C_Map = { GetBestMapForUnit = function() return 1 end,
            GetMapInfo = function() return nil end,
            GetPlayerMapPosition = function() error("boom") end } }))
        has(text, "map position: <error: ")
        has(text, "boom")
    end)
end

Tests["collector.character.stat_index_fallback"] = function()
    isolated(function()
        local seen = {}
        local text = render(fullApis({
            LE_UNIT_STAT_STRENGTH = false, LE_UNIT_STAT_AGILITY = false, LE_UNIT_STAT_STAMINA = false,
            LE_UNIT_STAT_INTELLECT = false, LE_UNIT_STAT_SPIRIT = false,
            UnitStat = function(_, index) seen[#seen + 1] = index return 1, 1, 0, 0 end,
        }))
        assert(table.concat(seen, ",") == "1,2,3,4,5", table.concat(seen, ","))
        has(text, "[UnitStat index 2 via UI stat list order]")
    end)
end

Tests["collector.character.played_live_and_stale"] = function()
    isolated(function()
        local apis = fullApis()
        -- Nothing received yet and nothing stored.
        local text = render(apis)
        has(text, "played time: <not_collected: no snapshot stored yet>")
        has(text, "played: <not_collected: no TIME_PLAYED_MSG received this session")
        -- A stored snapshot from an earlier session is printed as stale, never as live.
        Addon:Persist("played", { total = 90061, level = 3600 })
        text = render(apis)
        has(text, "played time: [stale snapshot captured")
        has(text, "played total: 1d 1h 1m 1s (90061 seconds)")
        assert(not string.find(text, "[live:", 1, true), text)
        -- Event this session: live, with age; the stale snapshot is no longer shown.
        WithGlobals({ GetServerTime = function() return 1000 end }, function()
            Addon.Dispatch(nil, "TIME_PLAYED_MSG", 7200, 600)
        end)
        assert(Addon.playedInfo.total == 7200 and Addon.playedInfo.level == 600)
        assert(Addon:Persisted("played").data.total == 7200)
        WithGlobals({ GetServerTime = function() return 1030 end }, function()
            text = render(apis)
        end)
        has(text, "played total: 0d 2h 0m 0s (7200 seconds) [live: TIME_PLAYED_MSG received this session, 30s ago]")
        has(text, "played this level: 0d 0h 10m 0s (600 seconds) [live")
        assert(not string.find(text, "stale", 1, true), text)
    end)
end

Tests["collector.character.played_event_rejects_bad_payload"] = function()
    isolated(function()
        Addon.Dispatch(nil, "TIME_PLAYED_MSG")
        Addon.Dispatch(nil, "TIME_PLAYED_MSG", "x", 1)
        Addon.Dispatch(nil, "TIME_PLAYED_MSG", 5, nil)
        Addon.Dispatch(nil, "TIME_PLAYED_MSG", FCE_SECRET, 1)
        assert(Addon.playedInfo == nil)
        assert(Addon:Persisted("played") == nil)
    end)
end

Tests["collector.character.played_persist_without_saved_variables"] = function()
    isolated(function()
        Addon.db = nil
        Addon.Dispatch(nil, "TIME_PLAYED_MSG", 100, 50)
        assert(Addon.playedInfo.total == 100, "live value is kept even when saving fails")
        assert(Addon.playedPersist == "saved variables not loaded", tostring(Addon.playedPersist))
        local text = render(fullApis())
        has(text, "played total: 0d 0h 1m 40s (100 seconds) [live")
        has(text, "played persist: <error: saved variables not loaded>")
    end)
end

-- The once flag is module state and cannot be reset, so first login and second login are checked in one test.
Tests["collector.character.login_requests_time_played_once"] = function()
    isolated(function()
        local errorsBefore = #Addon.handlerErrors
        local calls = 0
        WithGlobals({ RequestTimePlayed = function() calls = calls + 1 end }, function()
            Addon.Dispatch(nil, "PLAYER_LOGIN")
            assert(calls == 1, "RequestTimePlayed must be called at the first login, calls=" .. calls)
            Addon.Dispatch(nil, "PLAYER_LOGIN")
            assert(calls == 1, "RequestTimePlayed must be called only once, calls=" .. calls)
        end)
        assert(Addon.playedRequest == "requested at login", tostring(Addon.playedRequest))
        has(render(fullApis()), "played request: requested at login")
        for index = #Addon.handlerErrors, errorsBefore + 1, -1 do Addon.handlerErrors[index] = nil end
    end)
end

Tests["collector.character.in_combat_note"] = function()
    isolated(function()
        local text = render(fullApis({ InCombatLockdown = function() return true end }))
        has(text, "in combat (lockdown): true")
        has(text, "note: in combat, so secret-value restrictions may hide stats below")
    end)
end
