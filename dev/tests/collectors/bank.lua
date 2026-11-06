-- Mocked contract tests for the bank collector and its event snapshots (not a WoW runtime).
local Addon = AddonUnderTest

local ARROW = 2515
local ARROW_NAME = "뾰족한 화살"

local function link(id, name)
    return "|cffffffff|Hitem:" .. id .. "::::::::80:::::|h[" .. name .. "]|h|r"
end

-- layout[containerID] = { size, items = { [slot] = {id, name, count, quality} } }
local function mockContainer(layout)
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
        return bag.size - used, 0
    end
    function C.GetBagName(id)
        return layout[id] and layout[id].name or nil
    end
    function C.HasContainerItem(id, slot)
        local bag = layout[id]
        return bag ~= nil and bag.items ~= nil and bag.items[slot] ~= nil
    end
    function C.GetContainerItemInfo(id, slot)
        local item = layout[id] and layout[id].items and layout[id].items[slot]
        if not item then return end
        return {
            iconFileID = 1, stackCount = item.count, isLocked = false, quality = item.quality, isReadable = false,
            hasLoot = false, hyperlink = link(item.id, item.name), isFiltered = false, hasNoValue = false,
            itemID = item.id, isBound = false, itemName = item.name,
        }
    end
    return C
end

local function bankLayout()
    return {
        [6] = { size = 28, name = "Bank", items = {
            [1] = { id = ARROW, name = ARROW_NAME, count = 1000, quality = 1 },
            [4] = { id = 2589, name = "Linen Cloth", count = 60, quality = 1 },
        } },
        [7] = { size = 14, name = "Bank Bag 2", items = {
            [3] = { id = 4306, name = "Silk Cloth", count = 20, quality = 1 },
        } },
        [15] = { size = 98, name = "Warband Tab 1", items = {
            [1] = { id = 6948, name = "Hearthstone", count = 1, quality = 1 },
        } },
    }
end

local function mockBank(overrides)
    local bank = {
        CanViewBank = function(bankType) return bankType == 0 or bankType == 2 end,
        FetchPurchasedBankTabData = function(bankType)
            if bankType == 0 then
                return { { ID = 6, bankType = 0, name = "Bank" }, { ID = 7, bankType = 0, name = "Bag 2" } }
            end
            return { { ID = 15, bankType = 2, name = "Warband 1" } }
        end,
    }
    for key, fn in pairs(overrides or {}) do bank[key] = fn end
    return bank
end

local function mockEnum()
    return {
        BankType = { Character = 0, Guild = 1, Account = 2 },
        PlayerInteractionType = { Banker = 8, GuildBanker = 10, CharacterBanker = 67, AccountBanker = 68 },
    }
end

-- Runs fn with a fresh SavedVariables table and bank state; restores the shared addon table afterwards.
local function withBank(layout, extra, fn)
    local saved = { Addon.db, Addon.bankOpen, Addon.bankDirty, Addon.bankSnapshotNote }
    Addon.db = { snapshots = {} }
    Addon.bankOpen, Addon.bankDirty, Addon.bankSnapshotNote = nil, nil, nil
    local globals = { Enum = mockEnum(), C_Container = mockContainer(layout), C_Bank = mockBank() }
    for key, value in pairs(extra or {}) do
        if value == false then globals[key] = nil else globals[key] = value end
    end
    local ok, err = pcall(WithGlobals, globals, fn)
    Addon.db, Addon.bankOpen, Addon.bankDirty, Addon.bankSnapshotNote = saved[1], saved[2], saved[3], saved[4]
    if not ok then error(err, 0) end
end

local function report()
    local section = Addon.collectors.bank(Addon)
    local out = Addon:NewWriter()
    Addon.formatters.bank(Addon, section, out)
    return section, out:Output()
end

local function fire(event, ...)
    Addon.Dispatch(nil, event, ...)
end

local function has(text, needle)
    if not string.find(text, needle, 1, true) then
        error("missing: " .. needle .. "\n--- output ---\n" .. text, 0)
    end
end

local function hasNot(text, needle)
    if string.find(text, needle, 1, true) then
        error("unexpected: " .. needle .. "\n--- output ---\n" .. text, 0)
    end
end

Tests["collector.bank.no_snapshot_says_open_the_bank"] = function()
    withBank(bankLayout(), nil, function()
        local section, text = report()
        has(text, "bank: <not_collected: no snapshot stored yet; open the bank once>")
        assert(section.snapshotState.status == "not_collected")
        assert(section.open == false)
        local _, problems = Addon:Tally(section)
        assert(#problems == 1, "the missing snapshot must be counted as an unread value")
    end)
end

Tests["collector.bank.open_event_snapshots_and_formats_stale"] = function()
    withBank(bankLayout(), nil, function()
        fire("BANKFRAME_OPENED")
        assert(Addon.bankOpen == true)
        local entry = Addon:Persisted("bank")
        assert(entry and entry.capturedAt == 123456, "snapshot stored with a capture time")
        assert(entry.data.trigger == "BANKFRAME_OPENED")
        -- open at export time: live read, labelled as such, stored snapshot only referenced
        local _, live = report()
        has(live, "bank is OPEN now: live read below (not a stored snapshot)")
        has(live, "### Character bank (BankType 0)")
        has(live, "slots: 39 free / 42 total (3 used)")
        has(live, "- " .. ARROW_NAME .. " (" .. ARROW .. ") x1000")
        has(live, "### Bag 6 Bank | size 28 | free 26")
        has(live, "[1] " .. ARROW_NAME .. " (" .. ARROW .. ") x1000 quality=1")
        has(live, "### Account bank (BankType 2)")
        has(live, "- Hearthstone (6948) x1")
        has(live, "bank last stored snapshot: [stale snapshot captured")
        -- closed: only the stale snapshot, even when the live API now returns nothing
        fire("BANKFRAME_CLOSED")
        assert(Addon.bankOpen == false)
        WithGlobals({ C_Container = mockContainer({}) }, function()
            local section, text = report()
            assert(section.live == nil)
            has(text, "bank: [stale snapshot captured")
            has(text, "not a live read]")
            has(text, "trigger: BANKFRAME_OPENED")
            has(text, "- Silk Cloth (4306) x20")
            has(text, "empty slots (26): 2-3,5-28")
            hasNot(text, "OPEN now")
            hasNot(text, "no snapshot stored yet")
        end)
    end)
end

Tests["collector.bank.interaction_manager_filters_bank_types"] = function()
    withBank(bankLayout(), nil, function()
        fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 10) -- guild banker: not this bank
        fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW") -- missing payload must not throw or open
        assert(not Addon.bankOpen and not Addon:Persisted("bank"))
        fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 67)
        assert(Addon.bankOpen == true)
        assert(Addon:Persisted("bank").data.trigger == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
        fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 10)
        assert(Addon.bankOpen == true, "hiding another interaction must not close the bank state")
        fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 67)
        assert(Addon.bankOpen == false)
    end)
end

Tests["collector.bank.changes_are_stored_only_while_open"] = function()
    local layout = bankLayout()
    withBank(layout, nil, function()
        fire("BAG_UPDATE_DELAYED")
        fire("BANK_TABS_CHANGED", 0)
        assert(not Addon:Persisted("bank"), "no snapshot while the bank is closed")
        fire("BANKFRAME_OPENED")
        layout[7].items[5] = { id = 5500, name = "Mithril Bar", count = 3, quality = 1 }
        fire("PLAYERBANKSLOTS_CHANGED", 5)
        assert(Addon.bankDirty == true)
        local before = Addon:Persisted("bank")
        assert(not before.data.types[1].tabs[2].items[2], "slot event must not rewrite the snapshot")
        fire("BAG_UPDATE_DELAYED")
        assert(Addon.bankDirty == nil)
        local after = Addon:Persisted("bank")
        assert(after.data.trigger == "BAG_UPDATE_DELAYED")
        assert(after.data.types[1].tabs[2].items[2].name == "Mithril Bar")
        fire("BANKFRAME_CLOSED")
        layout[7].items[6] = { id = 5501, name = "Never Seen", count = 1 }
        fire("BAG_UPDATE_DELAYED")
        assert(Addon:Persisted("bank").data.types[1].tabs[2].items[3] == nil, "closed bank is not re-read")
    end)
end

Tests["collector.bank.unsupported_bank_api_keeps_old_snapshot"] = function()
    withBank(bankLayout(), nil, function()
        fire("BANKFRAME_OPENED")
        local first = Addon:Persisted("bank")
        assert(first)
        WithGlobals({ C_Bank = {} }, function()
            fire("BAG_UPDATE_DELAYED")
            assert(Addon:Persisted("bank") == first, "a failed read must not replace a good snapshot")
            assert(string.find(Addon.bankSnapshotNote, "not stored", 1, true))
            local section, text = report()
            has(text, "bank is OPEN now: live read below")
            has(text, "tabs: <unsupported: function unavailable at runtime [C_Bank.FetchPurchasedBankTabData]>")
            has(text, "live read produced no readable container; falling back to the stored snapshot (stale):")
            has(text, "bank: [stale snapshot captured")
            has(text, "- Silk Cloth (4306) x20")
            has(text, "last snapshot attempt this session: BAG_UPDATE_DELAYED: not stored")
            assert(section.live.readableBags == 0)
        end)
    end)
end

Tests["collector.bank.no_c_bank_never_creates_snapshot"] = function()
    withBank(bankLayout(), { C_Bank = false }, function()
        fire("BANKFRAME_OPENED")
        assert(Addon.bankOpen == true and not Addon:Persisted("bank"))
        local _, text = report()
        has(text, "tabs: <unsupported")
        has(text, "bank: <not_collected: no snapshot stored yet; open the bank once>")
    end)
end

Tests["collector.bank.account_bank_not_viewable_is_stated"] = function()
    withBank(bankLayout(), { C_Bank = mockBank({
        CanViewBank = function(bankType) return bankType == 0 end,
    }) }, function()
        fire("BANKFRAME_OPENED")
        local _, text = report()
        has(text, "### Account bank (BankType 2)")
        has(text, "not viewable (C_Bank.CanViewBank returned false)")
        has(text, "### Character bank (BankType 0)")
        hasNot(text, "Hearthstone")
    end)
end

Tests["collector.bank.empty_and_nil_tab_lists_are_distinct"] = function()
    -- explicit empty list: no purchased tabs; nil: not collected (never "none")
    local bank = mockBank({
        FetchPurchasedBankTabData = function() end,
        CanViewBank = function(bankType) if bankType == 0 then return end return false end,
    })
    withBank(bankLayout(), { C_Bank = bank }, function()
        fire("BANKFRAME_OPENED")
        local _, text = report()
        has(text, "view check: <not_collected: API returned no value; readiness/availability unresolved "
            .. "[C_Bank.CanViewBank]>")
        has(text, "tabs: <not_collected: API returned no value; readiness/availability unresolved "
            .. "[C_Bank.FetchPurchasedBankTabData]>")
        hasNot(text, "none purchased")
    end)
    local emptyList = mockBank({ FetchPurchasedBankTabData = function() return {} end })
    withBank(bankLayout(), { C_Bank = emptyList }, function()
        fire("BANKFRAME_OPENED")
        local _, text = report()
        has(text, "tabs: none purchased (C_Bank.FetchPurchasedBankTabData returned an empty list)")
        assert(not Addon:Persisted("bank"), "a bank with no readable container is not stored")
    end)
end

Tests["collector.bank.restricted_slot_and_bad_tab_do_not_erase_the_rest"] = function()
    local layout = bankLayout()
    local mock = mockContainer(layout)
    local original = mock.GetContainerItemInfo
    mock.GetContainerItemInfo = function(id, slot)
        if id == 6 and slot == 4 then return FCE_SECRET end
        return original(id, slot)
    end
    mock.GetContainerNumSlots = (function(inner)
        return function(id)
            if id == 7 then return end
            return inner(id)
        end
    end)(mock.GetContainerNumSlots)
    withBank(layout, { C_Container = mock }, function()
        fire("BANKFRAME_OPENED")
        fire("BANKFRAME_CLOSED")
        local entry = Addon:Persisted("bank")
        assert(entry, "partial data is still stored")
        local _, text = report()
        has(text, "[PARTIAL: 1 container(s) unreadable, see below]")
        has(text, "[PARTIAL: 1 slot(s) unreadable]")
        has(text, "[4] <restricted: API returned a secret or inaccessible value [C_Container.GetContainerItemInfo]>")
        has(text, "### Bag 7: <not_collected: API returned no value; readiness/availability unresolved "
            .. "[C_Container.GetContainerNumSlots]>")
        has(text, "[1] " .. ARROW_NAME .. " (" .. ARROW .. ") x1000")
        has(text, "- Hearthstone (6948) x1")
        local section = Addon.collectors.bank(Addon)
        local _, problems = Addon:Tally(section)
        assert(#problems >= 2, "stale unreadable values still show in the coverage footer")
    end)
end

Tests["collector.bank.snapshot_without_saved_variables_is_reported"] = function()
    withBank(bankLayout(), nil, function()
        Addon.db = nil
        fire("BANKFRAME_OPENED")
        assert(string.find(Addon.bankSnapshotNote, "saved variables not loaded", 1, true))
        local _, text = report()
        has(text, "bank is OPEN now")
        has(text, "### Character bank (BankType 0)")
    end)
end
