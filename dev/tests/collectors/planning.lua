-- Mocked contract tests for the planning collector (not a WoW runtime).
-- luacheck: read globals GetTime
local Addon = AddonUnderTest

local function run()
    local section = Addon.collectors.planning(Addon)
    local out = Addon:NewWriter()
    Addon.formatters.planning(Addon, section, out)
    return out:Output(), section
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function lacks(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

local function withTrainer(open, fn)
    Addon.Dispatch(nil, open and "TRAINER_SHOW" or "TRAINER_CLOSED")
    local ok, err = pcall(fn)
    Addon.planningTrainerOpen = nil
    if not ok then error(err, 0) end
end

-- A spellbook with one skill line. items[slot] = SpellBookItemInfo-like table.
local function spellbookApi(items, size)
    return {
        GetNumSpellBookSkillLines = function() return 1 end,
        GetSpellBookSkillLineInfo = function()
            return { name = "Hunter", itemIndexOffset = 0, numSpellBookItems = size or #items, shouldHide = false }
        end,
        GetSpellBookItemInfo = function(slot) return items[slot] end,
    }
end

local function spell(id, name, extra)
    local info = { actionID = id, spellID = id, itemType = 1, name = name, isPassive = false, isOffSpec = false }
    for key, value in pairs(extra or {}) do info[key] = value end
    return info
end

-- A full, healthy fixture. overrides replace whole globals.
local function mock(overrides)
    local items = {
        spell(100, "Arcane Shot"),
        spell(101, "Hunter's Mark"),
        spell(102, "Passive Thing", { isPassive = true }),
        { actionID = 900, itemType = 4, name = "Traps", isPassive = false, isOffSpec = false },
        spell(103, "Off Spec", { isOffSpec = true }),
    }
    local globals = {
        Enum = { SpellBookSpellBank = { Player = 0 }, TrainerType = { General = 0, Pet = 3 } },
        GetTime = function() return 1000 end,
        C_SpellBook = spellbookApi(items),
        C_Spell = {
            GetSpellCooldown = function(id)
                if id == 100 then return { startTime = 990, duration = 30, isEnabled = true, modRate = 1 } end
                if id == 101 then return { startTime = 0, duration = 0, isEnabled = true, modRate = 1 } end
            end,
            GetSpellCharges = function(id)
                if id == 101 then return { someChargeField = 2, other = 3 } end
            end,
        },
        GetFlyoutInfo = function(id)
            if id == 900 then return "x", "y", 2, true end
        end,
        GetFlyoutSlotInfo = function(id, i)
            if id ~= 900 then return end
            if i == 1 then return 1001, 1002, true, "Freezing Trap", 0 end
            return 1003, 1003, false, "Explosive Trap", 0
        end,
        C_PaperDollInfo = {
            GetInventorySlotInfo = function(name)
                if name == "Trinket0Slot" then return 13 end
                if name == "HeadSlot" then return 1 end
            end,
        },
        GetInventoryItemID = function(_, slot)
            if slot == 13 then return 5000 end
            if slot == 1 then return 5001 end
        end,
        C_Item = {
            GetItemCooldown = function(id)
                if id == 5000 then return 995, 60, true end
                return 0, 0, false
            end,
            GetItemNameByID = function(id) if id == 7001 then return "Test Bow" end end,
        },
        GetNumSpecGroups = function() return 2 end,
        C_SpecializationInfo = {
            GetActiveSpecGroup = function() return 1 end,
            GetCombatConfigIDForSpecGroup = function(group) if group == 1 then return 310 end end,
        },
        C_Traits = {
            GetConfigInfo = function(id) return { ID = id, name = "Main", type = 1, treeIDs = { 77 } } end,
            GetTreeCurrencyInfo = function() return { { spent = 5, quantity = 2 } } end,
        },
        C_EquipmentSet = {
            CanUseEquipmentSets = function() return true end,
            GetEquipmentSetIDs = function() return { 4, 9 } end,
            GetEquipmentSetInfo = function(id)
                if id == 4 then return "PvE", 134, 4, true, 2, 2, 0, 0, 0 end
                return "PvP", 135, 9, false, 2, 1, 1, 0, 1
            end,
            GetEquipmentSetAssignedSpec = function(id) if id == 4 then return 1 end end,
            GetItemIDs = function(id)
                if id == 4 then return { [16] = 7001, [1] = 7002 } end
                return {}
            end,
            GetIgnoredSlots = function() return { [3] = true, [4] = false } end,
        },
        GetNumTrainerServices = function() return 2 end,
        GetTrainerServiceInfo = function(i) return "Spell " .. i, "available", 1, 10 * i, "Rank " .. i, "Category" end,
        GetTrainerServiceCost = function(i) return 12345 * i, false end,
        GetTrainerServiceSkillReq = function(i) if i == 2 then return "Skinning", 100, false end end,
        C_Trainer = { GetTrainerType = function() return 0 end },
        C_MajorFactions = {
            GetMajorFactionProgressionInfo = function()
                return { renownLevel = 3, previousWeekProgressiveMaxLevel = 4, currentWeekProgressiveMaxLevel = 6,
                    maxLevel = 10, renownReputationEarned = 40, renownLevelThreshold = 150, weekNumber = 2 }
            end,
            GetTotalReputationForRenownLevel = function(_, level) return level * 100 end,
            GetRenownRewardsForLevel = function(_, level)
                if level == 7 then
                    return { { renownRewardID = 1, name = "Reward Mount", description = "A mount", mountID = 55 } }
                end
                return {}
            end,
        },
        C_SeasonInfo = { GetTimeUntilCurrentPVPSeasonEnd = function() return 3 * 86400 end },
        GetCurrentArenaSeason = function() return 2 end,
    }
    for key, value in pairs(overrides or {}) do globals[key] = value end
    return globals
end

Tests["collector.planning.normal"] = function()
    WithGlobals(mock(), function()
        withTrainer(true, function()
            local text, section = run()
            -- trainer
            has(text, "### 상급자 가르침 목록 (12) [완전성: 미확인 - list may be narrowed")
            has(text, "Spell 1 | type=available | reqLevel=10 | sub=Rank 1 | category=Category")
            has(text, "cost=1g 23s 45c (12345c)")
            has(text, "skillReq=없음")
            has(text, "skillReq=Skinning 100 (충족=false)")
            -- spec groups
            has(text, "그룹 1 (활성: 상세는 talents 구역): config 310 name=Main")
            has(text, "tree 77: 사용 5 / 남음 2")
            has(text, "그룹 2 (비활성): config ID <not_collected")
            -- equipment sets
            has(text, "- PvE (setID 4) 착용중=true items=2 equipped=2 inBags=0 lost=0 ignored=0")
            has(text, "배정된 특성 그룹 index: 1")
            has(text, "slot 1=(item 7002); slot 16=Test Bow (item 7001)")
            has(text, "- PvP (setID 9) 착용중=false")
            has(text, "배정된 특성 그룹: 없음")
            has(text, "무시 슬롯: 3")
            -- flyouts
            has(text, "- Traps (flyoutID 900, book slot 4) 알려짐(isKnown)=true 칸=2")
            has(text, "1: Freezing Trap spellID=1001 overrideSpellID=1002 배움(isKnownSlot)=true")
            has(text, "2: Explosive Trap spellID=1003 배움(isKnownSlot)=false")
            -- cooldowns: one active spell, one ready spell with charges, passive/off-spec never checked
            has(text, "확인 2개: 사용 가능(대기 없음) 1, 대기 중 1")
            has(text, "Arcane Shot (spellID 100) 남음 20s | 총 30s (start 990)")
            has(text, "Hunter's Mark (spellID 101) 대기 없음 | 충전 정보(필드 미검증, 원문): {other=3,someChargeField=2}")
            lacks(text, "Passive Thing")
            lacks(text, "Off Spec")
            has(text, "GCD와 고유 쿨다운 구분: 문서화된 필드가 없어 판정 안 함")
            -- items (equipped slots only)
            has(text, "Trinket0Slot item 5000 남음 55s | 총 1m 0s (start 995) enableCooldownTimer=true")
            has(text, "슬롯 19개: 빈 슬롯 0, 미확인 17, 확인 2 (대기 없음 1, 대기 중 1")
            -- pvp
            has(text, "랭크 3 / 시즌 최대 10 | 현재 단계 점수 40 / 150")
            has(text, "이번 주 상한 단계 6 / 지난 주 4")
            has(text, "누적 점수(UI 계산식: 현재 단계 총합 + 단계 점수) 340 | 이번 주 상한 누적 600")
            has(text, "이번 주 상한 증가분 200")
            has(text, "시즌 종료까지: 3d")
            has(text, "현재 시즌 번호: 2")
            has(text, "다음 보상: 랭크 7")
            has(text, "Reward Mount: A mount mountID=55")
            assert(section.trainer.open == true and section.cooldowns.spells.counts.active == 1)
        end)
    end)
end

Tests["collector.planning.trainer_not_open"] = function()
    WithGlobals(mock(), function()
        withTrainer(false, function()
            local text, section = run()
            has(text, "### 상급자 가르침 목록 (12) [완전성: 미확인 - 창 안 열림]")
            has(text, "<not_collected: trainer window not open")
            lacks(text, "Spell 1")
            -- informational: not counted as an unread API value
            assert(section.trainer.state.info == true)
        end)
        -- never seen a TRAINER_SHOW this session
        local text = run()
        has(text, "no TRAINER_SHOW seen since login")
    end)
end

Tests["collector.planning.trainer_pet_cost_unit_and_truncation"] = function()
    WithGlobals(mock({
        C_Trainer = { GetTrainerType = function() return 3 end },
        GetNumTrainerServices = function() return 150 end,
    }), function()
        withTrainer(true, function()
            local text, section = run()
            has(text, "비용=훈련 포인트")
            has(text, "cost=12345 훈련 포인트")
            lacks(text, "cost=1g")
            has(text, "표시 100개 (상한 도달: 일부만 표시, truncated)")
            assert(section.trainer.truncated == true and #section.trainer.services == 100)
        end)
    end)
end

Tests["collector.planning.trainer_unknown_type_does_not_guess_the_unit"] = function()
    WithGlobals(mock({ C_Trainer = false }), function()
        withTrainer(true, function()
            local text = run()
            has(text, "교관 종류 (C_Trainer.GetTrainerType): <unsupported")
            has(text, "cost=12345 (단위 미확인)")
        end)
    end)
end

Tests["collector.planning.blocks_are_independent"] = function()
    -- A Lua error inside one block reader must not hide the other blocks.
    local realProbe = Addon.Probe
    WithGlobals(mock(), function()
        Addon.Probe = function(self, path, ...)
            if path == "GetNumSpecGroups" or path == "C_EquipmentSet.GetEquipmentSetIDs" then
                error("boom " .. path, 0)
            end
            return realProbe(self, path, ...)
        end
        local ok, text, section = pcall(run)
        Addon.Probe = realProbe
        assert(ok, text)
        has(text, "### 특성 그룹 (13a) [완전성: 불완전]")
        has(text, "### 장비 세트 (13b) [완전성: 불완전]")
        has(text, "boom GetNumSpecGroups")
        assert(section.specGroups.state.status == "error")
        -- the rest is unaffected
        has(text, "Traps (flyoutID 900")
        has(text, "Arcane Shot (spellID 100)")
        has(text, "다음 보상: 랭크 7")
    end)
end

Tests["collector.planning.unsupported_apis_stay_visible_and_separate"] = function()
    WithGlobals(mock({
        GetNumSpecGroups = false, C_EquipmentSet = false, GetFlyoutInfo = false, C_MajorFactions = false,
        C_Spell = false,
    }), function()
        local text = run()
        has(text, "<unsupported: function unavailable at runtime [GetNumSpecGroups]>")
        has(text, "세트 목록: <unsupported")
        has(text, "flyoutID 900, book slot 4): <unsupported")
        has(text, "<unsupported: function unavailable at runtime [C_Spell.GetSpellCooldown]>")
        has(text, "[C_MajorFactions.GetMajorFactionProgressionInfo]")
        -- item cooldowns do not depend on the spell API or the spellbook pass
        has(text, "Trinket0Slot item 5000")
    end)
end

Tests["collector.planning.restricted_cooldowns_do_not_leak_or_pretend_ready"] = function()
    WithGlobals(mock({
        C_Spell = {
            GetSpellCooldown = function() return { startTime = FCE_SECRET, duration = FCE_SECRET, isEnabled = true } end,
            GetSpellCharges = function() return { currentCharges = FCE_SECRET } end,
        },
    }), function()
        local text, section = run()
        has(text, "제한(restricted) 2")
        has(text, "충전형 0개 (충전 제한 2")
        has(text, "<restricted: 쿨다운 값이 제한됨")
        has(text, "사용 가능(대기 없음) 0, 대기 중 0")
        has(text, "[완전성: 불완전/일부]")
        assert(section.cooldowns.spells.complete == false)
        assert(#section.cooldowns.spells.entries == 0)
        assert(section.cooldowns.spells.samples.restricted.status == "restricted")
    end)
end

Tests["collector.planning.unknown_gcd_and_extra_fields_are_shown_not_interpreted"] = function()
    WithGlobals(mock({
        C_Spell = {
            GetSpellCooldown = function(id)
                if id == 100 or id == 101 then
                    return { startTime = 999, duration = 1.5, isEnabled = true, modRate = 1, mysteryFlag = true }
                end
            end,
            GetSpellCharges = function() end,
        },
    }), function()
        local text = run()
        has(text, "같은 타이머 2개 (GCD 여부 미확인)")
        has(text, "기타 필드: mysteryFlag=true")
        lacks(text, "GCD=true")
    end)
end

Tests["collector.planning.cooldown_list_is_capped_with_marker"] = function()
    local items = {}
    for id = 1, 60 do items[#items + 1] = spell(id, "S" .. id) end
    WithGlobals(mock({
        C_SpellBook = spellbookApi(items),
        C_Spell = {
            GetSpellCooldown = function() return { startTime = 990, duration = 30, isEnabled = true } end,
            GetSpellCharges = function() end,
        },
    }), function()
        local text, section = run()
        assert(#section.cooldowns.spells.entries == 40)
        assert(section.cooldowns.spells.entriesTruncated == 20)
        has(text, "... 20개 더 있음 (목록 상한 40, truncated)")
        has(text, "확인 60개")
        assert(section.cooldowns.spells.complete == false)
    end)
end

Tests["collector.planning.nil_returns_do_not_flood_coverage"] = function()
    local items = {}
    for id = 1, 200 do items[#items + 1] = spell(id, "S" .. id) end
    WithGlobals(mock({
        C_SpellBook = spellbookApi(items),
        C_Spell = { GetSpellCooldown = function() end, GetSpellCharges = function() end },
    }), function()
        local text, section = run()
        has(text, "확인 200개")
        has(text, "반환 없음(nil) 200")
        local counts = Addon:Tally(section)
        -- 200 nil results are counted in the text, not as 400 unread API values
        assert(counts.not_collected < 20, "not_collected=" .. counts.not_collected)
    end)
end

Tests["collector.planning.spellbook_cap_is_marked"] = function()
    local items = {}
    for id = 1, 450 do items[#items + 1] = spell(id, "S" .. id) end
    WithGlobals(mock({
        C_SpellBook = spellbookApi(items),
        C_Spell = { GetSpellCooldown = function() end, GetSpellCharges = function() end },
    }), function()
        local text, section = run()
        assert(section.flyouts.spellbook.truncated == true and section.flyouts.spellbook.slotsRead == 400)
        has(text, "주문서 400칸 읽음, 칸 상한 도달 (truncated)")
        assert(section.cooldowns.spells.complete == false and section.flyouts.complete == false)
    end)
end

Tests["collector.planning.no_flyouts_is_empty_only_when_the_book_was_fully_read"] = function()
    WithGlobals(mock({ C_SpellBook = spellbookApi({ spell(1, "A") }) }), function()
        local text, section = run()
        has(text, "주문서의 flyout 0개")
        lacks(text, "없다는 증거 아님")
        assert(section.flyouts.complete == true)
    end)
    -- one unreadable book slot: zero flyouts is not proof
    local book = spellbookApi({ spell(1, "A"), spell(2, "B") })
    book.GetSpellBookItemInfo = function(slot) if slot == 1 then return spell(1, "A") end end
    WithGlobals(mock({ C_SpellBook = book }), function()
        local text, section = run()
        has(text, "주문서의 flyout 0개 (주문서 읽기가 불완전하므로 없다는 증거 아님)")
        assert(section.flyouts.complete == false)
    end)
end

Tests["collector.planning.spellbook_unsupported_marks_flyouts_and_spell_cooldowns_only"] = function()
    WithGlobals(mock({ Enum = {}, C_SpellBook = spellbookApi({}) }), function()
        local text, section = run()
        has(text, "Enum.SpellBookSpellBank.Player unavailable at runtime")
        assert(section.flyouts.complete == false and section.cooldowns.spells.complete == false)
        has(text, "Trinket0Slot item 5000") -- item cooldowns still collected
        has(text, "다음 보상: 랭크 7")
    end)
end

Tests["collector.planning.pvp_unknowns_are_not_zero"] = function()
    WithGlobals(mock({
        C_SeasonInfo = { GetTimeUntilCurrentPVPSeasonEnd = function() return 0 end },
        GetCurrentArenaSeason = function() return 0 end,
        C_MajorFactions = {
            GetMajorFactionProgressionInfo = function()
                return { renownLevel = 0, previousWeekProgressiveMaxLevel = 0, currentWeekProgressiveMaxLevel = 0,
                    maxLevel = 10, renownReputationEarned = 0, renownLevelThreshold = 150, weekNumber = 1 }
            end,
            GetTotalReputationForRenownLevel = function() return 0 end,
            GetRenownRewardsForLevel = function() return {} end,
        },
    }), function()
        local text, section = run()
        has(text, "시즌 종료까지: <not_collected: API가 0 반환 = 종료 시점 모름")
        has(text, "현재 시즌 번호: 0 (UI는 0이면 시즌 표시를 숨김)")
        has(text, "이번 주 상한: 표시 없음")
        has(text, "다음 보상: 랭크 1~10 모두 보상 없음")
        assert(section.pvp.seasonEndsAtServerTime == nil)
    end)
end

Tests["collector.planning.pvp_missing_faction_and_failed_reward_scan"] = function()
    WithGlobals(mock({
        C_MajorFactions = { GetMajorFactionProgressionInfo = function() end },
    }), function()
        local text, section = run()
        has(text, "진행 정보 (C_MajorFactions.GetMajorFactionProgressionInfo 2800): <not_collected")
        assert(section.pvp.complete == false)
    end)
    WithGlobals(mock({
        C_MajorFactions = {
            GetMajorFactionProgressionInfo = function()
                return { renownLevel = 3, previousWeekProgressiveMaxLevel = 3, currentWeekProgressiveMaxLevel = 3,
                    maxLevel = 6, renownReputationEarned = 1, renownLevelThreshold = 100, weekNumber = 1 }
            end,
            GetTotalReputationForRenownLevel = function(_, level) return level end,
            GetRenownRewardsForLevel = function() error("blocked") end,
        },
    }), function()
        local text = run()
        has(text, "다음 보상: <not_collected: 3단계 읽기 실패; 없다는 증거 아님")
        lacks(text, "모두 보상 없음")
    end)
end

Tests["collector.planning.pvp_reward_scan_is_capped"] = function()
    local calls = 0
    WithGlobals(mock({
        C_MajorFactions = {
            GetMajorFactionProgressionInfo = function()
                return { renownLevel = 0, previousWeekProgressiveMaxLevel = 0, currentWeekProgressiveMaxLevel = 0,
                    maxLevel = 500, renownReputationEarned = 0, renownLevelThreshold = 100, weekNumber = 1 }
            end,
            GetTotalReputationForRenownLevel = function() return 0 end,
            GetRenownRewardsForLevel = function() calls = calls + 1 return {} end,
        },
    }), function()
        local text = run()
        assert(calls == 60, "calls=" .. calls)
        has(text, "다음 보상: <not_collected: 60단계 확인 후 상한 도달 (truncated)>")
    end)
end

Tests["collector.planning.spec_group_without_config_is_not_zero_talents"] = function()
    WithGlobals(mock({ GetNumSpecGroups = function() return 1 end }), function()
        local text, section = run()
        has(text, "그룹 수 (GetNumSpecGroups): 1")
        lacks(text, "그룹 2")
        assert(section.specGroups.complete == true)
    end)
    WithGlobals(mock({
        C_SpecializationInfo = {
            GetActiveSpecGroup = function() return 1 end,
            GetCombatConfigIDForSpecGroup = function() end,
        },
    }), function()
        local text, section = run()
        has(text, "특성 0개의 증거 아님")
        assert(section.specGroups.complete == false)
    end)
end

Tests["collector.planning.empty_equipment_sets_are_a_real_empty_list"] = function()
    WithGlobals(mock({
        C_EquipmentSet = {
            CanUseEquipmentSets = function() return true end,
            GetEquipmentSetIDs = function() return {} end,
        },
    }), function()
        local text, section = run()
        has(text, "세트 0개 (읽기만 함; 착용 안 함)")
        assert(section.equipmentSets.complete == true)
    end)
end

Tests["collector.planning.equipment_set_item_cap_is_marked"] = function()
    local many = {}
    for slot = 1, 30 do many[slot] = 8000 + slot end
    local sets = mock().C_EquipmentSet
    sets.GetItemIDs = function() return many end
    WithGlobals(mock({ C_EquipmentSet = sets }), function()
        local text, section = run()
        has(text, "... (상한 도달, truncated)")
        assert(section.equipmentSets.complete == false)
    end)
end

Tests["collector.planning.item_cooldown_restricted_is_counted"] = function()
    WithGlobals(mock({ C_Item = { GetItemCooldown = function() return FCE_SECRET, 5, true end } }), function()
        local text, section = run()
        has(text, "제한 2, 오류 0)")
        assert(section.cooldowns.items.complete == false and #section.cooldowns.items.entries == 0)
    end)
end

Tests["collector.planning.registered_and_ordered"] = function()
    assert(type(Addon.collectors.planning) == "function" and type(Addon.formatters.planning) == "function")
    local found
    for _, name in ipairs(Addon.order) do if name == "planning" then found = true end end
    assert(found)
end
