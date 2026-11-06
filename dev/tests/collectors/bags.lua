-- Mocked contract tests for the bags collector (not a WoW runtime).
local Addon = AddonUnderTest

local ARROW = 2515
local ARROW_NAME = "뾰족한 화살"

local function link(id, name)
    return "|cffffffff|Hitem:" .. id .. "::::::::80:::::|h[" .. name .. "]|h|r"
end

-- layout[bagID] = { size, items = { [slot] = {id, name, count, quality, locked} }, name, family, bagItem = {id, name} }
local function mockContainer(layout, overrides)
    local C = {}
    function C.GetContainerNumSlots(id)
        local bag = layout[id]
        if bag then return bag.size end
    end
    function C.GetContainerNumFreeSlots(id)
        local bag = layout[id]
        if not bag then return end
        local used = 0
        for _ in pairs(bag.items or {}) do used = used + 1 end
        return bag.size - used, bag.family or 0
    end
    function C.GetBagName(id)
        local bag = layout[id]
        return bag and bag.name or nil
    end
    function C.HasContainerItem(id, slot)
        local bag = layout[id]
        return bag ~= nil and bag.items ~= nil and bag.items[slot] ~= nil
    end
    function C.GetContainerItemInfo(id, slot)
        local item = layout[id] and layout[id].items and layout[id].items[slot]
        if not item then return end
        return {
            iconFileID = 1, stackCount = item.count, isLocked = item.locked or false, quality = item.quality,
            isReadable = false, hasLoot = false, hyperlink = link(item.id, item.name), isFiltered = false,
            hasNoValue = false, itemID = item.id, isBound = false, itemName = item.name,
        }
    end
    function C.ContainerIDToInventoryID(id)
        if id >= 1 and id <= 5 then return 19 + id end
    end
    for key, fn in pairs(overrides or {}) do C[key] = fn end
    return C
end

local function mockEnum()
    return {
        BagIndex = { Keyring = -1, Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5 },
        ItemClass = { Consumable = 0, Projectile = 6, Tradegoods = 7 },
    }
end

local classes = { [ARROW] = 6, [2589] = 7, [159] = 0, [7146] = 13 }
local function mockItem()
    return {
        GetItemInfoInstant = function(id)
            if classes[id] then return id, "type", "sub", "", 0, classes[id], 0 end
        end,
    }
end

local function bagLayout()
    return {
        [0] = { size = 16, name = "Backpack", items = {
            [1] = { id = ARROW, name = ARROW_NAME, count = 200, quality = 1 },
            [2] = { id = ARROW, name = ARROW_NAME, count = 200, quality = 1 },
            [3] = { id = ARROW, name = ARROW_NAME, count = 316, quality = 1 },
            [5] = { id = 2589, name = "Linen Cloth", count = 20, quality = 1, locked = true },
        } },
        [1] = { size = 8, name = "Big Bag", bagItem = { id = 1234, name = "Big Bag" }, items = {
            [2] = { id = 159, name = "Refreshing Spring Water", count = 5, quality = 1 },
        } },
        [2] = { size = 0 }, [3] = { size = 0 }, [4] = { size = 0 }, [5] = { size = 0 },
        [-1] = { size = 4, name = "Keyring", items = { [1] = { id = 7146, name = "The Scarab Gong", count = 1 } } },
    }
end

local function run(layout, extra, fn)
    local globals = {
        Enum = mockEnum(),
        C_Container = mockContainer(layout),
        C_Item = mockItem(),
        GetInventoryItemLink = function(unit, inv)
            if unit == "player" and inv == 20 then return link(1234, "Big Bag") end
        end,
    }
    for key, value in pairs(extra or {}) do
        if value == false then globals[key] = nil else globals[key] = value end
    end
    WithGlobals(globals, function()
        local section = Addon.collectors.bags(Addon)
        local out = Addon:NewWriter()
        if section.bags then Addon.formatters.bags(Addon, section, out) end
        fn(section, out:Output())
    end)
end

local function has(text, needle, label)
    if not string.find(text, needle, 1, true) then
        error((label or "missing") .. ": " .. needle .. "\n--- output ---\n" .. text, 0)
    end
end

local function hasNot(text, needle)
    if string.find(text, needle, 1, true) then
        error("unexpected: " .. needle .. "\n--- output ---\n" .. text, 0)
    end
end

Tests["collector.bags.successful_reads_are_tallied"] = function()
    run(bagLayout(), nil, function(section)
        local counts = Addon:Tally(section)
        assert(counts.ok > 0, "successful container reads must count as ok")
        assert(counts.not_collected == 0 and counts.error == 0)
    end)
end

Tests["collector.bags.normal"] = function()
    run(bagLayout(), nil, function(section, text)
        has(text, "bag ids scanned: 0..5 + keyring -1 (not counted in slot totals)")
        has(text, "slots: 19 free / 24 total (5 used)")
        has(text, "ammo: 716 in bags (" .. ARROW_NAME .. " (" .. ARROW .. ") x716)")
        has(text, "- " .. ARROW_NAME .. " (" .. ARROW .. ") x716")
        has(text, "- Linen Cloth (2589) x20")
        has(text, "(4 types in 6 stacks, sorted by name):")
        local linen = string.find(text, "- Linen Cloth", 1, true)
        local arrow = string.find(text, "- " .. ARROW_NAME, 1, true)
        local water = string.find(text, "- Refreshing Spring Water", 1, true)
        assert(linen < water and water < arrow, "item list must be sorted by name")
        has(text, "### Bag 0 [Backpack] \"Backpack\" | size 16 | free 12")
        has(text, "[1] " .. ARROW_NAME .. " (" .. ARROW .. ") x200 quality=1")
        has(text, "[5] Linen Cloth (2589) x20 quality=1 locked")
        has(text, "empty slots (12): 4,6-16")
        has(text, "### Bag 1 [Bag_1] \"Big Bag\" | bag item: Big Bag (1234) | size 8 | free 7")
        has(text, "### Bag 2 [Bag_2]: size 0 (no container in this slot)")
        has(text, "### Bag -1 [Keyring]")
        has(text, "The Scarab Gong (7146) x1")
        assert(section.ammo.total == 716)
        -- plain data must survive the persistence guard
        local ok = Addon:Sanitize(section.bags[1])
        assert(ok, "bag data must be persistable")
        -- per-slot reads must not inflate the coverage tally: only problems and states are tagged
        local _, problems = Addon:Tally(section)
        assert(#problems == 0, "no problems expected in a healthy read")
    end)
end

Tests["collector.bags.empty_is_not_unreadable"] = function()
    local layout = { [0] = { size = 16, items = {} }, [1] = { size = 0 }, [2] = { size = 0 }, [3] = { size = 0 },
        [4] = { size = 0 }, [5] = { size = 0 }, [-1] = { size = 0 } }
    run(layout, nil, function(section, text)
        has(text, "slots: 16 free / 16 total (0 used)")
        has(text, "items: none read (all readable slots are empty)")
        has(text, "ammo: none in bags (every item type classified; none is a projectile)")
        has(text, "empty slots (16): 1-16")
        hasNot(text, "UNREADABLE")
        assert(section.bags[1].unreadableCount == 0)
    end)
end

Tests["collector.bags.unsupported_container_api"] = function()
    run(bagLayout(), { C_Container = false }, function(section, text)
        has(text, "### Bag 0 [Backpack]: <unsupported: function unavailable at runtime [C_Container.GetContainerNumSlots]>")
        has(text, "[PARTIAL: 7 container(s) unreadable")
        has(text, "NOT proof of empty")
        assert(section.bags[1].sizeState.status == "unsupported")
        local counts = Addon:Tally(section)
        assert(counts.unsupported >= 7)
    end)
end

Tests["collector.bags.restricted_slot_keeps_other_slots"] = function()
    local layout = bagLayout()
    local mock = mockContainer(layout)
    local original = mock.GetContainerItemInfo
    mock.GetContainerItemInfo = function(id, slot)
        if id == 0 and slot == 2 then return FCE_SECRET end
        return original(id, slot)
    end
    run(layout, { C_Container = mock }, function(section, text)
        has(text, "[PARTIAL: 1 slot(s) unreadable]")
        has(text, "UNREADABLE slots (1, not proof of empty):")
        has(text, "[2] <restricted: API returned a secret or inaccessible value [C_Container.GetContainerItemInfo]>")
        has(text, "[1] " .. ARROW_NAME .. " (" .. ARROW .. ") x200")
        has(text, "[3] " .. ARROW_NAME .. " (" .. ARROW .. ") x316")
        has(text, "ammo: 516 in bags")
        has(text, "[PARTIAL: some items/slots could not be read or classified]")
        has(text, "empty slots (12): 4,6-16")
        assert(section.bags[1].unreadable[1].status == "restricted")
    end)
end

Tests["collector.bags.nil_item_info_is_not_empty"] = function()
    local layout = bagLayout()
    local mock = mockContainer(layout)
    local original = mock.GetContainerItemInfo
    mock.GetContainerItemInfo = function(id, slot)
        if id == 0 and slot == 1 then return end
        return original(id, slot)
    end
    run(layout, { C_Container = mock }, function(section, text)
        has(text, "[1] <not_collected: slot holds an item but item info was not returned "
            .. "[C_Container.GetContainerItemInfo]>")
        assert(section.bags[1].emptySlots[1] == 4, "an unreadable slot must not be listed as empty")
        assert(section.bags[1].unreadableCount == 1)
        has(text, "ammo: 516 in bags")
    end)
end

Tests["collector.bags.free_list_decides_when_hascontaineritem_missing"] = function()
    local layout = bagLayout()
    local mock = mockContainer(layout)
    mock.HasContainerItem = nil
    mock.GetContainerFreeSlots = function(id)
        local free = {}
        for slot = 1, layout[id].size do
            if not (layout[id].items and layout[id].items[slot]) then free[#free + 1] = slot end
        end
        return free
    end
    run(layout, { C_Container = mock }, function(section, text)
        has(text, "empty slots (12): 4,6-16")
        hasNot(text, "UNREADABLE")
        assert(section.bags[1].unreadableCount == 0)
    end)
    -- neither oracle available: an empty slot (nil item info) must be reported as unconfirmed, never as empty
    local blind = mockContainer(layout)
    blind.HasContainerItem = nil
    run(layout, { C_Container = blind }, function(section, text)
        has(text, "no item info and emptiness unconfirmed")
        assert(#section.bags[1].emptySlots == 0)
        assert(section.bags[1].unreadableCount == 12, "only the 4 slots with item info are readable")
    end)
end

Tests["collector.bags.partial_failure_keeps_other_bags"] = function()
    local layout = bagLayout()
    local mock = mockContainer(layout)
    local original = mock.GetContainerNumSlots
    mock.GetContainerNumSlots = function(id)
        if id == 2 then return end
        return original(id)
    end
    run(layout, { C_Container = mock }, function(section, text)
        has(text, "### Bag 2 [Bag_2]: <not_collected: API returned no value; readiness/availability unresolved "
            .. "[C_Container.GetContainerNumSlots]>")
        has(text, "[PARTIAL: 1 container(s) unreadable, see below]")
        has(text, "- " .. ARROW_NAME .. " (" .. ARROW .. ") x716")
        has(text, "### Bag 1 [Bag_1]")
    end)
end

Tests["collector.bags.ammo_states"] = function()
    -- classification API missing: no guess, no "none"
    run(bagLayout(), { C_Item = false }, function(section, text)
        has(text, "ammo: <unsupported: function unavailable at runtime; items cannot be classified [C_Item.GetItemInfoInstant]>")
        assert(section.ammo.status == "unsupported")
    end)
    -- Projectile enum missing
    local enum = mockEnum()
    enum.ItemClass = {}
    run(bagLayout(), { Enum = enum }, function(section, text)
        has(text, "ammo: <not_collected: Enum.ItemClass.Projectile unavailable; items cannot be classified>")
        assert(section.ammo.status == "not_collected")
    end)
    -- one item type unclassifiable (no cached class): the sum is reported partial
    classes[2589] = nil
    local ok, err = pcall(run, bagLayout(), nil, function(section, text)
        has(text, "ammo: 716 in bags")
        has(text, "[PARTIAL: some items/slots could not be read or classified]")
        assert(section.ammo.unclassified == 1)
    end)
    classes[2589] = 7
    assert(ok, err)
end

Tests["collector.bags.missing_enum_is_not_collected"] = function()
    WithGlobals({ Enum = {} }, function()
        local section = Addon.collectors.bags(Addon)
        assert(section.status == "not_collected" and string.find(section.reason, "Enum.BagIndex", 1, true))
    end)
end

Tests["collector.bags.bag_range_follows_inventory_constants"] = function()
    local layout = bagLayout()
    layout[6] = { size = 4, name = "Extra", items = {} }
    run(layout, { Constants = { InventoryConstants = { NumBagSlots = 5, NumReagentBagSlots = 1 } } },
        function(section, text)
            has(text, "bag ids scanned: 0..6")
            has(text, "### Bag 6")
            has(text, "slots: 23 free / 28 total")
            assert(#section.bags == 8)
        end)
end

Tests["collector.bags.item_list_cap"] = function()
    local layout = bagLayout()
    layout[0] = { size = 100, items = {} }
    for slot = 1, 90 do
        layout[0].items[slot] = { id = 10000 + slot, name = string.format("Item %03d", slot), count = 1 }
    end
    run(layout, nil, function(_, text)
        has(text, "- ... 12 more item types omitted")
        has(text, "(92 types in 92 stacks, sorted by name):")
    end)
end
