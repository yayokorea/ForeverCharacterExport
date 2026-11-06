local _, Addon = ...

-- Equipment section. Evidence (pinned Blizzard UI commit, see references/upstream):
--  * Slot names: Camelot PaperDollFrame.xml frames CharacterHeadSlot ... CharacterRangedSlot, CharacterAmmoSlot;
--    PaperDollFrame.lua:1997-2000 derives the slot name by stripping "Character", and :1959 resolves the slot ID with
--    C_PaperDollInfo.GetInventorySlotInfo(slotName). Slot IDs are therefore never hardcoded here.
--  * PaperDollFrame.lua:2178-2186 (PaperDollItemSlotButton_Update): GetInventoryItemTexture("player", id) == nil
--    means the slot is empty (hasItem = textureName ~= nil). PaperDollFrameStats.lua:685 treats a nil
--    GetInventoryItemID("player", slot) as "nothing equipped" as well.
--  * Per-slot reads used by that UI: GetInventoryItemLink (:2172), GetInventoryItemID (:2221),
--    GetInventoryItemQuality (:2219), GetInventoryItemCount (:2185), GetInventoryItemBroken (:2187),
--    GetInventoryItemDurability(slotID) -> durability, maxDurability (:1598).
--  * Ranged / ammo: IsRangedSlotShown (:1933), AmmoNeeded (:1952), UnitUsesAmmo("player") (:1517),
--    UnitHasRelicSlot("player") (:2201). The Camelot UI does have a separate AmmoSlot (XML + :3669).
--  * C_Item.GetDetailedItemLevelInfo(itemInfo) and C_Item.GetItemInfoInstant(itemInfo) are declared in
--    ItemDocumentation.lua; GetItemInfoInstant(itemID) is called with an item ID in PaperDollFrameStats.lua:692.

-- Display order follows the Camelot character sheet. Entries: { slotName, label }.
local SLOTS = {
    { "HeadSlot", "Head" }, { "NeckSlot", "Neck" }, { "ShoulderSlot", "Shoulder" }, { "BackSlot", "Back" },
    { "ChestSlot", "Chest" }, { "ShirtSlot", "Shirt" }, { "TabardSlot", "Tabard" }, { "WristSlot", "Wrist" },
    { "HandsSlot", "Hands" }, { "WaistSlot", "Waist" }, { "LegsSlot", "Legs" }, { "FeetSlot", "Feet" },
    { "Finger0Slot", "Finger 1" }, { "Finger1Slot", "Finger 2" },
    { "Trinket0Slot", "Trinket 1" }, { "Trinket1Slot", "Trinket 2" },
    { "MainHandSlot", "Main hand" }, { "SecondaryHandSlot", "Off hand" }, { "RangedSlot", "Ranged/Relic" },
}
local AMMO = { "AmmoSlot", "Ammo" }

-- Display-only labels for the numeric quality (the number is always printed too).
local QUALITY = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom" }

-- A Probe that returned nothing (nil). Distinct from unsupported/restricted/error, which carry no values.
local function returnedNothing(result)
    return type(result) == "table" and result.status == "not_collected" and type(result.values) == "table"
        and result.values[1] == nil
end

-- "present" (value read), "none" (API returned nothing), "unknown" (unsupported, restricted, error, ...).
local function presence(result)
    if type(result) ~= "table" then return "unknown" end
    if result.status == "ok" then return "present" end
    if returnedNothing(result) then return "none" end
    return "unknown"
end

local function readSlot(self, entry, isAmmo)
    local slot = { slotName = entry[1], label = entry[2], isAmmo = isAmmo or nil }
    slot.info = self:Probe("C_PaperDollInfo.GetInventorySlotInfo", entry[1])
    local id = self:Val(slot.info, 1)
    if type(id) ~= "number" then
        -- Unresolved slot ID: never guess a number and never call it empty.
        slot.occupied = nil
        return slot
    end
    slot.slotID = id

    local texture = self:Probe("GetInventoryItemTexture", "player", id)
    local itemId = self:Probe("GetInventoryItemID", "player", id)
    local link = self:Probe("GetInventoryItemLink", "player", id)
    local seen = { presence(texture), presence(itemId), presence(link) }
    local hasPresent, hasNone = false, false
    for _, state in ipairs(seen) do
        if state == "present" then hasPresent = true end
        if state == "none" then hasNone = true end
    end
    if not hasPresent then
        if hasNone then
            -- UI contract: no texture / no item ID for a valid slot ID means the slot is empty.
            slot.occupied = false
            slot.emptyEvidence = "texture=" .. seen[1] .. " itemID=" .. seen[2] .. " link=" .. seen[3]
        else
            slot.occupied = nil
            slot.texture, slot.itemIdRead, slot.link = texture, itemId, link
        end
        return slot
    end

    slot.occupied = true
    slot.texture, slot.itemIdRead, slot.link = texture, itemId, link
    local linkText = self:Val(link, 1)
    local linkName, linkId = self:LinkInfo(linkText)
    slot.itemName = linkName
    slot.itemID = linkId or self:Val(itemId, 1)
    if returnedNothing(link) and type(slot.itemID) == "number" then
        -- The link is optional when the item ID was read another way (the ammo slot returns no link).
        link.info = true
        if not slot.itemName then
            slot.itemName = self:Val(self:Probe("C_Item.GetItemNameByID", slot.itemID), 1)
        end
    end
    slot.quality = self:Probe("GetInventoryItemQuality", "player", id)
    slot.count = self:Probe("GetInventoryItemCount", "player", id)
    if isAmmo then
        return slot
    end
    slot.durability = self:Probe("GetInventoryItemDurability", id)
    slot.broken = self:Probe("GetInventoryItemBroken", "player", id)
    -- No value means the item has no durability (shown as such); it is not an unread value.
    if returnedNothing(slot.durability) then slot.durability.info = true end
    if returnedNothing(slot.broken) then slot.broken.info = true end
    if type(linkText) == "string" then
        slot.itemLevel = self:Probe("C_Item.GetDetailedItemLevelInfo", linkText)
    else
        slot.itemLevel = self:State("not_collected", "no item link to query the item level with")
    end
    if type(slot.itemID) == "number" then
        slot.itemType = self:Probe("C_Item.GetItemInfoInstant", slot.itemID)
    else
        slot.itemType = self:State("not_collected", "no item ID to query the item type with")
    end

    local cur, max = self:Val(slot.durability, 1), self:Val(slot.durability, 2)
    if type(cur) == "number" and type(max) == "number" and max > 0 and cur >= 0 then
        slot.durabilityPct = cur / max * 100
    end
    return slot
end

local function collect(self)
    local section = {}
    self:Read(section, "rangedSlotShown", "C_PaperDollInfo.IsRangedSlotShown")
    self:Read(section, "ammoNeeded", "C_PaperDollInfo.AmmoNeeded")
    self:Read(section, "usesAmmo", "UnitUsesAmmo", "player")
    self:Read(section, "hasRelicSlot", "UnitHasRelicSlot", "player")

    section.slots = {}
    local summary = { total = #SLOTS, equipped = 0, empty = 0, unresolved = 0, durabilityRead = 0, broken = 0 }
    for index, entry in ipairs(SLOTS) do
        local slot = readSlot(self, entry, false)
        section.slots[index] = slot
        if slot.occupied == true then
            summary.equipped = summary.equipped + 1
            if slot.durabilityPct then
                summary.durabilityRead = summary.durabilityRead + 1
                if not summary.lowestPct or slot.durabilityPct < summary.lowestPct then
                    summary.lowestPct, summary.lowestSlot = slot.durabilityPct, slot.label
                end
            end
            local brokenFlag = self:Val(slot.broken, 1)
            local cur = self:Val(slot.durability, 1)
            if (brokenFlag and brokenFlag ~= 0) or (slot.durabilityPct and cur == 0) then
                slot.isBroken = true
                summary.broken = summary.broken + 1
            end
        elseif slot.occupied == false then
            summary.empty = summary.empty + 1
        else
            summary.unresolved = summary.unresolved + 1
        end
    end
    section.summary = summary
    section.ammo = readSlot(self, AMMO, true)
    return section
end

local function field(label, result, fmt)
    local tag = Addon:Describe(result)
    if tag then return label .. "=" .. tag end
    local text = fmt and fmt(result.values[1], result.values) or Addon:Fmt(result.values[1])
    return label .. "=" .. text
end

local function qualityText(value)
    local name = QUALITY[value]
    if name then return value .. " (" .. name .. ")" end
    return Addon:Fmt(value)
end

local function durabilityText(value, values)
    local max = values[2]
    if type(value) == "number" and type(max) == "number" and max > 0 then
        return string.format("%s/%s (%d%%)", value, max, math.floor(value / max * 100))
    end
    return Addon:Fmt(value) .. "/" .. Addon:Fmt(max)
end

local function typeText(_, values)
    return Addon:Fmt(values[2]) .. "/" .. Addon:Fmt(values[3]) .. " " .. Addon:Fmt(values[4])
end

local function slotHeader(slot)
    local id = slot.slotID and ("slot " .. slot.slotID) or "slot ID unresolved"
    return slot.label .. " (" .. slot.slotName .. ", " .. id .. ")"
end

local function slotLine(slot, section)
    local header = slotHeader(slot)
    if slot.slotID == nil then
        return header .. ": " .. (Addon:Describe(slot.info) or "<not_collected: slot ID is not a number>")
    end
    if slot.occupied == false then
        local note = ""
        if slot.slotName == "RangedSlot" and Addon:Val(section.rangedSlotShown, 1) == false then
            note = " (ranged slot not shown in UI)"
        elseif slot.isAmmo and Addon:Val(section.ammoNeeded, 1) == false then
            note = " (UI hides ammo slot: ammoNeeded=false)"
        end
        return header .. ": <empty slot>" .. note
    end
    if slot.occupied == nil then
        return header .. ": <not_collected: texture/itemID/link reads unresolved: "
            .. (Addon:Describe(slot.texture) or "?") .. ">"
    end
    local parts = {}
    local name = slot.itemName and Addon:Clean(slot.itemName) or "<not_collected: item link unavailable>"
    local ident = slot.itemID and tostring(slot.itemID) or "<not_collected: item ID unavailable>"
    parts[#parts + 1] = name .. " (" .. ident .. ")"
    parts[#parts + 1] = field("quality", slot.quality, qualityText)
    if slot.isAmmo then
        parts[#parts + 1] = field("count", slot.count)
        return header .. ": " .. table.concat(parts, "  ")
    end
    parts[#parts + 1] = field("ilvl", slot.itemLevel)
    local count = Addon:Val(slot.count, 1)
    if type(count) ~= "number" or count > 1 then
        parts[#parts + 1] = field("count", slot.count)
    end
    if slot.durability.status == "ok" then
        parts[#parts + 1] = field("durability", slot.durability, durabilityText)
    else
        local tag = Addon:Describe(slot.durability)
        if returnedNothing(slot.durability) then
            tag = "none reported (item may not have durability)"
        end
        parts[#parts + 1] = "durability=" .. tag
    end
    if slot.isBroken then
        parts[#parts + 1] = "BROKEN"
    elseif slot.broken.status ~= "ok" and not returnedNothing(slot.broken) then
        parts[#parts + 1] = "broken=" .. Addon:Describe(slot.broken)
    end
    parts[#parts + 1] = field("type", slot.itemType, typeText)
    return header .. ": " .. table.concat(parts, "  ")
end

local function render(_, section, out)
    out:Result("ranged slot shown", section.rangedSlotShown)
    out:Result("ammo needed", section.ammoNeeded)
    out:Result("uses ammo", section.usesAmmo)
    out:Result("has relic slot", section.hasRelicSlot)
    local s = section.summary or {}
    local lowest = s.lowestPct and string.format("%d%% (%s)", math.floor(s.lowestPct), s.lowestSlot or "?")
        or "<not_collected: no durability value read>"
    out:Add(string.format("summary: equipped %d/%d slots, empty %d, unresolved %d; lowest durability %s; "
        .. "broken items %d; durability read for %d items",
        s.equipped or 0, s.total or 0, s.empty or 0, s.unresolved or 0, lowest, s.broken or 0,
        s.durabilityRead or 0))
    for _, slot in ipairs(section.slots or {}) do
        out:Add(slotLine(slot, section))
    end
    if section.ammo then
        out:Add(slotLine(section.ammo, section))
        out:Add("note: the ammo slot count may be the same arrows as the bags 'ammo:' total; do not add them")
    end
end

Addon:RegisterCollector("equipment", collect, render)
