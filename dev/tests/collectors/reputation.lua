-- Mocked contract tests for the reputation collector. Not a WoW runtime.
local Addon = AddonUnderTest

local function run()
    local section = Addon.collectors.reputation(Addon)
    local out = Addon:NewWriter()
    Addon.formatters.reputation(Addon, section, out)
    return section, out:Output()
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function lacks(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

local function faction(overrides)
    local data = {
        factionID = 69, name = "다르나서스", description = "", reaction = 5,
        currentReactionThreshold = 3000, nextReactionThreshold = 9000, currentStanding = 7760,
        atWarWith = false, canToggleAtWar = true, isChild = true, isHeader = false, isHeaderWithRep = false,
        isCollapsed = false, isWatched = false, hasBonusRepGain = false, canSetInactive = true,
        isAccountWide = false,
    }
    for key, value in pairs(overrides or {}) do data[key] = value end
    return data
end

local function header(overrides)
    local data = faction({
        factionID = 469, name = "얼라이언스", reaction = 4, currentReactionThreshold = 0,
        nextReactionThreshold = 0, currentStanding = 0, isChild = false, isHeader = true, canToggleAtWar = false,
        canSetInactive = false,
    })
    for key, value in pairs(overrides or {}) do data[key] = value end
    return data
end

local function api(list, extra)
    local rep = {
        GetNumFactions = function() return #list end,
        GetFactionDataByIndex = function(index) return list[index] end,
        GetReputationSortType = function() return 0 end,
        AreLegacyReputationsShown = function() return false end,
        GetWatchedFactionData = function() return nil end,
        IsFactionActive = function() return true end,
    }
    for key, value in pairs(extra or {}) do rep[key] = value end
    return rep
end

local function labels(token, gender)
    assert(gender == 2, "gender is passed through")
    local map = { FACTION_STANDING_LABEL5 = "우호적", FACTION_STANDING_LABEL6 = "매우 우호적" }
    return map[token]
end

Tests["collector.reputation.normal_groups_and_values"] = function()
    local list = {
        header(),
        faction({ factionID = 54, name = "놈리건", reaction = 6, currentReactionThreshold = 9000,
            nextReactionThreshold = 21000, currentStanding = 10000 }),
        faction({ isWatched = true }),
    }
    WithGlobals({ C_Reputation = api(list), UnitSex = function() return 2 end, GetText = labels }, function()
        local section, text = run()
        assert(section.count.status == "ok")
        has(text, "### 얼라이언스 (469)")
        has(text, "- 다르나서스 (69): standing=5 (우호적) progress=4760/6000 value=7760 range=3000..9000")
        has(text, "watched=yes")
        has(text, "atWar=no(toggle=yes)")
        has(text, "active=yes")
        has(text, "- 놈리건 (54): standing=6 (매우 우호적) progress=1000/12000")
        has(text, "counts: 2 factions, 1 headers, 0 unreadable rows")
        has(text, "completeness: no collapsed header")
        has(text, "watched: <empty: no faction is watched (declared nilable return) [C_Reputation.GetWatchedFactionData]>")
        has(text, "sort type: 0 (None)")
    end)
end

Tests["collector.reputation.watched_faction_reported"] = function()
    local list = { header(), faction({ isWatched = true }) }
    local extra = { GetWatchedFactionData = function() return list[2] end }
    WithGlobals({ C_Reputation = api(list, extra), UnitSex = function() return 2 end, GetText = labels }, function()
        local _, text = run()
        has(text, "watched: 다르나서스 (69)")
    end)
end

Tests["collector.reputation.collapsed_header_is_not_complete"] = function()
    local list = { header({ isCollapsed = true }), header({ factionID = 67, name = "호드", isCollapsed = false }) }
    WithGlobals({ C_Reputation = api(list), UnitSex = function() return 2 end, GetText = labels }, function()
        local section, text = run()
        assert(#section.collapsed == 1 and section.collapsed[1].factionID == 469)
        has(text, "completeness: INCOMPLETE - 1 collapsed header(s)")
        has(text, "<not_collected: header collapsed; children hidden, not expanded>")
        lacks(text, "completeness: no collapsed header")
    end)
end

Tests["collector.reputation.header_with_own_reputation"] = function()
    local list = { header({ isHeaderWithRep = true, reaction = 5, currentReactionThreshold = 3000,
        nextReactionThreshold = 9000, currentStanding = 3500 }) }
    WithGlobals({ C_Reputation = api(list), UnitSex = function() return 2 end, GetText = labels }, function()
        local _, text = run()
        has(text, "### 얼라이언스 (469)")
        has(text, "header rep standing=5 (우호적) progress=500/6000")
    end)
end

Tests["collector.reputation.empty_list_is_empty"] = function()
    WithGlobals({ C_Reputation = api({}) }, function()
        local section, text = run()
        assert(section.count.status == "empty")
        has(text, "rows: <empty: GetNumFactions returned 0 [C_Reputation.GetNumFactions]>")
    end)
end

Tests["collector.reputation.missing_api_is_unsupported"] = function()
    WithGlobals({ C_Reputation = false }, function()
        local section, text = run()
        assert(section.count.status == "unsupported")
        has(text, "rows: <unsupported: function unavailable at runtime [C_Reputation.GetNumFactions]>")
    end)
end

Tests["collector.reputation.nil_count_stays_not_collected"] = function()
    local rep = api({}, { GetNumFactions = function() return nil end })
    WithGlobals({ C_Reputation = rep }, function()
        local section = run()
        assert(section.count.status == "not_collected")
    end)
end

Tests["collector.reputation.restricted_row_does_not_erase_the_rest"] = function()
    local list = { header(), faction({ name = FCE_SECRET }), faction({ factionID = 54, name = "놈리건" }) }
    WithGlobals({ C_Reputation = api(list), UnitSex = function() return 2 end, GetText = labels }, function()
        local _, text = run()
        has(text, "#2: <restricted: API returned a secret or inaccessible value [C_Reputation.GetFactionDataByIndex]>")
        has(text, "- 놈리건 (54): standing=5")
        has(text, "counts: 1 factions, 1 headers, 1 unreadable rows")
    end)
end

Tests["collector.reputation.nil_row_stays_not_collected"] = function()
    local rep = api({ header(), faction() }, {
        GetNumFactions = function() return 3 end,
        GetFactionDataByIndex = function(index)
            if index == 1 then return header() end
            if index == 3 then return faction({ factionID = 47, name = "아이언포지" }) end
            return nil
        end,
    })
    WithGlobals({ C_Reputation = rep, UnitSex = function() return 2 end, GetText = labels }, function()
        local _, text = run()
        has(text, "#2: <not_collected: API returned no value; readiness/availability unresolved")
        has(text, "- 아이언포지 (47)")
    end)
end

Tests["collector.reputation.missing_standing_text_and_active_are_tagged"] = function()
    local rep = api({ header(), faction() })
    rep.IsFactionActive = nil
    WithGlobals({ C_Reputation = rep, UnitSex = false, GetText = false }, function()
        local _, text = run()
        has(text, "standing text unavailable for reaction: 5 <unsupported: function unavailable at runtime [GetText]>")
        has(text, "active flag unavailable on 1 rows: <unsupported")
        has(text, "- 다르나서스 (69): standing=5 progress=4760/6000")
        lacks(text, "active=")
    end)
end

Tests["collector.reputation.inactive_faction_is_flagged"] = function()
    local rep = api({ header(), faction() }, { IsFactionActive = function() return false end })
    WithGlobals({ C_Reputation = rep, UnitSex = function() return 2 end, GetText = labels }, function()
        local _, text = run()
        has(text, "active=no (inactive/hidden)")
    end)
end

Tests["collector.reputation.invalid_count_is_error"] = function()
    local rep = api({}, { GetNumFactions = function() return -1 end })
    WithGlobals({ C_Reputation = rep }, function()
        local section = run()
        assert(section.count.status == "error")
    end)
end
