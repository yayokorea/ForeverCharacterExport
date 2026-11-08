local _, Addon = ...

-- Deterministic Lua-style text, with explicit nil slots in packed API returns.
local function serialize(value, depth)
    local kind = type(value)
    if kind == "string" then
        return string.format("%q", value)
    elseif kind ~= "table" then
        return tostring(value)
    end
    local keys, lines = {}, { "{" }
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    if type(value.n) == "number" then
        for index = 1, value.n do
            if value[index] == nil then
                keys[#keys + 1] = index
            end
        end
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then
            return a < b
        end
        return type(a) < type(b)
    end)
    for _, key in ipairs(keys) do
        lines[#lines + 1] = string.rep("  ", depth + 1) .. "[" .. serialize(key, 0) .. "] = "
            .. serialize(value[key], depth + 1) .. ","
    end
    lines[#lines + 1] = string.rep("  ", depth) .. "}"
    return table.concat(lines, "\n")
end

function Addon:Export(report, cached)
    return "ForeverCharacterExport diagnostic; in-game verification pending\n" .. serialize({
        status = cached and "stale" or "snapshot",
        reason = cached and "earlier snapshot in this session; freshness not established" or "manual collection",
        viewedAt = self:Timestamp(),
        report = report,
    }, 0)
end

-- Expected gaps. These are limits of the client API, not addon bugs, so they are stated up front.
local UNKNOWABLE = {
    "the client cannot list quests you have not accepted or that are available from NPCs (needs a quest database)",
    "auction/vendor prices and item market value (no client-side source)",
    "other characters, account-wide or server-side data",
    "talent/quest/item meaning beyond what the client returns (no guide data bundled)",
    "keybinds, macro bodies and UI settings are not collected by this addon (action slot contents are)",
}
local NEEDS_ACTION = {
    "bank: open the bank once; the contents are then saved and shown as a stale snapshot",
    "flight paths: open a flight master's map once; known nodes are then saved as a stale snapshot",
    "played time: arrives by event after login; shown as stale when older than this session",
}

local function problemKey(a, b)
    if a.status ~= b.status then return a.status < b.status end
    local aa, ba = a.api or "", b.api or ""
    if aa ~= ba then return aa < ba end
    return (a.reason or "") < (b.reason or "")
end

function Addon:Report(report, cached)
    local out = self:NewWriter()
    local build = report.build and report.build.values or {}
    out:Add("# ForeverCharacterExport " .. self.version .. " | WoW " .. tostring(build[1]) .. " (build "
        .. tostring(build[2]) .. ", interface " .. tostring(build[4]) .. ")")
    local startedAt = self:Val(report.startedAt)
    out:Add("# captured " .. self:Date(startedAt) .. " | epoch " .. tostring(startedAt)
        .. (cached and " | STALE: earlier snapshot of this session, viewed " .. self:Date(self:Now()) or ""))
    out:Add("# addon runtime-verified: " .. tostring(report.runtimeVerified)
        )
    out:Add("# tags: <empty> = the API answered with a real empty value | <not_collected: why> = could not be read, "
        .. "NOT proof of none | <unsupported>/<restricted>/<error> = see reason | "
        .. "[stale ...] = saved earlier, not live")
    local totals, allProblems = {}, {}
    for _, name in ipairs(self.order) do
        local section = report.sections[name]
        local counts, problems = self:Tally(section)
        totals[name] = counts
        allProblems[name] = problems
        local summary = "[api ok=" .. counts.ok .. " empty=" .. counts.empty .. " not_read="
            .. (counts.not_collected + counts.unsupported + counts.restricted + counts.error) .. "]"
        out:Section(name, summary)
        local formatter = self.formatters[name]
        if type(section) == "table" and self.knownStatus[section.status] and section.status ~= "ok" then
            -- The collector returned a bare state (build mismatch, collector failure): nothing to format.
            out:State("section", section)
        elseif type(formatter) ~= "function" then
            out:Add("<not_collected: no formatter registered>")
        else
            local ok, err = pcall(formatter, self, section, out)
            if not ok then
                out:Add("<error: formatter failed: " .. tostring(err) .. ">")
            end
        end
    end
    out:Section("coverage")
    out:Add("Per-section API results (ok/empty/not_collected/unsupported/restricted/error):")
    for _, name in ipairs(self.order) do
        local c = totals[name]
        out:Add("- " .. name .. ": " .. c.ok .. "/" .. c.empty .. "/" .. c.not_collected .. "/" .. c.unsupported
            .. "/" .. c.restricted .. "/" .. c.error)
    end
    local shown, limit = 0, 60
    out:Add("Unread values (status, API, reason):")
    for _, name in ipairs(self.order) do
        table.sort(allProblems[name], problemKey)
        local last
        for _, problem in ipairs(allProblems[name]) do
            local line = "- " .. name .. ": " .. problem.status .. " " .. (problem.api or "-")
                .. (problem.reason and (" - " .. problem.reason) or "")
            if line ~= last then
                shown = shown + 1
                if shown <= limit then out:Add(line) end
                last = line
            end
        end
    end
    if shown == 0 then out:Add("- none") elseif shown > limit then out:Add("- ... " .. (shown - limit) .. " more") end
    local eventLines = {}
    for event, status in pairs(self.eventStatus) do
        if status ~= "registered" then eventLines[#eventLines + 1] = event .. ": " .. status end
    end
    table.sort(eventLines)
    for _, line in ipairs(eventLines) do out:Add("- event " .. line) end
    for _, line in ipairs(self.handlerErrors) do out:Add("- handler error " .. line) end
    out:Add("Unknowable from the client (expected gaps):")
    for _, line in ipairs(UNKNOWABLE) do out:Add("- " .. line) end
    out:Add("Needs a player action first:")
    for _, line in ipairs(NEEDS_ACTION) do out:Add("- " .. line) end
    out:Add("# end")
    return out:Output()
end
