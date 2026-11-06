local _, Addon = ...

-- Evidence (pinned commit eac30af, references/upstream/Interface/AddOns/):
--  Blizzard_APIDocumentationGenerated/QuestLogDocumentation.lua: GetAllCompletedQuestIDs :116, GetInfo :191 (nil
--  possible), GetMaxNumQuestsCanAccept :241, GetNumQuestLogEntries :303 (numShownEntries, numQuests),
--  GetQuestObjectives :477 (MayReturnNothing), GetTitleForQuestID :668 (title nilable), IsComplete :734,
--  ReadyForTurnIn :1174 (nilable bool), QuestInfo :1547, QuestObjectiveInfo :1581, QuestFrequency :1486.
--  Blizzard_UIPanels_Game/Mainline/QuestMapFrame.lua:928-931 (GetNumQuestLogEntries + GetInfo loop),
--  :1885,:2194 (C_QuestLog.IsComplete(questID)); Blizzard_FrameXMLUtil/Mainline/Blizzard_QuestSuperTracking.lua:55
--  (ReadyForTurnIn); Blizzard_ObjectiveTracker/Blizzard_AutoQuestPopUpTracker.lua:21 (GetTitleForQuestID).
-- The collapsed state of a header is only reported, never changed: the old game output showed that the log still
-- returns every quest row while headers are collapsed.

local MAX_ROWS = 500
local MAX_TITLE_LOOKUPS = 500
local TITLE_API = "C_QuestLog.GetTitleForQuestID"

local function isCount(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0
end

-- Ascending list of positive integer IDs, plus how many entries were not such IDs.
local function sortedIDs(list)
    local ids, invalid = {}, 0
    if type(list) == "table" then
        for _, value in pairs(list) do
            if type(value) == "number" and value > 0 and value % 1 == 0 then
                ids[#ids + 1] = value
            else
                invalid = invalid + 1
            end
        end
        table.sort(ids)
    end
    return ids, invalid
end

local function readQuestDetails(self, row, questID)
    row.complete = self:Probe("C_QuestLog.IsComplete", questID)
    row.ready = self:Probe("C_QuestLog.ReadyForTurnIn", questID)
    local objectives = self:Probe("C_QuestLog.GetQuestObjectives", questID)
    if objectives.status == "ok" then
        local list = objectives.values[1]
        if type(list) ~= "table" then
            objectives.status = "error"
            objectives.reason = "unexpected objectives shape: " .. type(list)
        elseif next(list) == nil then
            objectives.status = "empty"
            objectives.reason = "API returned an empty objective list for this quest"
        end
    end
    row.objectives = objectives
end

local function readLog(self, section)
    section.rows = {}
    section.counts = self:Probe("C_QuestLog.GetNumQuestLogEntries")
    section.maxQuests = self:Probe("C_QuestLog.GetMaxNumQuestsCanAccept")
    local entries, total = self:Val(section.counts, 1), self:Val(section.counts, 2)
    if not isCount(entries) or not isCount(total) then
        section.logCoverage = self:State("not_collected",
            "quest log entry counts unavailable or invalid; rows not read")
        return
    end
    local limit = math.min(entries, MAX_ROWS)
    local headers, collapsed, quests, missing, malformed = 0, 0, 0, 0, 0
    for index = 1, limit do
        local row = { index = index }
        section.rows[#section.rows + 1] = row
        row.info = self:Probe("C_QuestLog.GetInfo", index)
        local info = self:Val(row.info, 1)
        if type(info) ~= "table" then
            missing = missing + 1
            if row.info.status == "unsupported" then
                missing = missing + (limit - index)
                break
            end
        elseif info.isHeader == true then
            headers = headers + 1
            if info.isCollapsed == true then collapsed = collapsed + 1 end
        elseif type(info.questID) == "number" and info.questID > 0 then
            quests = quests + 1
            readQuestDetails(self, row, info.questID)
        else
            malformed = malformed + 1
        end
    end
    section.headerCount, section.collapsedHeaders = headers, collapsed
    section.visibleQuestCount, section.missingRows, section.malformedRows = quests, missing, malformed

    local problems = {}
    if entries > MAX_ROWS then
        problems[#problems + 1] = "log has " .. entries .. " entries, only the first " .. MAX_ROWS .. " were read"
    end
    if missing > 0 then
        problems[#problems + 1] = missing .. " row(s) returned no readable info"
    end
    if malformed > 0 then
        problems[#problems + 1] = malformed .. " non-header row(s) without a valid questID"
    end
    if quests ~= total then
        problems[#problems + 1] = "visible quest rows (" .. quests
            .. ") differ from the API quest total (" .. total .. ")"
    end
    if #problems > 0 then
        section.logCoverage = self:State("not_collected", table.concat(problems, "; "))
    elseif entries == 0 and total == 0 then
        section.logCoverage = self:State("empty", "API reports 0 log entries and 0 quests")
    else
        local reason = "visible quest rows match the API quest total (" .. quests .. " of " .. total .. ")"
        if collapsed > 0 then
            reason = reason .. "; " .. collapsed
                .. " header(s) collapsed in the UI, rows still returned (nothing expanded)"
        end
        section.logCoverage = self:State("ok", reason)
    end
end

local function lookupTitles(self, section, ids)
    local titles, known, unknown, blocked, skipped = {}, 0, 0, 0, 0
    local unsupported
    for position, id in ipairs(ids) do
        if position > MAX_TITLE_LOOKUPS then
            skipped = skipped + 1
        else
            local result = self:Probe(TITLE_API, id)
            local title = self:Val(result, 1)
            if result.status == "unsupported" then
                unsupported = result
                break
            elseif type(title) == "string" and title ~= "" then
                titles[id] = title
                known = known + 1
            elseif result.status == "restricted" or result.status == "error" then
                blocked = blocked + 1
            else
                unknown = unknown + 1
            end
        end
    end
    section.completedTitles = titles
    local state
    if unsupported then
        state = self:State("unsupported", unsupported.reason)
        section.completedTitles = {}
    elseif known == #ids then
        state = self:State("ok", "titles returned for all " .. known .. " ids")
    else
        state = self:State("partial", known .. " of " .. #ids .. " ids returned a title; " .. unknown
            .. " returned none (cache cold or unknown), " .. blocked .. " restricted/error, " .. skipped
            .. " not looked up (cap " .. MAX_TITLE_LOOKUPS .. ")")
    end
    state.api = TITLE_API
    state.info = true -- partial titles are reported in the text, not counted as an unread API value
    section.titleLookup = state
end

local function readCompleted(self, section)
    local completed = self:Probe("C_QuestLog.GetAllCompletedQuestIDs")
    section.completedIDs = completed
    -- The client-side history is never claimed to be complete, whatever the API returned.
    section.completedCoverage = self:State("unverified",
        "client-side completed-quest history; completeness not verified (a missing id is not proof of 'not done')")
    section.completedCoverage.info = true
    if completed.status ~= "ok" then return end
    local list = completed.values[1]
    if type(list) ~= "table" then
        completed.status = "error"
        completed.reason = "unexpected completed-quest list shape: " .. type(list)
        return
    end
    if next(list) == nil then
        completed.status = "empty"
        completed.reason = "API returned an empty list (history completeness still unverified)"
        return
    end
    local ids, invalid = sortedIDs(list)
    section.completedInvalid = invalid
    lookupTitles(self, section, ids)
end

Addon:RegisterCollector("quests", function(self)
    local section = {}
    readLog(self, section)
    readCompleted(self, section)
    return section
end, function(self, section, out)
    if type(section) ~= "table" then
        out:Add("<not_collected: no quest data>")
        return
    end
    local function stateText(state)
        if state.info and state.status ~= "ok" then
            -- Informational note (unverified/partial): plain text, not an unread-value tag.
            return state.status .. (state.reason and (" - " .. state.reason) or "")
        end
        local tag = self:Describe(state)
        if tag then return tag end
        return "ok" .. (state.reason and (" - " .. state.reason) or "")
    end
    local function yesNo(result)
        local tag = self:Describe(result)
        if tag then return tag end
        local value = result.values[1]
        if value == true then return "yes" elseif value == false then return "no" end
        return self:Fmt(value)
    end

    out:Add("### Quest log")
    out:Add("log coverage: " .. stateText(section.logCoverage))
    local used, entries = self:Val(section.counts, 2), self:Val(section.counts, 1)
    local maxText = self:Describe(section.maxQuests) or tostring(self:Val(section.maxQuests, 1))
    if used ~= nil then
        out:Add("quest slots: " .. tostring(used) .. " used / " .. maxText .. " max (" .. tostring(entries)
            .. " log entries including zone headers)")
    else
        out:Add("quest slots: " .. (self:Describe(section.counts) or "<not_collected: count not numeric>")
            .. " used / " .. maxText .. " max")
    end

    local groups, current = {}, { quests = {} }
    local function flush()
        if current.title ~= nil or #current.quests > 0 then groups[#groups + 1] = current end
    end
    for _, row in ipairs(section.rows or {}) do
        local info = self:Val(row.info, 1)
        if type(info) == "table" and info.isHeader == true then
            flush()
            current = { title = type(info.title) == "string" and self:Clean(info.title) or "<title unavailable>",
                quests = {}, collapsed = info.isCollapsed == true }
        else
            current.quests[#current.quests + 1] = row
        end
    end
    flush()
    if #groups == 0 and section.logCoverage and section.logCoverage.status == "empty" then
        out:Add("quest log is empty (API reports 0 entries)")
    end

    for _, group in ipairs(groups) do
        out:Add("#### " .. (group.title or "(rows before any zone header)") .. " (" .. #group.quests .. " quests"
            .. (group.collapsed and ", header collapsed in UI" or "") .. ")")
        for _, row in ipairs(group.quests) do
            local info = self:Val(row.info, 1)
            if type(info) ~= "table" then
                out:Add("- log row " .. row.index .. ": " .. (self:Describe(row.info) or "<error: row is not a table>"))
            elseif row.complete == nil then
                out:Add("- log row " .. row.index .. ": <error: no valid questID>")
            else
                local title = type(info.title) == "string" and self:Clean(info.title) or "<title unavailable>"
                local ready, complete = yesNo(row.ready), yesNo(row.complete)
                local state = "state unclear"
                if ready == "yes" then
                    state = "READY TO TURN IN"
                elseif complete == "yes" then
                    state = "objectives complete"
                elseif complete == "no" and ready == "no" then
                    state = "in progress"
                end
                local flags = ""
                local frequency = { [1] = "daily", [2] = "weekly", [3] = "scheduler-reset" }
                if info.frequency ~= nil and info.frequency ~= 0 then
                    flags = flags .. " | " .. (frequency[info.frequency] or ("frequency=" .. self:Fmt(info.frequency)))
                end
                for _, flag in ipairs({ "isTask", "isStory", "isBounty", "isHidden", "isAutoComplete" }) do
                    if info[flag] == true then flags = flags .. " | " .. flag end
                end
                if type(info.suggestedGroup) == "number" and info.suggestedGroup > 0 then
                    flags = flags .. " | suggestedGroup=" .. info.suggestedGroup
                end
                out:Add("- " .. title .. " (" .. tostring(info.questID) .. ") | level " .. self:Fmt(info.level)
                    .. " | " .. state .. " | IsComplete=" .. complete .. " ReadyForTurnIn=" .. ready .. flags)
                local tag = self:Describe(row.objectives)
                if tag then
                    out:Add("    objectives: " .. tag)
                else
                    for index, objective in ipairs(row.objectives.values[1]) do
                        if index > 20 then
                            out:Add("    ... more objectives not printed")
                            break
                        end
                        if type(objective) ~= "table" then
                            out:Add("    - <error: unexpected objective shape>")
                        else
                            local text = type(objective.text) == "string" and objective.text ~= ""
                                and self:Clean(objective.text) or "(no text)"
                            local progress = ""
                            if type(objective.numFulfilled) == "number" and type(objective.numRequired) == "number" then
                                progress = " (" .. objective.numFulfilled .. "/" .. objective.numRequired .. ")"
                            end
                            local mark = objective.finished == true and "x" or " "
                            out:Add("    - [" .. mark .. "] " .. text .. progress)
                        end
                    end
                end
            end
        end
    end

    out:Add("### Completed quests")
    local tag = self:Describe(section.completedIDs)
    if tag then
        out:Add("completed quests: " .. tag)
    else
        local ids, invalid = sortedIDs(section.completedIDs.values[1])
        local note = invalid > 0 and (" (+" .. invalid .. " non-id entries ignored)") or ""
        out:Add("completed quests: " .. #ids .. " ids" .. note)
        out:Add("completed coverage: " .. stateText(section.completedCoverage))
        out:Add("completed ids (ascending):")
        for first = 1, #ids, 25 do
            out:Add("  " .. table.concat(ids, ",", first, math.min(first + 24, #ids)))
        end
        local titles, shown = section.completedTitles or {}, {}
        for _, id in ipairs(ids) do
            if titles[id] then shown[#shown + 1] = id end
        end
        out:Add("title lookup (" .. TITLE_API .. "): " .. stateText(section.titleLookup))
        out:Add("completed (with titles known) " .. #shown .. " of " .. #ids .. ":")
        for _, id in ipairs(shown) do
            out:Add("  " .. id .. " " .. self:Clean(titles[id]))
        end
        if #shown < #ids then
            local missing = {}
            for _, id in ipairs(ids) do
                if not titles[id] then missing[#missing + 1] = id end
            end
            out:Add("ids without a title (" .. #missing .. "): "
                .. table.concat(missing, ",", 1, math.min(#missing, 50)))
        end
    end
    if tag then
        out:Add("completed coverage: " .. stateText(section.completedCoverage))
    end
end)
