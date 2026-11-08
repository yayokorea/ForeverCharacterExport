-- Mocked contract tests for the spelldetails collector (not a WoW runtime).
local PLAYER = 0

local function run(full)
    local addon = AddonUnderTest
    local saved = addon.detail
    addon.detail = full and { spelldetails = true } or nil
    local ok, section, text = pcall(function()
        local collected = addon.collectors.spelldetails(addon)
        local out = addon:NewWriter()
        addon.formatters.spelldetails(addon, collected, out)
        return collected, out:Output()
    end)
    addon.detail = saved
    if not ok then error(section, 0) end
    return text, section
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function lacks(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

local function spell(name, id, extra)
    local item = { actionID = id, spellID = id, itemType = 1, name = name, subName = "", iconID = 1,
        isPassive = false, isOffSpec = false }
    for key, value in pairs(extra or {}) do item[key] = value end
    return item
end

local function equipmentMocks(options)
    options = options or {}
    local slotIds = { HeadSlot = 1, Trinket0Slot = 13, MainHandSlot = 16 }
    local links = options.links or {
        [1] = "|cff1eff00|Hitem:100:0:0:0|h[Hunter Helm]|h|r",
        [13] = "|cffffffff|Hitem:200:5:0:0|h[Whistle]|h|r",
    }
    return {
        C_PaperDollInfo = { GetInventorySlotInfo = function(name) return slotIds[name] end },
        GetInventoryItemLink = function(_, slot) return links[slot] end,
        GetInventoryItemID = function(_, slot)
            local link = links[slot]
            return link and tonumber(string.match(link, "item:(%d+)")) or nil
        end,
        C_Item = options.item or {
            GetItemStats = function(link)
                if string.find(link, "item:100", 1, true) then return { STAT_A = 7, STAT_B = 3 } end
            end,
            GetItemSpell = function(id)
                if id == 200 then return "Call Pet", 883 end
            end,
        },
    }
end

local function fixture(options)
    options = options or {}
    local lines = options.lines or {
        { name = "General", iconID = 1, itemIndexOffset = 0, numSpellBookItems = 3, isGuild = false, shouldHide = false },
        { name = "Hunter", iconID = 1, itemIndexOffset = 3, numSpellBookItems = 4, isGuild = false, shouldHide = false },
        { name = "Off", iconID = 1, itemIndexOffset = 7, numSpellBookItems = 1, isGuild = false, shouldHide = false,
            offSpecID = 253 },
    }
    local items = options.items or {
        [1] = spell("Mount Up", 1),
        [2] = spell("Pet Flyout", 7, { itemType = 4, spellID = nil }),
        [3] = spell("Tracking", 2, { isPassive = true }),
        [4] = spell("Shot", 3),
        [5] = spell("Shot Again", 3), -- same spell ID on a second skill line / slot
        [6] = spell("Future Shot", 4, { itemType = 2 }),
        [7] = spell("Other Spec", 5, { isOffSpec = true }),
    }
    local mocks = equipmentMocks(options)
    mocks.Enum = options.enum or { SpellBookSpellBank = { Player = PLAYER, Pet = 1 } }
    mocks.C_SpellBook = {
        GetNumSpellBookSkillLines = function() return #lines end,
        GetSpellBookSkillLineInfo = function(index) return lines[index] end,
        GetSpellBookItemInfo = function(slot, bank)
            assert(bank == PLAYER, "must read the Player bank only")
            assert(slot < 8, "off-spec skill line slots must not be read")
            return items[slot]
        end,
    }
    local descriptions = options.descriptions or {
        [1] = "Summons a mount. Second line.", [2] = "", [3] = "Shoots |cff00ff00an arrow|r.",
    }
    mocks.C_Spell = options.spell or {
        GetSpellDescription = function(id) return descriptions[id] end,
        GetSpellInfo = function(id)
            if id == 4 then return nil end
            return { name = "S" .. id, iconID = 1, originalIconID = 1, castTime = 1500, minRange = 0, maxRange = 40,
                spellID = id }
        end,
        GetSpellLevelLearned = function(id) return id * 2 end,
        GetSpellPowerCost = function(id)
            if id == 3 then return { { amount = 30, kind = "x" } } end
        end,
    }
    return mocks
end

Tests["collector.spelldetails.compact_default_has_no_description_text"] = function()
    WithGlobals(fixture(), function()
        local text, section = run(false)
        assert(section.detail == "compact")
        has(text, "상세 수준: 요약")
        has(text, "Addon.detail.spelldetails = true")
        -- Unique spell IDs 1, 2, 3 (ID 3 repeated once, flyout / future / off-spec only counted).
        has(text, "고유 주문 3개")
        has(text, "중복 ID 1")
        has(text, "미습득 1")
        has(text, "주문 아님(전문화창/소환수 등) 1")
        has(text, "비활성 특성 1")
        has(text, "표시 3 / 전체 3 — 완전(complete)")
        has(text, "설명=읽음(")
        lacks(text, "Summons a mount")
        lacks(text, "Future Shot")
        lacks(text, "Other Spec")
        lacks(text, "Pet Flyout")
    end)
end

Tests["collector.spelldetails.empty_description_is_not_loaded_but_nil_is_not_found"] = function()
    local mocks = fixture()
    -- spell 3 has no entry: the API returns nothing (documented: not found)
    local descriptions = { [1] = "Summons a mount.", [2] = "" }
    mocks.C_Spell.GetSpellDescription = function(id) return descriptions[id] end
    WithGlobals(mocks, function()
        local text, section = run(true)
        local byId = {}
        for _, entry in ipairs(section.spells) do byId[entry.spellID] = entry end
        assert(byId[1].description.status == "ok")
        assert(byId[2].description.status == "not_collected")
        assert(string.find(byId[2].description.reason, "not loaded", 1, true))
        assert(byId[3].description.status == "not_collected")
        assert(string.find(byId[3].description.reason, "spell not found", 1, true))
        has(text, "설명: Summons a mount.")
        has(text, "설명: <not_collected: description not loaded yet")
        has(text, "SPELL_TEXT_UPDATE")
        has(text, "설명: <not_collected: API returned nothing (documented: spell not found)")
    end)
end

Tests["collector.spelldetails.nil_cost_is_ambiguous_never_free_or_zero"] = function()
    WithGlobals(fixture(), function()
        local text, section = run(true)
        has(text, "소모=보고 없음(무료이거나 주문 미확인, API는 구분 불가)")
        has(text, "소모={{amount=30,kind=x}}")
        lacks(text, "소모=0")
        lacks(text, "무료입니다")
        for _, entry in ipairs(section.spells) do
            if entry.spellID == 1 then assert(entry.cost.info == true, "ambiguous cost must not count as unread") end
        end
    end)
end

Tests["collector.spelldetails.full_mode_prints_cleaned_description_and_fields"] = function()
    WithGlobals(fixture(), function()
        local text = run(true)
        has(text, "상세 수준: 전체")
        has(text, "- Mount Up (id=1, General) 시전=1500 사거리=0~40")
        has(text, "습득레벨=2")
        has(text, "설명: Summons a mount. Second line.")
        has(text, "Shoots an arrow.")
        has(text, "패시브")
        -- Same spell ID is detailed once.
        assert(select(2, string.gsub(text, "%(id=3", "")) == 1, "spell ID 3 repeated")
    end)
end

Tests["collector.spelldetails.truncates_at_the_cap_with_a_marker"] = function()
    local items, lines = {}, { { name = "General", iconID = 1, itemIndexOffset = 0, numSpellBookItems = 40,
        isGuild = false, shouldHide = false } }
    for slot = 1, 40 do items[slot] = spell("Spell " .. slot, 1000 + slot) end
    local mocks = fixture({ items = items, lines = lines, descriptions = {} })
    mocks.C_SpellBook.GetSpellBookItemInfo = function(slot) return items[slot] end
    WithGlobals(mocks, function()
        local text, section = run(false)
        assert(#section.spells == 10 and section.spellsTruncated == true)
        has(text, "표시 10 / 전체 40 — 잘림(truncated)")
        lacks(text, "Spell 11 ")
    end)
    -- full mode cap
    items = {}
    lines[1].numSpellBookItems = 300
    for slot = 1, 300 do items[slot] = spell("Spell " .. slot, 2000 + slot) end
    mocks = fixture({ items = items, lines = lines, descriptions = {} })
    mocks.C_SpellBook.GetSpellBookItemInfo = function(slot) return items[slot] end
    WithGlobals(mocks, function()
        local text = run(true)
        has(text, "표시 250 / 전체 300 — 잘림(truncated)")
    end)
end

Tests["collector.spelldetails.long_description_is_clipped_on_a_utf8_boundary"] = function()
    local long = string.rep("\234\176\128", 400) -- U+AC00 x 400 = 1200 bytes
    WithGlobals(fixture({ descriptions = { [1] = long } }), function()
        local text = run(true)
        has(text, "잘림, 전체 1200바이트")
        local body = string.match(text, "설명: (.-)%.%.%.%(잘림")
        assert(body and #body % 3 == 0 and #body <= 500, "cut inside a multibyte character")
    end)
end

Tests["collector.spelldetails.missing_c_spell_is_unsupported_but_spell_list_survives"] = function()
    local mocks = fixture()
    mocks.C_Spell = false
    WithGlobals(mocks, function()
        local text, section = run(true)
        has(text, "미지원 API (아래 항목에서 생략): C_Spell.GetSpellDescription, C_Spell.GetSpellInfo, "
            .. "C_Spell.GetSpellLevelLearned, C_Spell.GetSpellPowerCost")
        has(text, "- Mount Up (id=1, General)")
        has(text, "- Shot (id=3, Hunter)") -- listed under its first skill line
        assert(section.spells[1].description.status == "unsupported")
        lacks(text, "소모=")
        lacks(text, "습득레벨=")
    end)
end

Tests["collector.spelldetails.restricted_description_does_not_erase_others"] = function()
    local mocks = fixture()
    mocks.C_Spell.GetSpellDescription = function(id)
        if id == 1 then return FCE_SECRET end
        if id == 2 then error("desc boom", 0) end
        return "ok text"
    end
    WithGlobals(mocks, function()
        local text = run(true)
        has(text, "설명: <restricted")
        has(text, "설명: <error: desc boom [C_Spell.GetSpellDescription]>")
        has(text, "설명: ok text")
    end)
end

Tests["collector.spelldetails.missing_bank_enum_is_unsupported_but_equipment_survives"] = function()
    WithGlobals(fixture({ enum = {} }), function()
        local text, section = run(false)
        assert(section.spells == nil)
        has(text, "주문서: <unsupported: Enum.SpellBookSpellBank.Player unavailable at runtime>")
        has(text, "- 머리: Hunter Helm (id=100)")
    end)
end

Tests["collector.spelldetails.equipment_compact_counts_stats_and_keeps_item_spell"] = function()
    WithGlobals(fixture(), function()
        local text = run(false)
        has(text, "장비: 착용 2, 빈 슬롯 1, 확인 불가 16")
        has(text, "- 머리: Hunter Helm (id=100), 능력치 2종, 아이템 주문=보고 없음(없거나 미로딩, API는 구분 불가)")
        has(text, "- 장신구 1: Whistle (id=200), 능력치=보고 없음(능력치가 없거나 미로딩, API는 구분 불가), "
            .. "아이템 주문=Call Pet (id=883)")
        has(text, "- 주무기: <empty slot: 링크·ID 모두 보고 없음>")
        lacks(text, "STAT_A")
        lacks(text, "item:200:5")
    end)
end

Tests["collector.spelldetails.equipment_full_keeps_link_and_dumps_stats_unmodified"] = function()
    local mocks = fixture()
    WithGlobals(mocks, function()
        local text = run(true)
        has(text, "링크: item:200:5:0:0")
        has(text, "링크: item:100:0:0:0")
        has(text, "능력치: {STAT_A=7,STAT_B=3}")
        has(text, "아이템 주문 설명: <not_collected: API returned nothing (documented: spell not found)")
    end)
end

Tests["collector.spelldetails.item_spell_description_not_repeated_for_known_spell"] = function()
    local mocks = fixture()
    mocks.C_Item.GetItemSpell = function(id)
        if id == 200 then return "Mounty", 1 end -- spell ID 1 is also in the spellbook
        if id == 100 then return "Mounty Too", 1 end
    end
    WithGlobals(mocks, function()
        local text = run(true)
        local _, count = string.gsub(text, "Summons a mount%.", "")
        assert(count == 1, "description repeated " .. count .. " times")
        has(text, "같은 주문 ID 설명은 위 '주문서' 항목 참조")
    end)
end

Tests["collector.spelldetails.restricted_or_failed_item_apis_are_tagged"] = function()
    local mocks = fixture()
    mocks.C_Item = {
        GetItemStats = function() return FCE_SECRET end,
        GetItemSpell = function() error("spell boom", 0) end,
    }
    WithGlobals(mocks, function()
        local text = run(false)
        has(text, "능력치=<restricted")
        has(text, "아이템 주문=<error: spell boom [C_Item.GetItemSpell]>")
    end)
end

Tests["collector.spelldetails.detail_flag_tolerates_garbage"] = function()
    local addon = AddonUnderTest
    local saved = addon.detail
    local ok, err = pcall(WithGlobals, fixture(), function()
        for _, value in ipairs({ "yes", 1, false }) do
            addon.detail = { spelldetails = value }
            assert(addon.collectors.spelldetails(addon).detail == "compact")
        end
        addon.detail = "not a table"
        assert(addon.collectors.spelldetails(addon).detail == "compact")
        addon.detail = { spelldetails = "full" }
        assert(addon.collectors.spelldetails(addon).detail == "full")
    end)
    addon.detail = saved
    if not ok then error(err, 0) end
end
