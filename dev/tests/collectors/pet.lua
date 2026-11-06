-- Mocked contract tests for the pet collector. Not a WoW runtime.
local Addon = AddonUnderTest

local function check(condition, message)
    if not condition then error(message, 2) end
end

local function has(text, needle)
    return string.find(text, needle, 1, true) ~= nil
end

local PET_BANK = { SpellBookSpellBank = { Pet = 1 } }

-- Pet spellbook rows shaped like the real koKR ground truth (SpellBookItemInfo, SpellBookDocumentation.lua:1012).
local function row(fields)
    local item = { actionID = 1, iconID = 1, isOffSpec = false, isPassive = false, itemType = 3, name = "x",
        subName = "" }
    for key, value in pairs(fields) do item[key] = value end
    return item
end

local function petBook()
    return {
        row({ actionID = 117440514, name = "공격", subName = "소환수 명령" }),
        row({ actionID = 18040320, name = "공격 속도 증가 IV", isPassive = true, spellID = 1263104 }),
        row({ actionID = 100663298, name = "공격적", subName = "소환수 태세" }),
        row({ actionID = 3238005337, name = "포효", spellID = 2649, subName = "1 레벨" }),
    }
end

local function spellApis(book)
    return {
        Enum = PET_BANK,
        C_SpellBook = {
            HasPetSpells = function() if #book > 0 then return #book, "PET" end end,
            GetSpellBookItemInfo = function(slot, bank)
                check(bank == 1, "pet bank expected")
                return book[slot]
            end,
        },
    }
end

local function stablePet(fields)
    local pet = {
        slotID = 1, icon = 1, name = "살쾡이", level = 9, familyName = "살쾡이", specialization = "야성",
        type = "t", petAbilities = { 1, 2 }, specAbilities = {}, displayID = 1, isFavorite = false, isExotic = false,
        petNumber = 77, creatureID = 5, specID = 0, loyaltyLevel = 2, loyaltyName = "충성", happinessLevel = 3,
        experience = 10, experienceNeeded = 100,
    }
    for key, value in pairs(fields or {}) do pet[key] = value end
    return pet
end

-- A full set of "pet is out" mocks. Pass overrides (false removes an API).
local function mocks(overrides)
    local api = {
        UnitExists = function() return true end,
        UnitName = function() return "살쾡이", nil end,
        UnitLevel = function() return 9 end,
        UnitCreatureFamily = function() return "살쾡이", 4 end,
        UnitCreatureType = function() return "야수", 1 end,
        UnitHealth = function() return 250 end,
        UnitHealthMax = function() return 300 end,
        UnitPowerType = function() return 2, "FOCUS", 1, 1, 0 end,
        UnitPower = function() return 80 end,
        UnitPowerMax = function() return 100 end,
        UnitIsDeadOrGhost = function() return false end,
        GetPetExperience = function() return 40, 120 end,
        UnitClassBase = function() return "HUNTER", 3 end,
        C_PetInfo = {
            GetPetLoyalty = function() return "충성" end,
            GetPetHappiness = function() return 3, 100, 1 end,
            GetPetTrainingPoints = function() return 5, 2 end,
            GetPetFoodTypes = function() return { "고기", "생선" } end,
        },
        C_StableInfo = {
            IsAtStableMaster = function() return false end,
            GetNumStableSlots = function() return 2 end,
            GetNumStablePets = function() return 1 end,
            GetStablePetInfo = function(index)
                if index == 1 then return stablePet() end
                if index == 2 then return stablePet({ name = "곰", level = 12, familyName = "곰", petNumber = 78 }) end
            end,
        },
    }
    for key, value in pairs(spellApis(petBook())) do api[key] = value end
    for key, value in pairs(overrides or {}) do api[key] = value end
    return api
end

local function run(overrides, fn)
    WithGlobals(mocks(overrides), function()
        local section = Addon.collectors.pet(Addon)
        local out = Addon:NewWriter()
        Addon.formatters.pet(Addon, section, out)
        fn(section, out:Output())
    end)
end

Tests["collector.pet.normal"] = function()
    run(nil, function(section, text)
        check(section.status == nil, "no top-level status on a data section")
        check(section.exists.status == "ok" and section.name.values.n == 2 and section.name.values[2] == nil,
            "UnitName keeps the trailing nil")
        check(section.deadOrGhost.values[1] == false, "false is data")
        check(#section.spells == 4 and section.spellTraversal == nil, "all four pet spells read")
        check(has(text, "name: 살쾡이"), text)
        check(has(text, "level: 9"), text)
        check(has(text, "family: 살쾡이 (id 4)") and has(text, "creature type: 야수 (id 1)"), text)
        check(has(text, "health: 250 / 300"), text)
        check(has(text, "power type: FOCUS (id 2)") and has(text, "power: 80 / 100"), text)
        check(has(text, "dead or ghost: false"), text)
        check(has(text, "experience (GetPetExperience): 40 / 120"), text)
        check(has(text, "loyalty (GetPetLoyalty): 충성"), text)
        check(has(text, "total=5 used=2"), text)
        check(has(text, "happiness=3 damagePercentage=100 loyaltyRate=1"), text)
        check(has(text, "food types (GetPetFoodTypes): 고기, 생선"), text)
        check(has(text, "entries: 4 (command 1, stance 1, ability 1, passive 1)"), text)
        check(has(text, 'slot 1: [command] 공격 (actionID 117440514) subName="소환수 명령" itemType=3'), text)
        check(has(text, "slot 2: [passive] 공격 속도 증가 IV (spellID 1263104, actionID 18040320) subName=\"\""), text)
        check(has(text, "slot 3: [stance] 공격적"), text)
        check(has(text, 'slot 4: [ability] 포효 (spellID 2649, actionID 3238005337) subName="1 레벨"'), text)
        check(has(text, "slot 1 (current pet slot): 살쾡이 (level 9 살쾡이)"), text)
        check(has(text, "slot 2: 곰 (level 12 곰)") and has(text, "experience=10/100"), text)
        check(has(text, "stable slots (GetNumStableSlots): 2"), text)
    end)
end

Tests["collector.pet.no_pet_unit_is_not_a_statement_about_owned_pets"] = function()
    local book = {}
    local api = spellApis(book)
    api.UnitExists = function() return false end
    run(api, function(section, text)
        check(section.unitDetails.status == "empty", "no pet unit is empty")
        check(has(section.unitDetails.reason, "not a statement about owned pets"), section.unitDetails.reason)
        check(section.name == nil and section.experience == nil, "no unit details are read without a unit")
        check(section.spellTraversal.status == "empty" and #section.spells == 0, "HasPetSpells nothing is empty")
        check(has(text, "<empty: current pet unit absent; not a statement about owned pets>"), text)
        check(has(text, "player class (UnitClassBase): HUNTER (classID 3)"), text)
        check(has(text, "<empty: HasPetSpells reports no current pet spells>"), text)
        -- stable data is still read: slot 3 is nil while away from a stable master.
        check(has(text, "slot 3: <not_collected: no PetInfo returned: empty slot or stable data not loaded"), text)
    end)
end

Tests["collector.pet.unit_state_unreadable_stays_not_collected"] = function()
    run({ UnitExists = function() end }, function(section, text)
        check(section.unitDetails.status == "not_collected", "nil UnitExists is not 'no pet'")
        check(has(text, "current pet unit state unavailable"), text)
    end)
end

Tests["collector.pet.stable_empty_slot_at_master"] = function()
    local empty = mocks().C_StableInfo
    empty.IsAtStableMaster = function() return true end
    empty.GetNumStableSlots = function() return 2 end
    empty.GetStablePetInfo = function(index) if index == 1 then return stablePet() end end
    run({ C_StableInfo = empty }, function(section, text)
        check(section.stable.pets[2].info.status == "empty" and section.stable.pets[3].info.status == "empty",
            "nil PetInfo at the stable master is an empty slot")
        check(has(text, "slot 2: <empty: no pet in this slot"), text)
    end)
end

Tests["collector.pet.missing_apis_are_unsupported"] = function()
    run({ GetPetExperience = false, C_PetInfo = false, C_StableInfo = false, UnitCreatureFamily = false },
        function(section, text)
            check(section.experience.status == "unsupported" and section.loyalty.status == "unsupported", "unsupported")
            check(section.stable.pets[1].info.status == "unsupported", "stable slot 1 unsupported")
            check(section.stable.traversal.status == "not_collected", "slot count unavailable is stated")
            check(has(text, "experience (GetPetExperience): <unsupported: function unavailable at runtime [GetPetExperience]>"),
                text)
            check(has(text, "happiness (GetPetHappiness raw): <unsupported"), text)
            check(has(text, "food types (GetPetFoodTypes): <unsupported"), text)
            check(has(text, "family: <unsupported"), text)
            check(has(text, "level: 9"), "other unit facts survive: " .. text)
            check(has(text, "entries: 4"), "spellbook survives: " .. text)
        end)
end

Tests["collector.pet.missing_pet_bank_enum"] = function()
    run({ Enum = {} }, function(section)
        check(section.spellTraversal.status == "unsupported" and #section.spells == 0, "no bank enum, no traversal")
    end)
end

Tests["collector.pet.restricted_values_are_tagged_not_printed"] = function()
    local book = petBook()
    local api = spellApis(book)
    api.UnitHealth = function() return FCE_SECRET end
    api.UnitName = function() return FCE_DENIED end
    api.C_SpellBook.GetSpellBookItemInfo = function(slot)
        if slot == 2 then return { name = FCE_SECRET } end
        return book[slot]
    end
    run(api, function(section, text)
        check(section.health.status == "restricted" and section.name.status == "restricted", "restricted")
        check(section.spells[2].info.status == "restricted", "restricted spell row")
        check(has(text, "health: current=<restricted"), text)
        check(has(text, "name: <restricted"), text)
        check(has(text, "slot 2: <restricted"), text)
        check(has(text, "entries: 4 (command 1, stance 1, ability 1, unreadable 1)"), text)
        check(has(text, "level: 9"), "other facts survive: " .. text)
    end)
end

Tests["collector.pet.nil_returns_stay_not_collected"] = function()
    run({
        UnitLevel = function() end,
        C_PetInfo = {
            GetPetLoyalty = function() end,
            GetPetHappiness = function() end,
            GetPetTrainingPoints = function() end,
            GetPetFoodTypes = function() end,
        },
        GetPetExperience = function() end,
    }, function(section, text)
        check(section.level.status == "not_collected", "nil level")
        check(section.happiness.status == "not_collected" and section.loyalty.status == "not_collected", "nil pet info")
        check(has(text, "level: <not_collected"), text)
        check(has(text, "happiness (GetPetHappiness raw): <not_collected"), text)
        check(has(text, "training points (total, used): <not_collected"), text)
    end)
end

Tests["collector.pet.empty_diet_and_empty_loyalty_are_explicit"] = function()
    run({
        C_PetInfo = {
            GetPetLoyalty = function() return "" end,
            GetPetHappiness = function() return 2, 0, 0 end,
            GetPetTrainingPoints = function() return 0, 0 end,
            GetPetFoodTypes = function() return {} end,
        },
        GetPetExperience = function() return 0, 0 end,
    }, function(_, text)
        check(has(text, "food types (GetPetFoodTypes): <empty: API returned an empty diet list>"), text)
        check(has(text, 'loyalty (GetPetLoyalty): "" (empty string)'), text)
        check(has(text, "experience (GetPetExperience): 0 / 0 (expNeeded 0)"), text)
        check(has(text, "happiness=2 damagePercentage=0 loyaltyRate=0"), text)
    end)
end

Tests["collector.pet.one_failing_spell_slot_does_not_erase_the_rest"] = function()
    local book = petBook()
    local api = spellApis(book)
    api.C_SpellBook.GetSpellBookItemInfo = function(slot)
        if slot == 3 then error("slot unavailable") end
        if slot == 4 then return nil end
        return book[slot]
    end
    run(api, function(section, text)
        check(section.spells[3].info.status == "error" and section.spells[4].info.status == "not_collected", "states")
        check(has(text, "slot 1: [command] 공격") and has(text, "slot 2: [passive]"), text)
        check(has(text, "slot 3: <error: ") and has(text, "slot unavailable"), text)
        check(has(text, "slot 4: <not_collected"), text)
        check(has(text, "entries: 4 (command 1, passive 1, unreadable 2)"), text)
    end)
end

Tests["collector.pet.spell_count_guards"] = function()
    local api = spellApis({})
    api.C_SpellBook.HasPetSpells = function() return -1, "PET" end
    run(api, function(section)
        check(section.spellTraversal.status == "error" and #section.spells == 0, "negative count is an error")
    end)
    local seen = 0
    api.C_SpellBook.HasPetSpells = function() return 100000, "PET" end
    api.C_SpellBook.GetSpellBookItemInfo = function() seen = seen + 1; return row({ name = "x", spellID = 1 }) end
    run(api, function(section)
        check(#section.spells == 500 and seen == 500, "hard cap applies")
        check(section.spellTraversal.status == "not_collected", "truncation is stated")
    end)
end

Tests["collector.pet.stable_slot_count_is_bounded"] = function()
    local stable = mocks().C_StableInfo
    stable.GetNumStableSlots = function() return 100000 end
    local calls = 0
    stable.GetStablePetInfo = function() calls = calls + 1 end
    run({ C_StableInfo = stable }, function(section)
        check(calls == 20 and #section.stable.pets == 20, "stable traversal is capped")
        check(section.stable.traversal.status == "not_collected", "truncation is stated")
    end)
    stable.GetNumStableSlots = function() return -3 end
    run({ C_StableInfo = stable }, function(section)
        check(section.stable.traversal.status == "error" and #section.stable.pets == 1, "invalid count reads slot 1 only")
    end)
end
