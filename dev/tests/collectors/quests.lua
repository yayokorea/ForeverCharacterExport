-- Mocked contract tests for the quests collector (not a WoW runtime).
local Addon = AddonUnderTest

local function header(title, collapsed)
    return { isHeader = true, isCollapsed = collapsed ~= false, questID = 0, title = title, level = 0 }
end

local function quest(id, title, level, extra)
    local info = { isHeader = false, isCollapsed = true, questID = id, title = title, level = level, frequency = 0,
        isTask = false, suggestedGroup = 0 }
    for key, value in pairs(extra or {}) do info[key] = value end
    return info
end

-- 3 headers + 3 quests, headers collapsed like the real game output; 3 quest rows == API total 3.
local function logApi(rows, overrides)
    local api = {
        GetNumQuestLogEntries = function()
            local quests = 0
            for _, row in ipairs(rows) do
                if not row.isHeader then quests = quests + 1 end
            end
            return #rows, quests
        end,
        GetMaxNumQuestsCanAccept = function() return 25 end,
        GetInfo = function(index) return rows[index] end,
        IsComplete = function(id) return id == 2002 end,
        ReadyForTurnIn = function(id) return id == 2002 end,
        GetQuestObjectives = function(id)
            if id == 2001 then
                return { { text = "Kill 3 boars: 1/3", type = "monster", finished = false, numFulfilled = 1, numRequired = 3 } }
            elseif id == 2002 then
                return { { text = "Find the key", type = "item", finished = true, numFulfilled = 1, numRequired = 1 } }
            end
            return {}
        end,
        GetAllCompletedQuestIDs = function() return { 99582, 456, 457, 3117 } end,
        GetTitleForQuestID = function(id)
            if id == 456 then return "|cff00ff00Old Quest|r" end
            return nil
        end,
    }
    for key, value in pairs(overrides or {}) do api[key] = value end
    return api
end

local function collect(api, fn)
    WithGlobals({ C_QuestLog = api }, function()
        local section = Addon.collectors.quests(Addon)
        local out = Addon:NewWriter()
        Addon.formatters.quests(Addon, section, out)
        fn(section, out:Output())
    end)
end

local function sampleRows()
    return {
        header("Darnassus"),
        quest(2001, "Boar Hunt", 10),
        quest(2002, "Lost Key", 11, { frequency = 1 }),
        header("Teldrassil"),
        quest(2003, "Plain Talk", 11),
        header("Empty Zone"),
    }
end

Tests["collector.quests.normal_collapsed_headers_still_ok"] = function()
    collect(logApi(sampleRows()), function(section, text)
        assert(section.logCoverage.status == "ok", section.logCoverage.reason)
        assert(section.collapsedHeaders == 3 and section.visibleQuestCount == 3)
        assert(text:find("log coverage: ok - ", 1, true))
        assert(text:find("quest slots: 3 used / 25 max (6 log entries", 1, true), text)
        assert(text:find("#### Darnassus (2 quests, header collapsed in UI)", 1, true))
        assert(text:find("#### Empty Zone (0 quests", 1, true))
        assert(text:find("- Boar Hunt (2001) | level 10 | in progress | IsComplete=no ReadyForTurnIn=no", 1, true), text)
        assert(text:find("- Lost Key (2002) | level 11 | READY TO TURN IN | IsComplete=yes ReadyForTurnIn=yes | daily", 1, true))
        assert(text:find("    - [ ] Kill 3 boars: 1/3 (1/3)", 1, true))
        assert(text:find("    - [x] Find the key (1/1)", 1, true))
        assert(text:find("objectives: <empty: API returned an empty objective list", 1, true))
    end)
end

Tests["collector.quests.count_mismatch_is_not_collected_but_prints_rows"] = function()
    local rows = sampleRows()
    local api = logApi(rows, { GetNumQuestLogEntries = function() return #rows, 4 end })
    collect(api, function(section, text)
        assert(section.logCoverage.status == "not_collected")
        assert(section.logCoverage.reason:find("differ from the API quest total", 1, true))
        assert(text:find("- Boar Hunt (2001)", 1, true))
    end)
end

Tests["collector.quests.missing_row_is_reported_not_dropped"] = function()
    local rows = sampleRows()
    local api = logApi(rows, { GetInfo = function(index)
        if index == 3 then return nil end
        return rows[index]
    end })
    collect(api, function(section, text)
        assert(section.logCoverage.status == "not_collected")
        assert(section.missingRows == 1)
        assert(text:find("- log row 3: <not_collected", 1, true), text)
        assert(text:find("- Boar Hunt (2001)", 1, true) and text:find("- Plain Talk (2003)", 1, true))
    end)
end

Tests["collector.quests.empty_log"] = function()
    collect(logApi({}, { GetAllCompletedQuestIDs = function() return {} end }), function(section, text)
        assert(section.logCoverage.status == "empty")
        assert(section.completedIDs.status == "empty" and section.completedCoverage.status == "unverified" and section.completedCoverage.info)
        assert(text:find("quest log is empty", 1, true))
        assert(text:find("completed quests: <empty: ", 1, true), text)
    end)
end

Tests["collector.quests.completed_ids_sorted_titles_only_when_returned"] = function()
    collect(logApi({}), function(section, text)
        assert(section.completedCoverage.status == "unverified")
        assert(text:find("completed quests: 4 ids", 1, true))
        assert(text:find("  456,457,3117,99582", 1, true), text)
        assert(text:find("completed (with titles known) 1 of 4:", 1, true))
        assert(text:find("  456 Old Quest", 1, true))
        assert(not text:find("457 ", 1, true) and not text:find("3117 ", 1, true))
        assert(section.titleLookup.status == "partial" and section.titleLookup.info
            and section.titleLookup.reason:find("1 of 4", 1, true))
        assert(text:find("ids without a title (3): 457,3117,99582", 1, true), text)
        local _, problems = Addon:Tally(section)
        for _, p in ipairs(problems) do assert(p.api ~= "C_QuestLog.GetTitleForQuestID", "informational state counted") end
    end)
end

Tests["collector.quests.unsupported_apis"] = function()
    collect(logApi(sampleRows(), { GetAllCompletedQuestIDs = false, GetInfo = false }), function(section, text)
        assert(section.completedIDs.status == "unsupported")
        assert(text:find("completed quests: <unsupported", 1, true))
        assert(section.logCoverage.status == "not_collected")
        assert(text:find("log row 1: <unsupported", 1, true), text)
    end)
    collect(logApi({}, { GetTitleForQuestID = false }), function(section, text)
        assert(section.titleLookup.status == "unsupported")
        assert(text:find("completed (with titles known) 0 of 4:", 1, true))
        assert(text:find("456,457,3117,99582", 1, true))
    end)
end

Tests["collector.quests.restricted_objectives_do_not_erase_other_quests"] = function()
    local api = logApi(sampleRows(), { GetQuestObjectives = function(id)
        if id == 2001 then return { { text = FCE_SECRET, finished = false } } end
        return { { text = "Fine", finished = false, numFulfilled = 0, numRequired = 2 } }
    end })
    collect(api, function(section, text)
        assert(section.logCoverage.status == "ok")
        assert(text:find("objectives: <restricted", 1, true), text)
        assert(text:find("    - [ ] Fine (0/2)", 1, true))
        assert(text:find("completed quests: 4 ids", 1, true))
    end)
end

Tests["collector.quests.nil_returns_stay_not_collected"] = function()
    local api = logApi(sampleRows(), {
        IsComplete = function() end,
        ReadyForTurnIn = function() end,
        GetQuestObjectives = function() end,
        GetMaxNumQuestsCanAccept = function() end,
    })
    collect(api, function(section, text)
        assert(section.logCoverage.status == "ok")
        local row = section.rows[2]
        assert(row.complete.status == "not_collected" and row.ready.status == "not_collected")
        assert(row.objectives.status == "not_collected")
        assert(text:find("state unclear", 1, true))
        assert(text:find("IsComplete=<not_collected", 1, true))
        assert(text:find("3 used / <not_collected", 1, true), text)
    end)
end

Tests["collector.quests.restricted_count_and_missing_counts"] = function()
    collect(logApi({}, { GetNumQuestLogEntries = function() return FCE_SECRET, 0 end }), function(section, text)
        assert(section.counts.status == "restricted" and section.logCoverage.status == "not_collected")
        assert(text:find("log coverage: <not_collected: quest log entry counts", 1, true))
    end)
    collect(logApi({}, { GetNumQuestLogEntries = function() end }), function(section)
        assert(section.counts.status == "not_collected" and section.logCoverage.status == "not_collected")
    end)
end

Tests["collector.quests.whole_api_missing"] = function()
    WithGlobals({ C_QuestLog = false }, function()
        local section = Addon.collectors.quests(Addon)
        local out = Addon:NewWriter()
        Addon.formatters.quests(Addon, section, out)
        local text = out:Output()
        assert(section.counts.status == "unsupported" and section.completedIDs.status == "unsupported")
        assert(text:find("completed quests: <unsupported", 1, true))
        local counts = Addon:Tally(section)
        assert(counts.unsupported >= 3)
    end)
end
