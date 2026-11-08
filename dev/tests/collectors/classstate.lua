-- Mocked contract tests for the classstate collector (not a WoW runtime; the returns below are test inputs).
local Addon = AddonUnderTest

local function run()
    local section = Addon.collectors.classstate(Addon)
    local out = Addon:NewWriter()
    Addon.formatters.classstate(Addon, section, out)
    return out:Output(), section
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function hasNot(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

local ENUM = {
    PowerType = { Mana = 0, Rage = 1, Focus = 2, Energy = 3, ComboPoints = 4 },
    WeaponSlot = { MainHand = 0, OffHand = 1, Ranged = 2 },
    ItemEnchantType = { None = 0, Permanent = 1, Temporary = 2, Imbue = 3 },
}

-- Hunter-like baseline: aspects as forms, focus primary power, no combo resource, no totem slots, ranged weapon.
local function hunter(extra)
    local globals = {
        Enum = ENUM,
        GetTime = function() return 1000 end,
        UnitClassBase = function() return "HUNTER", 3 end,
        GetNumShapeshiftForms = function() return 2 end,
        GetShapeshiftForm = function() return 1 end,
        GetShapeshiftFormInfo = function(i) return 100 + i, i == 1, true, 13160 + i end,
        GetShapeshiftFormCooldown = function(i) return i == 2 and 990 or 0, i == 2 and 30 or 0, 1 end,
        C_Spell = { GetSpellName = function(id) return "Aspect " .. id end },
        UnitPowerType = function() return 2, "FOCUS", 1, 1, 0 end,
        UnitPower = function(_, powerType) return powerType == 0 and 400 or 90 end,
        UnitPowerMax = function(_, powerType) return powerType == 4 and 0 or 1000 end,
        UnitExists = function() return false end,
        GetComboPoints = function() error("must not be called without a combo resource") end,
        IsStealthed = function() return false end,
        C_Item = { GetWeaponEnchantInfo = function() return {} end },
        GetNumTotemSlots = function() return 0 end,
        GetTotemInfo = function() error("must not be called with 0 slots") end,
        C_Minimap = {
            GetNumTrackingTypes = function() return 3 end,
            GetTrackingInfo = function(i)
                local list = {
                    { name = "Find Fish", texture = 1, active = false, type = "spell", subType = 0, spellID = 43308 },
                    { name = "Track Beasts", texture = 2, active = true, type = "spell", subType = 1, spellID = 1494 },
                    { name = "Banker", texture = 3, active = false, type = "other", subType = 2 },
                }
                return list[i]
            end,
            GetTrackingFilter = function(i) return i == 3 and { filterID = 7 } or { spellID = 1000 + i } end,
        },
    }
    for key, value in pairs(extra or {}) do globals[key] = value end
    return globals
end

Tests["collector.classstate.hunter_baseline"] = function()
    WithGlobals(hunter(), function()
        local text, section = run()
        has(text, "플레이어 직업(UnitClassBase): HUNTER (classID 3)")
        -- forms: spellID, names via GetSpellName, active flag, cooldown as momentary value
        has(text, "형태 수: 2")
        has(text, "현재 형태 인덱스(GetShapeshiftForm")
        has(text, "- 형태 1: Aspect 13161 (spellID 13161) 활성=true 사용가능=true")
        has(text, "남은≈20s")
        has(text, "(완전: 2/2)")
        -- mana is a separate pool when the primary resource is focus
        has(text, "주 자원이 마나가 아님")
        has(text, "마나: 400 / 1000")
        -- no combo resource: empty, not a failure, no API call
        has(text, "<empty: UnitPowerMax(ComboPoints) is 0")
        assert(section.combo.state.status == "empty" and section.combo.points == nil)
        has(text, "(직업 참고)")
        -- stealth false is a real value
        has(text, "은신(IsStealthed; 드루이드 야생 표범 은신 포함 여부는 미확인): false")
        -- weapon: empty enchant list for every slot, ranged included
        has(text, "- Ranged (slot 2): <empty:")
        -- totems: 0 slots is empty, GetTotemInfo never called
        has(text, "<empty: GetNumTotemSlots returned 0")
        -- tracking
        has(text, "읽음 3/3 (완전), 활성 1, 읽지 못함 0")
        has(text, "- 활성 [2] Track Beasts (spellID 1494, type=spell, subType=1")
        has(text, "Find Fish[1]")
        has(text, "spellID 없는 비활성 유형 1종: Banker[3]")
        assert(section.tracking.activeState == nil)
    end)
end

Tests["collector.classstate.everything_unsupported_is_not_empty"] = function()
    WithGlobals({ Enum = {} }, function()
        local text, section = run()
        has(text, "<unsupported: function unavailable at runtime [GetNumShapeshiftForms]>")
        has(text, "<not_collected: form count unavailable")
        has(text, "<unsupported: Enum.PowerType.Mana unavailable")
        has(text, "<unsupported: Enum.PowerType.ComboPoints unavailable")
        has(text, "<unsupported: Enum.WeaponSlot unavailable")
        has(text, "<not_collected: totem slot count unavailable")
        has(text, "<not_collected: tracking type count unavailable")
        hasNot(text, "<empty")
        assert(section.forms.traversal.status == "not_collected")
        assert(section.weapon.state.status == "unsupported")
    end)
end

Tests["collector.classstate.combo_points_need_a_target"] = function()
    local calls = 0
    local combo = function(max, target)
        return hunter({
            UnitPowerMax = function(_, powerType) return powerType == 4 and max or 100 end,
            UnitExists = function() return target end,
            GetComboPoints = function(unit, to)
                calls = calls + 1
                assert(unit == "player" and to == "target")
                return 3
            end,
        })
    end
    WithGlobals(combo(5, false), function()
        local text, section = run()
        assert(calls == 0, "GetComboPoints must not be called without a target")
        assert(section.combo.state.status == "empty")
        has(text, "no target: GetComboPoints not called")
    end)
    WithGlobals(combo(5, true), function()
        local text = run()
        assert(calls == 1)
        has(text, "연계 점수(GetComboPoints player->target, 현재 대상 기준 순간값): 3")
        has(text, "최대(UnitPowerMax ComboPoints): 5")
    end)
    -- unreadable target existence: unresolved, not "no target"
    WithGlobals(combo(5, nil), function()
        local _, section = run()
        assert(calls == 1)
        assert(section.combo.state.status == "not_collected")
    end)
end

Tests["collector.classstate.restricted_combo_points"] = function()
    WithGlobals(hunter({
        UnitPowerMax = function(_, powerType) return powerType == 4 and 5 or 100 end,
        UnitExists = function() return true end,
        GetComboPoints = function() return FCE_SECRET end,
    }), function()
        local text, section = run()
        assert(section.combo.points.status == "restricted")
        has(text, "<restricted")
    end)
end

Tests["collector.classstate.mana_pool_variants"] = function()
    -- primary power is mana: the value duplicates the character section
    WithGlobals(hunter({ UnitPowerType = function() return 0, "MANA", 0, 0, 1 end }), function()
        local text = run()
        has(text, "주 자원이 마나: character 구역의 현재 자원 값과 같음")
    end)
    -- no mana pool at all
    WithGlobals(hunter({ UnitPowerMax = function() return 0 end }), function()
        local text = run()
        has(text, "<empty: UnitPowerMax(Mana)=0")
    end)
    -- restricted current mana keeps the max
    WithGlobals(hunter({ UnitPower = function(_, powerType) return powerType == 0 and FCE_SECRET or 1 end }),
        function()
            local text = run()
            has(text, "마나: current=<restricted")
        end)
end

Tests["collector.classstate.forms_none_and_partial"] = function()
    WithGlobals(hunter({ GetNumShapeshiftForms = function() return 0 end,
        GetShapeshiftFormInfo = function() error("must not be called") end }), function()
        local text, section = run()
        assert(section.forms.traversal.status == "empty")
        has(text, "<empty: GetNumShapeshiftForms returned 0")
    end)
    -- a failing entry does not erase the others, and a missing spell name keeps the spellID
    WithGlobals(hunter({
        GetShapeshiftFormInfo = function(i)
            if i == 1 then error("blocked") end
            return 1, false, false, 5
        end,
        C_Spell = { GetSpellName = function() end },
    }), function()
        local text = run()
        has(text, "- 형태 1: <error:")
        has(text, "(spellID 5) 활성=false 사용가능=false")
        has(text, "<not_collected")
    end)
    -- forms beyond the cap are marked truncated
    WithGlobals(hunter({ GetNumShapeshiftForms = function() return 40 end }), function()
        local text, section = run()
        assert(#section.forms.entries == 20 and section.forms.complete == false)
        has(text, "(잘림: 20/40 형태만 읽음)")
    end)
end

Tests["collector.classstate.weapon_enchants"] = function()
    local seen = {}
    WithGlobals(hunter({
        C_Item = { GetWeaponEnchantInfo = function(slot)
            seen[#seen + 1] = slot
            if slot == 0 then
                return { { hasEnchant = true, enchantType = 3, timeLeft = 1800000, charges = 0, enchantID = 283,
                    enchantIconID = 135 } }
            elseif slot == 1 then
                return { { hasEnchant = false, enchantType = 0, timeLeft = 0, charges = 0, enchantID = 0,
                    enchantIconID = 0 } }
            end
            return {}
        end },
    }), function()
        local text = run()
        assert(seen[1] == 0 and seen[2] == 1 and seen[3] == 2 and #seen == 3)
        has(text, "- MainHand (slot 0): hasEnchant=true enchantType=3 (Imbue) enchantID=283 charges=0 "
            .. "timeLeft(raw)=1800000 ≈1800s")
        has(text, "- OffHand (slot 1): hasEnchant=false enchantType=0 (None)")
        has(text, "- Ranged (slot 2): <empty:")
    end)
    -- API raising for one slot only affects that slot
    WithGlobals(hunter({
        C_Item = { GetWeaponEnchantInfo = function(slot)
            if slot == 1 then error("nope") end
            return {}
        end },
    }), function()
        local text = run()
        has(text, "- MainHand (slot 0): <empty:")
        has(text, "- OffHand (slot 1): <error:")
    end)
    -- the new struct API is required: an absent function is unsupported, never the old multi-return global
    WithGlobals(hunter({ C_Item = false, GetWeaponEnchantInfo = function() return true, 1000, 0 end }), function()
        local text = run()
        has(text, "<unsupported: function unavailable at runtime [C_Item.GetWeaponEnchantInfo]>")
        hasNot(text, "hasEnchant=true")
    end)
    -- a secret field makes the slot restricted
    WithGlobals(hunter({
        C_Item = { GetWeaponEnchantInfo = function() return { { hasEnchant = true, timeLeft = FCE_SECRET } } end },
    }), function()
        local text = run()
        has(text, "- MainHand (slot 0): <restricted")
    end)
end

Tests["collector.classstate.totems"] = function()
    local timeLeftCalls = {}
    WithGlobals(hunter({
        GetNumTotemSlots = function() return 4 end,
        GetTotemInfo = function(slot)
            if slot == 1 then return true, "Searing Totem", 900, 55, 1, 1, 3599 end
            if slot == 2 then return false, "", 0, 0, 0, 0, 0 end
            if slot == 3 then return end -- MayReturnNothing
            return true, FCE_SECRET, 900, 55, 1, 1, 3600
        end,
        GetTotemTimeLeft = function(slot)
            timeLeftCalls[#timeLeftCalls + 1] = slot
            return 42
        end,
    }), function()
        local text, section = run()
        has(text, "토템 슬롯 수(API 값, 고정 안 함): 4")
        has(text, "- 슬롯 1: Searing Totem (spellID 3599) startTime=900 duration=55 modRate=1")
        has(text, "GetTotemTimeLeft, 단위 미확인)=42")
        has(text, "- 슬롯 2: <empty: haveTotem=false>")
        -- nothing returned is unresolved, never empty
        has(text, "- 슬롯 3: <not_collected")
        has(text, "MayReturnNothing")
        assert(section.totems.entries[3].info.status == "not_collected")
        -- a secret value is restricted and its text is not printed
        has(text, "- 슬롯 4: <restricted")
        assert(section.totems.entries[4].info.status == "restricted")
        -- time left only for a slot that has a totem
        assert(#timeLeftCalls == 1 and timeLeftCalls[1] == 1)
        has(text, "(설치됨 1 / 읽은 슬롯 4 / 전체 4, 완전)")
    end)
    -- slot count comes from the API (not 4) and is capped with a visible marker
    WithGlobals(hunter({
        GetNumTotemSlots = function() return 30 end,
        GetTotemInfo = function() return false, "", 0, 0, 0, 0, 0 end,
    }), function()
        local text, section = run()
        assert(#section.totems.entries == 12 and section.totems.complete == false)
        has(text, "전체 30, 잘림)")
    end)
    -- unsupported API
    WithGlobals(hunter({ GetNumTotemSlots = false }), function()
        local text = run()
        has(text, "<unsupported: function unavailable at runtime [GetNumTotemSlots]>")
    end)
end

Tests["collector.classstate.tracking_none_active_unreadable_and_truncated"] = function()
    -- all readable, none active: empty
    WithGlobals(hunter({
        C_Minimap = {
            GetNumTrackingTypes = function() return 1 end,
            GetTrackingInfo = function() return { name = "Find Fish", active = false, type = "spell", subType = 0 } end,
            GetTrackingFilter = function() return { spellID = 1 } end,
        },
    }), function()
        local text, section = run()
        assert(section.tracking.activeState.status == "empty")
        has(text, "<empty: all 1 tracking types read; none active>")
    end)
    -- a type that returns nil is unreadable: "none active" must not be claimed
    WithGlobals(hunter({
        C_Minimap = {
            GetNumTrackingTypes = function() return 2 end,
            GetTrackingInfo = function(i) if i == 1 then return { name = "A", active = false } end end,
            GetTrackingFilter = function() end,
        },
    }), function()
        local text, section = run()
        assert(section.tracking.unreadable == 1 and section.tracking.activeState.status == "not_collected")
        has(text, "NOT proof of none")
        hasNot(text, "none active")
    end)
    -- more types than the cap: truncated marker and a bounded number of reads
    local infoCalls = 0
    WithGlobals(hunter({
        C_Minimap = {
            GetNumTrackingTypes = function() return 100 end,
            GetTrackingInfo = function(i)
                infoCalls = infoCalls + 1
                return { name = "T" .. i, active = i == 5, type = "spell", subType = 0, spellID = i }
            end,
            GetTrackingFilter = function() return { spellID = 1 } end,
        },
    }), function()
        local text, section = run()
        assert(infoCalls == 60 and #section.tracking.entries == 60 and section.tracking.complete == false)
        has(text, "읽음 60/100 (잘림), 활성 1")
        has(text, "- 활성 [5] T5")
    end)
    -- unsupported and error
    WithGlobals(hunter({ C_Minimap = false }), function()
        local text = run()
        has(text, "<unsupported: function unavailable at runtime [C_Minimap.GetNumTrackingTypes]>")
    end)
end

Tests["collector.classstate.stealth_states"] = function()
    WithGlobals(hunter({ IsStealthed = function() return true end }), function()
        local text, section = run()
        assert(section.stealth.status == "ok" and section.stealth.values[1] == true)
        has(text, "은신(IsStealthed; 드루이드 야생 표범 은신 포함 여부는 미확인): true")
    end)
    WithGlobals(hunter({ IsStealthed = false }), function()
        local text = run()
        has(text, "<unsupported: function unavailable at runtime [IsStealthed]>")
    end)
end

Tests["collector.classstate.read_only_apis_are_never_called"] = function()
    local forbidden = {}
    local function trap(name)
        return function() forbidden[#forbidden + 1] = name end
    end
    WithGlobals(hunter({
        CastShapeshiftForm = trap("CastShapeshiftForm"),
        CancelShapeshiftForm = trap("CancelShapeshiftForm"),
        DestroyTotem = trap("DestroyTotem"),
        TargetTotem = trap("TargetTotem"),
        GetTotemDuration = trap("GetTotemDuration"),
        GetNumTotemSlots = function() return 1 end,
        GetTotemInfo = function() return true, "Totem", 1, 1, 1, 1, 1 end,
        GetTotemTimeLeft = function() return 1 end,
    }), function()
        local original = Addon.Probe
        local probed = {}
        Addon.Probe = function(self, path, ...)
            probed[#probed + 1] = path
            return original(self, path, ...)
        end
        local ok, err = pcall(run)
        Addon.Probe = original
        assert(ok, err)
        assert(#forbidden == 0, table.concat(forbidden, ","))
        for _, path in ipairs(probed) do
            assert(not string.find(path, "Cast") and not string.find(path, "Cancel") and not string.find(path, "Destroy")
                and not string.find(path, "SetTracking") and not string.find(path, "ClearAll"), path)
        end
    end)
end

Tests["collector.classstate.section_registered_and_ordered"] = function()
    assert(type(Addon.collectors.classstate) == "function" and type(Addon.formatters.classstate) == "function")
    local found = false
    for _, name in ipairs(Addon.order) do
        if name == "classstate" then found = true end
    end
    assert(found)
end

-- The first hunter report printed MainHand and Ranged twice: one API call returned two entries, it was not a double read.
Tests["collector.classstate.several_entries_in_one_call_are_numbered_not_duplicated"] = function()
    local calls = {}
    WithGlobals(hunter({
        C_Item = { GetWeaponEnchantInfo = function(slot)
            calls[slot] = (calls[slot] or 0) + 1
            if slot == 0 then
                return { { hasEnchant = false, enchantType = 0 }, { hasEnchant = false, enchantType = 0 } }
            end
            return {}
        end },
    }), function()
        local text = run()
        assert(calls[0] == 1, "the API is called once per slot")
        has(text, "- MainHand (slot 0) [항목 1/2]: hasEnchant=false")
        has(text, "- MainHand (slot 0) [항목 2/2]: hasEnchant=false")
        has(text, "슬롯마다 API를 1번만 호출함")
    end)
end
