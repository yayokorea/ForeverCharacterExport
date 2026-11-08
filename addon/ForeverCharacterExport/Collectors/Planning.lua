local _, Addon = ...
-- luacheck: read globals Enum

-- Planning section: six independent read-only sub-blocks. One failing API (or one Lua error) must not hide the others;
-- every block carries its own state/completeness. Nothing here changes user state: no spec switch, no equip, no
-- trainer filter change, no window opened, no server data request (research doc section 7).
--
-- Evidence. Paths are relative to Interface/AddOns/. "upstream" = references/upstream/ (local copy of the pinned
-- Blizzard UI commit eac30af5...). "research cache" = dev/.tools/forever-research/ (same pinned commit; files that the
-- local upstream copy lacks, named by docs/collection-expansion-research.md). Cache-only evidence is marked [cache].
--
-- (12) Trainer services. All [cache]: Blizzard_TrainerUI/Mainline/Blizzard_TrainerUI.lua
--   * GetNumTrainerServices() -> count (:460). GetTrainerServiceInfo(i) -> name, serviceType, texture, reqLevel,
--     subText, category (:469, :618). Only "used" and "unavailable" are named serviceType values (:664-:679), so the
--     type is printed raw. GetTrainerServiceSkillReq(i) -> skill, rank, hasSkillReq; a nil skill means no skill
--     requirement (:637-:638). GetTrainerServiceCost(i) -> moneyCost, isProfession (:692); for a pet trainer the cost
--     is training points, not money (:700-:705). C_Trainer.GetTrainerType() -> Enum.TrainerType (:444;
--     Blizzard_APIDocumentationGenerated/TrainerDocumentation.lua:20, TrainerConstantsDocumentation.lua:13-16:
--     General 0, TalentsObsolete 1, Tradeskills 2, Pet 3).
--   * Window state: events TRAINER_SHOW / TRAINER_CLOSED (TrainerDocumentation.lua:43,61). Blizzard_TrainerUI is
--     LoadOnDemand, so no frame global is touched; the open state comes from the events. Not persisted (live only).
--   * The list the UI shows can be narrowed by the trainer filters (SavedVariables TRAINER_FILTER_*, TrainerUI.toc:3),
--     so completeness is reported as unknown. Filters are never changed.
-- (13) Spec groups and equipment sets.
--   * GetNumSpecGroups() -> number (upstream Blizzard_PlayerSpells/Camelot/ClassTalents/Blizzard_ClassTalentsFrame.lua:
--     124, Blizzard_PlayerSpells/Blizzard_PlayerSpellsFrame.lua:901). C_SpecializationInfo.GetActiveSpecGroup and
--     GetCombatConfigIDForSpecGroup(groupIndex) -> configID|nil (upstream SpecializationInfoDocumentation.lua:41,90;
--     ClassTalentsFrame.lua:112,120,183: a nil config means the group has no combat config).
--   * C_Traits.GetConfigInfo / GetTreeCurrencyInfo(configID, treeID, excludeStagedChanges): same calls as Talents.lua
--     (upstream SharedTraitsDocumentation.lua; Blizzard_SharedTalentUtil.lua:148-155). Only config + point currency
--     are read for each group; nodes are not walked.
--   * C_EquipmentSet.GetEquipmentSetIDs() -> {id...} (upstream PaperDollFrame.lua:3217; [cache]
--     EquipmentManagerDocumentation.lua:119). GetEquipmentSetInfo(id) -> name, iconFileID, setID, isEquipped,
--     numItems, numEquipped, numInInventory, numLost, numIgnored (:128-148; call sites PaperDollFrame.lua:2788,3159,
--     3193). GetEquipmentSetAssignedSpec(id) -> specIndex|nil (:71-84; PaperDollFrame.lua:3121). GetItemIDs(id) ->
--     {itemID...} with holes (:171-183, declaration only). GetIgnoredSlots(id) -> {slot=bool} (:152-165;
--     PaperDollFrame.lua:1560). CanUseEquipmentSets() -> bool ([cache] :22-28, declaration only).
--     C_Item.GetItemNameByID(itemInfo) -> name|nil (upstream ItemDocumentation.lua:846).
-- (14) Flyouts. Discovered from the spellbook only: C_SpellBook.GetSpellBookItemInfo(slot, Enum.SpellBookSpellBank.
--   Player) with itemType Flyout (4) where actionID is the flyoutID (upstream SpellBookDocumentation.lua:1016-1018,
--   SpellBookConstantsDocumentation.lua:27-31, Blizzard_SpellBookItem.lua:160). GetFlyoutInfo(flyoutID) -> ?, ?,
--   numSlots, isKnown (upstream Blizzard_PlayerSpellsFrame.lua:676; [cache] Blizzard_ActionBar/Shared/SpellFlyout.lua:
--   295: returns 1-2 are unnamed in the source and are not interpreted). GetFlyoutSlotInfo(flyoutID, i) -> spellID,
--   overrideSpellID, isKnownSlot, spellName, slotSpecID (SpellFlyout.lua:313; Blizzard_PlayerSpellsFrame.lua:680).
--   Action-bar flyout discovery is NOT done: GetActionInfo has no source in the mirror (see ActionBars.lua).
-- (15) Cooldowns and charges (time-stamped snapshot).
--   * C_Spell.GetSpellCooldown(spellIdentifier) -> SpellCooldownInfo|nil, C_Spell.GetSpellCharges(spellIdentifier)
--     -> SpellChargeInfo|nil, both SecretWhenCooldownsRestricted (upstream SpellDocumentation.lua:291-324). Only
--     startTime, duration, isEnabled, modRate are source-backed fields of SpellCooldownInfo
--     (Blizzard_SpellBookItem.lua:369-370, 917). SpellChargeInfo has no definition or field use in the mirror:
--     the copy is printed raw and no field is read by name. Fields that are not source-backed are listed
--     as "extra fields" without interpretation.
--   * No GCD flag or GCD spell is documented in the mirror, so GCD vs real cooldown is NOT decided here; spells that
--     report an identical start/duration are only annotated as sharing a timer.
--   * C_Item.GetItemCooldown(itemInfo) -> startTimeSeconds, durationSeconds, enableCooldownTimer (upstream
--     ItemDocumentation.lua:434-449; declaration only, no secret flag). Items = equipped slots only (slot IDs from
--     C_PaperDollInfo.GetInventorySlotInfo and GetInventoryItemID, as Equipment.lua); bag items are not scanned.
--   * remaining = startTime + duration - GetTime() (same clock arithmetic as upstream Blizzard_UnitPopupShared/
--     UnitPopupSharedButtonMixins.lua:2217 for another cooldown API; that spell/item startTime uses the GetTime
--     clock is assumed from that pattern and is NOT proven). GetTime: SystemTimeDocumentation.lua:57.
-- (16) PvP rank cap/season/next reward. Camelot/PVPRankFrame.lua (upstream): faction 2800 (:1);
--   C_MajorFactions.GetMajorFactionProgressionInfo (:91,134; fields MajorFactionsDocumentation.lua:287-298),
--   GetTotalReputationForRenownLevel (:147-151; MajorFactionsDocumentation.lua:126), GetRenownRewardsForLevel
--   (:185; MajorFactionsDocumentation.lua:110; reward fields :323-339), C_SeasonInfo.GetTimeUntilCurrentPVPSeasonEnd
--   (:80; [cache] SeasonInfoDocumentation.lua:29; 0 = season end not known, :79), GetCurrentArenaSeason() (:35,55,101;
--   a value of 0 hides the season, :103). Weekly cap and next reward follow :140-200.

local PVP_RANK_POINTS_FACTION_ID = 2800
local ITEM_SPELL, ITEM_FLYOUT = 1, 4 -- SpellBookConstantsDocumentation.lua:27-31

local CAP = {
    trainer = 100, specGroups = 4, trees = 6, sets = 20, flyouts = 20, flyoutSlots = 40, spellSlots = 400,
    cooldownList = 40, rewardScan = 60, rewardList = 6, setItems = 20,
}

-- Equipped slots checked for item cooldowns (names verified in Equipment.lua; ammo has no on-use cooldown).
local ITEM_SLOTS = {
    "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot", "WristSlot",
    "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot", "Trinket0Slot", "Trinket1Slot",
    "MainHandSlot", "SecondaryHandSlot", "RangedSlot",
}

local F = {} -- per-block formatters, defined at the end of the file

local function isNumber(v)
    return type(v) == "number"
end

-- A Probe that returned nil: ok call, no value. The API contract decides what that means.
local function returnedNothing(result)
    return type(result) == "table" and result.status == "not_collected" and type(result.values) == "table"
end

-- Run one block reader under pcall so a Lua error in it cannot blank the other blocks.
local function guard(self, parent, key, fn, ...)
    local ok, result = pcall(fn, self, ...)
    if ok and type(result) == "table" then
        parent[key] = result
    else
        local state = self:Failure(ok and "block reader returned no table" or result)
        state.api = "Planning." .. key
        parent[key] = { state = state, complete = false }
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- (12) Trainer

Addon:On("TRAINER_SHOW", function(self)
    self.planningTrainerOpen = true
    self.planningTrainerSeenAt = self:Now()
end)
Addon:On("TRAINER_CLOSED", function(self)
    self.planningTrainerOpen = false
end)

local function readTrainer(self)
    local block = {}
    local open = self.planningTrainerOpen
    if open ~= true then
        block.open = false
        block.state = self:State("not_collected", open == false
            and "trainer window not open (open a trainer, then export)"
            or "no TRAINER_SHOW seen since login; reopen the trainer window, then export")
        block.state.info = true
        return block
    end
    block.open = true
    block.openedAt = self.planningTrainerSeenAt
    block.trainerType = self:Probe("C_Trainer.GetTrainerType")
    local count = self:Read(block, "count", "GetNumTrainerServices")
    if not isNumber(count) or count < 0 or count ~= math.floor(count) then
        block.complete = false
        return block
    end
    local limit = math.min(count, CAP.trainer)
    block.listed = limit
    block.truncated = count > limit
    block.services = {}
    for index = 1, limit do
        local entry = { index = index }
        entry.info = self:Probe("GetTrainerServiceInfo", index)
        entry.cost = self:Probe("GetTrainerServiceCost", index)
        entry.skillReq = self:Probe("GetTrainerServiceSkillReq", index)
        -- TrainerUI.lua:637-638: a nil skill is "no skill requirement", not an unread value.
        if returnedNothing(entry.skillReq) then entry.skillReq.info = true end
        block.services[#block.services + 1] = entry
    end
    -- complete stays nil: the trainer UI filters are not read, so the list may be narrowed.
    block.note = "list may be narrowed by the trainer window filters (not read, not changed)"
    return block
end

-- ---------------------------------------------------------------------------------------------------------------
-- (13a) Spec groups

local function readSpecGroups(self)
    local block = { groups = {} }
    local num = self:Read(block, "numGroups", "GetNumSpecGroups")
    local active = self:Read(block, "activeGroup", "C_SpecializationInfo.GetActiveSpecGroup")
    if not isNumber(num) or num < 0 then
        block.complete = false
        return block
    end
    local limit = math.min(num, CAP.specGroups)
    block.truncated = num > limit
    local complete = not block.truncated
    for group = 1, limit do
        local entry = { group = group, trees = {} }
        if isNumber(active) then entry.isActive = (group == active) end
        block.groups[#block.groups + 1] = entry
        local configID = self:Read(entry, "configID", "C_SpecializationInfo.GetCombatConfigIDForSpecGroup", group)
        if not isNumber(configID) then
            complete = false
        else
            entry.configIDValue = configID
            local config = self:Read(entry, "config", "C_Traits.GetConfigInfo", configID)
            if type(config) ~= "table" or type(config.treeIDs) ~= "table" then
                complete = false
            else
                for index, treeID in ipairs(config.treeIDs) do
                    if index > CAP.trees then
                        entry.treesTruncated = true
                        complete = false
                        break
                    end
                    -- excludeStagedChanges = true: committed state only (as Talents.lua).
                    local tree = { treeID = treeID,
                        currency = self:Probe("C_Traits.GetTreeCurrencyInfo", configID, treeID, true) }
                    if tree.currency.status ~= "ok" then complete = false end
                    entry.trees[#entry.trees + 1] = tree
                end
            end
        end
    end
    block.complete = complete
    return block
end

-- ---------------------------------------------------------------------------------------------------------------
-- (13b) Equipment sets

local function readItemNames(self, itemIDs)
    local names, unnamed = {}, 0
    for _, itemID in ipairs(itemIDs) do
        local name = self:Val(self:Probe("C_Item.GetItemNameByID", itemID))
        if type(name) == "string" and name ~= "" then names[itemID] = name else unnamed = unnamed + 1 end
    end
    return names, unnamed
end

local function readEquipmentSets(self)
    local block = { sets = {} }
    block.canUse = self:Probe("C_EquipmentSet.CanUseEquipmentSets")
    block.idList = self:Probe("C_EquipmentSet.GetEquipmentSetIDs")
    local ids = self:Val(block.idList)
    if type(ids) ~= "table" then
        block.complete = false
        return block
    end
    local limit = math.min(#ids, CAP.sets)
    block.total = #ids
    block.truncated = #ids > limit
    local complete = not block.truncated
    for index = 1, limit do
        local setID = ids[index]
        local set = { setID = setID }
        block.sets[#block.sets + 1] = set
        if not isNumber(setID) then
            complete = false
        else
            set.info = self:Probe("C_EquipmentSet.GetEquipmentSetInfo", setID)
            set.spec = self:Probe("C_EquipmentSet.GetEquipmentSetAssignedSpec", setID)
            set.items = self:Probe("C_EquipmentSet.GetItemIDs", setID)
            set.ignored = self:Probe("C_EquipmentSet.GetIgnoredSlots", setID)
            -- MayReturnNothing; the UI treats a nil spec as "not assigned" (PaperDollFrame.lua:3121).
            if returnedNothing(set.spec) then set.spec.info = true end
            if set.info.status ~= "ok" or set.items.status ~= "ok" then complete = false end
            local items = self:Val(set.items)
            if type(items) == "table" then
                local slots, ids2 = {}, {}
                for slot, itemID in pairs(items) do
                    if isNumber(slot) and isNumber(itemID) then slots[#slots + 1] = slot end
                end
                table.sort(slots)
                set.slots = {}
                for position, slot in ipairs(slots) do
                    if position > CAP.setItems then
                        set.itemsTruncated = true
                        complete = false
                        break
                    end
                    set.slots[#set.slots + 1] = { slot = slot, itemID = items[slot] }
                    ids2[#ids2 + 1] = items[slot]
                end
                set.names, set.unnamed = readItemNames(self, ids2)
            end
        end
    end
    block.complete = complete
    return block
end

-- ---------------------------------------------------------------------------------------------------------------
-- Shared spellbook pass for (14) and (15). Plain data only: probes are kept just for failures.

local function playerBank()
    local banks = type(Enum) == "table" and Enum.SpellBookSpellBank
    if type(banks) == "table" and isNumber(banks.Player) then return banks.Player end
end

local function scanSpellbook(self)
    local scan = { spells = {}, flyouts = {}, okReads = 0, unreadable = 0, failures = {} }
    local count = self:Read(scan, "numSkillLines", "C_SpellBook.GetNumSpellBookSkillLines")
    local bank = playerBank()
    if not bank then
        scan.state = self:State("unsupported", "Enum.SpellBookSpellBank.Player unavailable at runtime")
        scan.complete = false
        return scan
    end
    if not isNumber(count) or count < 0 then
        scan.complete = false
        return scan
    end
    local total = 0
    local complete = true
    for lineIndex = 1, count do
        local line = self:Probe("C_SpellBook.GetSpellBookSkillLineInfo", lineIndex)
        local info = self:Val(line)
        if type(info) ~= "table" then
            complete = false
            scan.unreadable = scan.unreadable + 1
            if #scan.failures < 3 then scan.failures[#scan.failures + 1] = line end
        elseif info.shouldHide ~= true and info.offSpecID == nil then
            local offset, size = info.itemIndexOffset, info.numSpellBookItems
            if not isNumber(offset) or not isNumber(size) or offset < 0 or size < 0 then
                complete = false
            else
                scan.okReads = scan.okReads + 1
                for slot = offset + 1, offset + size do
                    if total >= CAP.spellSlots then
                        scan.truncated = true
                        complete = false
                        break
                    end
                    total = total + 1
                    local item = self:Probe("C_SpellBook.GetSpellBookItemInfo", slot, bank)
                    local spell = self:Val(item)
                    if type(spell) ~= "table" then
                        complete = false
                        scan.unreadable = scan.unreadable + 1
                        if #scan.failures < 3 then scan.failures[#scan.failures + 1] = item end
                    else
                        scan.okReads = scan.okReads + 1
                        if spell.isOffSpec ~= true then
                            local name = type(spell.name) == "string" and spell.name or nil
                            if spell.itemType == ITEM_FLYOUT and isNumber(spell.actionID) then
                                scan.flyouts[#scan.flyouts + 1] = { slot = slot, flyoutID = spell.actionID,
                                    name = name }
                            elseif spell.itemType == ITEM_SPELL and spell.isPassive ~= true then
                                local id = isNumber(spell.spellID) and spell.spellID or spell.actionID
                                if isNumber(id) then
                                    scan.spells[#scan.spells + 1] = { slot = slot, spellID = id, name = name }
                                end
                            end
                        end
                    end
                end
            end
        end
        if scan.truncated then break end
    end
    scan.slotsRead = total
    scan.complete = complete
    return scan
end

-- ---------------------------------------------------------------------------------------------------------------
-- (14) Flyouts

local function readFlyouts(self, scan)
    local block = { flyouts = {}, spellbookComplete = scan.complete, spellbookState = scan.state,
        okReads = scan.okReads,
        spellbook = { numSkillLines = scan.numSkillLines, failures = scan.failures, slotsRead = scan.slotsRead,
            truncated = scan.truncated, unreadable = scan.unreadable, spellsFound = #scan.spells } }
    if scan.state or scan.complete == nil then
        block.complete = false
        return block
    end
    local limit = math.min(#scan.flyouts, CAP.flyouts)
    block.total = #scan.flyouts
    block.truncated = #scan.flyouts > limit
    local complete = scan.complete and not block.truncated
    for index = 1, limit do
        local source = scan.flyouts[index]
        local entry = { slot = source.slot, flyoutID = source.flyoutID, name = source.name, slots = {} }
        block.flyouts[#block.flyouts + 1] = entry
        entry.info = self:Probe("GetFlyoutInfo", source.flyoutID)
        local numSlots = self:Val(entry.info, 3)
        if not isNumber(numSlots) then
            complete = false
        else
            entry.numSlots = numSlots
            entry.isKnown = self:Val(entry.info, 4)
            local shown = math.min(numSlots, CAP.flyoutSlots)
            if numSlots > shown then
                entry.slotsTruncated = true
                complete = false
            end
            for slot = 1, shown do
                local result = self:Probe("GetFlyoutSlotInfo", source.flyoutID, slot)
                if result.status ~= "ok" then complete = false end
                entry.slots[#entry.slots + 1] = { index = slot, info = result }
            end
        end
    end
    block.complete = complete
    return block
end

-- ---------------------------------------------------------------------------------------------------------------
-- (15) Cooldowns and charges

local KNOWN_COOLDOWN_KEYS = { startTime = true, duration = true, isEnabled = true, modRate = true }

local function readSpellCooldowns(self, scan, now)
    local block = { entries = {}, counts = { checked = 0, ready = 0, active = 0, noValue = 0, restricted = 0,
        errors = 0, badShape = 0, chargeSpells = 0, chargesRestricted = 0, chargesErrors = 0 }, okReads = 0 }
    if scan.state or scan.complete == nil then
        block.complete = false
        block.spellbookState = scan.state
        return block
    end
    local counts = block.counts
    local samples = {}
    for _, spell in ipairs(scan.spells) do
        local cd = self:Probe("C_Spell.GetSpellCooldown", spell.spellID)
        if cd.status == "unsupported" then
            block.unsupported = cd
            break
        end
        counts.checked = counts.checked + 1
        local active, remaining = false, nil
        local info = self:Val(cd)
        if cd.status == "ok" then
            if type(info) == "table" and isNumber(info.duration) then
                if info.duration > 0 then
                    if isNumber(info.startTime) and isNumber(now) then
                        remaining = info.startTime + info.duration - now
                    end
                    active = remaining == nil or remaining > 0
                end
            else
                counts.badShape = counts.badShape + 1
                if not samples.badShape then samples.badShape = cd end
            end
        elseif returnedNothing(cd) then
            counts.noValue = counts.noValue + 1
        elseif cd.status == "restricted" then
            counts.restricted = counts.restricted + 1
            samples.restricted = samples.restricted or cd
        else
            counts.errors = counts.errors + 1
            samples.errors = samples.errors or cd
        end
        local charges = self:Probe("C_Spell.GetSpellCharges", spell.spellID)
        local hasCharges = false
        if charges.status == "ok" and type(self:Val(charges)) == "table" then
            hasCharges = true
            counts.chargeSpells = counts.chargeSpells + 1
        elseif charges.status == "restricted" then
            counts.chargesRestricted = counts.chargesRestricted + 1
        elseif charges.status ~= "ok" and not returnedNothing(charges) then
            counts.chargesErrors = counts.chargesErrors + 1
            samples.chargesErrors = samples.chargesErrors or charges
        end
        if active then
            counts.active = counts.active + 1
        elseif cd.status == "ok" then
            counts.ready = counts.ready + 1
        end
        if active or hasCharges then
            if #block.entries < CAP.cooldownList then
                block.entries[#block.entries + 1] = { spellID = spell.spellID, name = spell.name, cd = cd,
                    charges = hasCharges and charges or nil, active = active, remaining = remaining }
            else
                block.entriesTruncated = (block.entriesTruncated or 0) + 1
            end
        elseif cd.status == "ok" then
            block.okReads = block.okReads + 1
        end
    end
    block.samples = samples
    -- Spells that report an identical start/duration share one timer (annotation only; not decided to be the GCD).
    local groups = {}
    for _, entry in ipairs(block.entries) do
        local info = self:Val(entry.cd)
        if entry.active and type(info) == "table" and isNumber(info.startTime) and isNumber(info.duration) then
            entry.timerKey = info.startTime .. "/" .. info.duration
            groups[entry.timerKey] = (groups[entry.timerKey] or 0) + 1
        end
    end
    for _, entry in ipairs(block.entries) do
        if entry.timerKey then entry.timerShared = groups[entry.timerKey] end
    end
    block.complete = scan.complete and not block.unsupported and counts.restricted == 0 and counts.errors == 0
        and counts.badShape == 0 and counts.chargesRestricted == 0 and counts.chargesErrors == 0
        and not block.entriesTruncated
    return block
end

local function readItemCooldowns(self, now)
    local block = { entries = {}, counts = { slots = #ITEM_SLOTS, empty = 0, unresolved = 0, checked = 0, ready = 0,
        active = 0, restricted = 0, errors = 0 }, okReads = 0 }
    local counts = block.counts
    for _, slotName in ipairs(ITEM_SLOTS) do
        local slotInfo = self:Probe("C_PaperDollInfo.GetInventorySlotInfo", slotName)
        local slotID = self:Val(slotInfo)
        if not isNumber(slotID) then
            counts.unresolved = counts.unresolved + 1
        else
            block.okReads = block.okReads + 1
            local idResult = self:Probe("GetInventoryItemID", "player", slotID)
            local itemID = self:Val(idResult)
            if returnedNothing(idResult) then
                counts.empty = counts.empty + 1
            elseif not isNumber(itemID) then
                counts.unresolved = counts.unresolved + 1
            else
                local cd = self:Probe("C_Item.GetItemCooldown", itemID)
                counts.checked = counts.checked + 1
                local start, duration = self:Val(cd, 1), self:Val(cd, 2)
                if cd.status == "ok" and isNumber(duration) then
                    local remaining = isNumber(start) and isNumber(now) and (start + duration - now) or nil
                    if duration > 0 and (remaining == nil or remaining > 0) then
                        counts.active = counts.active + 1
                        block.entries[#block.entries + 1] = { slotName = slotName, slotID = slotID, itemID = itemID,
                            cd = cd, remaining = remaining }
                    else
                        counts.ready = counts.ready + 1
                        block.okReads = block.okReads + 1
                    end
                elseif cd.status == "restricted" then
                    counts.restricted = counts.restricted + 1
                    block.sample = block.sample or cd
                else
                    counts.errors = counts.errors + 1
                    block.sample = block.sample or cd
                end
            end
        end
    end
    block.complete = counts.unresolved == 0 and counts.restricted == 0 and counts.errors == 0
    return block
end

local function readCooldowns(self, scan, now)
    local block = {}
    guard(self, block, "spells", readSpellCooldowns, scan, now)
    guard(self, block, "items", readItemCooldowns, now)
    return block
end

-- ---------------------------------------------------------------------------------------------------------------
-- (16) PvP weekly cap / season / next reward

local function readPvp(self, now)
    local block = { factionID = PVP_RANK_POINTS_FACTION_ID }
    block.progression = self:Probe("C_MajorFactions.GetMajorFactionProgressionInfo", PVP_RANK_POINTS_FACTION_ID)
    block.seasonEnd = self:Probe("C_SeasonInfo.GetTimeUntilCurrentPVPSeasonEnd")
    block.season = self:Probe("GetCurrentArenaSeason")
    local seconds = self:Val(block.seasonEnd)
    if isNumber(seconds) and seconds > 0 and isNumber(now) then
        block.seasonEndsAtServerTime = now + seconds
    end
    local progress = self:Val(block.progression)
    if type(progress) ~= "table" then
        block.complete = false
        return block
    end
    local function total(level)
        if not isNumber(level) then return nil end
        return self:Probe("C_MajorFactions.GetTotalReputationForRenownLevel", PVP_RANK_POINTS_FACTION_ID, level)
    end
    block.totals = {
        current = total(progress.renownLevel),
        currentWeekMax = total(progress.currentWeekProgressiveMaxLevel),
        previousWeekMax = total(progress.previousWeekProgressiveMaxLevel),
        seasonMax = total(progress.maxLevel),
    }
    local cur = self:Val(block.totals.current)
    local weekMax = self:Val(block.totals.currentWeekMax)
    local prevMax = self:Val(block.totals.previousWeekMax)
    if isNumber(cur) and isNumber(progress.renownReputationEarned) then
        block.totalEarned = cur + progress.renownReputationEarned
    end
    if isNumber(weekMax) and isNumber(prevMax) then
        block.weeklyIncrease = weekMax - prevMax
    end
    -- Next reward: first level above the current rank whose reward list is non-empty (PVPRankFrame.lua:180-192).
    if isNumber(progress.renownLevel) and isNumber(progress.maxLevel) then
        local scanned, failures = 0, 0
        block.reward = { scanFrom = progress.renownLevel + 1, scanTo = progress.maxLevel }
        for level = progress.renownLevel + 1, progress.maxLevel do
            if scanned >= CAP.rewardScan then
                block.reward.truncated = true
                break
            end
            scanned = scanned + 1
            local result = self:Probe("C_MajorFactions.GetRenownRewardsForLevel", PVP_RANK_POINTS_FACTION_ID, level)
            local list = self:Val(result)
            if type(list) == "table" and #list > 0 then
                block.reward.level = level
                block.reward.items = {}
                for index, reward in ipairs(list) do
                    if index > CAP.rewardList then
                        block.reward.itemsTruncated = true
                        break
                    end
                    if type(reward) == "table" then
                        block.reward.items[#block.reward.items + 1] = {
                            renownRewardID = reward.renownRewardID, name = reward.name,
                            description = reward.description, itemID = reward.itemID, spellID = reward.spellID,
                            mountID = reward.mountID, titleMaskID = reward.titleMaskID,
                            isAccountUnlock = reward.isAccountUnlock,
                        }
                    end
                end
                break
            elseif result.status ~= "ok" then
                failures = failures + 1
                block.reward.firstFailure = block.reward.firstFailure or result
            end
        end
        block.reward.scanned = scanned
        block.reward.failures = failures
    end
    block.complete = block.progression.status == "ok" and not (block.reward and (block.reward.failures or 0) > 0)
        and not (block.reward and block.reward.truncated)
    return block
end

-- ---------------------------------------------------------------------------------------------------------------

Addon:RegisterCollector("planning", function(self)
    local section = { capturedAt = self:Timestamp(), time = self:Probe("GetTime") }
    local now = self:Val(section.time)
    guard(self, section, "trainer", readTrainer)
    guard(self, section, "specGroups", readSpecGroups)
    guard(self, section, "equipmentSets", readEquipmentSets)
    local ok, scan = pcall(scanSpellbook, self)
    if not ok or type(scan) ~= "table" then
        local state = self:Failure(scan)
        state.api = "Planning.spellbook"
        scan = { spells = {}, flyouts = {}, state = state, complete = false }
    end
    guard(self, section, "flyouts", readFlyouts, scan)
    if type(section.flyouts) == "table" and not section.flyouts.spellbook then
        section.flyouts.spellbook = { state = scan.state }
    end
    guard(self, section, "cooldowns", readCooldowns, scan, now)
    guard(self, section, "pvp", readPvp, now)
    return section
end, function(self, section, out)
    out:Add("(스냅샷: 읽기 전용. 특성 전환/장비 착용/창 열기/서버 요청 없음. 각 블록은 독립 상태와 완전성을 가짐)")
    out:Result("관측 시각", section.capturedAt, function(epoch) return self:Date(epoch) end)
    out:Result("GetTime", section.time)
    for _, item in ipairs({
        { "trainer", "상급자 가르침 목록 (12)" },
        { "specGroups", "특성 그룹 (13a)" },
        { "equipmentSets", "장비 세트 (13b)" },
        { "flyouts", "주문 flyout (14)" },
        { "cooldowns", "재사용 대기시간/충전 (15)" },
        { "pvp", "PvP 주간 상한/시즌/다음 보상 (16)" },
    }) do
        local key, title = item[1], item[2]
        local block = section[key]
        local ok, err = pcall(function()
            if type(block) ~= "table" then
                out:Add("### " .. title .. ": <not_collected: block missing>")
            elseif block.state and block.open == nil then
                -- The block reader itself failed (guard); nothing else to format.
                out:Add("### " .. title .. " [완전성: 불완전]")
                out:Add("  상태: " .. (self:Describe(block.state) or "ok"))
            else
                F[key](self, block, out, title, section)
            end
        end)
        if not ok then
            out:Add("### " .. title .. ": <error: formatter failed: " .. tostring(err) .. ">")
        end
    end
end)

-- ---------------------------------------------------------------------------------------------------------------
-- Formatting (labels in Korean; status tags stay English because coverage and tests key on them)

local function seconds(value)
    local sign = value < 0 and "-" or ""
    value = math.floor(math.abs(value))
    if value >= 86400 then
        return sign .. math.floor(value / 86400) .. "d " .. math.floor((value % 86400) / 3600) .. "h"
    elseif value >= 3600 then
        return sign .. math.floor(value / 3600) .. "h " .. math.floor((value % 3600) / 60) .. "m"
    elseif value >= 60 then
        return sign .. math.floor(value / 60) .. "m " .. (value % 60) .. "s"
    end
    return sign .. value .. "s"
end

local function coin(copper)
    copper = math.floor(copper)
    return string.format("%dg %ds %dc", math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100)
end

local function completeness(block)
    if block.complete == true then return "완전" end
    if block.complete == false then return "불완전" end
    return "미확인"
end

local function head(self, out, title, block, extra)
    -- Titles that start with spaces are sub-blocks and get no "###" marker.
    local marker = string.sub(title, 1, 2) == "  " and "" or "### "
    local text = marker .. title .. " [완전성: " .. completeness(block) .. (extra and (" - " .. extra) or "") .. "]"
    out:Add(text)
    if block.state then
        out:Add("  상태: " .. (self:Describe(block.state) or "ok"))
    end
end

-- A name or a "<not_collected>" fallback; both cleaned for plain text.
local function nameOf(self, value)
    if type(value) == "string" and value ~= "" then return self:Clean(value) end
    return "<not_collected: name missing>"
end

function F.trainer(self, block, out, title)
    if block.open == false then
        head(self, out, title, block, "창 안 열림")
        return
    end
    local unit = "금액 단위 미확인"
    local pet
    local kind = self:Val(block.trainerType)
    if isNumber(kind) then
        if type(Enum) == "table" and type(Enum.TrainerType) == "table" and isNumber(Enum.TrainerType.Pet) then
            pet = kind == Enum.TrainerType.Pet
            unit = pet and "비용=훈련 포인트" or "비용=구리(copper)"
        end
    end
    head(self, out, title, block, block.note)
    if isNumber(block.openedAt) then
        out:Add("  창 열림(TRAINER_SHOW) 감지: " .. self:Date(block.openedAt) .. " (이후 이 창의 현재 목록을 읽음)")
    end
    out:Result("  교관 종류 (C_Trainer.GetTrainerType)", block.trainerType)
    out:Result("  서비스 수", block.count)
    if not block.services then return end
    out:Add("  표시 " .. block.listed .. "개" .. (block.truncated and " (상한 도달: 일부만 표시, truncated)" or "")
        .. " / " .. unit .. " / 종류(type)는 원문 그대로")
    for _, entry in ipairs(block.services) do
        local tag = self:Describe(entry.info)
        local line = "  - #" .. entry.index .. " "
        if tag then
            line = line .. tag
        else
            local v = entry.info.values
            line = line .. nameOf(self, v[1]) .. " | type=" .. self:Fmt(v[2]) .. " | reqLevel=" .. self:Fmt(v[4])
            if type(v[5]) == "string" and v[5] ~= "" then line = line .. " | sub=" .. self:Clean(v[5]) end
            if type(v[6]) == "string" and v[6] ~= "" then line = line .. " | category=" .. self:Clean(v[6]) end
        end
        local costTag = self:Describe(entry.cost)
        if costTag then
            line = line .. " | cost=" .. costTag
        else
            local cost = entry.cost.values[1]
            if isNumber(cost) and pet == false then
                line = line .. " | cost=" .. coin(cost) .. " (" .. cost .. "c)"
            elseif isNumber(cost) and pet then
                line = line .. " | cost=" .. cost .. " 훈련 포인트"
            else
                line = line .. " | cost=" .. self:Fmt(cost) .. " (단위 미확인)"
            end
            if entry.cost.values[2] ~= nil then line = line .. " | isProfession=" .. self:Fmt(entry.cost.values[2]) end
        end
        local skillTag = self:Describe(entry.skillReq)
        if entry.skillReq.status == "ok" then
            local s = entry.skillReq.values
            line = line .. " | skillReq=" .. self:Fmt(s[1]) .. " " .. self:Fmt(s[2]) .. " (충족=" .. self:Fmt(s[3]) .. ")"
        elseif returnedNothing(entry.skillReq) then
            line = line .. " | skillReq=없음"
        else
            line = line .. " | skillReq=" .. skillTag
        end
        out:Add(line)
    end
end

function F.specGroups(self, block, out, title)
    head(self, out, title, block, block.truncated and "그룹 수 상한 도달" or nil)
    out:Result("  그룹 수 (GetNumSpecGroups)", block.numGroups)
    out:Result("  활성 그룹", block.activeGroup)
    for _, group in ipairs(block.groups) do
        local label = "  그룹 " .. group.group .. (group.isActive and " (활성: 상세는 talents 구역)" or
            (group.isActive == false and " (비활성)" or " (활성 여부 미확인)")) .. ": "
        local tag = self:Describe(group.configID)
        if tag then
            out:Add(label .. "config ID " .. tag .. " (없음/미준비일 수 있음; 특성 0개의 증거 아님)")
        else
            local config = self:Val(group.config)
            local text = label .. "config " .. group.configIDValue
            if type(config) == "table" then
                text = text .. " name=" .. nameOf(self, config.name) .. " type=" .. self:Fmt(config.type)
            else
                text = text .. " " .. (self:Describe(group.config) or "<error: config shape>")
            end
            out:Add(text)
            for _, tree in ipairs(group.trees) do
                local currencies = self:Val(tree.currency)
                if type(currencies) == "table" then
                    local parts = {}
                    for _, c in ipairs(currencies) do
                        if type(c) == "table" and isNumber(c.spent) and isNumber(c.quantity) then
                            parts[#parts + 1] = "사용 " .. c.spent .. " / 남음 " .. c.quantity
                        end
                    end
                    out:Add("    tree " .. tostring(tree.treeID) .. ": " .. (#parts > 0 and table.concat(parts, "; ")
                        or "<not_collected: no usable currency entry>"))
                else
                    out:Add("    tree " .. tostring(tree.treeID) .. ": " .. (self:Describe(tree.currency)
                        or "<error: currency shape>"))
                end
            end
            if group.treesTruncated then out:Add("    ... tree 목록 상한 도달 (truncated)") end
        end
    end
end

local function itemLabel(self, set, slot)
    local name = set.names and set.names[slot.itemID]
    return "slot " .. slot.slot .. "=" .. (name and self:Clean(name) .. " " or "") .. "(item " .. slot.itemID .. ")"
end

function F.equipmentSets(self, block, out, title)
    head(self, out, title, block, block.truncated and "세트 수 상한 도달" or nil)
    out:Result("  장비 세트 사용 가능 (CanUseEquipmentSets)", block.canUse)
    local tag = self:Describe(block.idList)
    if tag then
        out:Add("  세트 목록: " .. tag)
        return
    end
    out:Add("  세트 " .. block.total .. "개 (읽기만 함; 착용 안 함)" .. (block.truncated and ", 표시는 상한까지" or ""))
    for _, set in ipairs(block.sets) do
        local infoTag = set.info and self:Describe(set.info)
        if not set.info then
            out:Add("  - set " .. tostring(set.setID) .. ": <error: set ID is not a number>")
        elseif infoTag then
            out:Add("  - set " .. tostring(set.setID) .. ": " .. infoTag)
        else
            local v = set.info.values
            out:Add("  - " .. nameOf(self, v[1]) .. " (setID " .. self:Fmt(v[3]) .. ") 착용중=" .. self:Fmt(v[4])
                .. " items=" .. self:Fmt(v[5]) .. " equipped=" .. self:Fmt(v[6]) .. " inBags=" .. self:Fmt(v[7])
                .. " lost=" .. self:Fmt(v[8]) .. " ignored=" .. self:Fmt(v[9]))
            if set.spec.status == "ok" then
                out:Add("      배정된 특성 그룹 index: " .. self:Fmt(set.spec.values[1]))
            elseif returnedNothing(set.spec) then
                out:Add("      배정된 특성 그룹: 없음")
            else
                out:Add("      배정된 특성 그룹: " .. self:Describe(set.spec))
            end
            local itemsTag = self:Describe(set.items)
            if itemsTag then
                out:Add("      구성품: " .. itemsTag)
            elseif set.slots then
                local parts = {}
                for _, slot in ipairs(set.slots) do parts[#parts + 1] = itemLabel(self, set, slot) end
                out:Add("      구성품 (slot 번호는 API 반환 키 그대로): " .. (#parts > 0 and table.concat(parts, "; ")
                    or "없음") .. (set.itemsTruncated and " ... (상한 도달, truncated)" or ""))
                if (set.unnamed or 0) > 0 then
                    out:Add("      아이템 이름 미확인 " .. set.unnamed .. "개 (캐시 없음일 수 있음)")
                end
            end
            local ignoredTag = self:Describe(set.ignored)
            if ignoredTag then
                if not returnedNothing(set.ignored) then out:Add("      무시 슬롯: " .. ignoredTag) end
            else
                local ignored = {}
                for slot, flag in pairs(set.ignored.values[1] or {}) do
                    if flag == true and isNumber(slot) then ignored[#ignored + 1] = slot end
                end
                table.sort(ignored)
                if #ignored > 0 then out:Add("      무시 슬롯: " .. table.concat(ignored, ",")) end
            end
        end
    end
end

function F.flyouts(self, block, out, title)
    head(self, out, title, block, "주문서에서 찾은 flyout만. 행동 단축바 flyout은 근거 부족으로 미조사")
    if block.spellbookState then
        out:Add("  주문서 읽기: " .. (self:Describe(block.spellbookState) or "ok"))
    end
    local book = block.spellbook or {}
    if book.numSkillLines and self:Describe(book.numSkillLines) then
        out:Add("  주문서 기술 계열 수: " .. self:Describe(book.numSkillLines))
    end
    if book.slotsRead then
        out:Add("  주문서 " .. book.slotsRead .. "칸 읽음" .. ((book.unreadable or 0) > 0
            and (", 읽기 실패 " .. book.unreadable) or "") .. (book.truncated and ", 칸 상한 도달 (truncated)" or ""))
    end
    if not block.total then return end
    if block.total == 0 then
        out:Add("  주문서의 flyout 0개" .. (block.spellbookComplete and "" or " (주문서 읽기가 불완전하므로 없다는 증거 아님)"))
        return
    end
    out:Add("  flyout " .. block.total .. "개" .. (block.truncated and ", 표시는 상한까지 (truncated)" or ""))
    for _, flyout in ipairs(block.flyouts) do
        local tag = self:Describe(flyout.info)
        local line = "  - " .. nameOf(self, flyout.name) .. " (flyoutID " .. flyout.flyoutID .. ", book slot "
            .. flyout.slot .. ")"
        if tag then
            out:Add(line .. ": " .. tag)
        else
            out:Add(line .. " 알려짐(isKnown)=" .. self:Fmt(flyout.isKnown) .. " 칸=" .. self:Fmt(flyout.numSlots)
                .. (flyout.slotsTruncated and " (칸 상한 도달, truncated)" or ""))
            for _, slot in ipairs(flyout.slots) do
                local slotTag = self:Describe(slot.info)
                if slotTag then
                    out:Add("      " .. slot.index .. ": " .. slotTag)
                else
                    local v = slot.info.values
                    local text = "      " .. slot.index .. ": " .. nameOf(self, v[4]) .. " spellID=" .. self:Fmt(v[1])
                    if v[2] ~= nil and v[2] ~= v[1] then text = text .. " overrideSpellID=" .. self:Fmt(v[2]) end
                    text = text .. " 배움(isKnownSlot)=" .. self:Fmt(v[3])
                    if v[5] ~= nil and v[5] ~= 0 then text = text .. " specID=" .. self:Fmt(v[5]) end
                    out:Add(text)
                end
            end
        end
    end
end

local function extraFields(self, info)
    local keys = {}
    for key, value in pairs(info) do
        local kind = type(value)
        if not KNOWN_COOLDOWN_KEYS[key] and (kind == "boolean" or kind == "number" or kind == "string") then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. self:Fmt(info[key]) end
    return parts
end

local function cooldownText(self, info, remaining, nowTag)
    local parts = {}
    if remaining ~= nil then
        parts[#parts + 1] = "남음 " .. seconds(remaining)
    else
        parts[#parts + 1] = "남음 " .. (nowTag or "<not_collected: start/GetTime missing>")
    end
    parts[#parts + 1] = "총 " .. seconds(info.duration) .. " (start " .. self:Fmt(info.startTime) .. ")"
    parts[#parts + 1] = "isEnabled=" .. self:Fmt(info.isEnabled)
    if info.modRate ~= nil then parts[#parts + 1] = "modRate=" .. self:Fmt(info.modRate) .. " (적용 안 함)" end
    return table.concat(parts, " | ")
end

local function formatSpellCooldowns(self, block, out, nowTag)
    head(self, out, "  주문", block)
    if block.spellbookState then
        out:Add("    주문서 읽기: " .. (self:Describe(block.spellbookState) or "ok"))
    end
    if block.unsupported then
        out:Add("    " .. self:Describe(block.unsupported))
    end
    local c = block.counts
    out:Add("    확인 " .. c.checked .. "개: 사용 가능(대기 없음) " .. c.ready .. ", 대기 중 " .. c.active
        .. ", 반환 없음(nil) " .. c.noValue .. ", 제한(restricted) " .. c.restricted .. ", 오류 " .. c.errors
        .. (c.badShape > 0 and (", 예상 밖 형태 " .. c.badShape) or ""))
    out:Add("    충전형 " .. c.chargeSpells .. "개 (충전 제한 " .. c.chargesRestricted .. ", 오류 " .. c.chargesErrors .. ")")
    if c.restricted > 0 or c.chargesRestricted > 0 then
        out:Add("    <restricted: 쿨다운 값이 제한됨 (전투/인스턴스 등); 대기 없음의 증거 아님>")
    end
    out:Add("    GCD와 고유 쿨다운 구분: 문서화된 필드가 없어 판정 안 함 (같은 start/duration은 '공유 타이머'로만 표시)")
    for _, entry in ipairs(block.entries) do
        local info = self:Val(entry.cd)
        local text = "    - " .. nameOf(self, entry.name) .. " (spellID " .. entry.spellID .. ") "
        if entry.active and type(info) == "table" then
            text = text .. cooldownText(self, info, entry.remaining, nowTag)
            if entry.timerShared and entry.timerShared > 1 then
                text = text .. " | 같은 타이머 " .. entry.timerShared .. "개 (GCD 여부 미확인)"
            end
            local extra = extraFields(self, info)
            if #extra > 0 then text = text .. " | 기타 필드: " .. table.concat(extra, ",") end
        else
            text = text .. "대기 없음"
        end
        if entry.charges then
            text = text .. " | 충전 정보(필드 미검증, 원문): " .. self:Fmt(self:Val(entry.charges))
        end
        out:Add(text)
    end
    if block.entriesTruncated then
        out:Add("    ... " .. block.entriesTruncated .. "개 더 있음 (목록 상한 " .. CAP.cooldownList .. ", truncated)")
    end
    for name, sample in pairs(block.samples or {}) do
        out:Add("    예시 문제(" .. name .. "): " .. (self:Describe(sample) or "ok"))
    end
end

local function formatItemCooldowns(self, block, out, nowTag)
    head(self, out, "  착용 아이템", block, "가방 아이템은 미조사")
    local c = block.counts
    out:Add("    슬롯 " .. c.slots .. "개: 빈 슬롯 " .. c.empty .. ", 미확인 " .. c.unresolved .. ", 확인 " .. c.checked
        .. " (대기 없음 " .. c.ready .. ", 대기 중 " .. c.active .. ", 제한 " .. c.restricted .. ", 오류 " .. c.errors .. ")")
    for _, entry in ipairs(block.entries) do
        local v = entry.cd.values
        local remaining = entry.remaining ~= nil and ("남음 " .. seconds(entry.remaining))
            or ("남음 " .. (nowTag or "<not_collected: start/GetTime missing>"))
        out:Add("    - " .. entry.slotName .. " item " .. entry.itemID .. " " .. remaining .. " | 총 "
            .. seconds(v[2]) .. " (start " .. self:Fmt(v[1]) .. ") enableCooldownTimer=" .. self:Fmt(v[3]))
    end
    if block.sample then out:Add("    예시 문제: " .. (self:Describe(block.sample) or "ok")) end
end

function F.cooldowns(self, block, out, title, section)
    local nowTag = self:Describe(section.time)
    if block.state then
        head(self, out, title, block)
        return
    end
    local complete = type(block.spells) == "table" and block.spells.complete == true
        and type(block.items) == "table" and block.items.complete == true
    out:Add("### " .. title .. " [스냅샷: " .. self:Date(self:Val(section.capturedAt)) .. ", GetTime="
        .. self:Fmt(self:Val(section.time)) .. "; 값은 이 시각 기준이며 계속 변함] [완전성: "
        .. (complete and "완전" or "불완전/일부") .. "]")
    for _, part in ipairs({ { "spells", formatSpellCooldowns }, { "items", formatItemCooldowns } }) do
        local sub = block[part[1]]
        if type(sub) ~= "table" then
            out:Add("  " .. part[1] .. ": <not_collected: block missing>")
        elseif sub.state then
            head(self, out, "  " .. part[1], sub)
        else
            part[2](self, sub, out, nowTag)
        end
    end
end

function F.pvp(self, block, out, title)
    head(self, out, title, block, "랭크 원본 구조체는 currency 구역에 있음")
    local progress = self:Val(block.progression)
    if type(progress) ~= "table" then
        out:Result("  진행 정보 (C_MajorFactions.GetMajorFactionProgressionInfo " .. block.factionID .. ")",
            block.progression)
    else
        out:Add("  랭크 " .. self:Fmt(progress.renownLevel) .. " / 시즌 최대 " .. self:Fmt(progress.maxLevel)
            .. " | 현재 단계 점수 " .. self:Fmt(progress.renownReputationEarned) .. " / "
            .. self:Fmt(progress.renownLevelThreshold) .. " (평생 누적치로 해석하지 않음) | weekNumber="
            .. self:Fmt(progress.weekNumber))
        out:Add("  이번 주 상한 단계 " .. self:Fmt(progress.currentWeekProgressiveMaxLevel) .. " / 지난 주 "
            .. self:Fmt(progress.previousWeekProgressiveMaxLevel))
        local names = { current = "현재 단계", currentWeekMax = "이번 주 상한 단계", previousWeekMax = "지난 주 상한 단계",
            seasonMax = "시즌 최대 단계" }
        for _, key in ipairs({ "current", "currentWeekMax", "previousWeekMax", "seasonMax" }) do
            local result = block.totals and block.totals[key]
            if result then
                local tag = self:Describe(result)
                out:Add("  " .. names[key] .. " 도달 누적 점수 (GetTotalReputationForRenownLevel): "
                    .. (tag or self:Fmt(result.values[1])))
            end
        end
        local capTotal = block.totals and self:Val(block.totals.currentWeekMax)
        if isNumber(block.totalEarned) then
            if capTotal == 0 then
                out:Add("  누적 점수(UI 계산식: 현재 단계 총합 + 단계 점수) " .. block.totalEarned
                    .. " | 이번 주 상한: 표시 없음 (UI의 '상한 없음' 분기와 같은 0)")
            else
                out:Add("  누적 점수(UI 계산식: 현재 단계 총합 + 단계 점수) " .. block.totalEarned
                    .. " | 이번 주 상한 누적 " .. self:Fmt(capTotal))
            end
        else
            out:Add("  누적 점수: <not_collected: 단계 총합 또는 단계 점수를 읽지 못함>")
        end
        if isNumber(block.weeklyIncrease) then
            out:Add("  이번 주 상한 증가분 " .. block.weeklyIncrease)
        end
    end
    local seasonTag = self:Describe(block.seasonEnd)
    if seasonTag then
        out:Add("  시즌 종료까지: " .. seasonTag)
    else
        local secs = block.seasonEnd.values[1]
        if secs == 0 then
            out:Add("  시즌 종료까지: <not_collected: API가 0 반환 = 종료 시점 모름 (UI도 타이머를 숨김)>")
        elseif isNumber(secs) then
            out:Add("  시즌 종료까지: " .. seconds(secs) .. " (관측 시각 기준)"
                .. (block.seasonEndsAtServerTime and (", 약 " .. self:Date(block.seasonEndsAtServerTime)) or ""))
        else
            out:Add("  시즌 종료까지: <error: 예상 밖 값 " .. self:Fmt(secs) .. ">")
        end
    end
    local seasonNumberTag = self:Describe(block.season)
    if seasonNumberTag then
        out:Add("  현재 시즌 번호: " .. seasonNumberTag)
    elseif block.season.values[1] == 0 then
        out:Add("  현재 시즌 번호: 0 (UI는 0이면 시즌 표시를 숨김)")
    else
        out:Add("  현재 시즌 번호: " .. self:Fmt(block.season.values[1]))
    end
    local reward = block.reward
    if reward then
        if reward.level then
            out:Add("  다음 보상: 랭크 " .. reward.level .. " (현재 랭크 위에서 처음으로 보상이 있는 단계)")
            for _, item in ipairs(reward.items or {}) do
                local label = type(item.name) == "string" and item.name ~= "" and self:Clean(item.name) or nil
                local text = "    - " .. (label or "<not_collected: name missing>")
                if type(item.description) == "string" and item.description ~= "" then
                    text = text .. ": " .. self:Clean(item.description)
                end
                for _, key in ipairs({ "itemID", "spellID", "mountID", "titleMaskID", "renownRewardID" }) do
                    if item[key] ~= nil then text = text .. " " .. key .. "=" .. self:Fmt(item[key]) end
                end
                if item.isAccountUnlock ~= nil then text = text .. " 계정해금=" .. self:Fmt(item.isAccountUnlock) end
                out:Add(text)
            end
            if reward.itemsTruncated then out:Add("    ... 보상 목록 상한 도달 (truncated)") end
        elseif reward.truncated then
            out:Add("  다음 보상: <not_collected: " .. reward.scanned .. "단계 확인 후 상한 도달 (truncated)>")
        elseif reward.failures > 0 then
            out:Add("  다음 보상: <not_collected: " .. reward.failures .. "단계 읽기 실패; 없다는 증거 아님: "
                .. (self:Describe(reward.firstFailure) or "ok") .. ">")
        elseif reward.scanFrom > reward.scanTo then
            out:Add("  다음 보상: 현재 랭크가 시즌 최대 단계 (더 위 단계 없음)")
        else
            out:Add("  다음 보상: 랭크 " .. reward.scanFrom .. "~" .. reward.scanTo .. " 모두 보상 없음")
        end
    end
end
