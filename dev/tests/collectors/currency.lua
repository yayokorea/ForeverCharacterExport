-- Mocked contract tests for the currency collector. Not a WoW runtime.
local Addon = AddonUnderTest

local function run()
    local section = Addon.collectors.currency(Addon)
    local out = Addon:NewWriter()
    Addon.formatters.currency(Addon, section, out)
    return section, out:Output()
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function lacks(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

local function entry(overrides)
    local info = {
        name = "명예의 휘장", description = "", currencyID = 1500, isHeader = false, isHeaderExpanded = false,
        currencyListDepth = 1, isTypeUnused = false, isShowInBackpack = true, quantity = 120,
        trackedQuantity = 0, iconFileID = 1, maxQuantity = 4000, canEarnPerWeek = false,
        quantityEarnedThisWeek = 0, isTradeable = false, quality = 1, maxWeeklyQuantity = 0, totalEarned = 120,
        discovered = true, useTotalEarnedForMaxQty = false, isAccountWide = false, isAccountTransferable = false,
        rechargingCycleDurationMS = 0, rechargingAmountPerCycle = 0,
    }
    for key, value in pairs(overrides or {}) do info[key] = value end
    return info
end

local function head(overrides)
    local info = entry({ name = "기타", currencyID = 0, isHeader = true, isHeaderExpanded = true,
        currencyListDepth = 0, quantity = 0, maxQuantity = 0 })
    for key, value in pairs(overrides or {}) do info[key] = value end
    return info
end

local function api(list, extra)
    local currency = {
        GetCurrencyListSize = function() return #list end,
        GetCurrencyListInfo = function(index) return list[index] end,
    }
    for key, value in pairs(extra or {}) do currency[key] = value end
    return currency
end

Tests["collector.currency.normal_rows"] = function()
    local list = {
        head(),
        entry(),
        entry({ currencyID = 1600, name = "증표", maxQuantity = 0, quantity = 7, canEarnPerWeek = true,
            quantityEarnedThisWeek = 3, maxWeeklyQuantity = 10, isShowInBackpack = false, discovered = false }),
        entry({ currencyID = 1700, name = "누적", useTotalEarnedForMaxQty = true, totalEarned = 99, maxQuantity = 500 }),
    }
    WithGlobals({ C_CurrencyInfo = api(list) }, function()
        local section, text = run()
        assert(section.size.status == "ok")
        has(text, "### 기타 (0)")
        has(text, "- 명예의 휘장 (1500): quantity=120/4000 discovered=yes backpack=yes")
        has(text, "- 증표 (1600): quantity=7 (no cap) week=3/10 discovered=no")
        has(text, "capCountsTotalEarned=99")
        has(text, "counts: 3 currencies, 1 headers, 0 unreadable rows")
        has(text, "completeness: no collapsed header")
    end)
end

Tests["collector.currency.collapsed_header_is_not_complete"] = function()
    local list = { head({ isHeaderExpanded = false }), head({ name = "던전", currencyID = 5, isHeaderExpanded = true }) }
    WithGlobals({ C_CurrencyInfo = api(list) }, function()
        local section, text = run()
        assert(#section.collapsed == 1)
        has(text, "completeness: INCOMPLETE - 1 collapsed header(s)")
        has(text, "<not_collected: header collapsed; children hidden, not expanded>")
    end)
end

Tests["collector.currency.size_zero_is_empty"] = function()
    WithGlobals({ C_CurrencyInfo = api({}) }, function()
        local section, text = run()
        assert(section.list.status == "empty")
        has(text, "currency list: <empty: GetCurrencyListSize returned 0 [C_CurrencyInfo.GetCurrencyListSize]>")
    end)
end

Tests["collector.currency.missing_api_is_unsupported"] = function()
    WithGlobals({ C_CurrencyInfo = false }, function()
        local section, text = run()
        assert(section.size.status == "unsupported")
        has(text, "currency list size: <unsupported: function unavailable at runtime")
    end)
end

Tests["collector.currency.nil_size_stays_not_collected"] = function()
    WithGlobals({ C_CurrencyInfo = api({}, { GetCurrencyListSize = function() return nil end }) }, function()
        local section, text = run()
        assert(section.size.status == "not_collected")
        lacks(text, "<empty")
    end)
end

Tests["collector.currency.restricted_row_and_nil_row_do_not_erase_the_rest"] = function()
    local currency = api({}, {
        GetCurrencyListSize = function() return 3 end,
        GetCurrencyListInfo = function(index)
            if index == 1 then return entry({ name = FCE_SECRET }) end
            if index == 2 then return nil end
            return entry({ currencyID = 7, name = "남은 것" })
        end,
    })
    WithGlobals({ C_CurrencyInfo = currency }, function()
        local _, text = run()
        has(text, "#1: <restricted: API returned a secret or inaccessible value [C_CurrencyInfo.GetCurrencyListInfo]>")
        has(text, "#2: <not_collected: API returned no value; readiness/availability unresolved")
        has(text, "- 남은 것 (7): quantity=120/4000")
        has(text, "counts: 1 currencies, 0 headers, 2 unreadable rows")
    end)
end

Tests["collector.currency.pvp_pseudo_currencies"] = function()
    WithGlobals({
        C_CurrencyInfo = api({}),
        UnitHonor = function() return 120 end,
        UnitHonorMax = function() return 500 end,
        UnitHonorLevel = function() return 3 end,
        GetPVPLifetimeStats = function() return 250, 4 end,
        GetPVPSessionStats = function() return 2, 0 end,
        GetPVPYesterdayStats = function() return nil end,
        C_MajorFactions = { GetMajorFactionProgressionInfo = function(id)
            assert(id == 2800)
            return { renownLevel = 2, maxLevel = 14, renownReputationEarned = 30, renownLevelThreshold = 100 }
        end },
    }, function()
        local _, text = run()
        has(text, "honor: 120")
        has(text, "honor max: 500")
        has(text, "honor level: 3")
        has(text, "lifetime honorable kills: 250, max PvP rank id 4")
        has(text, "session honorable/dishonorable kills: 2/0")
        has(text, "yesterday honorable/dishonorable kills: <not_collected")
        has(text, "PvP rank (faction 2800): level 2/14, points 30/100")
    end)
end

Tests["collector.currency.pvp_partial_failure_keeps_list"] = function()
    local list = { entry() }
    WithGlobals({ C_CurrencyInfo = api(list), UnitHonor = function() return FCE_SECRET end,
        UnitHonorMax = false, GetPVPLifetimeStats = false }, function()
        local _, text = run()
        has(text, "- 명예의 휘장 (1500)")
        has(text, "honor: <restricted")
        has(text, "honor max: <unsupported")
        has(text, "lifetime honorable kills: <unsupported")
    end)
end

Tests["collector.currency.invalid_size_is_error"] = function()
    WithGlobals({ C_CurrencyInfo = api({}, { GetCurrencyListSize = function() return "x" end }) }, function()
        local section = run()
        assert(section.list.status == "error")
    end)
end
