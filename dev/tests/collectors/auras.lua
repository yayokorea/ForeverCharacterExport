-- Mocked contract tests for the auras collector (not a WoW runtime).
local Addon = AddonUnderTest

local function run()
    local section = Addon.collectors.auras(Addon)
    local out = Addon:NewWriter()
    Addon.formatters.auras(Addon, section, out)
    return out:Output(), section
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function hasNot(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

-- Index iterator over fixed lists per unit:filter; nil after the list ends (the end of iteration).
local function auraApi(lists, calls)
    return {
        GetAuraDataByIndex = function(unit, index, filter)
            if calls then calls[#calls + 1] = unit .. ":" .. index .. ":" .. filter end
            local list = lists[unit .. ":" .. filter]
            return list and list[index]
        end,
    }
end

local function noPet() return false end

Tests["collector.auras.normal"] = function()
    local lists = {
        ["player:HELPFUL"] = {
            { name = "Power Word: Fortitude", spellId = 1243, applications = 1, duration = 120,
              expirationTime = 1090, sourceUnit = "player", isHelpful = true },
            { name = "|cff00ff00Well Fed|r", spellId = 18125, applications = 3, duration = 0,
              expirationTime = 0, sourceUnit = "player" },
        },
        ["player:HARMFUL"] = {
            { name = "Curse of Agony", spellId = 980, duration = 24, expirationTime = 1010,
              dispelName = "Curse", isHarmful = true },
        },
    }
    local calls = {}
    WithGlobals({ C_UnitAuras = auraApi(lists, calls), GetTime = function() return 1000 end,
        UnitExists = noPet }, function()
        local text, section = run()
        has(text, "### Player buffs (HELPFUL): 2")
        has(text, "- Power Word: Fortitude (1243) | 1m 30s left of 2m 0s | source=player")
        has(text, "- Well Fed (18125) | stacks=3 | no expiry | source=player")
        has(text, "### Player debuffs (HARMFUL): 1")
        has(text, "Curse of Agony (980) | 10s left of 24s | source=<not provided> | dispel=Curse")
        has(text, "### Pet auras: <empty")
        assert(calls[1] == "player:1:HELPFUL")
        assert(section.player.buffs.complete == true and #section.player.buffs.auras == 2)
    end)
end

Tests["collector.auras.genuinely_empty"] = function()
    WithGlobals({ C_UnitAuras = auraApi({}), GetTime = function() return 1000 end, UnitExists = noPet }, function()
        local text, section = run()
        has(text, "### Player buffs (HELPFUL): <empty: index 1 returned nil")
        has(text, "### Player debuffs (HARMFUL): <empty: index 1 returned nil")
        assert(section.player.buffs.state.status == "empty")
    end)
end

Tests["collector.auras.unsupported_api"] = function()
    WithGlobals({ C_UnitAuras = false, GetTime = function() return 1000 end, UnitExists = noPet }, function()
        local text, section = run()
        has(text, "<unsupported: function unavailable at runtime [C_UnitAuras.GetAuraDataByIndex]>")
        hasNot(text, "Player buffs (HELPFUL): <empty")
        hasNot(text, "Player buffs (HELPFUL): 0")
        assert(section.player.buffs.state == nil and section.player.buffs.stopped.status == "unsupported")
    end)
end

Tests["collector.auras.restricted_midlist_is_incomplete"] = function()
    local lists = {
        ["player:HELPFUL"] = { { name = "Buff A", spellId = 1, duration = 0, expirationTime = 0 },
            { name = FCE_SECRET, spellId = 2 }, { name = "Buff C", spellId = 3 } },
        ["player:HARMFUL"] = { { name = "Debuff A", spellId = 9, duration = 0, expirationTime = 0 } },
    }
    WithGlobals({ C_UnitAuras = auraApi(lists), GetTime = function() return 1000 end, UnitExists = noPet }, function()
        local text = run()
        has(text, "### Player buffs (HELPFUL): 1 read (incomplete)")
        has(text, "Buff A (1)")
        hasNot(text, "Buff C")
        has(text, "stopped at index 2 after 1 readable: <restricted")
        has(text, "possibly combat/instance restriction")
        -- the other list is unaffected
        has(text, "### Player debuffs (HARMFUL): 1")
        has(text, "Debuff A (9)")
    end)
end

Tests["collector.auras.error_in_one_list_keeps_the_other"] = function()
    local api = {
        GetAuraDataByIndex = function(_, index, filter)
            if filter == "HELPFUL" then error("blocked: unit aura access") end
            if index == 1 then return { name = "Debuff A", spellId = 9, duration = 0, expirationTime = 0 } end
        end,
    }
    WithGlobals({ C_UnitAuras = api, GetTime = function() return 1000 end, UnitExists = noPet }, function()
        local text = run()
        has(text, "### Player buffs (HELPFUL): <error: ")
        has(text, "Debuff A (9)")
    end)
end

Tests["collector.auras.missing_time_stays_not_collected"] = function()
    local lists = { ["player:HELPFUL"] = { { name = "Buff A", spellId = 1, duration = 60, expirationTime = 1100 } } }
    WithGlobals({ C_UnitAuras = auraApi(lists), GetTime = function() end, UnitExists = noPet }, function()
        local text, section = run()
        assert(section.time.status == "not_collected")
        has(text, "Buff A (1) | remaining=<not_collected")
        has(text, "duration=1m 0s")
    end)
end

Tests["collector.auras.pet_read_only_when_pet_exists"] = function()
    local lists = { ["pet:HELPFUL"] = { { name = "Pet Buff", spellId = 77, duration = 0, expirationTime = 0 } } }
    local calls = {}
    WithGlobals({ C_UnitAuras = auraApi(lists, calls), GetTime = function() return 1 end,
        UnitExists = function() return true end }, function()
        local text = run()
        has(text, "### Pet buffs (HELPFUL): 1")
        has(text, "Pet Buff (77)")
        has(text, "### Pet debuffs (HARMFUL): <empty")
    end)
    -- unit existence unresolved: pet auras are not guessed
    WithGlobals({ C_UnitAuras = auraApi({}), GetTime = function() return 1 end, UnitExists = function() end },
        function()
            local text = run()
            has(text, "### Pet auras: <not_collected")
        end)
end

Tests["collector.auras.hard_cap"] = function()
    local api = { GetAuraDataByIndex = function() return { name = "x", spellId = 1, duration = 0, expirationTime = 0 } end }
    WithGlobals({ C_UnitAuras = api, GetTime = function() return 1 end, UnitExists = noPet }, function()
        local text, section = run()
        assert(#section.player.buffs.auras == 100 and section.player.buffs.truncated)
        has(text, "incomplete: <not_collected: stopped after 100 auras")
    end)
end
