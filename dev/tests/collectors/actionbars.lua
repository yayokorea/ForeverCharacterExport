-- Mocked contract tests for the actionbars collector (not a WoW runtime).
local Addon = AddonUnderTest

local function run()
    local section = Addon.collectors.actionbars(Addon)
    local out = Addon:NewWriter()
    Addon.formatters.actionbars(Addon, section, out)
    return out:Output(), section
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function hasNot(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

local function noPet() return false end

-- actions: slot -> { type, id, subType }. HasAction answers true/false like the long-standing client function.
local function barGlobals(actions, extra)
    local globals = {
        HasAction = function(slot) return actions[slot] ~= nil end,
        GetActionInfo = function(slot)
            local action = actions[slot]
            if action then return action[1], action[2], action[3] end
        end,
        C_ActionBar = { GetActionBarPage = function() return 1 end },
        C_Spell = { GetSpellName = function(id) return id == 133 and "Fireball" or nil end },
        C_Item = { GetItemNameByID = function(id) return id == 6948 and "Hearthstone" or nil end },
        GetMacroInfo = function(index) if index == 2 then return "Heal Macro", 134400, "/cast Heal" end end,
        UnitExists = noPet,
    }
    for key, value in pairs(extra or {}) do globals[key] = value end
    return globals
end

Tests["collector.actionbars.lists_spells_items_macros"] = function()
    local actions = {
        [1] = { "spell", 133, "" }, [2] = { "item", 6948 }, [13] = { "macro", 2 },
        [14] = { "flyout", 7 },
    }
    WithGlobals(barGlobals(actions), function()
        local text, section = run()
        has(text, "filled slots: 4 (flyout 1, item 1, macro 1, spell 1)")
        has(text, "-- slots 1-12")
        has(text, "slot 1: [spell] Fireball (spellID 133)")
        has(text, "slot 2: [item] Hearthstone (itemID 6948)")
        has(text, "-- slots 13-24")
        has(text, "slot 13: [macro] Heal Macro (macroIndex 2)")
        has(text, "slot 14: [flyout] (id 7)")
        has(text, "current action bar page (C_ActionBar.GetActionBarPage): 1")
        hasNot(text, "slot 3:")
        -- 116 empty slots are counted as successful reads, not stored as nodes
        assert(section.okReads == 120 + 0 and section.slots.entries[1].slot == 1)
        has(text, "### Pet bar")
        has(text, "<empty: UnitExists(\"pet\") is false")
    end)
end

Tests["collector.actionbars.unresolved_name_keeps_id"] = function()
    WithGlobals(barGlobals({ [5] = { "spell", 999 } }), function()
        local text = run()
        has(text, "slot 5: [spell] <not_collected")
        has(text, "(spellID 999)")
    end)
end

Tests["collector.actionbars.missing_has_action_is_not_empty_bar"] = function()
    WithGlobals(barGlobals({}, { HasAction = false }), function()
        local text, section = run()
        has(text, "slot 1: <unsupported: function unavailable at runtime [HasAction]>")
        has(text, "sweep stopped at slot 1")
        assert(section.slots.stoppedAt == 1 and #section.slots.entries == 1)
        hasNot(text, "filled slots: 0 (")
    end)
end

Tests["collector.actionbars.nil_from_both_is_empty_but_noted"] = function()
    local actions = { [3] = { "spell", 133 } }
    WithGlobals(barGlobals(actions, { HasAction = function(slot) if actions[slot] then return true end end }),
        function()
            local text, section = run()
            has(text, "slot 3: [spell] Fireball (spellID 133)")
            assert(section.slots.emptyByNil == 119)
            has(text, "119 slots where HasAction and GetActionInfo both returned no value")
        end)
end

Tests["collector.actionbars.restricted_slot_is_reported"] = function()
    local actions = { [1] = { "spell", 133 } }
    WithGlobals(barGlobals(actions, { GetActionInfo = function(slot)
        if slot == 1 then return FCE_SECRET, 133 end
    end }), function()
        local text = run()
        has(text, "slot 1: <restricted")
        hasNot(text, "Fireball")
    end)
end

Tests["collector.actionbars.pet_bar"] = function()
    local pet = {
        [1] = { "PET_ACTION_ATTACK", "Interface\\Icons\\x", true, false, false, false },
        [4] = { "Growl", "Interface\\Icons\\y", false, false, true, true, 2649 },
    }
    WithGlobals(barGlobals({}, {
        UnitExists = function() return true end,
        PET_ACTION_ATTACK = "Attack",
        GetPetActionInfo = function(slot)
            local row = pet[slot]
            if row then return unpack(row, 1, 7) end
        end,
    }), function()
        local text = run()
        has(text, "pet slot 1: Attack token=true")
        has(text, "pet slot 4: Growl (spellID 2649) autocast=on")
        hasNot(text, "pet slot 2:")
    end)
end

Tests["collector.actionbars.pet_token_truthy_number_and_missing_global"] = function()
    local pet = { [1] = { "PET_ACTION_FOLLOW", "x", 1, false, false, false }, [2] = { "PET_NOPE", "x", 1 } }
    WithGlobals(barGlobals({}, {
        UnitExists = function() return true end,
        PET_ACTION_FOLLOW = "Follow",
        GetPetActionInfo = function(slot) local row = pet[slot]; if row then return unpack(row, 1, 7) end end,
    }), function()
        local text = run()
        has(text, "pet slot 1: Follow token=1")
        has(text, "pet slot 2: PET_NOPE <not_collected: token key has no global text> token=1")
    end)
end

Tests["collector.actionbars.same_subtype_is_not_repeated"] = function()
    WithGlobals(barGlobals({ [1] = { "spell", 133, "spell" } }), function()
        local text = run()
        has(text, "slot 1: [spell] Fireball (spellID 133)")
        hasNot(text, "subType=spell")
    end)
end

Tests["collector.actionbars.pet_unit_unresolved_is_not_empty"] = function()
    WithGlobals(barGlobals({}, { UnitExists = function() end }), function()
        local text = run()
        has(text, "UnitExists('pet'): <not_collected")
        hasNot(text, "pet bar: <empty")
    end)
end
