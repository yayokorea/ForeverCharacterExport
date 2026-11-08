local _, Addon = ...
-- luacheck: read globals Constants

-- Bags (live read) plus the container helpers shared with Bank.lua (which loads after this file).
--
-- Evidence (all under references/upstream/Interface/AddOns/):
--  * Bag index enum (Backpack 0 .. Bag_4 4, ReagentBag 5, Keyring -1): Blizzard_APIDocumentationGenerated/
--    BagIndexConstantsDocumentation.lua. Held bags are Backpack..NUM_TOTAL_BAG_FRAMES
--    (NumBagSlots + NumReagentBagSlots): Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua:1-3,80,400.
--    Camelot bag bar has backpack, 4 bag slots, a reagent bag slot and a keyring:
--    Blizzard_MainMenuBarBagButtons/Camelot/MainMenuBarBagButtons.xml:57-78,
--    Camelot/MainMenuBarBagButtons.lua (KEYRING_CONTAINER).
--  * C_Container.GetContainerNumSlots / GetContainerNumFreeSlots / GetContainerItemInfo / HasContainerItem /
--    GetBagName / ContainerIDToInventoryID: ContainerDocumentation.lua (ContainerItemInfo struct at :766);
--    UI use: ContainerFrame.lua:120-126,925,2081 (GetInventoryItemLink("player", ContainerIDToInventoryID(id))),
--    MainMenuBarBagButtons.lua (Shared):273-320.
--  * Ammo: C_Item.GetItemInfoInstant returns classID as 6th value (ItemDocumentation.lua:659-678; used
--    Shared/MainMenuBarBagButtons.lua:257); Enum.ItemClass.Projectile (ItemConstantsDocumentation.lua:282).


local floor = math.floor

-- A State table with the failing API attached (counted by Addon:Tally).
local function stateFrom(result)
    local status = result.status
    if status == "ok" then
        status = "error"
    end
    return { status = status, reason = result.reason or "unexpected value", api = result.api }
end

local function problem(status, reason, api)
    return { status = status, reason = reason, api = api }
end

local function enumName(bagID)
    local index = type(Enum) == "table" and Enum.BagIndex
    if type(index) ~= "table" then return nil end
    for name, value in pairs(index) do
        if value == bagID then return name end
    end
end

-- Returns "item", entry | "empty" | "unreadable", state. Emptiness is never inferred from a nil item info:
-- C_Container.HasContainerItem (non-nilable bool), or membership in GetContainerFreeSlots, decides it.
local function readSlot(self, bagID, slot, ctx)
    local infoApi = "C_Container.GetContainerItemInfo"
    local has = ctx.probe("C_Container.HasContainerItem", bagID, slot)
    local occupied
    if has.status == "ok" and type(has.values[1]) == "boolean" then
        occupied = has.values[1]
    else
        if not ctx.loaded then
            -- Fallback oracle, read once per container: the list of free slot indexes.
            ctx.loaded = true
            local list = self:Val(ctx.probe("C_Container.GetContainerFreeSlots", bagID), 1)
            if type(list) == "table" then
                ctx.freeSet = {}
                for _, index in pairs(list) do
                    if type(index) == "number" then ctx.freeSet[index] = true end
                end
            end
        end
        if ctx.freeSet then
            occupied = not ctx.freeSet[slot]
        end
    end
    if occupied == false then
        return "empty"
    end
    local result = ctx.probe(infoApi, bagID, slot)
    if result.status ~= "ok" then
        if result.status == "not_collected" and occupied == nil then
            local why = self:Describe(has) or "HasContainerItem gave no bool"
            local reason = "no item info and emptiness unconfirmed (" .. why .. ")"
            return "unreadable", problem("not_collected", reason, infoApi)
        elseif result.status == "not_collected" then
            return "unreadable", problem("not_collected", "slot holds an item but item info was not returned", infoApi)
        end
        return "unreadable", stateFrom(result)
    end
    local info = result.values[1]
    if type(info) ~= "table" then
        return "unreadable", problem("error", "unexpected " .. type(info) .. " item info", infoApi)
    end
    local linkName, linkID = self:LinkInfo(info.hyperlink)
    local itemID = type(info.itemID) == "number" and info.itemID or linkID
    if not itemID then
        return "unreadable", problem("error", "item info without itemID", infoApi)
    end
    if type(info.stackCount) ~= "number" then
        return "unreadable", problem("error", "item info without stackCount", infoApi)
    end
    local name = type(info.itemName) == "string" and info.itemName ~= "" and info.itemName or linkName
    return "item", {
        slot = slot,
        itemID = itemID,
        name = name,
        count = info.stackCount,
        quality = type(info.quality) == "number" and info.quality or nil,
        locked = info.isLocked == true or nil,
    }
end

-- Reads one container. Returns a small plain table (safe to persist):
--  id, enumName, name, size, free, family, emptySlots{}, items{ {slot,itemID,name,count,quality,locked} },
--  unreadable{ State+slot }, unreadableCount, sizeState/freeState (State when that value was unreadable),
--  bagItem{itemID,name} / bagItemState.
-- opts.bagItem: also read the bag item equipped in this slot. opts.noTotals: keep out of slot totals.
function Addon:ReadContainer(bagID, opts)
    opts = opts or {}
    local bag = {
        id = bagID,
        enumName = enumName(bagID),
        items = {},
        emptySlots = {},
        unreadable = {},
        unreadableCount = 0,
        noTotals = opts.noTotals or nil,
        okReads = 0,
    }
    local function probe(path, ...)
        local result = self:Probe(path, ...)
        if result.status == "ok" then bag.okReads = bag.okReads + 1 end
        return result
    end
    local sizeResult = probe("C_Container.GetContainerNumSlots", bagID)
    local size = self:Val(sizeResult, 1)
    if type(size) ~= "number" or size < 0 or size ~= floor(size) then
        bag.sizeState = stateFrom(sizeResult)
        if sizeResult.status == "ok" then
            bag.sizeState.reason = "unexpected container size value"
        end
        return bag
    end
    bag.size = size
    if size == 0 then
        bag.free = 0 -- an explicit size of 0 means there is no slot to be free
        return bag
    end

    local nameResult = probe("C_Container.GetBagName", bagID)
    local bagName = self:Val(nameResult, 1)
    if type(bagName) == "string" and bagName ~= "" then
        bag.name = bagName
    end

    local freeResult = probe("C_Container.GetContainerNumFreeSlots", bagID)
    local freeApi = self:Val(freeResult, 1)
    if type(freeApi) == "number" then
        bag.family = self:Val(freeResult, 2)
        if type(bag.family) ~= "number" then bag.family = nil end
    else
        bag.freeState = stateFrom(freeResult)
        if freeResult.status == "ok" then bag.freeState.reason = "unexpected free-slot value" end
    end

    if opts.bagItem then
        local inv = self:Val(probe("C_Container.ContainerIDToInventoryID", bagID), 1)
        if type(inv) == "number" then
            local linkResult = probe("GetInventoryItemLink", "player", inv)
            local link = self:Val(linkResult, 1)
            if type(link) == "string" then
                local itemName, itemID = self:LinkInfo(link)
                bag.bagItem = { itemID = itemID, name = itemName }
            else
                bag.bagItemState = stateFrom(linkResult)
            end
        else
            bag.bagItemState = problem("not_collected", "no inventory slot for this container id",
                "C_Container.ContainerIDToInventoryID")
        end
    end

    local ctx = { probe = probe }

    local last = size
    for slot = 1, last do
        local kind, payload = readSlot(self, bagID, slot, ctx)
        if kind == "item" then
            bag.items[#bag.items + 1] = payload
        elseif kind == "empty" then
            bag.emptySlots[#bag.emptySlots + 1] = slot
        else
            bag.unreadableCount = bag.unreadableCount + 1
            payload.slot = slot
            bag.unreadable[#bag.unreadable + 1] = payload
            if payload.status == "unsupported" then
                -- Every remaining slot would fail the same way.
                bag.unreadableCount = bag.unreadableCount + (last - slot)
                break
            end
        end
    end

    if type(freeApi) == "number" then
        bag.free = freeApi
        if bag.unreadableCount == 0 and freeApi ~= #bag.emptySlots then
            bag.freeMismatch = #bag.emptySlots
        end
    elseif bag.unreadableCount == 0 then
        bag.free = #bag.emptySlots
        bag.freeCounted = true
    end
    return bag
end

-- Totals and the aggregated item list over a list of bags (as returned by ReadContainer).
function Addon:SummarizeContainers(bags)
    local summary = {
        total = 0, free = 0, special = 0, unreadBags = 0, unreadableSlots = 0, freeUnknown = 0, stacks = 0, items = {},
    }
    local byID = {}
    for _, bag in ipairs(bags) do
        if type(bag.size) ~= "number" then
            summary.unreadBags = summary.unreadBags + 1
        else
            if not bag.noTotals then
                summary.total = summary.total + bag.size
                if type(bag.free) == "number" then
                    summary.free = summary.free + bag.free
                    if bag.family and bag.family ~= 0 then summary.special = summary.special + bag.free end
                else
                    summary.freeUnknown = summary.freeUnknown + 1
                end
            end
            summary.unreadableSlots = summary.unreadableSlots + bag.unreadableCount
            for _, item in ipairs(bag.items) do
                summary.stacks = summary.stacks + 1
                local entry = byID[item.itemID]
                if not entry then
                    entry = { itemID = item.itemID, name = item.name, count = 0 }
                    byID[item.itemID] = entry
                    summary.items[#summary.items + 1] = entry
                end
                entry.count = entry.count + item.count
                entry.name = entry.name or item.name
            end
        end
    end
    table.sort(summary.items, function(a, b)
        if (a.name == nil) ~= (b.name == nil) then return a.name ~= nil end
        if a.name ~= b.name then return a.name < b.name end
        return a.itemID < b.itemID
    end)
    return summary
end

local function ranges(list)
    local parts, first, prev = {}, nil, nil
    local function flush()
        if first then
            parts[#parts + 1] = first == prev and tostring(first) or (first .. "-" .. prev)
        end
    end
    for _, value in ipairs(list) do
        if prev and value == prev + 1 then
            prev = value
        else
            flush()
            first, prev = value, value
        end
    end
    flush()
    return table.concat(parts, ",")
end

local function itemText(self, name, itemID)
    return (name and self:Clean(name) or "<not_collected: name not cached>") .. " (" .. tostring(itemID) .. ")"
end

local function bagHeader(self, bag)
    local text = "### Bag " .. tostring(bag.id)
    if bag.enumName then text = text .. " [" .. bag.enumName .. "]" end
    if bag.tabName then text = text .. " " .. self:Clean(bag.tabName) end
    if bag.name and bag.name ~= bag.tabName then text = text .. " \"" .. self:Clean(bag.name) .. "\"" end
    if bag.bagItem then
        text = text .. " | bag item: " .. itemText(self, bag.bagItem.name, bag.bagItem.itemID)
    elseif bag.bagItemState then
        text = text .. " | bag item: " .. (self:Describe(bag.bagItemState) or "?")
    end
    return text
end

-- Prints totals, then an aggregated item list, then every container. opts: afterTotals(summary)
-- (called right after the totals line, used for the ammo line).
function Addon:WriteContainers(out, bags, opts)
    opts = opts or {}
    local summary = self:SummarizeContainers(bags)

    local line = "slots: " .. summary.free .. " free / " .. summary.total .. " total"
    if summary.freeUnknown == 0 then
        line = line .. " (" .. (summary.total - summary.free) .. " used)"
    end
    if summary.special > 0 then
        line = line .. "; " .. summary.special .. " of the free slots are in special-family bags (not general space)"
    end
    if summary.freeUnknown > 0 then
        line = line .. " [PARTIAL: free count unreadable for " .. summary.freeUnknown .. " container(s)]"
    end
    if summary.unreadBags > 0 then
        line = line .. " [PARTIAL: " .. summary.unreadBags .. " container(s) unreadable, see below]"
    end
    if summary.unreadableSlots > 0 then
        line = line .. " [PARTIAL: " .. summary.unreadableSlots .. " slot(s) unreadable]"
    end
    out:Add(line)
    if opts.afterTotals then opts.afterTotals(summary) end

    if #summary.items == 0 then
        out:Add("items: none read (" .. (summary.unreadBags + summary.unreadableSlots > 0
            and "NOT proof of empty: some containers/slots were unreadable" or "all readable slots are empty") .. ")")
    else
        out:Add("items (" .. #summary.items .. " types in " .. summary.stacks .. " stacks, sorted by name):")
        for _, item in ipairs(summary.items) do
            out:Add("- " .. itemText(self, item.name, item.itemID) .. " x" .. item.count)
        end
    end

    for _, bag in ipairs(bags) do
        if type(bag.size) ~= "number" then
            out:Add("### Bag " .. tostring(bag.id) .. (bag.enumName and (" [" .. bag.enumName .. "]") or "")
                .. ": " .. (self:Describe(bag.sizeState) or "<not_collected: size unreadable>"))
        elseif bag.size == 0 then
            out:Add("### Bag " .. tostring(bag.id) .. (bag.enumName and (" [" .. bag.enumName .. "]") or "")
                .. ": size 0 (no container in this slot)")
        else
            local head = bagHeader(self, bag) .. " | size " .. bag.size .. " | free "
                .. (bag.free ~= nil and tostring(bag.free) or (self:Describe(bag.freeState) or "<not_collected>"))
            if bag.freeCounted then head = head .. " (counted)" end
            if bag.family and bag.family ~= 0 then head = head .. " | bagFamily " .. bag.family end
            out:Add(head)
            if bag.freeMismatch then
                out:Add("  [free-slot API and counted empty slots disagree: " .. tostring(bag.free) .. " vs "
                    .. bag.freeMismatch .. "]")
            end
            for _, item in ipairs(bag.items) do
                out:Add("  [" .. item.slot .. "] " .. itemText(self, item.name, item.itemID) .. " x" .. item.count
                    .. (item.quality and (" quality=" .. item.quality) or "") .. (item.locked and " locked" or ""))
            end
            if #bag.emptySlots > 0 then
                out:Add("  empty slots (" .. #bag.emptySlots .. "): " .. ranges(bag.emptySlots))
            end
            if bag.unreadableCount > 0 then
                out:Add("  UNREADABLE slots (" .. bag.unreadableCount .. ", not proof of empty):")
                for _, state in ipairs(bag.unreadable) do
                    out:Add("  [" .. tostring(state.slot) .. "] " .. (self:Describe(state) or "?"))
                end
                if bag.unreadableCount > #bag.unreadable then
                    out:Add("  ... " .. (bag.unreadableCount - #bag.unreadable) .. " more unreadable slots")
                end
            end
        end
    end
    return summary
end

-- Held bag ids: Backpack .. (NumBagSlots + NumReagentBagSlots), like the base UI's NUM_TOTAL_BAG_FRAMES loops.
local function bagIDs()
    local index = type(Enum) == "table" and Enum.BagIndex
    if type(index) ~= "table" then
        return nil, "Enum.BagIndex unavailable; bag ids unknown"
    end
    local first = index.Backpack
    if type(first) ~= "number" then
        return nil, "Enum.BagIndex.Backpack unavailable; bag ids unknown"
    end
    local last, source = index.ReagentBag, "Enum.BagIndex.ReagentBag"
    local constants = type(Constants) == "table" and Constants.InventoryConstants
    if type(constants) == "table" and type(constants.NumBagSlots) == "number"
        and type(constants.NumReagentBagSlots) == "number" then
        last = first + constants.NumBagSlots + constants.NumReagentBagSlots
        source = "Constants.InventoryConstants NumBagSlots+NumReagentBagSlots"
    end
    if type(last) ~= "number" or last < first or last - first > 20 then
        return nil, "bag id range unreadable (ReagentBag/InventoryConstants unavailable)"
    end
    local ids = {}
    for id = first, last do ids[#ids + 1] = id end
    return ids, source, type(index.Keyring) == "number" and index.Keyring or nil
end

-- Sum of stacks whose class is Projectile. Only claims "none" when every item type was classified.
local function computeAmmo(self, summary)
    local projectile = type(Enum) == "table" and type(Enum.ItemClass) == "table" and Enum.ItemClass.Projectile
    if type(projectile) ~= "number" then
        return self:State("not_collected", "Enum.ItemClass.Projectile unavailable; items cannot be classified")
    end
    local api = "C_Item.GetItemInfoInstant"
    local ammo = { total = 0, items = {}, unclassified = 0 }
    for _, item in ipairs(summary.items) do
        local result = self:Probe(api, item.itemID)
        if result.status == "unsupported" then
            local state = self:State("unsupported", "function unavailable at runtime; items cannot be classified")
            state.api = api
            return state
        end
        local classID = self:Val(result, 6)
        if type(classID) ~= "number" then
            ammo.unclassified = ammo.unclassified + 1
        elseif classID == projectile then
            ammo.total = ammo.total + item.count
            ammo.items[#ammo.items + 1] = item
        end
    end
    if ammo.unclassified > 0 then
        ammo.unclassifiedState = problem("not_collected", ammo.unclassified .. " item type(s) not classified", api)
    end
    return ammo
end

Addon:RegisterCollector("bags", function(self)
    local ids, source, keyring = bagIDs()
    if not ids then
        return self:State("not_collected", source)
    end
    local section = { bagIdSource = source, ids = { ids[1], ids[#ids] }, bags = {} }
    for _, id in ipairs(ids) do
        section.bags[#section.bags + 1] = self:ReadContainer(id, { bagItem = id ~= ids[1] })
    end
    if keyring then
        section.bags[#section.bags + 1] = self:ReadContainer(keyring, { noTotals = true })
        section.keyringId = keyring
    end
    section.ammo = computeAmmo(self, self:SummarizeContainers(section.bags))
    return section
end, function(self, section, out)
    if type(section) ~= "table" or type(section.bags) ~= "table" then
        out:Add("<not_collected: bag section missing>")
        return
    end
    local ids = section.ids or {}
    out:Add("bag ids scanned: " .. tostring(ids[1]) .. ".." .. tostring(ids[2])
        .. (section.keyringId and (" + keyring " .. section.keyringId .. " (not counted in slot totals)") or "")
        .. " [range from " .. tostring(section.bagIdSource) .. "]")
    self:WriteContainers(out, section.bags, {
        afterTotals = function(summary)
            local ammo = section.ammo
            if type(ammo) == "table" and ammo.status == nil and ammo.total ~= nil then
                local partial = ammo.unclassified + summary.unreadableSlots + summary.unreadBags
                if ammo.total > 0 then
                    local parts = {}
                    for _, item in ipairs(ammo.items) do
                        parts[#parts + 1] = itemText(self, item.name, item.itemID) .. " x" .. item.count
                    end
                    out:Add("ammo: " .. ammo.total .. " in bags (" .. table.concat(parts, ", ") .. ")"
                        .. (partial > 0 and " [PARTIAL: some items/slots could not be read or classified]" or ""))
                elseif partial > 0 then
                    out:Add("ammo: <not_collected: none seen, but some items/slots could not be read or classified>")
                else
                    out:Add("ammo: none in bags (every item type classified; none is a projectile)")
                end
            else
                out:Add("ammo: " .. self:Describe(ammo))
            end
        end,
    })
end)
