local _, Addon = ...
-- luacheck: read globals MAX_REPUTATION_REACTION

-- Reputation list as the Camelot reputation panel reads it (Camelot/ReputationFrame.lua:165-210):
-- C_Reputation.GetNumFactions() visible rows, C_Reputation.GetFactionDataByIndex(i) per row.
-- Collapsed headers hide their children; expanding them is a UI state change, so it is reported instead.
-- Declared ReputationSortType enum (ReputationInfoDocumentation.lua:328-338).
local SORT_NAMES = { [0] = "None", [1] = "Account", [2] = "Character" }

-- A nil return documented as "nothing" (Nilable = true) becomes a real empty state instead of unresolved.
local function nilMeansEmpty(result, reason)
    if type(result) == "table" and result.status == "not_collected" and type(result.values) == "table" then
        return { status = "empty", api = result.api, reason = reason }
    end
    return result
end

local function isCount(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value)
end

Addon:RegisterCollector("reputation", function(self)
    local section = {}
    local size = self:Probe("C_Reputation.GetNumFactions")
    section.count = size
    section.sortType = self:Probe("C_Reputation.GetReputationSortType")
    section.legacyShown = self:Probe("C_Reputation.AreLegacyReputationsShown")
    section.watched = nilMeansEmpty(self:Probe("C_Reputation.GetWatchedFactionData"),
        "no faction is watched (declared nilable return)")
    section.gender = self:Probe("UnitSex", "player")
    section.rows = {}
    section.standingText = {}
    section.collapsed = {}

    if size.status ~= "ok" then
        return section
    end
    local total = size.values[1]
    if not isCount(total) then
        section.count = self:State("error", "GetNumFactions returned an unexpected value")
        section.count.api = size.api
        return section
    end
    if total == 0 then
        section.count = self:State("empty", "GetNumFactions returned 0")
        section.count.api = size.api
        return section
    end

    local gender = self:Val(section.gender, 1)
    for index = 1, total do
        local row = { index = index }
        row.data = self:Probe("C_Reputation.GetFactionDataByIndex", index)
        local data = self:Val(row.data, 1)
        if type(data) == "table" and data.isHeader ~= true then
            row.active = self:Probe("C_Reputation.IsFactionActive", index)
        end
        if type(data) == "table" and data.isHeader == true and data.isCollapsed == true then
            section.collapsed[#section.collapsed + 1] = { index = index, factionID = data.factionID }
        end
        -- Readable standing text: the Camelot UI looks up the global string FACTION_STANDING_LABEL<reaction>
        -- through GetText(token, gender) (Camelot/ReputationFrame.lua:524).
        if type(data) == "table" and type(data.reaction) == "number"
            and (data.isHeader ~= true or data.isHeaderWithRep == true)
            and section.standingText[data.reaction] == nil then
            section.standingText[data.reaction] =
                self:Probe("GetText", "FACTION_STANDING_LABEL" .. data.reaction, gender)
        end
        section.rows[index] = row
    end
    return section
end, function(self, section, out)
    local function yesno(value)
        if value == true then return "yes" end
        if value == false then return "no" end
        return "?"
    end
    local function label(data)
        local name = type(data.name) == "string" and self:Clean(data.name) or "<name unreadable>"
        return name .. " (" .. (type(data.factionID) == "number" and data.factionID or "?") .. ")"
    end

    out:Result("rows", section.count)
    if section.count.status ~= "ok" then
        return
    end
    out:Result("sort type", section.sortType, function(v)
        return tostring(v) .. (SORT_NAMES[v] and (" (" .. SORT_NAMES[v] .. ")") or "")
    end)
    out:Result("legacy reputations shown", section.legacyShown)
    out:Result("watched", section.watched, function(v)
        return type(v) == "table" and label(v) or self:Fmt(v)
    end)

    local headers, factions, failedRows = 0, 0, 0
    local activeFailure, activeFailures = nil, 0
    local textFailure = {}
    for _, row in ipairs(section.rows) do
        local data = self:Val(row.data, 1)
        if type(data) ~= "table" then
            failedRows = failedRows + 1
        elseif data.isHeader == true then
            headers = headers + 1
        else
            factions = factions + 1
        end
        if row.active and row.active.status ~= "ok" then
            activeFailures = activeFailures + 1
            activeFailure = activeFailure or self:Describe(row.active)
        end
    end
    for reaction, result in pairs(section.standingText) do
        if result.status ~= "ok" or type(self:Val(result, 1)) ~= "string" then
            local tag = self:Describe(result) or "<not_collected: not a string>"
            textFailure[#textFailure + 1] = reaction .. " " .. tag
        end
    end
    table.sort(textFailure)
    out:Add("counts: " .. factions .. " factions, " .. headers .. " headers, " .. failedRows .. " unreadable rows")
    if #textFailure > 0 then
        out:Add("standing text unavailable for reaction: " .. table.concat(textFailure, "; "))
    end
    if activeFailure then
        out:Add("active flag unavailable on " .. activeFailures .. " rows: " .. activeFailure)
    end
    if #section.collapsed > 0 then
        out:Add("completeness: INCOMPLETE - " .. #section.collapsed
            .. " collapsed header(s) hide their children (not expanded: that would change UI state)")
    else
        out:Add("completeness: no collapsed header among the rows read")
    end

    for _, row in ipairs(section.rows) do
        local data = self:Val(row.data, 1)
        if type(data) ~= "table" then
            out:Add("#" .. row.index .. ": " .. (self:Describe(row.data) or "<not_collected: row is not a table>"))
        else
            local isHeader = data.isHeader == true
            if isHeader then
                out:Add((data.isChild == true and "#### " or "### ") .. label(data))
                if data.isCollapsed == true then
                    out:Add("  <not_collected: header collapsed; children hidden, not expanded>")
                end
            end
            if not isHeader or data.isHeaderWithRep == true then
                local parts = {}
                local reaction = data.reaction
                local text = self:Val(section.standingText[reaction], 1)
                local standing = "standing=" .. self:Fmt(reaction)
                if type(text) == "string" then standing = standing .. " (" .. self:Clean(text) .. ")" end
                if type(MAX_REPUTATION_REACTION) == "number" and reaction == MAX_REPUTATION_REACTION then
                    standing = standing .. " [max reaction]"
                end
                parts[#parts + 1] = standing
                local low, high, current = data.currentReactionThreshold, data.nextReactionThreshold,
                    data.currentStanding
                if type(low) == "number" and type(high) == "number" and type(current) == "number" then
                    parts[#parts + 1] = "progress=" .. (current - low) .. "/" .. (high - low)
                    parts[#parts + 1] = "value=" .. current .. " range=" .. low .. ".." .. high
                else
                    parts[#parts + 1] = "values=<not_collected: threshold/standing fields missing>"
                end
                parts[#parts + 1] = "watched=" .. yesno(data.isWatched)
                parts[#parts + 1] = "atWar=" .. yesno(data.atWarWith) .. "(toggle=" .. yesno(data.canToggleAtWar) .. ")"
                if row.active and row.active.status == "ok" then
                    local active = row.active.values[1]
                    parts[#parts + 1] = "active=" .. yesno(active) .. (active == false and " (inactive/hidden)" or "")
                end
                parts[#parts + 1] = "accountWide=" .. yesno(data.isAccountWide)
                if data.hasBonusRepGain == true then parts[#parts + 1] = "bonusRepGain=yes" end
                out:Add((isHeader and "  header rep " or "- ") .. (isHeader and "" or label(data) .. ": ")
                    .. table.concat(parts, " "))
            end
        end
    end
end)
