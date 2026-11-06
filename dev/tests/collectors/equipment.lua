-- Mocked contract tests for the equipment collector. Not a WoW runtime.
local Addon = AddonUnderTest

local NAMES = {
    "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot", "WristSlot",
    "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot", "Trinket0Slot",
    "Trinket1Slot", "MainHandSlot", "SecondaryHandSlot", "RangedSlot", "AmmoSlot",
}
-- Arbitrary mock IDs (the addon must take whatever the API returns): slot i has ID i, ranged = 18 as in the real client.
local function mockIds()
    local ids = {}
    for i, name in ipairs(NAMES) do ids[name] = i end
    ids.RangedSlot, ids.AmmoSlot, ids.SecondaryHandSlot = 18, 0, 17
    ids.MainHandSlot = 21
    return ids
end

local function link(id, name)
    return "|cff1eff00|Hitem:" .. id .. ":0:0:0|h[" .. name .. "]|h|r"
end

-- items[slotID] = { id=, name=, tex=, quality=, count=, dur={cur,max}|nil, broken=, ilvl= }
local function world(items, extra)
    local ids = mockIds()
    local env = {
        ["C_PaperDollInfo"] = {
            IsRangedSlotShown = function() return true end,
            AmmoNeeded = function() return true end,
            GetInventorySlotInfo = function(slotName)
                if ids[slotName] == nil then return end
                return ids[slotName], 134400, slotName == "RangedSlot"
            end,
        },
        ["C_Item"] = {
            GetDetailedItemLevelInfo = function(l)
                local id = tonumber(string.match(l, "item:(%d+)"))
                for _, item in pairs(items) do
                    if item.id == id and item.ilvl then return item.ilvl, false, item.ilvl end
                end
            end,
            GetItemInfoInstant = function(id) return id, "Armor", "Leather", "INVTYPE_CHEST", 1, 4, 2 end,
        },
        UnitUsesAmmo = function() return true end,
        UnitHasRelicSlot = function() return false end,
        GetInventoryItemTexture = function(_, slot) return items[slot] and items[slot].tex or nil end,
        GetInventoryItemID = function(_, slot) return items[slot] and items[slot].id or nil end,
        GetInventoryItemLink = function(_, slot)
            local item = items[slot]
            return item and link(item.id, item.name) or nil
        end,
        GetInventoryItemQuality = function(_, slot) return items[slot] and items[slot].quality or nil end,
        GetInventoryItemCount = function(_, slot) return items[slot] and (items[slot].count or 1) or nil end,
        GetInventoryItemBroken = function(_, slot) return items[slot] and items[slot].broken and 1 or nil end,
        GetInventoryItemDurability = function(slot)
            local dur = items[slot] and items[slot].dur
            if dur then return dur[1], dur[2] end
        end,
    }
    for key, value in pairs(extra or {}) do env[key] = value end
    return env
end

local function run()
    local section = Addon.collectors.equipment(Addon)
    local out = Addon:NewWriter()
    Addon.formatters.equipment(Addon, section, out)
    return section, out:Output()
end

local function sample()
    return {
        [1] = { id = 100, name = "Helm of Test", tex = 1, quality = 4, dur = { 90, 100 }, ilvl = 70 },
        [5] = { id = 101, name = "Chest of Test", tex = 2, quality = 3, dur = { 45, 100 }, ilvl = 66 },
        [11] = { id = 102, name = "Cracked Legs", tex = 3, quality = 2, dur = { 0, 60 }, broken = true, ilvl = 20 },
        [13] = { id = 103, name = "Ring of Test", tex = 4, quality = 3, ilvl = 60 }, -- no durability value
        [18] = { id = 2506, name = "뿔나무 곡궁", tex = 5, quality = 1, dur = { 30, 40 }, ilvl = 5 },
        [0] = { id = 2512, name = "Rough Arrow", tex = 6, quality = 1, count = 842 },
    }
end

Tests["collector.equipment.normal_data"] = function()
    WithGlobals(world(sample()), function()
        local section, text = run()
        assert(section.summary.equipped == 5, "equipped " .. tostring(section.summary.equipped))
        assert(section.summary.empty == 14 and section.summary.unresolved == 0)
        assert(string.find(text, "Head (HeadSlot, slot 1): Helm of Test (100)", 1, true), text)
        assert(string.find(text, "quality=4 (Epic)", 1, true))
        assert(string.find(text, "ilvl=70", 1, true))
        assert(string.find(text, "durability=90/100 (90%)", 1, true))
        assert(string.find(text, "type=Armor/Leather INVTYPE_CHEST", 1, true))
        -- the bow that the old output missed
        assert(string.find(text, "Ranged/Relic (RangedSlot, slot 18): 뿔나무 곡궁 (2506)", 1, true), text)
        -- summary: lowest durability comes from the broken legs (0%), broken count from the API flag
        assert(string.find(text, "lowest durability 0% (Legs)", 1, true), text)
        assert(string.find(text, "broken items 1", 1, true))
        assert(string.find(text, "BROKEN", 1, true))
        assert(string.find(text, "equipped 5/19 slots", 1, true))
        -- a ring has no durability value: reported as such, not as 0 or empty
        assert(string.find(text, "durability=none reported", 1, true))
        -- ammo slot (exists in the Camelot UI): ID 0 is a valid ID, count is printed
        assert(string.find(text, "Ammo (AmmoSlot, slot 0): Rough Arrow (2512)", 1, true), text)
        assert(string.find(text, "count=842", 1, true))
        assert(string.find(text, "ranged slot shown: true", 1, true))
    end)
end

Tests["collector.equipment.empty_slot_only_for_valid_slot_with_no_item"] = function()
    WithGlobals(world(sample()), function()
        local _, text = run()
        assert(string.find(text, "Shirt (ShirtSlot, slot 6): <empty slot>", 1, true), text)
        assert(string.find(text, "Tabard (TabardSlot, slot 7): <empty slot>", 1, true))
    end)
    -- Unresolved slot ID: never <empty slot>, never a guessed number.
    local env = world(sample())
    env["C_PaperDollInfo"].GetInventorySlotInfo = function(slotName)
        if slotName == "NeckSlot" then return end
        return mockIds()[slotName], 1, false
    end
    WithGlobals(env, function()
        local section, text = run()
        assert(string.find(text, "Neck (NeckSlot, slot ID unresolved): <not_collected", 1, true), text)
        assert(not string.find(text, "Neck (NeckSlot, slot ID unresolved): <empty slot>", 1, true))
        assert(section.summary.unresolved == 1)
        assert(section.slots[2].slotID == nil)
    end)
end

Tests["collector.equipment.truly_empty_character"] = function()
    WithGlobals(world({}), function()
        local section, text = run()
        assert(section.summary.equipped == 0 and section.summary.empty == 19)
        assert(string.find(text, "Head (HeadSlot, slot 1): <empty slot>", 1, true))
        assert(string.find(text, "lowest durability <not_collected: no durability value read>", 1, true), text)
        assert(string.find(text, "Ammo (AmmoSlot, slot 0): <empty slot>", 1, true))
    end)
end

Tests["collector.equipment.ranged_not_shown_and_ammo_hidden"] = function()
    local env = world({})
    env["C_PaperDollInfo"].IsRangedSlotShown = function() return false end
    env["C_PaperDollInfo"].AmmoNeeded = function() return false end
    WithGlobals(env, function()
        local _, text = run()
        assert(string.find(text, "RangedSlot, slot 18): <empty slot> (ranged slot not shown in UI)", 1, true), text)
        assert(string.find(text, "(UI hides ammo slot: ammoNeeded=false)", 1, true))
    end)
end

Tests["collector.equipment.missing_apis_are_unsupported_not_empty"] = function()
    WithGlobals({
        ["C_PaperDollInfo"] = false, GetInventoryItemTexture = false, GetInventoryItemID = false,
        GetInventoryItemLink = false, UnitUsesAmmo = false, UnitHasRelicSlot = false,
    }, function()
        local section, text = run()
        assert(section.rangedSlotShown.status == "unsupported")
        assert(section.summary.unresolved == 19 and section.summary.empty == 0)
        assert(not string.find(text, "<empty slot>", 1, true), text)
        assert(string.find(text, "ranged slot shown: <unsupported", 1, true))
        assert(string.find(text, "slot ID unresolved): <unsupported", 1, true))
    end)
    -- Slot IDs fine, but every item read is unsupported: unresolved, not empty.
    local env = world(sample())
    env.GetInventoryItemTexture, env.GetInventoryItemID, env.GetInventoryItemLink = nil, nil, nil
    WithGlobals(env, function()
        local section, text = run()
        assert(section.summary.unresolved == 19 and section.summary.equipped == 0)
        assert(not string.find(text, "<empty slot>", 1, true), text)
    end)
end

Tests["collector.equipment.restricted_value_is_tagged"] = function()
    local env = world(sample())
    env.GetInventoryItemDurability = function(slot)
        if slot == 1 then return FCE_SECRET, 100 end
        if slot == 5 then return 45, 100 end
    end
    env.GetInventoryItemLink = function(_, slot)
        if slot == 11 then return FCE_DENIED end
        local item = sample()[slot]
        return item and link(item.id, item.name) or nil
    end
    WithGlobals(env, function()
        local section, text = run()
        assert(section.slots[1].durability.status == "restricted")
        assert(string.find(text, "durability=<restricted", 1, true), text)
        -- the other slots are not lost
        assert(string.find(text, "Chest of Test (101)", 1, true))
        -- unreadable link for the legs: item still present (texture/ID), name tagged, ID kept
        assert(string.find(text, "Legs (LegsSlot, slot 11): <not_collected: item link unavailable> (102)", 1, true),
            text)
        assert(string.find(text, "lowest durability 45% (Chest)", 1, true), text)
    end)
end

Tests["collector.equipment.partial_failure_keeps_other_fields"] = function()
    local env = world(sample())
    env["C_Item"] = {} -- item level and item type unsupported
    env.GetInventoryItemQuality = function() error("boom") end
    WithGlobals(env, function()
        local section, text = run()
        assert(section.summary.equipped == 5)
        assert(string.find(text, "Helm of Test (100)", 1, true))
        assert(string.find(text, "ilvl=<unsupported", 1, true), text)
        assert(string.find(text, "type=<unsupported", 1, true))
        assert(string.find(text, "quality=<error", 1, true))
        assert(string.find(text, "durability=90/100 (90%)", 1, true))
    end)
end

Tests["collector.equipment.slot_ids_come_from_the_api"] = function()
    local env = world({ [77] = { id = 9, name = "Odd Helm", tex = 1, quality = 1, dur = { 1, 2 } } })
    env["C_PaperDollInfo"].GetInventorySlotInfo = function(slotName)
        if slotName == "HeadSlot" then return 77, 1, false end
        return nil
    end
    WithGlobals(env, function()
        local _, text = run()
        assert(string.find(text, "Head (HeadSlot, slot 77): Odd Helm (9)", 1, true), text)
        assert(string.find(text, "durability=1/2 (50%)", 1, true))
    end)
end
