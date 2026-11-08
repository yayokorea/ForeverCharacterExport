local _, Addon = ...
-- luacheck: read globals Enum

-- spelldetails: description / cast time / range / cost / learned level of the player's spellbook spells, plus
-- stats / use spell of the equipped items. Research doc candidates 06 and 09. Read-only: no data request, no
-- SpellMixin load, no tooltip, no state change.
--
-- OPT-IN DETAIL LEVEL. Default is a compact summary (counts + COMPACT_SPELLS spells, active spells first, no
-- description text). Full text is emitted only when `Addon.detail.spelldetails` is true (or the string "full"),
-- which the settings window (UI.lua) sets from ForeverCharacterExportDB.detail. nil / a non-table `Addon.detail` /
-- any other value means compact.
--
-- Evidence (paths under references/upstream/Interface/AddOns/):
--  Spell list (same walk as Collectors/Spells.lua):
--   * C_SpellBook.GetNumSpellBookSkillLines / GetSpellBookSkillLineInfo(index): Blizzard_APIDocumentationGenerated/
--     SpellBookDocumentation.lua:137,486,1028; UI loop Blizzard_PlayerSpells/Camelot/SpellBook/
--     Blizzard_SpellBookFrame.lua:118-120 (skips shouldHide lines). Slots: itemIndexOffset + 1 .. + numSpellBookItems
--     (SpellBookDocumentation.lua:1034).
--   * C_SpellBook.GetSpellBookItemInfo(slot, Enum.SpellBookSpellBank.Player): SpellBookDocumentation.lua:290,1012.
--     Fields used: spellID (nil when not a spell; the overriding spellID if overridden, :1017), itemType, name,
--     isPassive, isOffSpec. Enum.SpellBookSpellBank.Player = 0 (SpellBookConstantsDocumentation.lua:35-43);
--     SpellBookItemType Spell = 1 (SpellBookConstantsDocumentation.lua:20-32). Only itemType Spell is detailed;
--     FutureSpell, PetAction and Flyout are counted, never detailed. The Pet bank is not read.
--  Per spell (SpellIdentifier = spell ID, SpellDocumentation.lua:416-430):
--   * C_Spell.GetSpellDescription(id) -> string, MayReturnNothing: SpellDocumentation.lua:344-361 ("Returns nil if
--     spell is not found"; "May be empty if spell's data isn't loaded yet; Listen for SPELL_TEXT_UPDATE event").
--     Real call: Blizzard_SharedTalentUI/Blizzard_SharedTalentUtil.lua:101. nil and "" are kept apart here.
--   * C_Spell.GetSpellInfo(id) -> SpellInfo{name, iconID, originalIconID, castTime, minRange, maxRange, spellID}:
--     SpellDocumentation.lua:415-430 and structure :1183-1196. The documentation states no unit for castTime /
--     minRange / maxRange: they are printed as raw API numbers.
--   * C_Spell.GetSpellLevelLearned(id) -> number: SpellDocumentation.lua:432-446 ("May return a different value if
--     the player is currently Level Linked with another player"). Printed raw, 0 is not interpreted.
--   * C_Spell.GetSpellPowerCost(id) -> table of SpellPowerCostInfo, MayReturnNothing: SpellDocumentation.lua:534-551
--     ("May return nil if spell is not found or has no resource costs"). The SpellPowerCostInfo structure is NOT
--     defined anywhere in references/upstream (only named as InnerType), so its fields are UNVERIFIED: the copied
--     table is printed generically (Addon:Fmt), no field name is read. nil stays ambiguous (free vs unknown).
--  Equipped items (slot resolution identical to Collectors/Equipment.lua):
--   * C_PaperDollInfo.GetInventorySlotInfo(slotName) -> slotID: PaperDollInfoDocumentation.lua:164-179; call
--     Blizzard_UIPanels_Game/Camelot/PaperDollFrame.lua:1959. Slot names from PaperDollFrame.xml (see Equipment.lua).
--   * GetInventoryItemLink("player", slotID): PaperDollFrame.lua:2172. GetInventoryItemID: PaperDollFrame.lua:2221.
--   * C_Item.GetItemStats(itemLink) -> statTable (LuaValueVariant), MayReturnNothing: ItemDocumentation.lua:1003-1016.
--     Keys / value types are not documented: the table is printed generically, keys are not interpreted.
--   * C_Item.GetItemSpell(itemInfo) -> spellName, spellID, MayReturnNothing: ItemDocumentation.lua:969-985; real
--     call with an item ID: PaperDollFrame.lua:1819. nil means "no spell OR data not loaded" (cannot tell).
--   * C_TooltipInfo.GetInventoryItem is NOT used: it has no declaration or call site in references/upstream and the
--     TooltipData line layout is not defined anywhere we hold, so no call shape is grounded (skipped on purpose).
--  Snapshot time: GetServerTime (SystemTimeDocumentation.lua:30) through Addon:Timestamp().

local ITEM_SPELL, ITEM_FUTURE, ITEM_PET_ACTION, ITEM_FLYOUT = 1, 2, 3, 4
local COMPACT_SPELLS = 10 -- spells detailed in the default compact mode
local FULL_SPELLS = 250 -- spells detailed in full mode (cap, with a truncated marker)
local DESC_MAX = 500 -- bytes of one description printed (cap, with a truncated marker)

-- Same slot names as Collectors/Equipment.lua (that table is local there). Entries: { slotName, label }.
local SLOTS = {
    { "HeadSlot", "머리" }, { "NeckSlot", "목" }, { "ShoulderSlot", "어깨" }, { "BackSlot", "등" },
    { "ChestSlot", "가슴" }, { "ShirtSlot", "셔츠" }, { "TabardSlot", "휘장" }, { "WristSlot", "손목" },
    { "HandsSlot", "손" }, { "WaistSlot", "허리" }, { "LegsSlot", "다리" }, { "FeetSlot", "발" },
    { "Finger0Slot", "반지 1" }, { "Finger1Slot", "반지 2" },
    { "Trinket0Slot", "장신구 1" }, { "Trinket1Slot", "장신구 2" },
    { "MainHandSlot", "주무기" }, { "SecondaryHandSlot", "보조무기" }, { "RangedSlot", "원거리/성물" },
}

local function isNumber(v)
    return type(v) == "number"
end

-- SPELL_TEXT_UPDATE(spellID): SpellDocumentation.lua:1141-1149 (SynchronousEvent, payload spellID). The API docs name
-- it as the signal that a description that read as "" has loaded (SpellDocumentation.lua:358). Nothing in
-- references/upstream says that reading an empty description REQUESTS the load, so no automatic retry is done:
-- the event is only counted, and the report asks the player to export again after it has fired.
Addon.spellTextUpdates = 0
Addon:On("SPELL_TEXT_UPDATE", function(self)
    self.spellTextUpdates = (self.spellTextUpdates or 0) + 1
end)

local function playerBank()
    local banks = type(Enum) == "table" and Enum.SpellBookSpellBank
    if type(banks) == "table" and isNumber(banks.Player) then
        return banks.Player
    end
end

-- A Probe that returned nothing (nil). Distinct from unsupported / restricted / error, which carry no values.
local function returnedNothing(result)
    return type(result) == "table" and result.status == "not_collected" and type(result.values) == "table"
        and result.values[1] == nil
end

local function isFull(self)
    local detail = self.detail
    if type(detail) ~= "table" then return false end
    local flag = detail.spelldetails
    return flag == true or flag == "full"
end

-- A function missing at runtime is probed once; later calls reuse that state instead of repeating it per spell.
local function newProbe(self, missing)
    return function(api, ...)
        local known = missing[api]
        if known then
            return { status = known.status, reason = known.reason, api = api }
        end
        local result = self:Probe(api, ...)
        if result.status == "unsupported" then missing[api] = result end
        return result
    end
end

-- "" is "not loaded yet", nil is "spell not found" (SpellDocumentation.lua:349,359): never plain text, never 0/empty.
local function readDescription(self, probe, spellID)
    local result = probe("C_Spell.GetSpellDescription", spellID)
    if result.status == "ok" then
        local text = result.values[1]
        if text == "" then
            local state = self:State("not_collected",
                "description not loaded yet (API returned an empty string; SPELL_TEXT_UPDATE not awaited)")
            state.api = "C_Spell.GetSpellDescription"
            return state
        elseif type(text) ~= "string" then
            local state = self:State("error", "unexpected description type " .. type(text))
            state.api = "C_Spell.GetSpellDescription"
            return state
        end
    elseif returnedNothing(result) then
        result.reason = "API returned nothing (documented: spell not found)"
    end
    return result
end

local function readSpellFields(self, probe, entry)
    local id = entry.spellID
    entry.info = probe("C_Spell.GetSpellInfo", id)
    entry.level = probe("C_Spell.GetSpellLevelLearned", id)
    entry.cost = probe("C_Spell.GetSpellPowerCost", id)
    -- nil is "no resource cost OR spell not found": shown as an explicit ambiguity, not as an unread value.
    if returnedNothing(entry.cost) then entry.cost.info = true end
    entry.description = readDescription(self, probe, id)
end

-- Unique, learned, player-bank spells in spellbook order. Counts everything it does not list.
local function listSpells(self, section, bank)
    local count = self:Read(section, "numSkillLines", "C_SpellBook.GetNumSpellBookSkillLines")
    local counts = { slotsRead = 0, unreadable = 0, future = 0, nonSpell = 0, offSpec = 0, duplicates = 0 }
    section.counts = counts
    local list, seen = {}, {}
    if not isNumber(count) or count < 0 or count ~= math.floor(count) then
        return nil -- unusable count: the list is unknown, not empty
    end
    section.lineErrors = {}
    for index = 1, count do
        local info = self:Probe("C_SpellBook.GetSpellBookSkillLineInfo", index)
        local line = self:Val(info)
        if type(line) ~= "table" then
            section.lineErrors[#section.lineErrors + 1] = { index = index, info = info }
        elseif line.shouldHide ~= true and line.offSpecID == nil then
            local offset, size = line.itemIndexOffset, line.numSpellBookItems
            if isNumber(offset) and isNumber(size) and offset >= 0 and size >= 0 then
                for slot = offset + 1, offset + size do
                    counts.slotsRead = counts.slotsRead + 1
                    local item = self:Val(self:Probe("C_SpellBook.GetSpellBookItemInfo", slot, bank))
                    if type(item) ~= "table" then
                        counts.unreadable = counts.unreadable + 1
                    elseif item.itemType == ITEM_FUTURE then
                        counts.future = counts.future + 1
                    elseif item.isOffSpec == true then
                        counts.offSpec = counts.offSpec + 1
                    elseif item.itemType ~= ITEM_SPELL or not isNumber(item.spellID)
                        or item.itemType == ITEM_FLYOUT or item.itemType == ITEM_PET_ACTION then
                        counts.nonSpell = counts.nonSpell + 1
                    elseif seen[item.spellID] then
                        counts.duplicates = counts.duplicates + 1
                    else
                        seen[item.spellID] = true
                        list[#list + 1] = {
                            spellID = item.spellID,
                            name = type(item.name) == "string" and item.name or nil,
                            passive = item.isPassive == true or nil,
                            lineName = type(line.name) == "string" and line.name or nil,
                        }
                    end
                end
            else
                section.lineErrors[#section.lineErrors + 1] = {
                    index = index,
                    info = self:State("error", "skill line has unusable itemIndexOffset/numSpellBookItems"),
                }
            end
        end
    end
    return list
end

local function readSlot(self, entry)
    local item = { slotName = entry[1], label = entry[2] }
    item.slotInfo = self:Probe("C_PaperDollInfo.GetInventorySlotInfo", entry[1])
    local slotID = self:Val(item.slotInfo, 1)
    if not isNumber(slotID) then
        return item -- unresolved slot: never guessed, never called empty
    end
    item.slotID = slotID
    item.link = self:Probe("GetInventoryItemLink", "player", slotID)
    local linkText = self:Val(item.link, 1)
    local _, linkId = self:LinkInfo(linkText)
    local itemID = linkId
    if not isNumber(itemID) then
        item.itemIDRead = self:Probe("GetInventoryItemID", "player", slotID)
        itemID = self:Val(item.itemIDRead, 1)
    end
    if not isNumber(itemID) then
        if returnedNothing(item.link) and (item.itemIDRead == nil or returnedNothing(item.itemIDRead)) then
            item.occupied = false
            -- Both reads returned nothing for a resolved slot: that is how an empty slot reads (same rule as
            -- Collectors/Equipment.lua), so the two reads are `empty`, not unread values in the coverage list.
            for _, result in ipairs({ item.link, item.itemIDRead or false }) do
                if result then
                    result.status = "empty"
                    result.reason = "slot has no item (GetInventoryItem* returned nothing for a valid slot)"
                end
            end
        end
        return item
    end
    item.occupied = true
    item.itemID = itemID
    return item
end

local function readItem(self, probe, item, full, seenDescriptions)
    if type(self:Val(item.link, 1)) == "string" then
        item.stats = probe("C_Item.GetItemStats", self:Val(item.link, 1))
        if returnedNothing(item.stats) then item.stats.info = true end
    else
        item.stats = self:State("not_collected", "no item link to query the stats with")
    end
    -- Real call site passes an item ID (PaperDollFrame.lua:1819).
    item.spell = probe("C_Item.GetItemSpell", item.itemID)
    if returnedNothing(item.spell) then item.spell.info = true end
    local spellID = self:Val(item.spell, 2)
    if full and isNumber(spellID) then
        if seenDescriptions[spellID] then
            item.descriptionSeenIn = seenDescriptions[spellID]
        else
            seenDescriptions[spellID] = item.label
            item.spellDescription = readDescription(self, probe, spellID)
        end
    end
end

-- Description text with colour escapes and newlines removed, cut at DESC_MAX bytes on a UTF-8 boundary.
local function clip(self, text)
    if type(text) ~= "string" then return "<error: description is not text>" end
    local clean = self:Clean(text)
    if #clean <= DESC_MAX then return clean end
    local cut = DESC_MAX
    while cut > 0 do
        local byte = string.byte(clean, cut + 1)
        if byte and byte >= 128 and byte < 192 then cut = cut - 1 else break end
    end
    return string.sub(clean, 1, cut) .. "...(잘림, 전체 " .. #clean .. "바이트)"
end

Addon:RegisterCollector("spelldetails", function(self)
    local full = isFull(self)
    local limit = full and FULL_SPELLS or COMPACT_SPELLS
    local section = {
        detail = full and "full" or "compact",
        scope = "player spellbook (Player bank, pet spells ignored) + equipped items of unit player; "
            .. "one snapshot, not refreshed",
        observedAt = self:Timestamp(),
        limit = limit,
    }
    local missing = {}
    local probe = newProbe(self, missing)
    local seenDescriptions = {}

    local bank = playerBank()
    if not bank then
        section.bank = self:State("unsupported", "Enum.SpellBookSpellBank.Player unavailable at runtime")
    else
        local list = listSpells(self, section, bank)
        if list then
            section.spellTotal = #list
            section.spells = {}
            local activeCount = 0
            for _, entry in ipairs(list) do
                if not entry.passive then activeCount = activeCount + 1 end
            end
            section.activeTotal, section.passiveTotal = activeCount, #list - activeCount
            if not full then
                -- Compact mode: active spells first (spellbook order kept inside each group), passives only fill
                -- what is left of the limit. Full mode keeps the plain spellbook order.
                local ordered = {}
                for _, entry in ipairs(list) do
                    if not entry.passive then ordered[#ordered + 1] = entry end
                end
                for _, entry in ipairs(list) do
                    if entry.passive then ordered[#ordered + 1] = entry end
                end
                list = ordered
            end
            for index = 1, math.min(#list, limit) do
                local entry = list[index]
                readSpellFields(self, probe, entry)
                seenDescriptions[entry.spellID] = "주문서"
                section.spells[index] = entry
            end
            section.spellsTruncated = #list > limit
        end
    end

    section.items = {}
    for index, slotEntry in ipairs(SLOTS) do
        local item = readSlot(self, slotEntry)
        section.items[index] = item
        if item.occupied == true then
            readItem(self, probe, item, full, seenDescriptions)
        end
    end
    section.unsupported = {}
    for api in pairs(missing) do section.unsupported[#section.unsupported + 1] = api end
    table.sort(section.unsupported)
    return section
end, function(self, section, out)
    local full = section.detail == "full"
    out:Add("범위: " .. self:Clean(section.scope))
    local observed = self:Val(section.observedAt)
    out:Add("읽은 시각: " .. (isNumber(observed) and self:Date(observed) or self:Describe(section.observedAt))
        .. " (이 시각의 스냅샷; 설명·비용은 읽은 시점 기준)")
    if full then
        out:Add("상세 수준: 전체 (주문 설명 최대 " .. DESC_MAX .. "바이트, 주문 최대 " .. section.limit .. "개)")
    else
        out:Add("상세 수준: 요약 (기본; 설명 본문은 생략하고 능동 주문 우선으로 " .. section.limit .. "개만 표시)")
        out:Add("전체 보기: 설정 창의 '상세 수준'에서 spelldetails를 '전체'로 바꾸세요")
    end
    out:Add("참고: castTime/minRange/maxRange는 API 원시 숫자이며 단위는 문서에 없음")
    local missing = {}
    for _, api in ipairs(section.unsupported or {}) do missing[api] = true end
    if #(section.unsupported or {}) > 0 then
        out:Add("미지원 API (아래 항목에서 생략): " .. table.concat(section.unsupported, ", "))
    end

    -- Spells
    out:Add("")
    out:Add("[주문 상세]")
    if section.bank then
        out:State("주문서", section.bank)
    elseif Addon:Describe(section.numSkillLines) then
        out:Add("주문서: " .. Addon:Describe(section.numSkillLines))
    elseif not section.spells then
        out:Add("주문서: <error: unexpected skill line count " .. self:Fmt(self:Val(section.numSkillLines)) .. ">")
    else
        local c = section.counts or {}
        out:Add("주문서: 고유 주문 " .. section.spellTotal .. "개 (읽은 슬롯 " .. (c.slotsRead or 0)
            .. ", 중복 ID " .. (c.duplicates or 0) .. ", 미습득 " .. (c.future or 0)
            .. ", 주문 아님(전문화창/소환수 등) " .. (c.nonSpell or 0) .. ", 비활성 특성 " .. (c.offSpec or 0)
            .. ", 읽기 실패 " .. (c.unreadable or 0) .. ", 읽지 못한 기술 분류 " .. #(section.lineErrors or {}) .. ")")
        local shown = #section.spells
        local gaps = (c.unreadable or 0) + #(section.lineErrors or {})
        local marker = "완전(complete)"
        if section.spellsTruncated then
            marker = "잘림(truncated)"
        elseif gaps > 0 then
            marker = "불완전(incomplete): 읽지 못한 슬롯/분류 " .. gaps .. "개"
        end
        out:Add("표시 " .. shown .. " / 전체 " .. section.spellTotal .. " — " .. marker)
        if section.activeTotal then
            local activeShown = 0
            for _, entry in ipairs(section.spells) do
                if not entry.passive then activeShown = activeShown + 1 end
            end
            out:Add("능동 " .. section.activeTotal .. "개 / 패시브 " .. (section.passiveTotal or 0)
                .. "개 중 표시한 능동 " .. activeShown .. "개, 패시브 " .. (shown - activeShown) .. "개"
                .. (full and "" or " (요약은 능동을 먼저 고름)"))
        end
        local loaded, notLoaded = 0, 0
        for _, entry in ipairs(section.spells) do
            if entry.description and entry.description.status == "ok" then loaded = loaded + 1
            elseif entry.description and entry.description.status == "not_collected"
                and not returnedNothing(entry.description) then notLoaded = notLoaded + 1 end
        end
        if not missing["C_Spell.GetSpellDescription"] then
            out:Add("설명 읽음 " .. loaded .. " / 미로딩(빈 문자열) " .. notLoaded .. " / 표시된 " .. shown .. "개 기준")
            if notLoaded > 0 then
                out:Add("미로딩 설명이 있음: 잠시 뒤 다시 내보내면 읽힐 수 있음 (SPELL_TEXT_UPDATE 로그인 후 수신 "
                    .. tostring(Addon.spellTextUpdates or 0) .. "회; 자동 재시도는 근거가 없어 하지 않음)")
            end
        end
        for _, entry in ipairs(section.spells) do
            local name = entry.name and entry.name ~= "" and self:Clean(entry.name) or "<not_collected: 이름 없음>"
            local head = "- " .. name .. " (id=" .. entry.spellID .. (entry.passive and ", 패시브" or "")
                .. (entry.lineName and (", " .. self:Clean(entry.lineName)) or "") .. ")"
            local parts = {}
            local info = self:Val(entry.info)
            if entry.info.status ~= "unsupported" then -- unsupported APIs are listed once in the header
                if self:Describe(entry.info) then
                    parts[#parts + 1] = "정보=" .. self:Describe(entry.info)
                elseif type(info) == "table" then
                    parts[#parts + 1] = "시전=" .. self:Fmt(info.castTime) .. " 사거리=" .. self:Fmt(info.minRange)
                        .. "~" .. self:Fmt(info.maxRange)
                else
                    parts[#parts + 1] = "정보=<error: unexpected spell info shape>"
                end
            end
            if entry.cost.status ~= "unsupported" then
                if returnedNothing(entry.cost) then
                    parts[#parts + 1] = "소모=보고 없음(무료이거나 주문 미확인, API는 구분 불가)"
                else
                    parts[#parts + 1] = "소모=" .. (self:Describe(entry.cost) or self:Fmt(entry.cost.values[1]))
                end
            end
            if entry.level.status ~= "unsupported" then
                parts[#parts + 1] = "습득레벨=" .. (self:Describe(entry.level) or self:Fmt(entry.level.values[1]))
            end
            local desc = entry.description
            local descTag = self:Describe(desc)
            if full then
                out:Add(head .. (#parts > 0 and (" " .. table.concat(parts, ", ")) or ""))
                if desc.status ~= "unsupported" then
                    local text = self:Val(desc, 1)
                    out:Add("    설명: " .. (descTag or clip(self, text)))
                end
            else
                if desc.status ~= "unsupported" then
                    parts[#parts + 1] = "설명=" .. (descTag or ("읽음(" .. #self:Val(desc, 1) .. "바이트)"))
                end
                out:Add(head .. (#parts > 0 and (" " .. table.concat(parts, ", ")) or ""))
            end
        end
        for _, bad in ipairs(section.lineErrors or {}) do
            out:Add("- 기술 분류 " .. bad.index .. ": " .. (self:Describe(bad.info) or "<error: unexpected shape>"))
        end
    end

    -- Equipment
    out:Add("")
    out:Add("[장비 상세]")
    local equipped, empty, unresolved = 0, 0, 0
    for _, item in ipairs(section.items or {}) do
        if item.occupied == true then equipped = equipped + 1
        elseif item.occupied == false then empty = empty + 1
        else unresolved = unresolved + 1 end
    end
    out:Add("장비: 착용 " .. equipped .. ", 빈 슬롯 " .. empty .. ", 확인 불가 " .. unresolved
        .. " — 전체 슬롯 " .. #(section.items or {}) .. "개 중 "
        .. (unresolved == 0 and "모두 확인(완전)" or ("확인 불가 " .. unresolved .. "개(불완전)")))
    for _, item in ipairs(section.items or {}) do
        local head = "- " .. item.label
        if item.slotID == nil then
            out:Add(head .. ": " .. (self:Describe(item.slotInfo) or "<not_collected: slot ID is not a number>"))
        elseif item.occupied == false then
            out:Add(head .. ": <empty slot: 링크·ID 모두 보고 없음>")
        elseif item.occupied ~= true then
            out:Add(head .. ": <not_collected: " .. (self:Describe(item.link) or "링크")
                .. (item.itemIDRead and (" / " .. (self:Describe(item.itemIDRead) or "")) or "") .. ">")
        else
            local linkText = self:Val(item.link, 1)
            local name = self:LinkInfo(linkText)
            local parts = { (name and self:Clean(name) or "<not_collected: 이름 없음>") .. " (id=" .. item.itemID .. ")" }
            local stats = item.stats
            local statsTag = self:Describe(stats)
            if returnedNothing(stats) then
                parts[#parts + 1] = "능력치=보고 없음(능력치가 없거나 미로딩, API는 구분 불가)"
            elseif statsTag then
                parts[#parts + 1] = "능력치=" .. statsTag
            elseif type(stats.values[1]) ~= "table" then
                parts[#parts + 1] = "능력치=<error: unexpected stats shape>"
            elseif not full then
                local n = 0
                for _ in pairs(stats.values[1]) do n = n + 1 end
                parts[#parts + 1] = "능력치 " .. n .. "종"
            end
            local spellTag = self:Describe(item.spell)
            if returnedNothing(item.spell) then
                parts[#parts + 1] = "아이템 주문=보고 없음(없거나 미로딩, API는 구분 불가)"
            elseif spellTag then
                parts[#parts + 1] = "아이템 주문=" .. spellTag
            else
                parts[#parts + 1] = "아이템 주문=" .. self:Fmt(item.spell.values[1])
                    .. " (id=" .. self:Fmt(item.spell.values[2]) .. ")"
            end
            out:Add(head .. ": " .. table.concat(parts, ", "))
            if full then
                local itemString = type(linkText) == "string" and string.match(linkText, "|H(item:[^|]*)|h")
                out:Add("    링크: " .. (itemString or "<not_collected: no item string in link>"))
                if not statsTag and type(item.stats.values[1]) == "table" then
                    out:Add("    능력치: " .. self:Fmt(item.stats.values[1]))
                end
                if item.descriptionSeenIn then
                    out:Add("    아이템 주문 설명: 같은 주문 ID 설명은 위 '" .. item.descriptionSeenIn .. "' 항목 참조")
                elseif item.spellDescription and item.spellDescription.status ~= "unsupported" then
                    local text = self:Val(item.spellDescription, 1)
                    out:Add("    아이템 주문 설명: "
                        .. (self:Describe(item.spellDescription) or clip(self, text)))
                end
            end
        end
    end
    out:Add("툴팁 문구는 수집하지 않음 (호출 형태 근거 없음)")
end)
