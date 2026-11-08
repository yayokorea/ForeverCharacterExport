-- Mocked contract tests for the combatdetails collector. Not a WoW runtime.
-- The enum values below are test data only; the collector never hardcodes them.
local Addon = AddonUnderTest

local function check(condition, message)
    if not condition then error(message, 2) end
end

local function has(text, needle)
    return string.find(text, needle, 1, true) ~= nil
end

local function enums()
    return {
        PowerType = { Mana = 0 },
        Damageclass = { Holy = 2, Fire = 3, Nature = 4, Frost = 5, Shadow = 6, Arcane = 7 },
        ItemClass = { Weapon = 2, Armor = 4 },
        ItemWeaponSubclass = { Axe1H = 0, Axe2H = 1, Bows = 2, Guns = 3, Mace1H = 4, Mace2H = 5, Polearm = 6,
            Sword1H = 7, Sword2H = 8, Staff = 10, Unarmed = 13, Dagger = 15, Thrown = 16, Crossbow = 18, Wand = 19 },
    }
end

local SLOT_IDS = { MainHandSlot = 16, SecondaryHandSlot = 17, RangedSlot = 18 }
local SKILL_NAMES = { [43] = "Swords", [45] = "Bows", [162] = "Unarmed", [3014] = "Feral Combat", [173] = "Daggers" }

-- calls: names of APIs invoked, to prove which reads happened.
local function mocks(overrides, calls)
    local function tracked(name, fn)
        return function(...)
            if calls then calls[#calls + 1] = name end
            return fn(...)
        end
    end
    local equipped = { [16] = 1001, [17] = nil, [18] = 1003 } -- sword, nothing, bow
    local itemInfo = {
        [1001] = { 2, 7 }, -- weapon, Sword1H
        [1003] = { 2, 2 }, -- weapon, Bows
        [1004] = { 4, 6 }, -- armor class (shield)
        [1005] = { 2, 99 }, -- weapon, subclass not in the UI table
    }
    local api = {
        Enum = enums(),
        CR_HIT_MELEE = 6, CR_HIT_SPELL = 8, LE_UNIT_STAT_INTELLECT = 4,
        InCombatLockdown = function() return false end,
        GetShapeshiftForm = function() return 0 end,
        UnitClass = function() return "Hunter", "HUNTER", 3 end,
        UnitStat = function(_, index) return 10, 100 + index, 0, 0 end,
        UnitExists = tracked("UnitExists", function() return true end),
        UnitName = function() return "Cat" end,
        UnitCreatureFamily = function() return "Cat", 2 end,
        UnitArmor = tracked("UnitArmor", function() return 150, 180, 150, 30 end),
        UnitDamage = tracked("UnitDamage", function() return 11.5, 14.5, 0, 0, 0, 0, 1.1 end),
        UnitAttackSpeed = tracked("UnitAttackSpeed", function() return 2.0 end),
        UnitAttackPower = tracked("UnitAttackPower", function() return 60, 10, -2 end),
        GetPetSpellBonusDamage = tracked("GetPetSpellBonusDamage", function() return 25 end),
        GetPetHitChanceModifier = tracked("GetPetHitChanceModifier", function() return 3 end),
        GetPetSpellHitChanceModifier = tracked("GetPetSpellHitChanceModifier", function() return 2 end),
        GetCombatRatingBonus = function(index) if index == 6 then return 1.5 end return 0.5 end,
        GetHitModifier = function() return 2 end,
        GetSpellHitModifier = function() return 1 end,
        GetPetCritChance = tracked("GetPetCritChance", function() return 5.5, 4.5 end),
        GetPetMeleeHaste = tracked("GetPetMeleeHaste", function() return 3 end),
        UnitSpellHaste = tracked("UnitSpellHaste", function() return 1 end),
        GetPetDodgeChance = tracked("GetPetDodgeChance", function() return 6.2 end),
        UnitDefenseSkill = function() return 40, 0 end,
        UnitResistance = function(unit, school) return 0, 10 * school, 10 * school, 0 end,
        UnitPowerMax = function() return 0 end,
        IsDualWielding = function() return false end,
        GetOffhandHitModifier = function() return 0 end,
        GetShieldBlock = function() return 0 end,
        GetHealthRegen = function() return 2.5, 1.5 end,
        GetHealthRegenFromSpirit = function() return 1.5, 0.5 end,
        GetManaRegenFromSpirit = function() return 3, 1 end,
        GetInventoryItemID = function(_, slot) return equipped[slot] end,
        C_PaperDollInfo = {
            GetInventorySlotInfo = function(name) return SLOT_IDS[name], 1, false end,
            OffhandHasShield = function() return false end,
        },
        C_Item = {
            GetItemInfoInstant = function(id)
                local row = itemInfo[id]
                if row then return id, "t", "s", "loc", 1, row[1], row[2] end
            end,
        },
        C_SkillInfo = {
            GetSkillLineInfoByID = function(id)
                if SKILL_NAMES[id] then
                    return { skillID = id, name = SKILL_NAMES[id], rank = 100, modifier = 2, maxRank = 300,
                        description = "long text" }
                end
            end,
        },
    }
    for key, value in pairs(overrides or {}) do api[key] = value end
    return api
end

local function run(overrides, fn, calls)
    local api = mocks(overrides, calls)
    WithGlobals(api, function()
        local section = Addon.collectors.combatdetails(Addon)
        local out = Addon:NewWriter()
        Addon.formatters.combatdetails(Addon, section, out)
        fn(section, out:Output(), api)
    end)
end

local function warlock(extra)
    local api = {
        UnitClass = function() return "Warlock", "WARLOCK", 9 end,
        UnitPowerMax = function() return 300 end,
        UnitCreatureFamily = function() return "Voidwalker", 16 end,
    }
    for key, value in pairs(extra or {}) do api[key] = value end
    return api
end

Tests["collector.combatdetails.hunter_with_pet"] = function()
    run(nil, function(section, text)
        check(section.status == nil and section.pet.unit == nil, "data section with a pet")
        check(section.pet.armor.values[2] == 180, "pet armor read with the pet unit")
        check(section.pet.attackPower.values[1] == 60, "pet attack power")
        check(section.pet.crit.values[2] == 4.5, "pet crit has two returns")
        check(has(text, "방어도 UnitArmor: effective=180 base=150 real=150 bonus=30"), text)
        check(has(text, "피해 UnitDamage: 11.50-14.50"), text)
        check(has(text, "공격 속도 UnitAttackSpeed: mainhand=2"), text)
        check(has(text, "공격력 UnitAttackPower: base=60 posBuff=10 negBuff=-2"), text)
        check(has(text, "주문력 GetPetSpellBonusDamage: 25"), text)
        check(has(text, "치명타 GetPetCritChance: 근접=5.50% 주문=4.50%"), text)
        check(has(text, "회피 GetPetDodgeChance: 6.20%"), text)
        check(has(text, "게임 내 확인 필요"), "unverified pet defense/resist is flagged: " .. text)
        check(has(text, "플레이어 직업 UnitClass: HUNTER (Hunter)"), text)
        check(has(text, "완전성: fixed field list; no truncation"), text)
        -- player resistances: runtime enum values passed through.
        check(has(text, "  Holy (damageClass 2): base=0 real=20 effective=20 bonus=0"), text)
        check(has(text, "  Arcane (damageClass 7): base=0 real=70"), text)
    end)
end

Tests["collector.combatdetails.hit_total_is_computed_with_inputs"] = function()
    run(nil, function(section, text)
        -- melee: 1.5 + 2 + pet 3 = 6.5; spell: 0.5 + 1 + pet 2 = 3.5; displayed = max
        local total = section.pet.hitTotal
        check(total.status == "ok" and total.values[1] == 6.5 and total.values[2] == 3.5 and total.values[3] == 6.5,
            "UI formula total")
        check(has(total.api, "computed"), "marked as computed")
        check(section.pet.hitInputs.ownerMeleeModifier.values[1] == 2, "inputs kept")
        check(has(text, "근접/원거리=6.50% 주문=3.50% UI 표시(최대)=6.50%"), text)
    end)
    run({ GetHitModifier = false }, function(section, text)
        check(section.pet.hitTotal.status == "not_collected", "an unreadable input blocks the total, no zero")
        check(section.pet.hitModifier.values[1] == 3, "raw pet modifier still stored")
        check(has(text, "UI 표시 명중 합계 (계산값: 주인 명중 + 소환수 보정): <not_collected"), text)
    end)
end

Tests["collector.combatdetails.no_pet_reads_no_pet_apis"] = function()
    local calls = {}
    run({ UnitExists = function() return false end }, function(section, text)
        check(section.pet.unit.status == "empty", "absent pet unit is empty")
        check(section.pet.armor == nil and section.pet.manaRegen == nil, "no pet fields")
        check(has(text, "<empty: current pet unit absent; not a statement about owned or stabled pets>"), text)
        check(has(text, "플레이어 전투 세부값"), "player block still collected: " .. text)
    end, calls)
    for _, name in ipairs(calls) do
        check(name == "UnitExists", "unexpected pet read without a pet: " .. name)
    end
end

Tests["collector.combatdetails.pet_unit_unknown_is_not_collected"] = function()
    run({ UnitExists = function() end }, function(section)
        check(section.pet.unit.status == "not_collected" and section.pet.armor == nil, "nil UnitExists is unknown")
    end)
end

Tests["collector.combatdetails.warlock_mana_regen_formula"] = function()
    -- Voidwalker (family 16): 0.1. Owner effective intellect is the second UnitStat return (104 in this mock).
    run(warlock(), function(section, text)
        local node = section.pet.manaRegen
        check(node.status == "ok" and node.values[1] == 10, "floor(104 * 0.1)")
        check(node.inputs.coefficient == 0.1 and node.inputs.petFamilyID == 16 and node.inputs.ownerEffectiveIntellect == 104,
            "inputs kept")
        check(has(node.api, "computed (70790 UI formula"), "marked as computed")
        check(has(text, "소환수 마나 재생 (70790 UI 계산값, 직접 관측값 아님): MP5 10"), text)
        check(has(text, "공식: floor(ownerEffectiveIntellect * coefficient)"), text)
        check(has(text, "플레이어 GetManaRegen 값은 쓰지 않음"), text)
    end)
    -- Imp (family 23): 0.3.
    run(warlock({ UnitCreatureFamily = function() return "Imp", 23 end }), function(section)
        local node = section.pet.manaRegen
        check(node.values[1] == 31 and node.inputs.coefficient == 0.3, "floor(104 * 0.3) = 31")
    end)
end

Tests["collector.combatdetails.warlock_pet_without_mana_is_not_applicable"] = function()
    run(warlock({ UnitPowerMax = function() return 0 end }), function(section, text)
        local node = section.pet.manaRegen
        check(node.status == "empty" and node.info == true and node.values == nil, "info note, no value")
        check(has(text, "<empty: not applicable: pet mana max is 0"), text)
        check(not has(text, "MP5 0"), "no fake zero: " .. text)
    end)
end

Tests["collector.combatdetails.non_warlock_mana_regen_not_applicable"] = function()
    run(nil, function(section, text)
        local node = section.pet.manaRegen
        check(node.status == "empty" and node.info == true and node.values == nil, "info note")
        check(has(text, "not applicable: the 70790 UI shows this stat only for WARLOCK"), text)
        local _, problems = Addon:Tally(section.pet)
        for _, problem in ipairs(problems) do
            check(problem.reason == nil or not has(problem.reason, "not applicable"), "info stays out of coverage")
        end
    end)
end

Tests["collector.combatdetails.mana_regen_inputs_unreadable"] = function()
    run(warlock({ UnitStat = function() return FCE_SECRET end }), function(section, text)
        check(section.pet.manaRegen.status == "not_collected", "unreadable intellect, no number")
        check(has(text, "owner effective intellect unread"), text)
    end)
    run(warlock({ LE_UNIT_STAT_INTELLECT = false }), function(section)
        check(section.pet.manaRegen.status == "not_collected", "undefined constant, no fallback index")
    end)
    run(warlock({ UnitCreatureFamily = function() end }), function(section)
        check(section.pet.manaRegen.status == "not_collected", "family unread, no coefficient chosen")
    end)
    run(warlock({ Enum = { Damageclass = enums().Damageclass } }), function(section)
        check(section.pet.manaRegen.status == "unsupported", "missing Enum.PowerType.Mana")
    end)
    run({ UnitClass = function() end }, function(section)
        check(section.pet.manaRegen.status == "not_collected", "class unread: applicability unknown")
    end)
end

Tests["collector.combatdetails.restricted_values_are_tagged"] = function()
    run({
        UnitArmor = function() return FCE_SECRET, 1, 1, 1 end,
        GetPetCritChance = function() return 1, FCE_DENIED end,
        GetShieldBlock = function() return FCE_SECRET end,
    }, function(section, text)
        check(section.pet.armor.status == "restricted", "secret pet armor")
        check(section.pet.crit.status == "restricted", "inaccessible crit")
        check(section.player.shieldBlock.status == "restricted", "secret shield block")
        check(has(text, "방어도 UnitArmor: <restricted"), text)
        check(has(text, "회피 GetPetDodgeChance: 6.20%"), "other facts survive: " .. text)
    end)
end

Tests["collector.combatdetails.missing_apis_are_unsupported"] = function()
    run({ GetPetDodgeChance = false, GetHealthRegen = false, C_PaperDollInfo = false, GetShapeshiftForm = false },
        function(section, text)
            check(section.pet.dodge.status == "unsupported", "pet dodge")
            check(section.player.healthRegen.status == "unsupported", "health regen")
            check(section.context.shapeshiftForm.status == "unsupported", "no declaration, runtime may lack it")
            check(section.weaponSkills[1].state.status == "not_collected", "slot ID unresolved, no weapon read")
            check(has(text, "회피 GetPetDodgeChance: <unsupported"), text)
            check(has(text, "armor") or has(text, "UnitArmor"), "other pet reads survive: " .. text)
        end)
end

Tests["collector.combatdetails.missing_damageclass_enum_has_no_numeric_fallback"] = function()
    local e = enums()
    e.Damageclass = nil
    run({ Enum = e }, function(section, text)
        for _, entry in ipairs(section.player.resistances) do
            check(entry.id == nil and entry.result.status == "unsupported", "no school id guessed: " .. entry.school)
        end
        check(section.pet.resistances[1].result.status == "unsupported", "pet too")
        check(has(text, "Holy: <unsupported: Enum.Damageclass unavailable; no numeric fallback"), text)
    end)
    e = enums()
    e.Damageclass.Frost = nil
    run({ Enum = e }, function(section)
        check(section.player.resistances[4].result.status == "unsupported" and section.player.resistances[1].id == 2,
            "only the missing school is unsupported")
    end)
end

Tests["collector.combatdetails.weapon_skill_links"] = function()
    run(nil, function(section, text)
        local main, off, ranged = section.weaponSkills[1], section.weaponSkills[2], section.weaponSkills[3]
        check(main.kind == "skill" and main.skillLineID == 43 and main.skill.values[1].name == "Swords", "sword -> 43")
        check(main.skill.values[1].description == nil, "skill line description is not stored")
        check(ranged.kind == "skill" and ranged.skillLineID == 45 and ranged.skill.values[1].name == "Bows", "bow -> 45")
        check(off.kind == "empty" and off.skillLineID == nil, "empty off hand has no skill")
        check(has(text, "주무기 (MainHandSlot, slot 16): skillLineID 43 Swords (rank 100, modifier 2, max 300)"), text)
        check(has(text, "원거리 (RangedSlot, slot 18): skillLineID 45 Bows"), text)
        check(has(text, "보조무기 (SecondaryHandSlot, slot 17): 연결된 무기 숙련 없음 - slot empty"), text)
    end)
end

Tests["collector.combatdetails.weapon_skill_empty_main_hand_and_non_weapons"] = function()
    run({ GetInventoryItemID = function(_, slot) if slot == 17 then return 1004 end if slot == 18 then return 1005 end end },
        function(section, text)
            local main, off, ranged = section.weaponSkills[1], section.weaponSkills[2], section.weaponSkills[3]
            check(main.kind == "skill" and main.skillLineID == 162 and has(main.basis, "empty main-hand"),
                "empty main hand follows the UI rule, labelled")
            check(off.kind == "no_skill" and off.skillLineID == nil, "shield: no weapon skill, not unarmed")
            check(ranged.kind == "no_skill" and has(ranged.note, "no entry"), "unmapped subclass stays unmapped")
            check(has(text, "equipped item is not a weapon"), text)
        end)
end

Tests["collector.combatdetails.weapon_skill_druid_form_rule"] = function()
    local druid = {
        UnitClass = function() return "Druid", "DRUID", 11 end,
        GetShapeshiftForm = function() return 1 end,
    }
    run(druid, function(section, text)
        for _, rec in ipairs(section.weaponSkills) do
            check(rec.skillLineID == 3014 and has(rec.basis, "druid shapeshift form 1"), "feral skill for every slot")
        end
        check(has(text, "skillLineID 3014 Feral Combat"), text)
    end)
    druid.GetShapeshiftForm = function() return 0 end
    run(druid, function(section)
        check(section.weaponSkills[1].skillLineID == 43, "form 0 uses the equipped weapon")
    end)
    druid.GetShapeshiftForm = false
    run(druid, function(section)
        check(section.weaponSkills[1].state.status == "not_collected", "druid with unread form is undetermined")
    end)
    -- A hunter never evaluates the form rule, even if the form API is missing.
    run({ GetShapeshiftForm = false }, function(section)
        check(section.weaponSkills[1].skillLineID == 43, "non-druid ignores the form")
    end)
end

Tests["collector.combatdetails.weapon_skill_unreadable_pieces"] = function()
    run({ C_SkillInfo = { GetSkillLineInfoByID = function() end } }, function(section, text)
        check(section.weaponSkills[1].skill.status == "not_collected", "nil skill line is not rank 0")
        check(has(text, "skillLineID 43 (weapon subclass Sword1H"), text)
        check(has(text, "숙련 정보: <not_collected"), text)
    end)
    run({ C_SkillInfo = false }, function(section)
        check(section.weaponSkills[1].skill.status == "unsupported", "skill API missing")
    end)
    run({ UnitClass = function() end }, function(section)
        check(section.weaponSkills[1].state.status == "not_collected", "class unread, rule undetermined")
    end)
    local e = enums()
    e.ItemWeaponSubclass = nil
    run({ Enum = e }, function(section)
        check(section.weaponSkills[1].state.status == "unsupported", "no subclass enum, no numeric fallback")
    end)
    e = enums()
    e.ItemClass = nil
    run({ Enum = e }, function(section)
        check(section.weaponSkills[1].state.status == "unsupported", "no item class enum")
    end)
    run({ C_Item = { GetItemInfoInstant = function() end } }, function(section)
        check(section.weaponSkills[1].state.status == "not_collected", "item info unreadable")
    end)
    run({ GetInventoryItemID = function() return FCE_SECRET end }, function(section)
        check(section.weaponSkills[1].itemID.status == "restricted" and section.weaponSkills[1].state.status ==
            "not_collected", "secret item ID is not an empty slot")
    end)
end

Tests["collector.combatdetails.player_details"] = function()
    run({
        IsDualWielding = function() return true end,
        GetOffhandHitModifier = function() return 4 end,
        GetShieldBlock = function() return 37 end,
        C_PaperDollInfo = {
            GetInventorySlotInfo = function(name) return SLOT_IDS[name], 1, false end,
            OffhandHasShield = function() return true end,
        },
    }, function(section, text)
        local p = section.player
        check(p.offhandHitModifier.values[1] == 4 and p.dualWielding.values[1] == true, "offhand hit")
        check(p.shieldBlock.values[1] == 37 and p.offhandHasShield.values[1] == true, "shield")
        check(has(text, "보조무기 명중 보정 GetOffhandHitModifier: 4.00%"), text)
        check(has(text, "방패 막기 수치 GetShieldBlock"), text)
        check(has(text, "healthRegen=2.50 combatHealthRegen=1.50"), text)
        check(has(text, "정신 기반 생명력 재생 GetHealthRegenFromSpirit: healthRegen=1.50 combatHealthRegen=0.50"), text)
        check(has(text, "powerRegen=3 combatPowerRegen=1"), text)
        check(has(text, "플레이어 전투 세부값 (character 구역에 없는 항목)"), text)
    end)
end

Tests["collector.combatdetails.context_records_state_and_time"] = function()
    run({ InCombatLockdown = function() return true end, GetShapeshiftForm = function() return 2 end },
        function(section, text)
            check(section.capturedAt.status == "ok" and section.capturedAt.values[1] == 123456, "observed-at")
            check(section.context.inCombatLockdown.values[1] == true and section.context.shapeshiftForm.values[1] == 2,
                "context")
            check(has(text, "전투 중 InCombatLockdown: true"), text)
            check(has(text, "변신 형태 GetShapeshiftForm (선언 없음, UI 호출만 근거): 2"), text)
            check(has(text, "수집 시각: "), text)
        end)
end
