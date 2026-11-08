local _, Addon = ...

-- Bank (snapshot). The bank can only be read while it is open, so contents are stored by events and printed
-- as a stale snapshot. Uses Addon:ReadContainer / WriteContainers from Bags.lua (loaded first).
--
-- Evidence (references/upstream/Interface/AddOns/):
--  * Events: BANKFRAME_OPENED, BANKFRAME_CLOSED, PLAYERBANKSLOTS_CHANGED, PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED,
--    BANK_TABS_CHANGED (Blizzard_APIDocumentationGenerated/BankDocumentation.lua:382-414; Camelot/BankFrame.lua:
--    BankFrameEvents, BankItemButtonBagEvents), BAG_UPDATE_DELAYED (ContainerDocumentation.lua:677),
--    PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE with payload `type` (PlayerInteractionManagerDocumentation.lua:
--    99-120). Camelot opens the bank through the interaction manager for Enum.PlayerInteractionType.Banker /
--    CharacterBanker / AccountBanker (Mainline/BankFrameTemplates.lua:133-135).
--  * Container ids of the bank come from C_Bank.FetchPurchasedBankTabData(bankType)[i].ID and are read with
--    C_Container.GetContainerNumSlots(ID) (Camelot/BankFrame.lua GetNumPagesForBankType; BankFrameTemplates.lua:
--    1067,1127). C_Bank.CanViewBank(bankType): Camelot/BankFrame.lua RefreshPageTabs. Enum.BankType.Character /
--    Account: ItemConstantsDocumentation.lua:17-27. No bank bag id is hardcoded.


local BANK_TYPES = {
    { key = "Character", label = "Character bank" },
    { key = "Account", label = "Account bank" },
}

local function stateOf(result)
    local status = result.status
    if status == "ok" then status = "error" end
    return { status = status, reason = result.reason or "unexpected value", api = result.api }
end

-- Reads every viewable bank type. Plain, small, persistable data. Does not touch UI state.
-- data.types[i] = { key, label, bankType, viewable, tabs = {containers}, tabsState, viewState, state }
-- data.readableBags: number of containers whose size was read (0 means nothing useful, do not persist).
function Addon:ReadBank()
    local data = { types = {}, readableBags = 0, tabListOk = false }
    local enum = type(Enum) == "table" and Enum.BankType
    for _, spec in ipairs(BANK_TYPES) do
        local entry = { key = spec.key, label = spec.label, tabs = {} }
        data.types[#data.types + 1] = entry
        local bankType = type(enum) == "table" and enum[spec.key]
        if type(bankType) ~= "number" then
            entry.state = { status = "unsupported", reason = "Enum.BankType." .. spec.key .. " unavailable" }
        else
            entry.bankType = bankType
            local view = self:Probe("C_Bank.CanViewBank", bankType)
            if view.status == "ok" and view.values[1] == false then
                entry.viewable = false
            else
                if view.status == "ok" and view.values[1] == true then
                    entry.viewable = true
                else
                    entry.viewState = stateOf(view) -- unknown; still try the tab list
                end
                local tabsResult = self:Probe("C_Bank.FetchPurchasedBankTabData", bankType)
                local list = self:Val(tabsResult, 1)
                if type(list) ~= "table" then
                    entry.tabsState = stateOf(tabsResult)
                else
                    data.tabListOk = true
                    for index, tab in ipairs(list) do
                        if type(tab) == "table" and type(tab.ID) == "number" then
                            local bag = self:ReadContainer(tab.ID)
                            if type(tab.name) == "string" and tab.name ~= "" then bag.tabName = tab.name end
                            entry.tabs[#entry.tabs + 1] = bag
                            if type(bag.size) == "number" then data.readableBags = data.readableBags + 1 end
                        else
                            local api = "C_Bank.FetchPurchasedBankTabData"
                            entry.tabs[#entry.tabs + 1] = { id = index, items = {}, emptySlots = {}, unreadable = {},
                                unreadableCount = 0,
                                sizeState = { status = "error", reason = "tab entry without numeric ID", api = api } }
                        end
                    end
                end
            end
        end
    end
    return data
end

-- Persist only when the tab list was read and at least one container size was read, so a failed or premature
-- read cannot overwrite a good older snapshot.
local function snapshot(self, trigger)
    local data = self:ReadBank()
    if not data.tabListOk or data.readableBags == 0 then
        self.bankSnapshotNote = trigger .. ": not stored (tab list or container sizes unreadable)"
        return false
    end
    data.trigger = trigger
    local ok, err = self:Persist("bank", data)
    self.bankSnapshotNote = ok and nil or (trigger .. ": not stored (" .. tostring(err) .. ")")
    return ok
end

local function isBankInteraction(interactionType)
    local kinds = type(Enum) == "table" and Enum.PlayerInteractionType
    if type(kinds) ~= "table" or type(interactionType) ~= "number" then return false end
    return interactionType == kinds.Banker or interactionType == kinds.CharacterBanker
        or interactionType == kinds.AccountBanker
end

Addon:On("BANKFRAME_OPENED", function(self)
    self.bankOpen = true
    snapshot(self, "BANKFRAME_OPENED")
end)
Addon:On("BANKFRAME_CLOSED", function(self)
    self.bankOpen = false
end)
Addon:On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(self, _, interactionType)
    if isBankInteraction(interactionType) then
        self.bankOpen = true
        snapshot(self, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    end
end)
Addon:On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(self, _, interactionType)
    if isBankInteraction(interactionType) then
        self.bankOpen = false
    end
end)
-- Slot-level events can come in bursts; mark dirty and let BAG_UPDATE_DELAYED (once per batch) take the snapshot.
for _, event in ipairs({ "PLAYERBANKSLOTS_CHANGED", "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED" }) do
    Addon:On(event, function(self)
        if self.bankOpen then self.bankDirty = true end
    end)
end
Addon:On("BANK_TABS_CHANGED", function(self)
    if self.bankOpen then snapshot(self, "BANK_TABS_CHANGED") end
end)
Addon:On("BAG_UPDATE_DELAYED", function(self)
    if self.bankOpen then
        self.bankDirty = nil
        snapshot(self, "BAG_UPDATE_DELAYED")
    end
end)

Addon:RegisterCollector("bank", function(self)
    local section = { open = self.bankOpen == true }
    local entry = self:Persisted("bank")
    section.snapshot = entry
    if not entry then
        section.snapshotState = self:State("not_collected", "no snapshot stored yet; open the bank once")
    end
    section.snapshotNote = self.bankSnapshotNote
    if section.open then
        section.live = self:ReadBank()
    end
    return section
end, function(self, section, out)
    if type(section) ~= "table" then
        out:Add("<not_collected: bank section missing>")
        return
    end
    local function writeData(data)
        if type(data) ~= "table" or type(data.types) ~= "table" then
            out:Add("<error: bank data has an unexpected shape>")
            return
        end
        for _, entry in ipairs(data.types) do
            local kind = entry.bankType and (" (BankType " .. entry.bankType .. ")") or ""
            out:Add("### " .. tostring(entry.label) .. kind)
            if entry.state then
                out:Add(self:Describe(entry.state))
            elseif entry.viewable == false then
                out:Add("not viewable (C_Bank.CanViewBank returned false)")
            else
                if entry.viewState then
                    out:Add("view check: " .. self:Describe(entry.viewState))
                end
                if entry.tabsState then
                    out:Add("tabs: " .. self:Describe(entry.tabsState))
                elseif #entry.tabs == 0 then
                    out:Add("tabs: none purchased (C_Bank.FetchPurchasedBankTabData returned an empty list)")
                else
                    self:WriteContainers(out, entry.tabs)
                end
            end
        end
    end

    if section.open and section.live then
        out:Add("bank is OPEN now: live read below (not a stored snapshot)")
        writeData(section.live)
        if section.live.readableBags > 0 then
            if section.snapshot then
                local stored = out:Stale("bank last stored snapshot", section.snapshot)
                if stored then out:Add("(stored snapshot not listed: the live read above is newer)") end
            end
            return
        end
        out:Add("live read produced no readable container; falling back to the stored snapshot (stale):")
    end
    if not section.snapshot then
        out:Add("bank: <not_collected: no snapshot stored yet; open the bank once>")
    else
        local data = out:Stale("bank", section.snapshot)
        if data then
            out:Add("trigger: " .. tostring(data.trigger))
            writeData(data)
        end
    end
    if section.snapshotNote then
        out:Add("last snapshot attempt this session: " .. section.snapshotNote)
    end
end)
