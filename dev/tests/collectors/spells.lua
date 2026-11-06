-- Mocked contract tests for the spells (player spellbook) collector (not a WoW runtime).
local function run()
    local addon = AddonUnderTest
    local section = addon.collectors.spells(addon)
    local out = addon:NewWriter()
    addon.formatters.spells(addon, section, out)
    return out:Output(), section
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function lacks(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

local PLAYER = 0

local function spell(name, id, extra)
    local item = { actionID = id, spellID = id, itemType = 1, name = name, subName = "", iconID = 1,
        isPassive = false, isOffSpec = false }
    for key, value in pairs(extra or {}) do item[key] = value end
    return item
end

-- Slots 1-3 General, 4-7 Class, 8-9 spec, 10-12 off-spec line (never read), line 5 hidden.
local function fixture(options)
    options = options or {}
    local items = options.items or {
        [1] = spell("Mount Up", 1, { subName = "Rank 2" }),
        [2] = spell("Tracking", 2, { isPassive = true }),
        [3] = { actionID = 7, itemType = 4, name = "Pet Flyout", subName = "", iconID = 1, isPassive = false,
            isOffSpec = false },
        [4] = spell("Shot", 3, { subName = "\237\148\136\236\138\164 2" }),
        [5] = spell("Future Shot", 4, { itemType = 2 }),
        [6] = spell("Other Spec Thing", 5, { isOffSpec = true }),
        [7] = spell("Aspect |cff00ff00of|r Hawk", 6),
        [8] = spell("Spec Spell", 8),
        [9] = spell("Spec Passive", 9, { isPassive = true }),
    }
    local lines = options.lines or {
        { name = "General", iconID = 1, itemIndexOffset = 0, numSpellBookItems = 3, isGuild = false, shouldHide = false },
        { name = "Hunter", iconID = 1, itemIndexOffset = 3, numSpellBookItems = 4, isGuild = false, shouldHide = false },
        { name = "Marksmanship", iconID = 1, itemIndexOffset = 7, numSpellBookItems = 2, isGuild = false,
            shouldHide = false, specID = 254 },
        { name = "Beast Mastery", iconID = 1, itemIndexOffset = 9, numSpellBookItems = 3, isGuild = false,
            shouldHide = false, offSpecID = 253 },
        { name = "Hidden", iconID = 1, itemIndexOffset = 12, numSpellBookItems = 1, isGuild = false,
            shouldHide = true },
    }
    return {
        Enum = options.enum or { SpellBookSpellBank = { Player = PLAYER, Pet = 1 } },
        C_SpellBook = {
            GetNumSpellBookSkillLines = options.count or function() return #lines end,
            GetSpellBookSkillLineInfo = options.lineInfo or function(index) return lines[index] end,
            GetSpellBookItemInfo = options.itemInfo or function(slot, bank)
                assert(bank == PLAYER, "must read the Player bank")
                assert(slot < 10 or slot > 12, "off-spec / hidden skill line slots must not be read")
                return items[slot]
            end,
        },
    }
end

Tests["collector.spells.groups_by_skill_line"] = function()
    WithGlobals(fixture(), function()
        local text = run()
        has(text, "skill lines: 5 reported, spells listed: 7, future (not learned, listed separately below): 1, off-spec skipped: 1, "
            .. "unreadable slots: 0, hidden skill lines skipped: 1, off-spec skill lines: 1")
        has(text, "### General (skill line 1, 3 listed)")
        has(text, "Mount Up(Rank 2,id=1)")
        has(text, "Tracking(id=2,passive)")
        has(text, "Pet Flyout(flyout=7)")
        has(text, "### Marksmanship, specID 254 (skill line 3, 2 listed)")
        has(text, "Spec Passive(id=9,passive)")
        has(text, "### Beast Mastery (skill line 4, off-spec; 3 items not listed)")
        has(text, "Aspect of Hawk(id=6)")
        -- Future spells are reported in their own block, never inside a skill line's known spells.
        has(text, "### not yet learned (spellbook future entries, 1)")
        has(text, "  Future Shot(id=4)")
        assert(not string.find(string.match(text, "(.-)### not yet learned") or "", "Future Shot", 1, true),
            "future spell leaked into known spells")
        lacks(text, "Other Spec Thing")
        lacks(text, "Hidden")
    end)
end

Tests["collector.spells.localized_rank_text_passes_through"] = function()
    WithGlobals(fixture(), function()
        local text = run()
        has(text, "Shot(\237\148\136\236\138\164 2,id=3)")
    end)
end

Tests["collector.spells.sixty_spells_wrap_into_short_lines"] = function()
    local items, lines = {}, { { name = "General", iconID = 1, itemIndexOffset = 0, numSpellBookItems = 60,
        isGuild = false, shouldHide = false } }
    for slot = 1, 60 do items[slot] = spell("Spell Number " .. slot, 1000 + slot, { subName = "Rank 1" }) end
    WithGlobals(fixture({ items = items, lines = lines, itemInfo = function(slot) return items[slot] end }), function()
        local text = run()
        has(text, "spells listed: 60")
        has(text, "Spell Number 60(Rank 1,id=1060)")
        for textLine in string.gmatch(text, "[^\n]+") do
            assert(#textLine <= 135, "line too long: " .. textLine)
        end
    end)
end

Tests["collector.spells.zero_skill_lines_is_explicit"] = function()
    WithGlobals(fixture({ lines = {} }), function()
        local text = run()
        has(text, "skill lines: 0 (the API reported no spellbook skill lines)")
        lacks(text, "<not_collected")
    end)
end

Tests["collector.spells.missing_api_is_unsupported"] = function()
    WithGlobals({ C_SpellBook = false, Enum = { SpellBookSpellBank = { Player = PLAYER } } }, function()
        local text, section = run()
        has(text, "skill lines: <unsupported")
        has(text, "C_SpellBook.GetNumSpellBookSkillLines")
        assert(section.numSkillLines.status == "unsupported")
    end)
end

Tests["collector.spells.missing_bank_enum_is_unsupported"] = function()
    WithGlobals(fixture({ enum = {} }), function()
        local text, section = run()
        has(text, "spellbook: <unsupported: Enum.SpellBookSpellBank.Player unavailable at runtime>")
        assert(section.lines == nil)
    end)
end

Tests["collector.spells.nil_count_stays_not_collected"] = function()
    WithGlobals(fixture({ count = function() end }), function()
        local text, section = run()
        assert(section.numSkillLines.status == "not_collected")
        has(text, "skill lines: <not_collected")
        lacks(text, "skill lines: 0")
    end)
end

Tests["collector.spells.restricted_item_does_not_erase_others"] = function()
    local mocks = fixture()
    local original = mocks.C_SpellBook.GetSpellBookItemInfo
    mocks.C_SpellBook.GetSpellBookItemInfo = function(slot, bank)
        if slot == 2 then return { name = FCE_SECRET, spellID = 2 } end
        if slot == 4 then error("item boom", 0) end
        if slot == 5 then return nil end
        return original(slot, bank)
    end
    WithGlobals(mocks, function()
        local text = run()
        has(text, "unreadable slots: 3")
        has(text, "slot 2 <restricted")
        has(text, "slot 4 <error: item boom [C_SpellBook.GetSpellBookItemInfo]>")
        has(text, "slot 5 <not_collected")
        has(text, "Mount Up(Rank 2,id=1)")
        has(text, "Spec Passive(id=9,passive)")
    end)
end

Tests["collector.spells.failed_skill_line_does_not_erase_others"] = function()
    local lines = {
        { name = "General", iconID = 1, itemIndexOffset = 0, numSpellBookItems = 1, isGuild = false, shouldHide = false },
        { name = "Broken", iconID = 1, itemIndexOffset = 1, numSpellBookItems = "x", isGuild = false,
            shouldHide = false },
    }
    local mocks = fixture({ lines = lines, count = function() return 3 end,
        lineInfo = function(index)
            if index == 3 then return nil end
            return lines[index]
        end })
    WithGlobals(mocks, function()
        local text = run()
        has(text, "Mount Up(Rank 2,id=1)")
        has(text, "### skill line 2: <error: skill line has unusable itemIndexOffset/numSpellBookItems")
        has(text, "### skill line 3: <not_collected")
    end)
end

Tests["collector.spells.uncached_name_keeps_id"] = function()
    local mocks = fixture({ lines = { { name = "General", iconID = 1, itemIndexOffset = 0, numSpellBookItems = 1,
        isGuild = false, shouldHide = false } }, items = { [1] = spell("", 55) } })
    WithGlobals(mocks, function()
        local text = run()
        has(text, "<not_collected: name not cached>(id=55)")
    end)
end
