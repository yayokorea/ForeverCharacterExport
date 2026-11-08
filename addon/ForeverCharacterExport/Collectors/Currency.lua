local _, Addon = ...

-- Currency list as the Camelot token panel reads it (Camelot/Blizzard_TokenUI.lua:395-400):
-- C_CurrencyInfo.GetCurrencyListSize() rows, C_CurrencyInfo.GetCurrencyListInfo(i) per row.
-- Collapsed headers hide their children; expanding them is a UI state change, so it is reported instead.
-- Money is collected by the character collector, not here.
-- PvP rank points faction used by the Camelot PvP rank panel (Camelot/PVPRankFrame.lua:1,91).
local PVP_RANK_POINTS_FACTION_ID = 2800

local function isCount(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value)
end

Addon:RegisterCollector("currency", function(self)
    local section = {}
    local size = self:Probe("C_CurrencyInfo.GetCurrencyListSize")
    section.size = size
    section.rows = {}
    section.collapsed = {}

    -- Honor and PvP pseudo-currencies: only APIs that appear in the declarations / Camelot UI.
    section.pvp = {
        honor = self:Probe("UnitHonor", "player"),
        honorMax = self:Probe("UnitHonorMax", "player"),
        honorLevel = self:Probe("UnitHonorLevel", "player"),
        lifetime = self:Probe("GetPVPLifetimeStats"),
        session = self:Probe("GetPVPSessionStats"),
        yesterday = self:Probe("GetPVPYesterdayStats"),
        rank = self:Probe("C_MajorFactions.GetMajorFactionProgressionInfo", PVP_RANK_POINTS_FACTION_ID),
    }

    if size.status ~= "ok" then
        return section
    end
    local total = size.values[1]
    if not isCount(total) then
        section.list = self:State("error", "GetCurrencyListSize returned an unexpected value")
        section.list.api = size.api
        return section
    end
    if total == 0 then
        section.list = self:State("empty", "GetCurrencyListSize returned 0")
        section.list.api = size.api
        return section
    end
    for index = 1, total do
        local row = { index = index, info = self:Probe("C_CurrencyInfo.GetCurrencyListInfo", index) }
        local info = self:Val(row.info, 1)
        if type(info) == "table" and info.isHeader == true and info.isHeaderExpanded == false then
            section.collapsed[#section.collapsed + 1] = { index = index, currencyID = info.currencyID }
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
    local function label(info)
        local name = type(info.name) == "string" and self:Clean(info.name) or "<name unreadable>"
        local id = type(info.currencyID) == "number" and info.currencyID or "?"
        return name .. " (" .. id .. ")"
    end

    if section.list then
        out:Result("currency list", section.list)
    else
        out:Result("currency list size", section.size)
    end
    if section.size.status == "ok" and not section.list then
        local headers, currencies, failed = 0, 0, 0
        for _, row in ipairs(section.rows) do
            local info = self:Val(row.info, 1)
            if type(info) ~= "table" then
                failed = failed + 1
            elseif info.isHeader == true then
                headers = headers + 1
            else
                currencies = currencies + 1
            end
        end
        out:Add("counts: " .. currencies .. " currencies, " .. headers .. " headers, " .. failed
            .. " unreadable rows")
        if #section.collapsed > 0 then
            out:Add("completeness: INCOMPLETE - " .. #section.collapsed
                .. " collapsed header(s) hide their children (not expanded: that would change UI state)")
        else
            out:Add("completeness: no collapsed header among the rows read")
        end
        for _, row in ipairs(section.rows) do
            local info = self:Val(row.info, 1)
            if type(info) ~= "table" then
                out:Add("#" .. row.index .. ": " .. (self:Describe(row.info) or "<not_collected: row is not a table>"))
            elseif info.isHeader == true then
                local depth = type(info.currencyListDepth) == "number" and info.currencyListDepth or 0
                out:Add((depth > 0 and "#### " or "### ") .. label(info))
                if info.isHeaderExpanded == false then
                    out:Add("  <not_collected: header collapsed; children hidden, not expanded>")
                end
            else
                local parts = {}
                local quantity = type(info.quantity) == "number" and info.quantity or nil
                local cap = type(info.maxQuantity) == "number" and info.maxQuantity or nil
                local amount = quantity and tostring(quantity) or "<not_collected: quantity missing>"
                if cap and cap > 0 then
                    amount = amount .. "/" .. cap
                elseif cap then
                    amount = amount .. " (no cap)"
                end
                parts[#parts + 1] = "quantity=" .. amount
                if info.useTotalEarnedForMaxQty == true then
                    parts[#parts + 1] = "capCountsTotalEarned=" .. self:Fmt(info.totalEarned)
                end
                if info.canEarnPerWeek == true then
                    parts[#parts + 1] = "week=" .. self:Fmt(info.quantityEarnedThisWeek) .. "/"
                        .. self:Fmt(info.maxWeeklyQuantity)
                end
                parts[#parts + 1] = "discovered=" .. yesno(info.discovered)
                if info.isShowInBackpack == true then parts[#parts + 1] = "backpack=yes" end
                if info.isTypeUnused == true then parts[#parts + 1] = "marked-unused=yes" end
                if info.isAccountWide == true then parts[#parts + 1] = "accountWide=yes" end
                out:Add("- " .. label(info) .. ": " .. table.concat(parts, " "))
            end
        end
    end

    local pvp = section.pvp or {}
    out:Add("### PvP / honor (stat APIs, not entries of the currency list)")
    out:Result("honor", pvp.honor)
    out:Result("honor max", pvp.honorMax)
    out:Result("honor level", pvp.honorLevel)
    out:Result("lifetime honorable kills", pvp.lifetime, function(_, values)
        return self:Fmt(values[1]) .. ", max PvP rank id " .. self:Fmt(values[2])
    end)
    out:Result("session honorable/dishonorable kills", pvp.session, function(_, values)
        return self:Fmt(values[1]) .. "/" .. self:Fmt(values[2])
    end)
    out:Result("yesterday honorable/dishonorable kills", pvp.yesterday, function(_, values)
        return self:Fmt(values[1]) .. "/" .. self:Fmt(values[2])
    end)
    out:Result("PvP rank (faction " .. PVP_RANK_POINTS_FACTION_ID .. ")", pvp.rank, function(info)
        if type(info) ~= "table" then return self:Fmt(info) end
        return "level " .. self:Fmt(info.renownLevel) .. "/" .. self:Fmt(info.maxLevel) .. ", points "
            .. self:Fmt(info.renownReputationEarned) .. "/" .. self:Fmt(info.renownLevelThreshold)
    end)
end)
