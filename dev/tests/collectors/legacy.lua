-- Mocked contract tests for the legacy collector (not a WoW runtime). Every number below is a fixture, not game data.
-- luacheck: read globals Constants EVALUATION_TREE_FLAG_PROGRESS_BAR LEGACY_TREE_PROFESSIONS LEGACY_TREE_ADVENTURE
-- luacheck: read globals LEGACY_TREE_PROGRESSION
local function run()
    local addon = AddonUnderTest
    local section = addon.collectors.legacy(addon)
    local out = addon:NewWriter()
    addon.formatters.legacy(addon, section, out)
    return out:Output(), section
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function lacks(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

local CONSTS = {
    LEGACY_REWARD_TRACK_FACTION_ID = 900, LEGACY_POINTS_TRAIT_CURRENCY_ID = 700,
    LEGACY_TREE_PROFESSIONS_ID = 11, LEGACY_TREE_ADVENTURE_ID = 12, LEGACY_TREE_PROGRESSION_ID = 13,
    LEGACY_DEFAULT_CATEGORY_HUNTER = 502,
}

-- Categories: 500 (top, no challenges), 502 (Hunter default, child of 500), 503 (other, top level).
-- Achievements (id, name, points, completed, month, day, year, description, flags, icon, rewardText, isGuild, earnedByMe)
local function fixture(options)
    options = options or {}
    local categories = options.categories or { 500, 502, 503 }
    local info = {
        [500] = { "Legacy", -1 }, [502] = { "Hunter", 500 }, [503] = { "General", -1 },
    }
    local counts = { [500] = { 0, 0, 0 }, [502] = { 3, 1, 2 }, [503] = { 1, 0, 1 } }
    local achievements = options.achievements or {
        [502] = {
            { 7001, "Mine", 5, true, 1, 2, 3, "Done here", 0, 0, "", false, true },
            { 7002, "Alt did it", 5, true, 1, 2, 3, "Done elsewhere", 0, 0, "", false, false },
            { 7003, "Kill things", 5, false, 0, 0, 0, "Do |cff00ff00stuff|r", 0, 0, "", false, false },
        },
        [503] = { { 7100, "General one", 1, false, 0, 0, 0, "x", 0, 0, "", false, false } },
    }
    local criteria = options.criteria or {
        [7002] = { { "Alt part", 1, true, 1, 1, "", 0 } },
        [7003] = { { "Slay 10", 0, false, 4, 10, "", 1 }, { "Visit", 0, false, 0, 0, "", 0 } },
        [7100] = {},
    }
    local mocks = {
        Constants = { LegacyConsts = options.consts or CONSTS },
        LEGACY_TREE_PROFESSIONS = "Professions Name", LEGACY_TREE_ADVENTURE = "Adventure Name",
        LEGACY_TREE_PROGRESSION = "Progression Name",
        EVALUATION_TREE_FLAG_PROGRESS_BAR = not options.noFlag and 1 or false,
        bit = { band = function(a, b) return (a % (2 * b)) >= b and b or 0 end },
        GetCategoryList = options.categoryList or function() return categories end,
        GetCategoryInfo = function(id) return info[id][1], info[id][2] end,
        GetCategoryNumAchievements = function(id) return unpack(counts[id]) end,
        GetAchievementInfo = options.achievementInfo or function(category, index)
            local row = achievements[category] and achievements[category][index]
            if row then return unpack(row, 1, 13) end
        end,
        GetAchievementNumCriteria = function(id)
            return criteria[id] and #criteria[id] or nil
        end,
        GetAchievementCriteriaInfo = function(id, index) return unpack(criteria[id][index]) end,
        UnitClassBase = function() return options.classFile or "HUNTER", 3 end,
        C_AddOns = { IsAddOnLoaded = function() return false, false end },
        C_Traits = {
            GetTraitCurrencyForAchievement = function(currency, id)
                assert(currency == 700)
                return id == 7003 and 3 or 1
            end,
            GetConfigIDByTreeID = options.configByTree or function(tree) return tree * 10 end,
            ConfigHasStagedChanges = function() return options.staged == true end,
            GetTreeCurrencyInfo = options.currency or function(config, tree, exclude)
                assert(config == tree * 10)
                if options.staged and exclude == false then
                    return { { traitCurrencyID = 700, quantity = 4, maxQuantity = 16, spent = 5, spentInTree = 1 } }
                end
                return { { traitCurrencyID = 700, quantity = 5, maxQuantity = 16, spent = 4, spentInTree = tree == 12 and 4 or 0 } }
            end,
            GetMaxAvailableTraitCurrency = function(currency, limit)
                assert(currency == 700 and limit == false)
                return 16
            end,
            GetTreeNodes = function(tree) return tree == 12 and { 1, 2 } or { 3 } end,
            GetNodeInfo = options.nodeInfo or function(_, node)
                if node == 1 then
                    return { currentRank = 2, ranksPurchased = 2, maxRanks = 3, activeEntry = { entryID = 50 } }
                end
                return { currentRank = 0, ranksPurchased = 0, maxRanks = 1, entryIDs = { 51 } }
            end,
            GetEntryInfo = function(_, entry) return { definitionID = entry + 10 } end,
            GetDefinitionInfo = function(def) return { spellID = def + 100 } end,
        },
        C_Spell = { GetSpellName = function(id) return "Perk " .. id end },
        C_MajorFactions = {
            GetCurrentRenownLevel = function(faction)
                assert(faction == 900)
                return options.renown or 2
            end,
            GetMajorFactionData = function()
                return { name = "Legacy", isUnlocked = true, renownLevel = options.renown or 2, maxLevel = 3,
                    renownReputationEarned = 10, renownLevelThreshold = 100 }
            end,
            GetRenownLevels = options.renownLevels or function()
                return {
                    { factionID = 900, level = 1, locked = false, isMilestone = false, isCapstone = false },
                    { factionID = 900, level = 2, locked = false, isMilestone = true, isCapstone = false },
                    { factionID = 900, level = 3, locked = true, isMilestone = false, isCapstone = true },
                }
            end,
            GetRenownRewardsForLevel = function(_, level)
                if level == 3 then return { { name = "Big Mount", mountID = 77, isAccountUnlock = true, isCollected = false } } end
                return {}
            end,
        },
    }
    return mocks
end

Tests["collector.legacy.full_read"] = function()
    WithGlobals(fixture(), function()
        local text = run()
        has(text, "faction ID: 900")
        has(text, "renown level: 2")
        has(text, "level 2 [level locked=false, milestone, <- current level]")
        has(text, "level 3 [level locked=true, capstone, <- next reward]: Big Mount (mount 77, account unlock, reward already collected=false)")
        has(text, "track levels: 3 total, 3 listed (complete)")
        has(text, "pool: traitCurrencyID 700 (read from tree PROFESSIONS; matches LEGACY_POINTS_TRAIT_CURRENCY_ID)")
        has(text, "earned (UI shows renown level as points): 2")
        has(text, "available (unspent, quantity): 5")
        has(text, "spent (committed, pool-wide): 4")
        has(text, "maxQuantity: 16 (cap reported by the tree currency)")
        has(text, "relation to maxQuantity not proven): 16")
        -- source keys stay separate from display names
        has(text, "tree PROFESSIONS [display=Professions Name] treeID=11 configID=110")
        has(text, "tree ADVENTURE [display=Adventure Name] treeID=12 configID=120")
        has(text, "currency 700: spentInTree=4")
        has(text, "invested node 1 rank 2/3: Perk 160 (spellID 160)")
        has(text, "no invested nodes (all 1 nodes read with 0 ranks)")
        -- shared pool counted once, never summed
        has(text, "shared pool check: currency 700 seen in trees PROFESSIONS, ADVENTURE, PROGRESSION; identical values, counted once, not summed")
        lacks(text, "spent 12")
    end)
end

-- Full detail needs Addon.detail.legacy = true; the default (summary) is covered by the tests further down.
local function withDetail(value, fn)
    local addon = AddonUnderTest
    local saved = addon.detail
    addon.detail = value
    local ok, err = pcall(fn)
    addon.detail = saved
    assert(ok, err)
end

Tests["collector.legacy.challenges_account_vs_character"] = function()
    withDetail({ legacy = true }, function() WithGlobals(fixture(), function()
        local text = run()
        has(text, "category 502 \"Hunter\" parent=500 total=3 complete=1 incomplete=2 listed=3 [class default tree]")
        has(text, "default category ID for class: 502")
        has(text, "[7001] Mine | EARNED by this character | legacy points 1")
        has(text, "[7002] Alt did it | complete on account, NOT earned by this character | legacy points 1")
        has(text, "[7003] Kill things | incomplete | legacy points 3 | Do stuff")
        has(text, "listed summary: earned by this character 1, complete only on other characters 1, incomplete 2")
        has(text, "challenge detail: 4 listed")
        has(text, "(complete)")
        -- criteria only for challenges not earned by this character; progress only with the progress-bar flag
        has(text, "1: Slay 10 | not done | progress 4/10")
        has(text, "2: Visit | not done")
        lacks(text, "raw count")
        has(text, "7100")
        has(text, "상세 수준: 전체")
    end) end)
end

Tests["collector.legacy.class_default_listed_first_and_cap_marks_truncation"] = function()
    local addon = AddonUnderTest
    local saved = addon.legacyLimits.challengesFull
    addon.legacyLimits.challengesFull = 2
    local ok, err = pcall(function()
        withDetail({ legacy = "full" }, function() WithGlobals(fixture(), function()
            local text = run()
            has(text, "challenge detail: 2 listed (cap 2")
            has(text, "TRUNCATED")
            has(text, "[7001]")
            lacks(text, "[7100]")
            has(text, "listed=2")
        end) end)
    end)
    addon.legacyLimits.challengesFull = saved
    assert(ok, err)
end

Tests["collector.legacy.progress_flag_unverified_prints_raw"] = function()
    WithGlobals(fixture({ noFlag = true }), function()
        local text = run()
        has(text, "raw count 4/10 (progress-bar flag unverified, flags=1)")
        lacks(text, "progress 4/10")
    end)
end

Tests["collector.legacy.locked_does_not_report_zero_points"] = function()
    WithGlobals(fixture({ configByTree = function() end, currency = function() end, renownLevels = function() return {} end }),
        function()
            local text = run()
            has(text, "tree PROFESSIONS")
            has(text, "<not_collected: no trait config for this tree")
            has(text, "NOT evidence of zero investment")
            has(text, "NOT 0 points")
            has(text, "track levels: <not_collected: GetRenownLevels returned no levels")
            lacks(text, "available (unspent")
            lacks(text, "no invested nodes")
        end)
end

Tests["collector.legacy.renown_zero_is_reported_as_locked_hint"] = function()
    WithGlobals(fixture({ renown = 0 }), function()
        local text = run()
        has(text, "renown level: 0 (the Legacy UI refuses to open at renown level <= 0")
    end)
end

Tests["collector.legacy.missing_apis_are_unsupported"] = function()
    WithGlobals({ Constants = false, C_Traits = false, C_MajorFactions = false, GetCategoryList = false,
        C_AddOns = false }, function()
        local text, section = run()
        has(text, "Constants.LegacyConsts: <unsupported")
        has(text, "reward track: <unsupported")
        has(text, "<unsupported: Constants.LegacyConsts.LEGACY_TREE_PROFESSIONS_ID unavailable")
        has(text, "points: <not_collected")
        has(text, "challenges: <not_collected: challenge category list unavailable or empty")
        assert(section.challenges.categoryList.status == "unsupported")
        lacks(text, "available (unspent")
    end)
end

Tests["collector.legacy.staged_changes_are_separate"] = function()
    WithGlobals(fixture({ staged = true }), function()
        local text = run()
        has(text, "uncommitted staged changes: true")
        has(text, "available (unspent, quantity): 5")
        has(text, "staged (unapplied) view differs: available=4 spent=5")
        has(text, "node ranks below may include unapplied changes")
    end)
end

Tests["collector.legacy.partial_failures_keep_other_reads"] = function()
    local mocks = fixture({ nodeInfo = function(_, node)
        if node == 1 then error("node gone", 0) end
        return { currentRank = FCE_SECRET, ranksPurchased = 0 }
    end, achievementInfo = function(category, index)
        if category == 502 and index == 2 then error("achievement boom", 0) end
        if category == 502 and index == 1 then return 7001, "Mine", 5, true, 1, 2, 3, "d", 0, 0, "", false, true end
        if category == 502 and index == 3 then return 7003, "Kill things", 5, false, 0, 0, 0, "d", 0, 0, "", false, false end
        if category == 503 then return 7100, "General one", 1, false, 0, 0, 0, "x", 0, 0, "", false, false end
    end })
    WithGlobals(mocks, function()
        local text = run()
        has(text, "unreadable node 1: <error: node gone [C_Traits.GetNodeInfo]>")
        has(text, "invested nodes: <not_collected:")
        lacks(text, "no invested nodes")
        has(text, "category 502 #2: <error: achievement boom [GetAchievementInfo]>")
        has(text, "[7001] Mine | EARNED by this character")
        has(text, "[7003] Kill things | incomplete")
    end)
end

Tests["collector.legacy.secret_values_are_restricted"] = function()
    WithGlobals(fixture({ currency = function() return FCE_SECRET end }), function()
        local text = run()
        has(text, "currency: <restricted")
        has(text, "NOT 0 points")
    end)
end

Tests["collector.legacy.completed_flag_missing_is_unknown_not_incomplete"] = function()
    local mocks = fixture({ achievementInfo = function(category, index)
        if category == 502 and index == 1 then return 7001, "Odd", 5, nil, 1, 2, 3, "d", 0, 0, "", false, nil end
    end })
    WithGlobals(mocks, function()
        local text = run()
        has(text, "[7001] Odd | <not_collected: completed flag missing>")
        has(text, "unreadable/unknown")
    end)
end

Tests["collector.legacy.never_calls_state_changing_apis"] = function()
    local mocks = fixture()
    local forbidden = { "LoadAddOn", "C_AddOns.LoadAddOn", "SetAchievementSearchString", "SetAchievementFilter",
        "ToggleLegacySystemUI", "ToggleLegacyChallenges", "ShowLegacyChallenge" }
    local called = {}
    for _, name in ipairs(forbidden) do
        if not string.find(name, ".", 1, true) then
            mocks[name] = function() called[#called + 1] = name end
        end
    end
    mocks.C_AddOns.LoadAddOn = function() called[#called + 1] = "C_AddOns.LoadAddOn" end
    WithGlobals(mocks, function() run() end)
    assert(#called == 0, "state-changing API called: " .. table.concat(called, ","))
end

Tests["collector.legacy.summary_details_only_class_and_my_skills"] = function()
    local mocks = fixture()
    -- the character has a skill named like category 503 ("General") -> that category is also detailed
    mocks.C_SkillInfo = {
        GetNumSkillLines = function() return 2 end,
        GetSkillLineInfo = function(i)
            if i == 1 then return { name = "Header", isHeader = true, skillID = 1 } end
            return { name = "General", isHeader = false, skillID = 2 }
        end,
    }
    withDetail(nil, function() WithGlobals(mocks, function()
        local text = run()
        has(text, "상세 수준: 요약")
        has(text, "category 503 \"General\"")
        has(text, "[my skill]")
        has(text, "[7001]")
        has(text, "[7100]")
        has(text, "내 전문기술/기술 이름과 일치한 카테고리: 1개")
        lacks(text, "category 502 \"Hunter\" parent=500 total=3 complete=1 incomplete=2 listed=3 [class default tree] [counts only]")
    end) end)
end

Tests["collector.legacy.summary_lists_unmatched_categories_as_counts_only"] = function()
    withDetail({}, function() WithGlobals(fixture(), function()
        local text, section = run()
        -- no skill API in the fixture: only the class category is detailed, 503 shows counts only
        has(text, "category 503 \"General\" parent=-1 total=1 complete=0 incomplete=1 listed=0 [counts only]")
        has(text, "[7003]")
        lacks(text, "[7100]")
        has(text, "skill line list unreadable")
        assert(section.challenges.full == false)
    end) end)
end

Tests["collector.legacy.major_faction_struct_with_function_member_is_read_by_field"] = function()
    local mocks = fixture()
    mocks.C_MajorFactions.GetMajorFactionData = function()
        return { name = "Legacy", isUnlocked = true, renownLevel = 2, maxLevel = 3, renownReputationEarned = 10,
            renownLevelThreshold = 100, factionFontColor = { GetRGB = function() end }, highlights = { { title = "x" } } }
    end
    WithGlobals(mocks, function()
        local text, section = run()
        assert(section.reward.data.status == "ok", text)
        has(text, "faction data: name=Legacy isUnlocked=true renownLevel=2 maxLevel=3 progress=10/100")
    end)
end

Tests["collector.legacy.major_faction_secret_field_is_restricted"] = function()
    local mocks = fixture()
    mocks.C_MajorFactions.GetMajorFactionData = function() return { name = FCE_SECRET } end
    WithGlobals(mocks, function()
        local _, section = run()
        assert(section.reward.data.status == "restricted")
    end)
end
