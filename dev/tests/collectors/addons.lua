-- Mocked contract tests for the addons collector (not a WoW runtime).
local Addon = AddonUnderTest

local function run()
    local section = Addon.collectors.addons(Addon)
    local out = Addon:NewWriter()
    Addon.formatters.addons(Addon, section, out)
    return out:Output(), section
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function hasNot(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

-- rows: { name, title, loaded(bool), reason, version }
local function api(rows, overrides)
    local mock = {
        GetNumAddOns = function() return #rows end,
        GetAddOnInfo = function(i)
            local row = rows[i]
            return row[1], row[2], "", row[3], row[4] or "", "Insecure"
        end,
        IsAddOnLoaded = function(i) return rows[i][3], rows[i][3] end,
        GetAddOnMetadata = function(i, field)
            if field == "Version" then return rows[i][5] end
        end,
    }
    for key, value in pairs(overrides or {}) do mock[key] = value end
    return mock
end

Tests["collector.addons.normal"] = function()
    local rows = {
        { "Blizzard_AuctionHouseUI", "Auction", true },
        { "Blizzard_Calendar", "Calendar", true },
        { "Blizzard_Collections", "Collections", false, "DEMAND_LOADED" },
        { "CharacterExport", "|cff00ff00Character Export|r", true, "", "2.1.0" },
        { "DeadAddon", "Dead", false, "DISABLED", "1.0" },
        { "ForeverCharacterExport", "ForeverCharacterExport", true, "", "0.3.0" },
        { "NoVersion", "NoVersion", true },
    }
    WithGlobals({ C_AddOns = api(rows) }, function()
        local text = run()
        has(text, "installed: 7 | running: 5 (third-party 3, Blizzard_* 2 collapsed) | not running: 2")
        has(text, "DEMAND_LOADED=1, DISABLED=1")
        has(text, "- CharacterExport | \"Character Export\" | v2.1.0 | [exporter?]")
        has(text, "- ForeverCharacterExport | v0.3.0")
        has(text, "(this addon)")
        has(text, "- NoVersion | version=<not_collected: no Version field returned>")
        hasNot(text, "Blizzard_Calendar")
        hasNot(text, "DeadAddon")
    end)
end

Tests["collector.addons.nothing_third_party"] = function()
    WithGlobals({ C_AddOns = api({ { "Blizzard_Calendar", "Calendar", true } }) }, function()
        local text = run()
        has(text, "running third-party addons: none")
        has(text, "Blizzard_* 1 collapsed")
    end)
    -- an explicit zero count is a real answer
    WithGlobals({ C_AddOns = api({}) }, function()
        local text = run()
        has(text, "installed: 0 | running: 0")
    end)
end

Tests["collector.addons.unsupported_api"] = function()
    WithGlobals({ C_AddOns = false }, function()
        local text = run()
        has(text, "installed addons: <unsupported: function unavailable at runtime [C_AddOns.GetNumAddOns]>")
        hasNot(text, "installed: 0")
    end)
end

Tests["collector.addons.count_nil_stays_not_collected"] = function()
    WithGlobals({ C_AddOns = { GetNumAddOns = function() end } }, function()
        local text = run()
        has(text, "installed addons: <not_collected")
    end)
end

Tests["collector.addons.restricted_entry_is_reported_not_dropped"] = function()
    local rows = { { "Good", "Good", true, "", "1.0" }, { "Bad", "Bad", true, "", "1.0" } }
    local mock = api(rows, { GetAddOnInfo = function(i)
        if i == 2 then return FCE_SECRET end
        return rows[i][1], rows[i][2], "", true, "", "Insecure"
    end })
    WithGlobals({ C_AddOns = mock }, function()
        local text = run()
        has(text, "- Good | v1.0")
        has(text, "- <index 2, name unreadable> | v1.0")
        has(text, "unreadable addon entries: 1 (first index 2): <restricted")
    end)
end

Tests["collector.addons.version_failure_does_not_erase_list"] = function()
    local rows = { { "A", "A", true, "", "1.0" }, { "B", "B", true, "", "2.0" } }
    local mock = api(rows, { GetAddOnMetadata = function(i)
        if i == 1 then error("boom") end
        return "2.0"
    end })
    WithGlobals({ C_AddOns = mock }, function()
        local text = run()
        has(text, "- A | version=<error: ")
        has(text, "- B | v2.0")
    end)
end
