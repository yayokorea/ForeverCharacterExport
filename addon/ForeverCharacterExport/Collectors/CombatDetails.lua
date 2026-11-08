local _, Addon = ...
-- luacheck: read globals Enum

-- CombatDetails section: pet combat stats, plus player combat details that the character section does not read.
-- Read-only. No spec/form/equipment/filter change, no window opened, no server data requested.
--
-- Evidence (paths under references/upstream/Interface/AddOns/; "Stats" = Blizzard_UIPanels_Game/Camelot/
-- PaperDollFrameStats.lua, "PDF" = .../Camelot/PaperDollFrame.lua, "Consts" = .../Camelot/PaperDollFrameConstants.lua,
-- "Doc" = Blizzard_APIDocumentationGenerated/):
--   Pet pane stat list (health, power, mana regen, move speed; armor, damage, attack power, spell power, hit, crit,
--     haste, expertise, dodge): Consts:94-117. The player pane list Consts:35-92.
--   Pet armor      UnitArmor(unit) -> base, effective, real, bonus: Doc UnitDocumentation.lua:645; Stats:487.
--   Pet damage     UnitDamage(unit) -> min, max, offMin, offMax, posBuff, negBuff, percent:
--                  Doc UnitDocumentation.lua:1047; PDF:978 (pet main-hand row) and PDF:882.
--   Pet speed      UnitAttackSpeed(unit) -> main, off?, ranged?: Doc UnitDocumentation.lua:682; PDF:882, PDF:1053.
--   Pet atk power  UnitAttackPower(unit) -> attackPower, posBuff, negBuff: Doc UnitDocumentation.lua:664; Stats:382.
--   Pet spell pwr  GetPetSpellBonusDamage(): Doc PlayerScriptDocumentation.lua:808; PDF:1097.
--   Pet hit        GetPetHitChanceModifier / GetPetSpellHitChanceModifier:
--                  Doc PlayerScriptDocumentation.lua:788 / :818; Stats:532 / :534.
--                  Owner inputs of the UI total: GetCombatRatingBonus(CR_HIT_MELEE|CR_HIT_SPELL)
--                  Doc PlayerScriptDocumentation.lua:319, GetHitModifier :533, GetSpellHitModifier :1113;
--                  Stats:530-535.
--   Pet crit       GetPetCritChance() -> meleeCrit, spellCrit: Doc PlayerScriptDocumentation.lua:767; Stats:599.
--   Pet haste      GetPetMeleeHaste(): Doc PlayerScriptDocumentation.lua:798; Stats:196.
--                  UnitSpellHaste(unit): Doc UnitDocumentation.lua:3132; Stats:189 (called with the pet unit).
--   Pet dodge      GetPetDodgeChance(): Doc PlayerScriptDocumentation.lua:778; PDF:789.
--   Pet defense / resistance: UnitDefenseSkill(unit) Doc UnitDocumentation.lua:1069 and
--                  UnitResistance(unit, damageClass) Doc UnitDocumentation.lua:3014 accept any UnitToken,
--                  and the UI helpers take a unit argument
--                  (PDF:718, PDF:753), but the 70790 pet pane never calls them with "pet". UNVERIFIED for pets.
--   Pet mana regen PaperDollFrame_SetWarlockPetManaRegen, Stats:146-165 (constants Stats:3-5): a UI-computed value
--                  floor(owner effective intellect * pct), never an API read. Inputs: UnitClass Doc :911,
--                  UnitPowerMax("pet", Enum.PowerType.Mana) Doc :2801 (Enum.PowerType: Doc
--                  PowerTypeConstantsDocumentation.lua:18), UnitCreatureFamily Doc :996, UnitStat Doc :3198
--                  with LE_UNIT_STAT_INTELLECT (Stats:155).
--   Pet identity   UnitExists Doc :1192, UnitName Doc :2489.
--   Player offhand hit GetOffhandHitModifier(): Doc PlayerScriptDocumentation.lua:660; Stats:525. IsDualWielding :1297.
--   Player block   GetShieldBlock(): Doc PlayerScriptDocumentation.lua:1040; Stats:444 and PDF:819 (the two UI files
--                  describe the number differently). C_PaperDollInfo.OffhandHasShield: Doc PaperDollInfoDocumentation
--                  .lua:267; Consts:87.
--   Player resist  UnitResistance(unit, damageClass) -> base, real, effective, bonus: Doc UnitDocumentation.lua:3014;
--                  PDF:718. School order Holy, Fire, Nature, Frost, Shadow, Arcane: PDF:255-272.
--                  Enum.Damageclass has no value declaration in the mirror, so values are only read from the
--                  runtime enum, never hardcoded.
--   Player regen   GetHealthRegen / GetHealthRegenFromSpirit -> regen, combatRegen: Doc PlayerScriptDocumentation.lua
--                  :513 / :523; GetManaRegenFromSpirit :582; UI use Stats:298-301.
--   Weapon skill   Stats:22-40 (subclass -> skillLineID, feral skill), Stats:681-715 (equipped-weapon rule).
--                  GetShapeshiftForm has no declaration; its only evidence is the UI call Stats:683.
--                  GetInventoryItemID Stats:687; C_Item.GetItemInfoInstant -> itemID, type, subType, equipLoc, icon,
--                  classID, subClassID: Doc ItemDocumentation.lua:659; Stats:692. Enum.ItemClass Doc
--                  ItemConstantsDocumentation.lua:269, Enum.ItemWeaponSubclass :618.
--                  C_SkillInfo.GetSkillLineInfoByID: Doc SkillInfoDocumentation.lua:74 (SkillLineAttributes :113-133);
--                  Stats:710. Slot IDs come from C_PaperDollInfo.GetInventorySlotInfo (Doc PaperDollInfoDocumentation
--                  .lua:164), because INVSLOT_* is not defined in the mirror.
--   Context        InCombatLockdown Doc RestrictedActionsDocumentation.lua:45, GetServerTime
--                  Doc SystemTimeDocumentation.lua:30.

local floor = math.floor

local PLAYER, PET = "player", "pet"

-- Stats:3-5. File-local constants of the 70790 UI, copied with that citation.
local IMP_CREATURE_FAMILY_ID = 23
local WARLOCK_PET_MANA_REGEN_PCT = 0.1
local IMP_MANA_REGEN_PCT = 0.3

-- PDF:255-272 order.
local SCHOOLS = { "Holy", "Fire", "Nature", "Frost", "Shadow", "Arcane" }

-- Stats:22-38: Enum.ItemWeaponSubclass name -> skillLineID. Keys are resolved from the runtime enum.
local WEAPON_SKILLS = {
    { "Sword1H", 43 }, { "Axe1H", 44 }, { "Bows", 45 }, { "Guns", 46 }, { "Mace1H", 54 }, { "Sword2H", 55 },
    { "Staff", 136 }, { "Mace2H", 160 }, { "Axe2H", 172 }, { "Dagger", 173 }, { "Thrown", 176 },
    { "Crossbow", 226 }, { "Wand", 228 }, { "Polearm", 229 }, { "Unarmed", 162 },
}
local UNARMED_SKILL = 162 -- Stats:688, empty slot rule
local FERAL_SKILL = 3014 -- Stats:40

local WEAPON_SLOTS = {
    { name = "MainHandSlot", label = "주무기", isMainHand = true },
    { name = "SecondaryHandSlot", label = "보조무기" },
    { name = "RangedSlot", label = "원거리" },
}

local function unavailable(self, status, reason, api)
    local result = self:State(status, reason)
    result.api = api
    return result
end

-- A Probe that returned no values at all (nil), as opposed to unsupported/restricted/error.
local function returnedNothing(result)
    return type(result) == "table" and result.status == "not_collected" and type(result.values) == "table"
        and result.values[1] == nil
end

local function isNumber(value)
    return type(value) == "number"
end

-- ---------------------------------------------------------------------------------------------------------------
-- Collection

local function readResistances(self, unit)
    local list = {}
    for _, name in ipairs(SCHOOLS) do
        local entry = { school = name }
        local enum = Enum and Enum.Damageclass
        if type(enum) ~= "table" then
            entry.result = unavailable(self, "unsupported", "Enum.Damageclass unavailable; no numeric fallback",
                "Enum.Damageclass." .. name)
        elseif type(enum[name]) ~= "number" then
            entry.result = unavailable(self, "unsupported", "Enum.Damageclass." .. name .. " unavailable at runtime",
                "Enum.Damageclass." .. name)
        else
            entry.id = enum[name]
            entry.result = self:Probe("UnitResistance", unit, enum[name])
        end
        list[#list + 1] = entry
    end
    return list
end

-- UI total shown on the pet pane: owner hit (rating bonus + modifier) plus the pet's own modifier (Stats:530-535).
-- A computed value; every input is kept so it can be audited.
local function computePetHit(self, pet)
    local api = "computed (70790 UI formula, PaperDollFrameStats.lua:530-535)"
    local inputs = {
        ownerMeleeRating = isNumber(_G.CR_HIT_MELEE) and self:Probe("GetCombatRatingBonus", _G.CR_HIT_MELEE)
            or unavailable(self, "not_collected", "constant CR_HIT_MELEE is not defined", "GetCombatRatingBonus"),
        ownerMeleeModifier = self:Probe("GetHitModifier"),
        ownerSpellRating = isNumber(_G.CR_HIT_SPELL) and self:Probe("GetCombatRatingBonus", _G.CR_HIT_SPELL)
            or unavailable(self, "not_collected", "constant CR_HIT_SPELL is not defined", "GetCombatRatingBonus"),
        ownerSpellModifier = self:Probe("GetSpellHitModifier"),
    }
    pet.hitInputs = inputs
    local values = {
        self:Val(inputs.ownerMeleeRating, 1), self:Val(inputs.ownerMeleeModifier, 1),
        self:Val(inputs.ownerSpellRating, 1), self:Val(inputs.ownerSpellModifier, 1),
        self:Val(pet.hitModifier, 1), self:Val(pet.spellHitModifier, 1),
    }
    for index = 1, 6 do
        if not isNumber(values[index]) then
            return unavailable(self, "not_collected",
                "an input was not read as a number (see inputs); total not computed", api)
        end
    end
    local melee = values[1] + values[2] + values[5]
    local spell = values[3] + values[4] + values[6]
    return { status = "ok", api = api, values = { n = 3, melee, spell, math.max(melee, spell) } }
end

-- Stats:146-165. Returns a result-like node. Never uses the UI's "return 0" for the not-applicable case.
local function computePetManaRegen(self, ctx, pet)
    local api = "computed (70790 UI formula, PaperDollFrameStats.lua:146-165)"
    local class = ctx.classToken
    if type(class) ~= "string" then
        return unavailable(self, "not_collected", "player class token unread; formula applicability unknown", api)
    end
    if class ~= "WARLOCK" then
        local note = unavailable(self, "empty", "not applicable: the 70790 UI shows this stat only for WARLOCK "
            .. "(Stats:148); player class is " .. class, api)
        note.info = true
        return note
    end
    local mana = Enum and Enum.PowerType and Enum.PowerType.Mana
    if type(mana) ~= "number" then
        return unavailable(self, "unsupported", "Enum.PowerType.Mana unavailable", "Enum.PowerType.Mana")
    end
    local powerMax = self:Probe("UnitPowerMax", PET, mana)
    pet.manaMax = powerMax
    local maxValue = self:Val(powerMax, 1)
    if not isNumber(maxValue) then
        return unavailable(self, "not_collected", "pet mana max not read as a number", api)
    end
    if maxValue <= 0 then
        local note = unavailable(self, "empty", "not applicable: pet mana max is " .. maxValue
            .. "; the 70790 UI hides this stat (Stats:148)", api)
        note.info = true
        return note
    end
    local familyID = self:Val(pet.family, 2)
    if not isNumber(familyID) then
        return unavailable(self, "not_collected", "pet creature family id unread; cannot choose the coefficient", api)
    end
    local stat = ctx.intellect
    local ownerIntellect = self:Val(stat, 2)
    if not isNumber(ownerIntellect) then
        return unavailable(self, "not_collected", "owner effective intellect unread (UnitStat/LE_UNIT_STAT_INTELLECT)",
            api)
    end
    local pct = (familyID == IMP_CREATURE_FAMILY_ID) and IMP_MANA_REGEN_PCT or WARLOCK_PET_MANA_REGEN_PCT
    local mp5 = floor(ownerIntellect * pct)
    return { status = "ok", api = api, values = { n = 1, mp5 },
        inputs = { playerClass = class, petManaMax = maxValue, petFamilyID = familyID, coefficient = pct,
            impFamilyID = IMP_CREATURE_FAMILY_ID, ownerEffectiveIntellect = ownerIntellect,
            formula = "floor(ownerEffectiveIntellect * coefficient)" } }
end

local function collectPet(self, ctx)
    local pet = {}
    local exists = self:Read(pet, "exists", "UnitExists", PET)
    if exists ~= true then
        pet.unit = self:State(exists == false and "empty" or "not_collected",
            exists == false and "current pet unit absent; not a statement about owned or stabled pets"
                or "current pet unit state unavailable; pet stats not read")
        return pet
    end
    self:Read(pet, "name", "UnitName", PET)
    pet.family = self:Probe("UnitCreatureFamily", PET)
    pet.armor = self:Probe("UnitArmor", PET)
    pet.damage = self:Probe("UnitDamage", PET)
    pet.attackSpeed = self:Probe("UnitAttackSpeed", PET)
    pet.attackPower = self:Probe("UnitAttackPower", PET)
    pet.spellPower = self:Probe("GetPetSpellBonusDamage")
    pet.hitModifier = self:Probe("GetPetHitChanceModifier")
    pet.spellHitModifier = self:Probe("GetPetSpellHitChanceModifier")
    pet.hitTotal = computePetHit(self, pet)
    pet.crit = self:Probe("GetPetCritChance")
    pet.meleeHaste = self:Probe("GetPetMeleeHaste")
    pet.spellHaste = self:Probe("UnitSpellHaste", PET)
    pet.dodge = self:Probe("GetPetDodgeChance")
    pet.defense = self:Probe("UnitDefenseSkill", PET)
    pet.resistances = readResistances(self, PET)
    pet.manaRegen = computePetManaRegen(self, ctx, pet)
    return pet
end

local function collectPlayer(self)
    local player = {}
    player.dualWielding = self:Probe("IsDualWielding")
    player.offhandHitModifier = self:Probe("GetOffhandHitModifier")
    player.shieldBlock = self:Probe("GetShieldBlock")
    player.offhandHasShield = self:Probe("C_PaperDollInfo.OffhandHasShield")
    player.resistances = readResistances(self, PLAYER)
    player.healthRegen = self:Probe("GetHealthRegen")
    player.healthRegenFromSpirit = self:Probe("GetHealthRegenFromSpirit")
    player.manaRegenFromSpirit = self:Probe("GetManaRegenFromSpirit")
    return player
end

-- Subclass id -> { skillLineID, enumName }, built from the runtime enum only.
local function subclassMap()
    local enum = Enum and Enum.ItemWeaponSubclass
    if type(enum) ~= "table" then return nil end
    local map = {}
    for _, row in ipairs(WEAPON_SKILLS) do
        local id = enum[row[1]]
        if type(id) == "number" then map[id] = { skillLineID = row[2], name = row[1] } end
    end
    return map
end

local function skillSummary(self, skillLineID)
    local result = self:Probe("C_SkillInfo.GetSkillLineInfoByID", skillLineID)
    if result.status ~= "ok" then return result end
    local info = result.values[1]
    if type(info) ~= "table" then
        return unavailable(self, "error", "unexpected skill line shape " .. type(info), result.api)
    end
    return { status = "ok", api = result.api, values = { n = 1, { skillID = info.skillID, name = info.name,
        rank = info.rank, modifier = info.modifier, maxRank = info.maxRank } } }
end

-- Stats:681-700 rule for one slot. Returns a plain record; the link outcome is in kind/state, never a guessed skill.
local function weaponSlot(self, ctx, slot)
    local rec = { slotName = slot.name, label = slot.label }
    rec.slotInfo = self:Probe("C_PaperDollInfo.GetInventorySlotInfo", slot.name)
    local slotID = self:Val(rec.slotInfo, 1)
    if not isNumber(slotID) then
        rec.state = self:State("not_collected", "slot ID unresolved; no weapon read")
        return rec
    end
    rec.slotID = slotID

    -- Stats:683: any druid shapeshift form overrides the equipped weapon (checked before the item).
    if type(ctx.classToken) ~= "string" then
        rec.state = self:State("not_collected", "player class unread; the druid-form rule cannot be evaluated")
        return rec
    end
    if ctx.classToken == "DRUID" then
        if not isNumber(ctx.form) then
            rec.state = self:State("not_collected", "druid, but GetShapeshiftForm was not read as a number")
            return rec
        end
        if ctx.form ~= 0 then
            rec.kind, rec.skillLineID = "skill", FERAL_SKILL
            rec.basis = "druid shapeshift form " .. ctx.form .. " (Stats:683-684)"
            rec.skill = skillSummary(self, FERAL_SKILL)
            return rec
        end
    end

    rec.itemID = self:Probe("GetInventoryItemID", PLAYER, slotID)
    local itemID = self:Val(rec.itemID, 1)
    if returnedNothing(rec.itemID) then
        if slot.isMainHand then
            rec.kind, rec.skillLineID = "skill", UNARMED_SKILL
            rec.basis = "empty main-hand: UI fallback rule (Stats:687-689)"
            rec.skill = skillSummary(self, UNARMED_SKILL)
        else
            rec.kind = "empty"
            rec.note = "slot empty; the UI rule would return skill " .. UNARMED_SKILL
                .. " for any empty slot (Stats:687-689), which is not recorded as this slot's skill"
        end
        return rec
    end
    if not isNumber(itemID) then
        rec.state = self:State("not_collected", "equipped item ID not read as a number")
        return rec
    end

    rec.itemInfo = self:Probe("C_Item.GetItemInfoInstant", itemID)
    local classID, subClassID = self:Val(rec.itemInfo, 6), self:Val(rec.itemInfo, 7)
    if not isNumber(classID) or not isNumber(subClassID) then
        rec.state = self:State("not_collected", "item classID/subClassID not read")
        return rec
    end
    rec.classID, rec.subClassID = classID, subClassID
    local weaponClass = Enum and Enum.ItemClass and Enum.ItemClass.Weapon
    if not isNumber(weaponClass) then
        rec.state = unavailable(self, "unsupported", "Enum.ItemClass.Weapon unavailable", "Enum.ItemClass.Weapon")
        return rec
    end
    if classID ~= weaponClass then
        rec.kind = "no_skill"
        rec.note = "equipped item is not a weapon (classID " .. classID
            .. "); the UI links no weapon skill (Stats:693-695)"
        return rec
    end
    local map = subclassMap()
    if not map then
        rec.state = unavailable(self, "unsupported", "Enum.ItemWeaponSubclass unavailable; no numeric fallback",
            "Enum.ItemWeaponSubclass")
        return rec
    end
    local row = map[subClassID]
    if not row then
        rec.kind = "no_skill"
        rec.note = "weapon subclass " .. subClassID .. " has no entry in the UI's subclass table (Stats:22-38)"
        return rec
    end
    rec.kind, rec.skillLineID = "skill", row.skillLineID
    rec.basis = "weapon subclass " .. row.name .. " (Stats:22-38, 697)"
    rec.skill = skillSummary(self, row.skillLineID)
    return rec
end

local function collect(self)
    local section = {
        scope = "player and current pet unit snapshot; pet values are read with the pet unit or pet-specific APIs, "
            .. "never copied from player values; weapon skill link follows the 70790 UI rule",
        capturedAt = self:Timestamp(),
    }
    local ctx = {}
    section.context = {}
    local c = section.context
    self:Read(c, "inCombatLockdown", "InCombatLockdown")
    ctx.form = self:Read(c, "shapeshiftForm", "GetShapeshiftForm")
    c.playerClass = self:Probe("UnitClass", PLAYER)
    ctx.classToken = self:Val(c.playerClass, 2)
    local stat = _G.LE_UNIT_STAT_INTELLECT
    ctx.intellect = isNumber(stat) and self:Probe("UnitStat", PLAYER, stat)
        or unavailable(self, "not_collected", "constant LE_UNIT_STAT_INTELLECT is not defined", "UnitStat")

    section.pet = collectPet(self, ctx)
    section.player = collectPlayer(self)
    section.weaponSkills = {}
    for _, slot in ipairs(WEAPON_SLOTS) do
        section.weaponSkills[#section.weaponSkills + 1] = weaponSlot(self, ctx, slot)
    end
    section.completeness = "fixed field list; no truncation"
    return section
end

-- ---------------------------------------------------------------------------------------------------------------
-- Formatting (labels in Korean, API names and status tags kept as is)

local function num(value)
    if type(value) ~= "number" then return Addon:Fmt(value) end
    if value == floor(value) then return string.format("%d", value) end
    return string.format("%.2f", value)
end

local function pct(value)
    if type(value) ~= "number" then return Addon:Fmt(value) end
    return string.format("%.2f%%", value)
end

local function resistLines(out, label, list)
    out:Add(label)
    for _, entry in ipairs(list) do
        out:Result("  " .. entry.school .. (entry.id and (" (damageClass " .. entry.id .. ")") or ""), entry.result,
            function(_, values)
                return string.format("base=%s real=%s effective=%s bonus=%s", num(values[1]), num(values[2]),
                    num(values[3]), num(values[4]))
            end)
    end
end

local function formatPetManaRegen(self, out, node)
    local tag = self:Describe(node)
    if tag then
        out:Add("소환수 마나 재생 (70790 UI 계산값): " .. tag)
        return
    end
    local i = node.inputs
    out:Add("소환수 마나 재생 (70790 UI 계산값, 직접 관측값 아님): MP5 " .. num(node.values[1]))
    out:Add(string.format("  입력: 직업=%s 소환수 마나 최대=%s 소환수 계열 ID=%s (임프 ID %s) 계수=%s "
        .. "주인 지능(유효)=%s", i.playerClass, num(i.petManaMax), num(i.petFamilyID), num(i.impFamilyID),
        num(i.coefficient), num(i.ownerEffectiveIntellect)))
    out:Add("  공식: " .. i.formula .. " (PaperDollFrameStats.lua:146-165); 플레이어 GetManaRegen 값은 쓰지 않음")
end

local function formatPet(self, section, out)
    local pet = section.pet
    out:Add("### 소환수 전투 능력치 (unit \"pet\"; 플레이어 값 복사 아님)")
    out:Result("UnitExists('pet')", pet.exists)
    if pet.unit then
        out:State("소환수 유닛", pet.unit)
        return
    end
    out:Result("이름", pet.name)
    out:Result("계열 (UnitCreatureFamily)", pet.family, function(value, values)
        return self:Fmt(value) .. " (id " .. self:Fmt(values[2]) .. ")"
    end)
    out:Result("방어도 UnitArmor", pet.armor, function(_, values)
        return string.format("effective=%s base=%s real=%s bonus=%s", num(values[2]), num(values[1]), num(values[3]),
            num(values[4]))
    end)
    out:Result("피해 UnitDamage", pet.damage, function(_, values)
        return string.format("%s-%s, 물리 보너스 +%s/%s, 배수 %s", num(values[1]), num(values[2]), num(values[5]),
            num(values[6]), num(values[7]))
    end)
    out:Result("공격 속도 UnitAttackSpeed", pet.attackSpeed, function(value, values)
        local text = "mainhand=" .. num(value)
        if values[2] ~= nil then text = text .. " offhand=" .. num(values[2]) end
        if values[3] ~= nil then text = text .. " ranged=" .. num(values[3]) end
        return text
    end)
    out:Result("공격력 UnitAttackPower", pet.attackPower, function(value, values)
        return string.format("base=%s posBuff=%s negBuff=%s", num(value), num(values[2]), num(values[3]))
    end)
    out:Result("주문력 GetPetSpellBonusDamage", pet.spellPower, num)
    out:Result("명중 보정 GetPetHitChanceModifier (소환수 자체값)", pet.hitModifier, pct)
    out:Result("주문 명중 보정 GetPetSpellHitChanceModifier (소환수 자체값)", pet.spellHitModifier, pct)
    out:Result("UI 표시 명중 합계 (계산값: 주인 명중 + 소환수 보정)", pet.hitTotal, function(value, values)
        return string.format("근접/원거리=%s 주문=%s UI 표시(최대)=%s", pct(value), pct(values[2]), pct(values[3]))
    end)
    if pet.hitInputs then
        local h = pet.hitInputs
        out:Add("  명중 합계 입력(주인 값): 근접 등급 보너스=" .. (self:Describe(h.ownerMeleeRating)
            or pct(self:Val(h.ownerMeleeRating, 1))) .. " 근접 보정=" .. (self:Describe(h.ownerMeleeModifier)
            or pct(self:Val(h.ownerMeleeModifier, 1))) .. " 주문 등급 보너스=" .. (self:Describe(h.ownerSpellRating)
            or pct(self:Val(h.ownerSpellRating, 1))) .. " 주문 보정=" .. (self:Describe(h.ownerSpellModifier)
            or pct(self:Val(h.ownerSpellModifier, 1))))
    end
    out:Result("치명타 GetPetCritChance", pet.crit, function(value, values)
        return string.format("근접=%s 주문=%s", pct(value), pct(values[2]))
    end)
    out:Result("가속(근접) GetPetMeleeHaste", pet.meleeHaste, pct)
    out:Result("가속(주문) UnitSpellHaste('pet')", pet.spellHaste, pct)
    out:Result("회피 GetPetDodgeChance", pet.dodge, pct)
    out:Result("방어 숙련 UnitDefenseSkill('pet') [UI가 pet으로 호출하지 않음: 게임 내 확인 필요]", pet.defense,
        function(value, values)
            return string.format("base=%s modifier=%s", num(value), num(values[2]))
        end)
    resistLines(out, "저항 UnitResistance('pet', school) [UI가 pet으로 호출하지 않음: 게임 내 확인 필요]",
        pet.resistances)
    formatPetManaRegen(self, out, pet.manaRegen)
    out:Add("note: 숙련(expertise)은 70790 UI가 소환수 창에 주인 값(GetExpertise)을 보여 주므로 소환수 값으로 기록하지 "
        .. "않음. 소환수 생명력/자원은 pet 구역, 재생 속도는 소환수 전용 API가 없어 수집하지 않음.")
end

local function formatPlayer(section, out)
    local p = section.player
    out:Add("### 플레이어 전투 세부값 (character 구역에 없는 항목)")
    out:Result("쌍수 IsDualWielding", p.dualWielding)
    out:Result("보조무기 명중 보정 GetOffhandHitModifier", p.offhandHitModifier, pct)
    out:Add("  (UI 표시 보조무기 명중 = character 구역의 근접 명중 등급 보너스 + 이 보정, Stats:525)")
    out:Result("방패 막기 수치 GetShieldBlock (UI가 '막기량'과 '방어도 감소'로 서로 다르게 설명: 게임 내 확인 필요)",
        p.shieldBlock, num)
    out:Result("보조무기가 방패 C_PaperDollInfo.OffhandHasShield", p.offhandHasShield)
    resistLines(out, "저항 UnitResistance('player', school)", p.resistances)
    out:Result("생명력 재생 GetHealthRegen", p.healthRegen, function(value, values)
        return string.format("healthRegen=%s combatHealthRegen=%s (API 원본값; UI는 5를 곱해 5초당으로 표시)",
            num(value), num(values[2]))
    end)
    out:Result("정신 기반 생명력 재생 GetHealthRegenFromSpirit", p.healthRegenFromSpirit, function(value, values)
        return string.format("healthRegen=%s combatHealthRegen=%s (원본값; UI는 앉아 있다고 가정해 0.75와 5를 곱함)",
            num(value), num(values[2]))
    end)
    out:Result("정신 기반 마나 재생 GetManaRegenFromSpirit", p.manaRegenFromSpirit, function(value, values)
        return string.format("powerRegen=%s combatPowerRegen=%s (원본값)", num(value), num(values[2]))
    end)
end

local function formatSkillLink(self, out, rec)
    local label = rec.label .. " (" .. rec.slotName .. (rec.slotID and (", slot " .. rec.slotID) or "") .. ")"
    if rec.state then
        out:Add(label .. ": " .. self:Describe(rec.state))
        return
    end
    if rec.kind == "empty" or rec.kind == "no_skill" then
        out:Add(label .. ": 연결된 무기 숙련 없음 - " .. rec.note)
        return
    end
    local skill = rec.skill
    local tag = self:Describe(skill)
    if tag then
        out:Add(label .. ": skillLineID " .. rec.skillLineID .. " (" .. rec.basis .. ") 숙련 정보: " .. tag)
        return
    end
    local info = skill.values[1]
    out:Add(string.format("%s: skillLineID %s %s (rank %s, modifier %s, max %s) [%s]", label, rec.skillLineID,
        self:Fmt(info.name), num(info.rank), num(info.modifier), num(info.maxRank), rec.basis))
end

local function formatWeapons(self, section, out)
    out:Add("### 장착 무기 숙련 연결 (70790 UI 규칙, PaperDollFrameStats.lua:681-715)")
    for _, rec in ipairs(section.weaponSkills) do formatSkillLink(self, out, rec) end
    out:Add("note: 숙련 수치는 API 값 그대로이며 전체 목록은 skills 구역. 변신 규칙(3014)과 비무기 슬롯 처리는 "
        .. "UI 코드 기준이고 게임 내 대조는 필요함.")
end

local function format(self, section, out)
    out:Add("### 관측 맥락")
    out:Add("수집 시각: " .. (self:Describe(section.capturedAt) or self:Date(self:Val(section.capturedAt, 1))))
    out:Add("범위: " .. section.scope)
    local c = section.context
    out:Result("전투 중 InCombatLockdown", c.inCombatLockdown)
    out:Result("변신 형태 GetShapeshiftForm (선언 없음, UI 호출만 근거)", c.shapeshiftForm)
    out:Result("플레이어 직업 UnitClass", c.playerClass, function(_, values)
        return self:Fmt(values[2]) .. " (" .. self:Fmt(values[1]) .. ")"
    end)
    out:Add("완전성: " .. section.completeness)
    formatPet(self, section, out)
    formatPlayer(section, out)
    formatWeapons(self, section, out)
end

Addon:RegisterCollector("combatdetails", collect, format)
