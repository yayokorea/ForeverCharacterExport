local _, Addon = ...

-- ClassState section: stance/form list, mana pool, combo points, stealth, weapon enchants, totems, tracking.
-- Read-only. Nothing here casts, shapeshifts, destroys a totem, changes tracking or cancels an enchant.
--
-- Evidence. Paths are under references/upstream/Interface/AddOns/ ("R:") unless marked CACHE.
--
--  In R: (grepped, cited as file:line)
--   * UnitClassBase(unit) -> classFilename, classID (MayReturnNothing, may be secret):
--     R:Blizzard_APIDocumentationGenerated/UnitDocumentation.lua:930. Same read as Pet.lua.
--   * UnitExists :1192, UnitPower(unit, powerType) :2732, UnitPowerMax(unit, powerType) :2801,
--     UnitPowerType(unit) -> powerType, token, ... :2859 (UnitDocumentation.lua). Character.lua reads the same trio.
--   * Enum.PowerType.Mana = 0, ComboPoints = 4: PowerTypeConstantsDocumentation.lua:25,29. Never hardcoded here;
--     the enum is read at runtime. Mana read call site: Blizzard_UIPanels_Game/Camelot/PaperDollFrame.lua:1239
--     (UnitPowerMax("player", Enum.PowerType.Mana) <= 0 means "no mana pool").
--   * GetComboPoints(unit, target) -> number: UnitDocumentation.lua:91 (SecretWhenUnitPowerRestricted).
--     Call site "GetComboPoints('player','target')": CACHE Blizzard_UnitFrame/Camelot/ComboFrame.lua:101.
--     The declaration says nothing about "no target", so UnitExists("target") is checked first and a missing target
--     is reported as such instead of calling the API (its 0 would read as "0 points").
--   * IsStealthed() -> bool: PlayerScriptDocumentation.lua:1489. Declaration only: no UI call site was found, so it is
--     not known whether Forever's druid Prowl counts. No separate prowl read exists in the source.
--   * GetShapeshiftForm() ~= 0 means "currently in a form": Blizzard_UIPanels_Game/Camelot/PaperDollFrameStats.lua:683.
--     That call site is the only evidence for the return meaning (no declaration was found).
--   * C_Item.GetWeaponEnchantInfo(weaponSlot) -> table of WeaponEnchantInfo: ItemDocumentation.lua:1141
--     (struct :1968: hasEnchant, enchantType, timeLeft, charges, enchantID, enchantIconID). It is NOT the old
--     multi-return global. Call site iterating `pairs(Enum.WeaponSlot)` and `pairs(enchants)`:
--     Blizzard_BuffFrame/BuffFrame.lua:765-766. UI divides timeLeft by 1000 before use (:774-775) -> raw value is
--     milliseconds per the UI; seconds below are derived from that single call site.
--   * Enum.WeaponSlot MainHand=0 OffHand=1 Ranged=2: ItemConstantsDocumentation.lua:819-828.
--     Enum.ItemEnchantType None=0 Permanent=1 Temporary=2 Imbue=3: ItemConstantsDocumentation.lua:382-392.
--   * C_Minimap.GetNumTrackingTypes() / GetTrackingInfo(index) loops: Blizzard_Minimap/Mainline/Minimap.lua:741,756,758
--     and :895-899. Fields used by the UI: name :786, texture :790, active :899, type :806, subType :761-763,
--     spellID :789. GetTrackingFilter(index) -> {spellID, filterID}: Minimap.lua:620,625,742 (the UI treats a type as
--     displayable when filter.filterID is optional or filter.spellID is set, :619-626). The UI notes the tracking
--     values are unavailable until MINIMAP_UPDATE_TRACKING / SPELLS_CHANGED have fired (:894).
--     Mainline file: Forever/Camelot use is not proven (docs/collection-expansion-research.md section 5, row 05).
--   * GetTime :SystemTimeDocumentation.lua:57; GetServerTime :30; C_Spell.GetSpellName :SpellDocumentation.lua:518.
--
--  UNVERIFIED (NOT in references/upstream; only in the research cache dev/.tools/forever-research/, same pinned
--  commit eac30af, research doc section 5 "U"). Probe reports "unsupported" when the global is absent:
--   * GetNumShapeshiftForms(), GetShapeshiftFormInfo(i) -> texture, isActive, isCastable, spellID,
--     GetShapeshiftFormCooldown(i) -> start, duration, enable:
--     CACHE Blizzard_ActionBar/Shared/StanceBar.lua:31,62,70,80 (return order from the call site only;
--     file header line 2 says "Shapsfit,Auras,Aspects").
--   * GetNumTotemSlots() -> numSlots, GetTotemInfo(slot) -> haveTotem, totemName, startTime, duration, icon, modRate,
--     spellID (MayReturnNothing, SecretWhenTotemSlotSecret), GetTotemTimeLeft(slot) -> number|nil:
--     CACHE Blizzard_APIDocumentationGenerated/TotemDocumentation.lua:20,59-80,82-96;
--     CACHE Blizzard_UnitFrame/Mainline/TotemFrame.lua:29-31,71. GetTotemDuration returns a LuaDurationObject and is
--     deliberately not called.
--   * C_Minimap.GetNumTrackingTypes / GetTrackingInfo / GetTrackingFilter declarations and the
--     MinimapScriptTrackingInfo / MinimapScriptTrackingFilter structs:
--     CACHE Blizzard_APIDocumentationGenerated/MinimapDocumentation.lua:61,88,103,299-319.
--
-- Class is recorded as context only. Every API is still called for every class (Forever reworked classes, and a
-- Hunter has aspects as forms); only a real zero / haveTotem=false / empty list becomes <empty>.

local MAX_FORMS, MAX_TOTEM_SLOTS, MAX_TRACKING, MAX_WEAPON_SLOTS, MAX_ENCHANTS = 20, 12, 60, 8, 10

local function isCount(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0
end

-- Enum.<group>.<name> as a number, else nil (the enum is read at runtime, never hardcoded).
local function enumMember(group, name)
    if type(Enum) == "table" and type(Enum[group]) == "table" and type(Enum[group][name]) == "number" then
        return Enum[group][name]
    end
end

local function enumName(group, value)
    if type(Enum) ~= "table" or type(Enum[group]) ~= "table" then return nil end
    for name, member in pairs(Enum[group]) do
        if member == value and type(name) == "string" then return name end
    end
end

local function unsupported(self, reason, api)
    local state = self:State("unsupported", reason)
    state.api = api
    return state
end

-- ---------------------------------------------------------------------------------------------------------------
-- Collection

local function collectForms(self, section)
    local forms = { entries = {} }
    section.forms = forms
    forms.count = self:Probe("GetNumShapeshiftForms")
    forms.current = self:Probe("GetShapeshiftForm")
    local count = self:Val(forms.count)
    if forms.count.status ~= "ok" then
        forms.traversal = self:State("not_collected", "form count unavailable; forms not listed")
    elseif not isCount(count) then
        forms.traversal = self:State("error", "unexpected form count; forms not listed")
    elseif count == 0 then
        forms.traversal = self:State("empty", "GetNumShapeshiftForms returned 0: no stance/form/aspect entry now")
    else
        forms.total = count
        forms.complete = count <= MAX_FORMS
        for index = 1, math.min(count, MAX_FORMS) do
            local entry = {
                index = index,
                info = self:Probe("GetShapeshiftFormInfo", index),
                cooldown = self:Probe("GetShapeshiftFormCooldown", index),
            }
            local spellID = self:Val(entry.info, 4)
            if type(spellID) == "number" then
                entry.spellName = self:Probe("C_Spell.GetSpellName", spellID)
            end
            forms.entries[#forms.entries + 1] = entry
        end
    end
end

local function collectPower(self, section)
    local power = {}
    section.power = power
    local mana = enumMember("PowerType", "Mana")
    if not mana then
        power.state = unsupported(self, "Enum.PowerType.Mana unavailable; mana pool not read", "Enum.PowerType.Mana")
        return
    end
    power.manaType = mana
    power.primary = self:Probe("UnitPowerType", "player")
    power.mana = self:Probe("UnitPower", "player", mana)
    power.manaMax = self:Probe("UnitPowerMax", "player", mana)
end

local function collectCombo(self, section)
    local combo = {}
    section.combo = combo
    local comboType = enumMember("PowerType", "ComboPoints")
    if not comboType then
        combo.state = unsupported(self, "Enum.PowerType.ComboPoints unavailable; combo points not read",
            "Enum.PowerType.ComboPoints")
        return
    end
    combo.max = self:Probe("UnitPowerMax", "player", comboType)
    combo.targetExists = self:Probe("UnitExists", "target")
    local max, targetExists = self:Val(combo.max), self:Val(combo.targetExists)
    if combo.max.status ~= "ok" then
        combo.state = self:State("not_collected", "combo point maximum unreadable; GetComboPoints not called")
    elseif type(max) ~= "number" then
        combo.state = self:State("error", "unexpected combo point maximum; GetComboPoints not called")
    elseif max <= 0 then
        combo.state = self:State("empty", "UnitPowerMax(ComboPoints) is 0: no combo point resource right now")
    elseif combo.targetExists.status ~= "ok" then
        combo.state = self:State("not_collected", "target existence unreadable; GetComboPoints not called")
    elseif targetExists ~= true then
        combo.state = self:State("empty", "no target: GetComboPoints not called (a 0 would be ambiguous)")
    else
        combo.points = self:Probe("GetComboPoints", "player", "target")
    end
end

local function collectWeapon(self, section)
    local weapon = { slots = {} }
    section.weapon = weapon
    local enum = type(Enum) == "table" and Enum.WeaponSlot
    if type(enum) ~= "table" then
        weapon.state = unsupported(self, "Enum.WeaponSlot unavailable; weapon enchants not read", "Enum.WeaponSlot")
        return
    end
    local list = {}
    for name, value in pairs(enum) do
        if type(name) == "string" and isCount(value) then list[#list + 1] = { name = name, slot = value } end
    end
    table.sort(list, function(a, b) return a.slot < b.slot end)
    if #list == 0 then
        weapon.state = self:State("not_collected", "Enum.WeaponSlot has no readable members")
        return
    end
    weapon.total = #list
    weapon.complete = #list <= MAX_WEAPON_SLOTS
    for index = 1, math.min(#list, MAX_WEAPON_SLOTS) do
        local item = list[index]
        item.info = self:Probe("C_Item.GetWeaponEnchantInfo", item.slot)
        weapon.slots[#weapon.slots + 1] = item
    end
end

local function collectTotems(self, section)
    local totems = { entries = {} }
    section.totems = totems
    totems.slots = self:Probe("GetNumTotemSlots")
    local slots = self:Val(totems.slots)
    if totems.slots.status ~= "ok" then
        totems.traversal = self:State("not_collected", "totem slot count unavailable; slots not listed")
    elseif not isCount(slots) then
        totems.traversal = self:State("error", "unexpected totem slot count; slots not listed")
    elseif slots == 0 then
        totems.traversal = self:State("empty", "GetNumTotemSlots returned 0: no totem slots")
    else
        totems.total = slots
        totems.complete = slots <= MAX_TOTEM_SLOTS
        for slot = 1, math.min(slots, MAX_TOTEM_SLOTS) do
            local entry = { slot = slot, info = self:Probe("GetTotemInfo", slot) }
            -- Time left is only read for a slot that reports a totem.
            if self:Val(entry.info, 1) == true then
                entry.timeLeft = self:Probe("GetTotemTimeLeft", slot)
            end
            totems.entries[#totems.entries + 1] = entry
        end
    end
end

local function collectTracking(self, section)
    local tracking = { entries = {} }
    section.tracking = tracking
    tracking.count = self:Probe("C_Minimap.GetNumTrackingTypes")
    local count = self:Val(tracking.count)
    if tracking.count.status ~= "ok" then
        tracking.traversal = self:State("not_collected", "tracking type count unavailable; types not listed")
        return
    elseif not isCount(count) then
        tracking.traversal = self:State("error", "unexpected tracking type count; types not listed")
        return
    elseif count == 0 then
        tracking.traversal = self:State("empty", "GetNumTrackingTypes returned 0: no tracking types")
        return
    end
    tracking.total = count
    tracking.complete = count <= MAX_TRACKING
    local active, unreadable = 0, 0
    for index = 1, math.min(count, MAX_TRACKING) do
        local entry = {
            index = index,
            info = self:Probe("C_Minimap.GetTrackingInfo", index),
            filter = self:Probe("C_Minimap.GetTrackingFilter", index),
        }
        local info = self:Val(entry.info)
        if type(info) ~= "table" then
            unreadable = unreadable + 1
        elseif info.active == true then
            active = active + 1
        end
        tracking.entries[#tracking.entries + 1] = entry
    end
    tracking.activeCount, tracking.unreadable = active, unreadable
    if active == 0 then
        if unreadable == 0 and tracking.complete then
            tracking.activeState = self:State("empty", "all " .. count .. " tracking types read; none active")
        else
            tracking.activeState = self:State("not_collected", "no active type among the readable ones, but "
                .. unreadable .. " unreadable" .. (tracking.complete and "" or " and the list is truncated")
                .. "; NOT proof of none")
        end
    end
end

Addon:RegisterCollector("classstate", function(self)
    local section = {
        scope = "momentary snapshot of the player at capture time (current form, target, equipped weapons, placed "
            .. "totems, active tracking); not persisted and not a statement about other forms or specs",
        capturedAt = self:Timestamp(),
        time = self:Probe("GetTime"),
        class = self:Probe("UnitClassBase", "player"),
    }
    collectForms(self, section)
    collectPower(self, section)
    collectCombo(self, section)
    section.stealth = self:Probe("IsStealthed")
    collectWeapon(self, section)
    collectTotems(self, section)
    collectTracking(self, section)
    return section
end, function(self, section, out)
    local now = self:Val(section.time)
    local nowTag = self:Describe(section.time)
    local classTag = self:Describe(section.class)
    local className = classTag or (self:Fmt(self:Val(section.class, 1)) .. " (classID "
        .. self:Fmt(self:Val(section.class, 2)) .. ")")
    local classNote = classTag and "" or (" [직업 " .. self:Fmt(self:Val(section.class, 1))
        .. ": 이 기능의 유무는 직업/폼에 따라 다르며 여기서 단정하지 않음]")
    out:Add("범위: " .. section.scope)
    out:Add("관측 시각: server epoch " .. self:Fmt(self:Val(section.capturedAt)) .. " | GetTime "
        .. (nowTag or self:Fmt(now)))
    out:Add("플레이어 직업(UnitClassBase): " .. className)

    -- Forms ---------------------------------------------------------------------------------------------------
    local forms = section.forms
    out:Add("### 자세/변신/상 (GetNumShapeshiftForms) [UNVERIFIED: 연구 캐시 StanceBar.lua]")
    out:Result("형태 수", forms.count)
    out:Result("현재 형태 인덱스(GetShapeshiftForm; 0 = 형태 없음, PaperDollFrameStats.lua:683)", forms.current)
    if forms.traversal then
        out:State("형태 목록", forms.traversal)
        if forms.traversal.status == "empty" then out:Add("(직업 참고)" .. classNote) end
    end
    for _, entry in ipairs(forms.entries) do
        local tag = self:Describe(entry.info)
        local head = "- 형태 " .. entry.index .. ": "
        if tag then
            out:Add(head .. tag)
        else
            local v = entry.info.values
            local nameTag = entry.spellName and self:Describe(entry.spellName)
            local name = entry.spellName and not nameTag and self:Fmt(self:Val(entry.spellName)) or nameTag or "?"
            local cd = self:Describe(entry.cooldown)
            local cdText
            if cd then
                cdText = cd
            else
                local c = entry.cooldown.values
                cdText = "start=" .. self:Fmt(c[1]) .. " duration=" .. self:Fmt(c[2]) .. " enable=" .. self:Fmt(c[3])
                if type(c[1]) == "number" and type(c[2]) == "number" and type(now) == "number" and c[2] > 0 then
                    cdText = cdText .. " 남은≈" .. math.max(0, math.floor(c[1] + c[2] - now + 0.5)) .. "s"
                end
            end
            out:Add(head .. name .. " (spellID " .. self:Fmt(v[4]) .. ") 활성=" .. self:Fmt(v[2]) .. " 사용가능="
                .. self:Fmt(v[3]) .. " | 재사용(순간값): " .. cdText)
        end
    end
    if forms.total and not forms.complete then
        out:Add("(잘림: " .. #forms.entries .. "/" .. forms.total .. " 형태만 읽음)")
    elseif forms.total then
        out:Add("(완전: " .. forms.total .. "/" .. forms.total .. ")")
    end

    -- Power ---------------------------------------------------------------------------------------------------
    local power = section.power
    out:Add("### 마나 풀 (UnitPower/UnitPowerMax, Enum.PowerType.Mana)")
    if power.state then
        out:State("마나", power.state)
    else
        out:Result("현재 주 자원(UnitPowerType)", power.primary, function(value, values)
            return self:Fmt(values[2]) .. " (powerType " .. self:Fmt(value) .. ")"
        end)
        local curTag, maxTag = self:Describe(power.mana), self:Describe(power.manaMax)
        if curTag or maxTag then
            out:Add("마나: current=" .. (curTag or self:Fmt(self:Val(power.mana))) .. " max="
                .. (maxTag or self:Fmt(self:Val(power.manaMax))))
        else
            local max = self:Val(power.manaMax)
            if max == 0 then
                out:Add("마나: <empty: UnitPowerMax(Mana)=0, 마나 풀 없음>" .. classNote)
            else
                out:Add("마나: " .. self:Fmt(self:Val(power.mana)) .. " / " .. self:Fmt(max))
            end
        end
        local primary = self:Val(power.primary, 1)
        if power.primary.status == "ok" and type(primary) == "number" then
            if primary == power.manaType then
                out:Add("(주 자원이 마나: character 구역의 현재 자원 값과 같음, 중복 집계 금지)")
            else
                out:Add("(주 자원이 마나가 아님: 위 마나는 별도 풀 관측값. 변신 중 값이 실제 마나인지는 게임에서 확인 필요)")
            end
        end
    end

    -- Combo points / stealth ----------------------------------------------------------------------------------
    local combo = section.combo
    out:Add("### 연계 점수 / 은신")
    if combo.state then
        out:State("연계 점수", combo.state)
        if combo.state.status == "empty" then out:Add("(직업 참고)" .. classNote) end
    else
        out:Result("연계 점수(GetComboPoints player->target, 현재 대상 기준 순간값)", combo.points)
        out:Result("최대(UnitPowerMax ComboPoints)", combo.max)
    end
    out:Result("은신(IsStealthed; 드루이드 야생 표범 은신 포함 여부는 미확인)", section.stealth)

    -- Weapon enchants -----------------------------------------------------------------------------------------
    local weapon = section.weapon
    out:Add("### 무기 강화 (C_Item.GetWeaponEnchantInfo)")
    if weapon.state then
        out:State("무기 강화", weapon.state)
    else
        for _, item in ipairs(weapon.slots) do
            local label = "- " .. item.name .. " (slot " .. item.slot .. ")"
            local tag = self:Describe(item.info)
            local list = self:Val(item.info)
            if tag then
                out:Add(label .. ": " .. tag)
            elseif type(list) ~= "table" then
                out:Add(label .. ": <error: unexpected return type " .. type(list) .. " [C_Item.GetWeaponEnchantInfo]>")
            else
                local keys = {}
                for key in pairs(list) do keys[#keys + 1] = key end
                table.sort(keys, function(a, b)
                    if type(a) == type(b) then return a < b end
                    return type(a) < type(b)
                end)
                if #keys == 0 then
                    out:Add(label .. ": <empty: API가 빈 강화 목록을 반환>")
                end
                for position, key in ipairs(keys) do
                    local enchant = list[key]
                    if position > MAX_ENCHANTS then
                        out:Add(label .. ": (잘림: " .. #keys .. "개 중 " .. MAX_ENCHANTS .. "개만 표시)")
                        break
                    elseif type(enchant) ~= "table" then
                        out:Add(label .. ": <error: unexpected enchant entry of type " .. type(enchant) .. ">")
                    else
                        local seconds = type(enchant.timeLeft) == "number" and math.floor(enchant.timeLeft / 1000)
                        local typeName = enumName("ItemEnchantType", enchant.enchantType)
                        -- One C_Item.GetWeaponEnchantInfo(slot) call returned several entries (the UI loops over
                        -- them: BuffFrame.lua:766); this is not a second read of the same slot.
                        local entryLabel = #keys > 1 and (label .. " [항목 " .. position .. "/" .. #keys .. "]") or label
                        out:Add(entryLabel .. ": hasEnchant=" .. self:Fmt(enchant.hasEnchant) .. " enchantType="
                            .. self:Fmt(enchant.enchantType) .. (typeName and (" (" .. typeName .. ")") or "")
                            .. " enchantID=" .. self:Fmt(enchant.enchantID) .. " charges=" .. self:Fmt(enchant.charges)
                            .. " timeLeft(raw)=" .. self:Fmt(enchant.timeLeft)
                            .. (seconds and (" ≈" .. seconds .. "s") or "")
                            .. " iconID=" .. self:Fmt(enchant.enchantIconID))
                    end
                end
            end
        end
        if not weapon.complete then
            out:Add("(잘림: " .. #weapon.slots .. "/" .. weapon.total .. " 슬롯만 읽음)")
        end
        out:Add("(슬롯마다 API를 1번만 호출함. 한 슬롯에 항목이 여러 개로 나오면 API가 항목 여러 개를 반환한 것이며 "
            .. "어느 항목이 무엇인지는 문서에 없음. BuffFrame.lua:766은 항목 전부를 순회함)")
        out:Add("(timeLeft 단위: BuffFrame.lua:775가 /1000 하므로 밀리초로 추정. 게임 UI와 대조 필요. "
            .. "hasEnchant=false 항목은 강화 없음)")
    end

    -- Totems --------------------------------------------------------------------------------------------------
    local totems = section.totems
    out:Add("### 토템 (GetNumTotemSlots/GetTotemInfo) [UNVERIFIED: 연구 캐시 TotemDocumentation.lua]")
    out:Result("토템 슬롯 수(API 값, 고정 안 함)", totems.slots)
    if totems.traversal then
        out:State("토템 목록", totems.traversal)
        if totems.traversal.status == "empty" then out:Add("(직업 참고)" .. classNote) end
    end
    local placed = 0
    for _, entry in ipairs(totems.entries) do
        local head = "- 슬롯 " .. entry.slot .. ": "
        local tag = self:Describe(entry.info)
        if tag then
            if entry.info.status == "not_collected" then
                tag = tag .. " (GetTotemInfo는 MayReturnNothing: 빈 슬롯인지 미준비인지 구별 불가)"
            end
            out:Add(head .. tag)
        else
            local v = entry.info.values
            if v[1] == true then
                placed = placed + 1
                local left = entry.timeLeft and (self:Describe(entry.timeLeft) or self:Fmt(self:Val(entry.timeLeft)))
                out:Add(head .. self:Fmt(v[2]) .. " (spellID " .. self:Fmt(v[7]) .. ") startTime=" .. self:Fmt(v[3])
                    .. " duration=" .. self:Fmt(v[4]) .. " modRate=" .. self:Fmt(v[6])
                    .. " timeLeft(GetTotemTimeLeft, 단위 미확인)=" .. tostring(left))
            elseif v[1] == false then
                out:Add(head .. "<empty: haveTotem=false>")
            else
                out:Add(head .. "<error: unexpected haveTotem " .. self:Fmt(v[1]) .. ">")
            end
        end
    end
    if totems.total then
        out:Add("(설치됨 " .. placed .. " / 읽은 슬롯 " .. #totems.entries .. " / 전체 " .. totems.total
            .. (totems.complete and ", 완전)" or ", 잘림)"))
    end

    -- Tracking ------------------------------------------------------------------------------------------------
    local tracking = section.tracking
    out:Add("### 추적 (C_Minimap.GetNumTrackingTypes/GetTrackingInfo; Mainline Minimap.lua 근거)")
    out:Result("추적 유형 수", tracking.count)
    if tracking.traversal then
        out:State("추적 목록", tracking.traversal)
    else
        local known, others = {}, {}
        out:Add("읽음 " .. #tracking.entries .. "/" .. tracking.total .. (tracking.complete and " (완전)" or " (잘림)")
            .. ", 활성 " .. tracking.activeCount .. ", 읽지 못함 " .. tracking.unreadable)
        if tracking.activeState then out:State("활성 추적", tracking.activeState) end
        for _, entry in ipairs(tracking.entries) do
            local info = self:Val(entry.info)
            local filter = self:Val(entry.filter)
            if type(info) ~= "table" then
                out:Add("- [" .. entry.index .. "] " .. self:Describe(entry.info))
            else
                local name = self:Fmt(info.name)
                local filterSpell = type(filter) == "table" and filter.spellID or nil
                local spellID = info.spellID or filterSpell
                if info.active == true then
                    out:Add("- 활성 [" .. entry.index .. "] " .. name .. " (spellID " .. self:Fmt(spellID) .. ", type="
                        .. self:Fmt(info.type) .. ", subType=" .. self:Fmt(info.subType) .. ", filterID="
                        .. self:Fmt(type(filter) == "table" and filter.filterID or nil) .. ")")
                elseif spellID ~= nil then
                    known[#known + 1] = name .. "[" .. entry.index .. "]"
                else
                    others[#others + 1] = name .. "[" .. entry.index .. "]"
                end
            end
        end
        if #known > 0 then out:Add("비활성이지만 spellID가 있는 유형(사용 가능 후보): " .. table.concat(known, ", ")) end
        if #others > 0 then
            out:Add("spellID 없는 비활성 유형 " .. #others .. "종: " .. table.concat(others, ", "))
        end
        out:Add("(spellID 유무는 Minimap.lua:619-626의 표시 조건 근거. '알고 있음'의 확정이 아님. "
            .. "초기값은 MINIMAP_UPDATE_TRACKING 전에는 미준비일 수 있음)")
    end
end)
