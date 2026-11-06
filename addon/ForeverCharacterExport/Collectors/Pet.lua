local _, Addon = ...
-- luacheck: read globals Enum

-- Pet section. Evidence (all paths under references/upstream/Interface/AddOns/):
--   Blizzard_APIDocumentationGenerated/UnitDocumentation.lua: UnitExists :1192, UnitName :2489, UnitLevel :2474,
--     UnitIsDeadOrGhost :1931, UnitCreatureFamily :996, UnitCreatureType :1030, UnitHealth :1526,
--     UnitHealthMax :1472, UnitPowerType :2859, UnitPower :2732, UnitPowerMax :2801, UnitClassBase :930
--   .../PetInfoDocumentation.lua: C_PetInfo.GetPetFoodTypes :26, GetPetHappiness :35, GetPetLoyalty :47,
--     GetPetTrainingPoints :82
--   Blizzard_UIPanels_Game/Camelot/PaperDollFrame.lua: GetPetExperience() -> exp, expNeeded :527 and :3706,
--     C_PetInfo.GetPetLoyalty :536
--   .../SpellBookDocumentation.lua: HasPetSpells, GetSpellBookItemInfo, SpellBookItemInfo struct :1012-1026
--   Blizzard_StableUI/Camelot/Blizzard_StableUI.lua: C_StableInfo.GetStablePetInfo(index) :86 :223 :268 :351,
--     GetNumStableSlots :97 :354 :383; slot 1 is the current pet (CURRENT_PET_SLOT :2), unlocked stable slots are
--     2..numSlots+1 (:354); a nil PetInfo is shown as an empty slot (:361-363)
--   .../StableInfoDocumentation.lua: GetNumStablePets, IsAtStableMaster :112, PetInfo struct
local MAX_PET_SPELLS = 500
local MAX_STABLE_SLOTS = 20
local NO_VALUE = "returned no value"

local function isCount(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0
end

-- A nil PetInfo is an empty slot only while the stable UI semantics apply (talking to the stable master).
local function interpretStableSlot(info, atMaster)
    if type(info) == "table" and info.status == "not_collected"
        and string.find(info.reason or "", NO_VALUE, 1, true) then
        if atMaster == true then
            return { status = "empty", api = info.api,
                reason = "no pet in this slot (stable master open; Blizzard_StableUI.lua:361-363)" }
        end
        info.reason = "no PetInfo returned: empty slot or stable data not loaded (not at a stable master)"
    end
    return info
end

local function collectUnit(self, section)
    local exists = self:Read(section, "exists", "UnitExists", "pet")
    if exists ~= true then
        section.unitDetails = self:State(exists == false and "empty" or "not_collected",
            exists == false and "current pet unit absent; not a statement about owned pets"
                or "current pet unit state unavailable; not a statement about owned pets")
        section.playerClass = self:Probe("UnitClassBase", "player")
        return
    end
    self:Read(section, "name", "UnitName", "pet")
    self:Read(section, "level", "UnitLevel", "pet")
    self:Read(section, "family", "UnitCreatureFamily", "pet")
    self:Read(section, "creatureType", "UnitCreatureType", "pet")
    self:Read(section, "health", "UnitHealth", "pet")
    self:Read(section, "healthMax", "UnitHealthMax", "pet")
    self:Read(section, "powerType", "UnitPowerType", "pet")
    self:Read(section, "power", "UnitPower", "pet")
    self:Read(section, "powerMax", "UnitPowerMax", "pet")
    self:Read(section, "deadOrGhost", "UnitIsDeadOrGhost", "pet")
    self:Read(section, "experience", "GetPetExperience")
    self:Read(section, "loyalty", "C_PetInfo.GetPetLoyalty")
    self:Read(section, "happiness", "C_PetInfo.GetPetHappiness")
    self:Read(section, "trainingPoints", "C_PetInfo.GetPetTrainingPoints")
    self:Read(section, "foodTypes", "C_PetInfo.GetPetFoodTypes")
end

local function collectSpells(self, section)
    local count = self:Read(section, "spellCount", "C_SpellBook.HasPetSpells")
    section.spells = {}
    if section.spellCount.status == "empty" then
        section.spellTraversal = self:State("empty", "HasPetSpells reports no current pet spells")
    elseif section.spellCount.status ~= "ok" then
        section.spellTraversal = self:State("not_collected", "pet spell count unavailable")
    elseif count == nil or count == 0 then
        -- HasPetSpells explicitly documents no returns when there are no pet spells.
        section.spellTraversal = self:State("empty", "HasPetSpells reports no current pet spells")
    elseif not isCount(count) then
        section.spellTraversal = self:State("error", "unexpected pet spell count")
    elseif not Enum or not Enum.SpellBookSpellBank or type(Enum.SpellBookSpellBank.Pet) ~= "number" then
        section.spellTraversal = self:State("unsupported", "Enum.SpellBookSpellBank.Pet unavailable")
    else
        local last = count
        if count > MAX_PET_SPELLS then
            last = MAX_PET_SPELLS
            section.spellTraversal = self:State("not_collected",
                "pet spell count " .. count .. " exceeds cap; first " .. MAX_PET_SPELLS .. " read")
        end
        for slot = 1, last do
            section.spells[#section.spells + 1] = {
                slot = slot,
                info = self:Probe("C_SpellBook.GetSpellBookItemInfo", slot, Enum.SpellBookSpellBank.Pet),
            }
        end
    end
end

local function collectStable(self, section)
    local stable = { pets = {} }
    section.stable = stable
    stable.atMaster = self:Probe("C_StableInfo.IsAtStableMaster")
    stable.numSlots = self:Probe("C_StableInfo.GetNumStableSlots")
    stable.numPets = self:Probe("C_StableInfo.GetNumStablePets")
    local atMaster = self:Val(stable.atMaster, 1)
    local numSlots = self:Val(stable.numSlots, 1)
    local last = 1
    if stable.numSlots.status ~= "ok" then
        stable.traversal = self:State("not_collected", "stable slot count unavailable; only current-pet slot 1 read")
    elseif not isCount(numSlots) then
        stable.traversal = self:State("error", "unexpected stable slot count; only current-pet slot 1 read")
    else
        last = numSlots + 1
        if last > MAX_STABLE_SLOTS then
            last = MAX_STABLE_SLOTS
            stable.traversal = self:State("not_collected",
                "stable slot count " .. numSlots .. " exceeds cap; first " .. MAX_STABLE_SLOTS .. " slots read")
        end
    end
    for index = 1, last do
        local info = self:Probe("C_StableInfo.GetStablePetInfo", index)
        stable.pets[#stable.pets + 1] = { index = index, info = interpretStableSlot(info, atMaster) }
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Formatting

local KO_COMMAND, KO_STANCE = "소환수 명령", "소환수 태세" -- subName texts observed on the koKR client

-- passive: SpellBookItemInfo.isPassive. ability: spellID is documented nil for non-spells. Remaining pet actions
-- split into command/stance only by exact koKR subName text; anything else stays a plain pet_action.
local function classify(item)
    if item.isPassive == true then return "passive" end
    if item.spellID ~= nil then return "ability" end
    if item.subName == KO_COMMAND then return "command" end
    if item.subName == KO_STANCE then return "stance" end
    return "pet_action"
end

local KIND_ORDER = { "command", "stance", "ability", "passive", "pet_action" }

local function quoted(self, text)
    if text == nil then return "<nil>" end
    return '"' .. self:Fmt(text) .. '"'
end

local function spellLine(self, slot, info)
    local tag = self:Describe(info)
    if tag then return "slot " .. slot .. ": " .. tag, nil end
    local item = info.values[1]
    if type(item) ~= "table" then
        local api = tostring(info.api)
        return "slot " .. slot .. ": <error: unexpected return type " .. type(item) .. " [" .. api .. "]>", nil
    end
    local kind = classify(item)
    local ids = {}
    if item.spellID ~= nil then ids[#ids + 1] = "spellID " .. self:Fmt(item.spellID) end
    ids[#ids + 1] = "actionID " .. self:Fmt(item.actionID)
    local line = "slot " .. slot .. ": [" .. kind .. "] " .. self:Fmt(item.name) .. " (" .. table.concat(ids, ", ")
        .. ") subName=" .. quoted(self, item.subName) .. " itemType=" .. self:Fmt(item.itemType)
    if item.isOffSpec == true then line = line .. " offSpec" end
    return line, kind
end

local function formatSpells(self, section, out)
    out:Add("### Pet spellbook")
    out:Result("pet spell count (HasPetSpells)", section.spellCount)
    if section.spellTraversal then out:State("pet spell traversal", section.spellTraversal) end
    local spells = section.spells or {}
    if #spells == 0 then return end
    local lines, counts, unreadable = {}, {}, 0
    for _, entry in ipairs(spells) do
        local line, kind = spellLine(self, entry.slot, entry.info)
        lines[#lines + 1] = line
        if kind then counts[kind] = (counts[kind] or 0) + 1 else unreadable = unreadable + 1 end
    end
    local parts = {}
    for _, kind in ipairs(KIND_ORDER) do
        if counts[kind] then parts[#parts + 1] = kind .. " " .. counts[kind] end
    end
    if unreadable > 0 then parts[#parts + 1] = "unreadable " .. unreadable end
    out:Add("entries: " .. #spells .. " (" .. table.concat(parts, ", ") .. ")")
    for _, line in ipairs(lines) do out:Add(line) end
    out:Add("note: kind = passive if isPassive; ability if spellID present; command/stance by exact koKR subName "
        .. "(" .. KO_COMMAND .. " / " .. KO_STANCE .. "); else pet_action. subName is printed as returned "
        .. "(rank text such as '1 레벨'); it may be empty when spell data is not loaded yet, so empty is not proof "
        .. "of 'no rank'.")
end

local function pair(self, out, label, cur, max)
    local curTag, maxTag = self:Describe(cur), self:Describe(max)
    if not curTag and not maxTag then
        out:Add(label .. ": " .. self:Fmt(cur.values[1]) .. " / " .. self:Fmt(max.values[1]))
    else
        out:Add(label .. ": current=" .. (curTag or self:Fmt(cur.values[1]))
            .. " max=" .. (maxTag or self:Fmt(max.values[1])))
    end
end

local function nameId(self, label, out, result)
    out:Result(label, result, function(value, values)
        return self:Fmt(value) .. " (id " .. self:Fmt(values[2]) .. ")"
    end)
end

local function formatUnit(self, section, out)
    out:Add("### Pet unit")
    out:Result("UnitExists('pet')", section.exists)
    if section.unitDetails then
        out:State("pet unit", section.unitDetails)
        if section.playerClass then
            out:Result("player class (UnitClassBase)", section.playerClass, function(value, values)
                return self:Fmt(value) .. " (classID " .. self:Fmt(values[2]) .. ")"
            end)
        end
        return
    end
    out:Result("name", section.name)
    out:Result("level", section.level)
    nameId(self, "family", out, section.family)
    nameId(self, "creature type", out, section.creatureType)
    pair(self, out, "health", section.health, section.healthMax)
    out:Result("power type", section.powerType, function(value, values)
        return self:Fmt(values[2]) .. " (id " .. self:Fmt(value) .. ")"
    end)
    pair(self, out, "power", section.power, section.powerMax)
    out:Result("dead or ghost", section.deadOrGhost)
    out:Result("experience (GetPetExperience)", section.experience, function(value, values)
        local text = self:Fmt(value) .. " / " .. self:Fmt(values[2])
        if values[2] == 0 then text = text .. " (expNeeded 0)" end
        return text
    end)
    out:Result("loyalty (GetPetLoyalty)", section.loyalty, function(value)
        if value == "" then return '"" (empty string)' end
        return self:Fmt(value)
    end)
    out:Result("training points (total, used)", section.trainingPoints, function(value, values)
        return "total=" .. self:Fmt(value) .. " used=" .. self:Fmt(values[2])
    end)
    out:Result("happiness (GetPetHappiness raw)", section.happiness, function(value, values)
        return "happiness=" .. self:Fmt(value) .. " damagePercentage=" .. self:Fmt(values[2])
            .. " loyaltyRate=" .. self:Fmt(values[3]) .. " (the declaration gives no meaning for these numbers)"
    end)
    out:Result("food types (GetPetFoodTypes)", section.foodTypes, function(value)
        if type(value) ~= "table" then return self:Fmt(value) end
        if #value == 0 then return "<empty: API returned an empty diet list>" end
        local foods = {}
        for index, food in ipairs(value) do
            if index > 50 then break end
            foods[#foods + 1] = self:Fmt(food)
        end
        return table.concat(foods, ", ")
    end)
end

local function stableLine(self, entry)
    local label = "slot " .. entry.index .. (entry.index == 1 and " (current pet slot)" or "")
    local tag = self:Describe(entry.info)
    if tag then return label .. ": " .. tag end
    local pet = entry.info.values[1]
    if type(pet) ~= "table" then
        return label .. ": <error: unexpected return type " .. type(pet) .. " [" .. tostring(entry.info.api) .. "]>"
    end
    return label .. ": " .. self:Fmt(pet.name) .. " (level " .. self:Fmt(pet.level) .. " " .. self:Fmt(pet.familyName)
        .. ") specialization=" .. self:Fmt(pet.specialization) .. " type=" .. self:Fmt(pet.type)
        .. " loyalty=" .. self:Fmt(pet.loyaltyName) .. " (level " .. self:Fmt(pet.loyaltyLevel) .. ")"
        .. " happinessLevel=" .. self:Fmt(pet.happinessLevel)
        .. " experience=" .. self:Fmt(pet.experience) .. "/" .. self:Fmt(pet.experienceNeeded)
        .. " petNumber=" .. self:Fmt(pet.petNumber) .. " creatureID=" .. self:Fmt(pet.creatureID)
        .. " slotID=" .. self:Fmt(pet.slotID) .. " favorite=" .. self:Fmt(pet.isFavorite)
        .. " exotic=" .. self:Fmt(pet.isExotic) .. " petAbilities=" .. self:Fmt(pet.petAbilities)
        .. " specAbilities=" .. self:Fmt(pet.specAbilities)
end

local function formatStable(self, section, out)
    out:Add("### Stable (C_StableInfo; slot 1 = current pet, slots 2.. = stable slots)")
    local stable = section.stable
    if type(stable) ~= "table" then
        out:Add("stable: <not_collected: no stable data>")
        return
    end
    out:Result("at stable master", stable.atMaster)
    out:Result("stable slots (GetNumStableSlots)", stable.numSlots)
    out:Result("stabled pets (GetNumStablePets)", stable.numPets)
    if stable.traversal then out:State("stable traversal", stable.traversal) end
    for _, entry in ipairs(stable.pets or {}) do
        out:Add(stableLine(self, entry))
    end
end

Addon:RegisterCollector("pet", function(self)
    local section = {
        scope = "current pet unit, pet spell bank and C_StableInfo slots; a missing pet unit says nothing about "
            .. "owned or stabled pets",
    }
    collectUnit(self, section)
    collectSpells(self, section)
    collectStable(self, section)
    return section
end, function(self, section, out)
    formatUnit(self, section, out)
    formatSpells(self, section, out)
    formatStable(self, section, out)
end)
