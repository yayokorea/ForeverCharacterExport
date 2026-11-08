-- Mocked contract tests for the professions collector (not a WoW runtime; the real API shapes are unverified).
-- luacheck: read globals C_TradeSkillUI C_Item
local Addon = AddonUnderTest

local function reset()
    Addon.tradeSkillWindow = nil
    Addon.db = nil
end

local function run()
    local section = Addon.collectors.professions(Addon)
    local out = Addon:NewWriter()
    Addon.formatters.professions(Addon, section, out)
    return out:Output(), section
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function hasNot(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

local function count(calls, name)
    local n = 0
    for _, call in ipairs(calls) do
        if call.name == name then n = n + 1 end
    end
    return n
end

local function first(calls, name)
    for _, call in ipairs(calls) do
        if call.name == name then return call end
    end
end

local SLOT_PLATES = { reagents = { { itemID = 2772 } }, reagentType = 1, quantityRequired = 2, required = true,
    slotIndex = 1, dataSlotIndex = 1 }
local SLOT_BARS = { reagents = { { itemID = 3575 } }, reagentType = 1, quantityRequired = 1, required = true,
    slotIndex = 2, dataSlotIndex = 2 }

local function defaultInfo(id)
    return { name = "Recipe " .. id, recipeID = id, learned = true, canSkillUp = false, relativeDifficulty = 2,
        craftable = true, disabled = false }
end

-- Builds C_TradeSkillUI. o.fn replaces a function; every call is recorded in o.calls.
local function trade(o)
    o = o or {}
    o.calls = o.calls or {}
    local profession = o.profession or { professionID = 164, professionName = "Blacksmithing" }
    local function value(v) return function() return v end end
    local defaults = {
        GetChildProfessionInfo = value(profession),
        GetBaseProfessionInfo = value(profession),
        IsTradeSkillGuild = value(false),
        IsTradeSkillGuildMember = value(false),
        IsTradeSkillLinked = value(false),
        IsNPCCrafting = value(false),
        IsTradeSkillReady = value(true),
        IsDataSourceChanging = value(false),
        GetRecipeItemNameFilter = value(""),
        GetOnlyShowMakeableRecipes = value(false),
        GetOnlyShowSkillUpRecipes = value(false),
        GetOnlyShowFirstCraftRecipes = value(false),
        GetShowUnlearned = value(false),
        GetShowLearned = value(true),
        AnyRecipeCategoriesFiltered = value(false),
        AreAnyInventorySlotsFiltered = value(false),
        GetFilteredRecipeIDs = value(o.ids or { 101, 102 }),
        IsRecipeInSkillLine = function(id) return not (o.outsideLine and o.outsideLine[id]) end,
        GetRecipeInfo = function(id)
            if o.info and o.info[id] ~= nil then return o.info[id] or nil end
            return defaultInfo(id)
        end,
        GetCraftableCount = function(id) return o.craftable and o.craftable[id] or 0 end,
        GetRecipeCooldown = function(id)
            if o.cooldown and o.cooldown[id] then return unpack(o.cooldown[id], 1, 4) end
            return nil, nil, nil, nil
        end,
        GetRecipeSchematic = function(id)
            if o.schematic and o.schematic[id] then return o.schematic[id] end
            return { recipeID = id, outputItemID = 5000 + id, quantityMin = 1, quantityMax = 1, recipeType = 1,
                reagentSlotSchematics = { SLOT_PLATES, SLOT_BARS } }
        end,
        GetRecipeRequirements = function(id) return o.requirements and o.requirements[id] or {} end,
    }
    local api = {}
    for name, fn in pairs(defaults) do
        local impl = o.fn and o.fn[name] or fn
        api[name] = function(...)
            o.calls[#o.calls + 1] = { name = name, args = { ... } }
            return impl(...)
        end
    end
    for name, impl in pairs(o.fn or {}) do
        if not api[name] then api[name] = impl end
    end
    return api
end

local function items(o)
    o = o or {}
    o.calls = o.calls or {}
    return {
        GetItemCount = function(id, ...)
            o.calls[#o.calls + 1] = { name = "GetItemCount", args = { id, ... } }
            return o.counts and o.counts[id] or 0
        end,
        GetItemNameByID = function(id)
            o.calls[#o.calls + 1] = { name = "GetItemNameByID", args = { id } }
            return o.names and o.names[id]
        end,
    }
end

local function openWindow()
    Addon.Dispatch(nil, "TRADE_SKILL_SHOW")
end

Tests["collector.professions.closed_window_observes_nothing"] = function()
    reset()
    local o = { profession = { professionID = 0 } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        local text, section = run()
        has(text, "창 상태: 열려 있지 않음")
        has(text, "창 열리지 않음, 관측 없음")
        has(text, "profession window not open")
        assert(section.state.status == "not_collected")
        assert(section.window.verdict == "closed" and section.recipes == nil and section.list == nil)
        -- nothing beyond the two profession-info reads was asked of the client
        assert(count(o.calls, "GetFilteredRecipeIDs") == 0 and count(o.calls, "IsTradeSkillLinked") == 0)
        assert(count(o.calls, "GetRecipeInfo") == 0)
        hasNot(text, "<empty")
        local counts = Addon:Tally(section)
        assert(counts.not_collected >= 1)
    end)
end

Tests["collector.professions.closed_child_falls_back_to_base"] = function()
    reset()
    local o = { fn = {
        GetChildProfessionInfo = function() return { professionID = 0 } end,
        GetBaseProfessionInfo = function() return { professionID = 164, professionName = "Blacksmithing" } end,
    } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        local text, section = run()
        assert(section.profession.source == "base" and section.window.verdict == "open")
        has(text, "출처=base")
    end)
end

Tests["collector.professions.parent_profession_is_the_effective_skill_line"] = function()
    reset()
    local o = { profession = { professionID = 2437, professionName = "Child", parentProfessionID = 164,
        parentProfessionName = "Blacksmithing" } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        local text, section = run()
        assert(section.profession.effectiveId == 164 and section.profession.skillLineId == 2437)
        -- IsRecipeInSkillLine uses the selected (child) professionID, as the window does
        assert(first(o.calls, "IsRecipeInSkillLine").args[2] == 2437)
        has(text, "스킬라인 id 2437, 유효 id 164")
    end)
end

Tests["collector.professions.unsupported_api"] = function()
    reset()
    WithGlobals({ C_TradeSkillUI = false }, function()
        local text, section = run()
        assert(section.state.status == "unsupported" and section.window.verdict == "unknown")
        has(text, "C_TradeSkillUI profession info unavailable at runtime")
        hasNot(text, "열려 있지 않음")
    end)
end

Tests["collector.professions.unreadable_profession_is_unknown_not_closed"] = function()
    reset()
    local o = { fn = {
        GetChildProfessionInfo = function() return FCE_SECRET end,
        GetBaseProfessionInfo = function() end,
    } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        local text, section = run()
        assert(section.window.verdict == "unknown" and section.state.status == "not_collected")
        has(text, "selected profession could not be read; observed nothing")
        has(text, "창 상태: 확인 불가")
        hasNot(text, "창 열리지 않음, 관측 없음")
    end)
end

Tests["collector.professions.events_toggle_the_flag"] = function()
    reset()
    local o = {}
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        local _, section = run()
        assert(section.window.events == "unseen" and section.window.verdict == "open")
        openWindow()
        _, section = run()
        assert(section.window.events == "open" and section.window.verdict == "open")
        Addon.Dispatch(nil, "TRADE_SKILL_CLOSE")
        assert(Addon.tradeSkillWindow.open == false and Addon.tradeSkillWindow.event == "TRADE_SKILL_CLOSE")
    end)
    -- window closed in the API and by event: closed
    WithGlobals({ C_TradeSkillUI = trade({ profession = { professionID = 0 } }), C_Item = items() }, function()
        local text, section = run()
        assert(section.window.events == "closed" and section.window.verdict == "closed")
        has(text, "이벤트 신호=closed")
    end)
end

Tests["collector.professions.signal_conflict_reads_nothing"] = function()
    reset()
    -- API says open, but the last event was a close
    local o = {}
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        Addon.Dispatch(nil, "TRADE_SKILL_CLOSE")
        local text, section = run()
        assert(section.window.verdict == "conflict" and section.list == nil)
        has(text, "창 상태: 신호 충돌 | API 신호=open | 이벤트 신호=closed")
        has(text, "window signals disagree (API open, events closed); observed nothing")
        assert(count(o.calls, "GetFilteredRecipeIDs") == 0)
    end)
    -- API says closed, but the last event was a show
    reset()
    local closed = { profession = { professionID = 0 } }
    WithGlobals({ C_TradeSkillUI = trade(closed), C_Item = items() }, function()
        openWindow()
        local text, section = run()
        assert(section.window.verdict == "conflict")
        has(text, "API 신호=closed | 이벤트 신호=open")
        assert(count(closed.calls, "GetFilteredRecipeIDs") == 0)
    end)
end

Tests["collector.professions.open_own_list_full_detail"] = function()
    reset()
    local o = {
        info = { [101] = { name = "|cff1eff00Iron Buckle|r", recipeID = 101, learned = true, canSkillUp = true,
            relativeDifficulty = 1, craftable = true, disabled = false, previousRecipeID = 99, nextRecipeID = 103 } },
        craftable = { [101] = 3 },
        requirements = { [101] = { { name = "Anvil", met = false, type = 1 }, { name = "Forge", met = true, type = 0 } } },
    }
    o.calls = {}
    local counts = { calls = o.calls, counts = { [2772] = 5, [3575] = 1 }, names = { [2772] = "Iron Bar" } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items(counts) }, function()
        openWindow()
        local text, section = run()
        has(text, "창 상태: 열림 | API 신호=open | 이벤트 신호=open")
        has(text, "데이터 소스: 이 캐릭터의 제작 목록으로 보임")
        has(text, "완전성: 필터된 목록입니다 — 전문기술의 전체 제작법이 아닙니다")
        has(text, "표시 2 / 2 — 필터된 목록 안에서는 모두 표시(complete within filter)")
        has(text, "- [recipeID 101] Iron Buckle | 학습=예 | 숙련 상승 가능=예 | 난이도(원시)=1")
        has(text, "이전/다음 랭크 ID=99/103")
        has(text, "제작 가능 수: API 3 (은행 포함 여부 미검증) | 가방 기준 계산 1")
        has(text, "쿨다운: 없음(API가 시간을 주지 않음) (관측 시점 기준)")
        has(text, "결과 itemID 5101 x1")
        -- slot 1: need 2, have 5 -> enough; slot 2: need 1, have 1 -> enough, but unnamed
        has(text, "재료칸 1 [필수, 유형(원시)=1] 필요 2 | 충분 | Iron Bar (itemID 2772) 보유 5")
        has(text, "재료칸 2 [필수, 유형(원시)=1] 필요 1 | 충분 | 이름 못 읽음 (itemID 3575) 보유 1")
        has(text, "조건: Anvil (충족=아니오, 유형(원시)=1) / Forge (충족=예, 유형(원시)=0)")
        local derived = section.recipes[1].derived
        assert(derived.bagCrafts == 1, "min(floor(5/2), floor(1/1)) = 1, got " .. tostring(derived.bagCrafts))
    end)
end

Tests["collector.professions.read_only_call_surface"] = function()
    reset()
    local allowed = {
        GetChildProfessionInfo = true, GetBaseProfessionInfo = true, IsTradeSkillGuild = true,
        IsTradeSkillGuildMember = true, IsTradeSkillLinked = true, IsNPCCrafting = true, IsTradeSkillReady = true,
        IsDataSourceChanging = true, GetRecipeItemNameFilter = true, GetOnlyShowMakeableRecipes = true,
        GetOnlyShowSkillUpRecipes = true, GetOnlyShowFirstCraftRecipes = true, GetShowUnlearned = true,
        GetShowLearned = true, AnyRecipeCategoriesFiltered = true, AreAnyInventorySlotsFiltered = true,
        GetFilteredRecipeIDs = true, IsRecipeInSkillLine = true, GetRecipeInfo = true, GetCraftableCount = true,
        GetRecipeCooldown = true, GetRecipeSchematic = true, GetRecipeRequirements = true,
    }
    local base = trade({})
    local touched = {}
    local strict = setmetatable({}, { __index = function(_, key)
        touched[key] = true
        return base[key]
    end })
    local strictItem = setmetatable({}, { __index = function(_, key)
        touched["C_Item." .. key] = true
        return items()[key]
    end })
    WithGlobals({ C_TradeSkillUI = strict, C_Item = strictItem }, function()
        openWindow()
        run()
    end)
    for name in pairs(touched) do
        assert(allowed[name] or name == "C_Item.GetItemCount" or name == "C_Item.GetItemNameByID",
            "unexpected API touched: " .. name)
    end
    assert(touched.GetRecipeSchematic and touched["C_Item.GetItemCount"])
end

Tests["collector.professions.argument_shapes"] = function()
    reset()
    local o = {}
    o.calls = {}
    local counts = { calls = o.calls }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items(counts) }, function()
        openWindow()
        run()
        local schematic = first(o.calls, "GetRecipeSchematic")
        assert(schematic.args[1] == 101 and schematic.args[2] == false, "isRecraft must be an explicit false")
        local item = first(o.calls, "GetItemCount")
        assert(item.args[1] == 2772 and item.args[2] == false and item.args[3] == false and item.args[4] == false
            and item.args[5] == false, "bank, uses, reagent bank and account bank must be excluded")
        local infoArgs = first(o.calls, "GetRecipeInfo").args
        assert(infoArgs[1] == 101 and #infoArgs == 1, "no optional recipeLevel is passed")
    end)
end

local function sourceCase(overrides)
    reset()
    local o = { fn = overrides }
    local result
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text, section = run()
        result = { text = text, section = section, calls = o.calls }
    end)
    return result
end

Tests["collector.professions.linked_list_is_not_own"] = function()
    local r = sourceCase({ IsTradeSkillLinked = function() return true, "SomeOtherPlayer" end })
    has(r.text, "데이터 소스: 링크로 본 다른 사람의 제작 목록 — 이 캐릭터의 제작법이 아님")
    has(r.text, "링크 대상 이름 있음, 기록 안 함")
    hasNot(r.text, "SomeOtherPlayer")
    assert(r.section.source.kind == "linked" and r.section.source.linkedNamePresent == true)
    -- the name must not reach the raw section (diag export) either
    assert(r.section.source.linked.values[2] == nil and r.section.source.linkedName == nil)
    assert(not string.find(Addon:Export({ sections = { professions = r.section } }, false), "SomeOtherPlayer", 1, true))
end

Tests["collector.professions.guild_and_npc_lists_are_not_own"] = function()
    local guild = sourceCase({ IsTradeSkillGuild = function() return true end })
    has(guild.text, "길드 제작 목록 — 이 캐릭터의 제작법이 아님")
    local member = sourceCase({ IsTradeSkillGuildMember = function() return true end })
    assert(member.section.source.kind == "guild")
    local npc = sourceCase({ IsNPCCrafting = function() return true end })
    has(npc.text, "NPC 제작 목록 — 이 캐릭터의 제작법이 아님")
    -- NPC crafting shows every recipe: the skill line filter is not applied
    assert(npc.section.list.mode == "not_applied" and count(npc.calls, "IsRecipeInSkillLine") == 0)
    local both = sourceCase({ IsTradeSkillGuild = function() return true end, IsNPCCrafting = function() return true end })
    assert(both.section.source.kind == "mixed")
    has(both.text, "여러 외부 신호가 동시에 참 (guild,npc)")
end

Tests["collector.professions.scope_unknown_when_a_signal_is_unreadable"] = function()
    reset()
    local o = {}
    local api = trade(o)
    api.IsTradeSkillGuild = nil
    WithGlobals({ C_TradeSkillUI = api, C_Item = items() }, function()
        openWindow()
        local text, section = run()
        assert(section.source.kind == "unknown", "absent signal must not default to own")
        has(text, "데이터 소스: 확인 불가")
        has(text, "<unsupported: function unavailable at runtime [C_TradeSkillUI.IsTradeSkillGuild]>")
        hasNot(text, "이 캐릭터의 제작 목록으로 보임")
    end)
    -- a signal that returns no value is unresolved, not false
    local silent = sourceCase({ IsTradeSkillLinked = function() end })
    assert(silent.section.source.kind == "unknown")
    has(silent.text, "링크 목록=<not_collected")
    -- restricted
    local secret = sourceCase({ IsNPCCrafting = function() return FCE_SECRET end })
    assert(secret.section.source.kind == "unknown")
end

Tests["collector.professions.data_source_changing_reads_nothing"] = function()
    local r = sourceCase({ IsDataSourceChanging = function() return true end })
    has(r.text, "trade skill data source is changing")
    assert(r.section.list == nil and count(r.calls, "GetFilteredRecipeIDs") == 0)
end

Tests["collector.professions.not_ready_is_flagged"] = function()
    local r = sourceCase({ IsTradeSkillReady = function() return false end })
    has(r.text, "준비되지 않았을 수 있어 목록이 덜 채워졌을 수 있음")
end

Tests["collector.professions.filters_are_reported"] = function()
    local r = sourceCase({
        GetRecipeItemNameFilter = function() return "buckle" end,
        GetOnlyShowMakeableRecipes = function() return true end,
        AnyRecipeCategoriesFiltered = function() end,
    })
    has(r.text, "textFilter=buckle")
    has(r.text, "onlyMakeable=true")
    has(r.text, "categoriesFiltered=<not_collected")
    has(r.text, "활성 필터: textFilter, onlyMakeable, showUnlearned=false | 읽지 못한 필터 1개")
    -- searching shows every recipe, so the skill line filter is not applied
    assert(r.section.list.mode == "not_applied" and count(r.calls, "IsRecipeInSkillLine") == 0)
    -- the list is a filtered view even when every filter is at its default
    local plain = sourceCase({})
    assert(plain.section.list.completeness == "filtered")
    has(plain.text, "전체 제작법이 아닙니다")
end

Tests["collector.professions.skill_line_filter_excludes_other_lines"] = function()
    reset()
    local o = { ids = { 101, 102, 103 }, outsideLine = { [102] = true } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text, section = run()
        assert(section.list.mode == "applied" and section.list.excluded == 1 and section.list.eligible == 2)
        has(text, "필터된 ID 3개 중 스킬라인 제외 1개, 표시 후보 2개")
        has(text, "recipeID 101")
        has(text, "recipeID 103")
        hasNot(text, "recipeID 102")
    end)
end

Tests["collector.professions.skill_line_check_unavailable_or_unreadable_excludes_nothing"] = function()
    reset()
    local o = { ids = { 101, 102 } }
    local api = trade(o)
    api.IsRecipeInSkillLine = nil
    WithGlobals({ C_TradeSkillUI = api, C_Item = items() }, function()
        openWindow()
        local text, section = run()
        assert(section.list.mode == "unavailable" and section.list.eligible == 2)
        has(text, "IsRecipeInSkillLine 사용 불가")
        has(text, "recipeID 102")
    end)
    -- unknown search state: annotate only
    local r = sourceCase({ GetRecipeItemNameFilter = function() return FCE_SECRET end })
    assert(r.section.list.mode == "unknown" and r.section.list.excluded == 0)
end

Tests["collector.professions.empty_filtered_list_is_not_zero_recipes"] = function()
    reset()
    local o = { ids = {} }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text, section = run()
        has(text, "<empty: 현재 창의 필터된 목록이 비어 있음 [C_TradeSkillUI.GetFilteredRecipeIDs]> 전체 제작법이 없다는 뜻이 아님")
        assert(section.list.eligible == 0 and #section.recipes == 0)
        assert(count(o.calls, "GetRecipeInfo") == 0)
    end)
end

Tests["collector.professions.filtered_list_failures"] = function()
    reset()
    local silent = { fn = { GetFilteredRecipeIDs = function() end } }
    WithGlobals({ C_TradeSkillUI = trade(silent), C_Item = items() }, function()
        openWindow()
        local text = run()
        has(text, "GetFilteredRecipeIDs: <not_collected")
        hasNot(text, "<empty")
    end)
    local absent = trade({})
    absent.GetFilteredRecipeIDs = nil
    WithGlobals({ C_TradeSkillUI = absent, C_Item = items() }, function()
        local text = run()
        has(text, "GetFilteredRecipeIDs: <unsupported")
    end)
    local wrong = { fn = { GetFilteredRecipeIDs = function() return 7 end } }
    WithGlobals({ C_TradeSkillUI = trade(wrong), C_Item = items() }, function()
        local text = run()
        has(text, "GetFilteredRecipeIDs returned a non-table value")
    end)
    local broken = { fn = { GetFilteredRecipeIDs = function() error("blocked") end } }
    WithGlobals({ C_TradeSkillUI = trade(broken), C_Item = items() }, function()
        local text = run()
        has(text, "GetFilteredRecipeIDs: <error")
    end)
end

Tests["collector.professions.invalid_and_duplicate_ids"] = function()
    reset()
    local o = { ids = { 101, "x", 101, -3, 102 } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text, section = run()
        assert(section.list.total == 5 and section.list.invalid == 2 and section.list.duplicates == 1)
        assert(section.list.eligible == 2)
        has(text, "잘못된 ID 2, 중복 1")
        assert(count(o.calls, "GetRecipeInfo") == 2)
    end)
end

Tests["collector.professions.cap_truncates_visibly"] = function()
    reset()
    local ids = {}
    for index = 1, 60 do ids[index] = 1000 + index end
    local o = { ids = ids }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text, section = run()
        assert(section.limits.maxRecipes == 15 and section.limits.detail == "reagents")
        assert(section.limits.source == "default" and section.limits.hardMax == 200)
        assert(section.list.shown == 15 and section.list.eligible == 60 and section.list.truncated == true)
        assert(#section.recipes == 15 and count(o.calls, "GetRecipeInfo") == 15)
        assert(count(o.calls, "GetRecipeSchematic") == 15)
        has(text, "표시 15 / 60 — 잘림(truncated): 나머지 45개는 읽지 않음")
        has(text, "제한: 상세 수준=reagents")
        hasNot(text, "complete within filter")
        has(text, "recipeID 1015")
        hasNot(text, "recipeID 1016")
    end)
end

Tests["collector.professions.cap_and_detail_override"] = function()
    reset()
    local ids = {}
    for index = 1, 30 do ids[index] = 2000 + index end
    local o = { ids = ids }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        Addon.db = { professions = { maxRecipes = 5, detail = "summary" } }
        local _
        local text, section = run()
        assert(section.limits.maxRecipes == 5 and section.limits.detail == "summary")
        assert(section.limits.source == "ForeverCharacterExportDB.professions")
        assert(#section.recipes == 5)
        -- summary detail never asks for reagents or requirements
        assert(count(o.calls, "GetRecipeSchematic") == 0 and count(o.calls, "GetRecipeRequirements") == 0)
        assert(count(o.calls, "GetItemCount") == 0)
        has(text, "표시 5 / 30 — 잘림(truncated)")
        has(text, "가방 기준 계산 계산 안 함(summary)")
        hasNot(text, "재료칸 1")
        -- the override cannot raise the cap above the hard limit
        Addon.db = { professions = { maxRecipes = 5000 } }
        _, section = run()
        assert(section.limits.maxRecipes == 200 and section.limits.detail == "reagents")
        -- nonsense values are ignored
        Addon.db = { professions = { maxRecipes = -1, detail = "everything" } }
        _, section = run()
        assert(section.limits.maxRecipes == 15 and section.limits.source == "default")
    end)
    reset()
end

Tests["collector.professions.cooldown_variants"] = function()
    reset()
    local o = { ids = { 1, 2, 3, 4, 5 }, cooldown = {
        [2] = { 90061, false, nil, nil },
        [3] = { 43200, true, nil, nil },
        [4] = { nil, nil, 2, 3 },
        [5] = { 1800, false, 1, 3 },
    }, fn = {} }
    -- recipe 1 uses the default four nils (no cooldown); recipe 6 below returns no value at all
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text = run()
        has(text, "쿨다운: 없음(API가 시간을 주지 않음) (관측 시점 기준)")
        has(text, "쿨다운: 남은 25시간 1분 (관측 시점 기준)")
        has(text, "쿨다운: 남은 12시간 0분 (일 단위 쿨다운: 자정 기준) (관측 시점 기준)")
        has(text, "쿨다운: 없음(API가 시간을 주지 않음) | 충전 2/3")
        has(text, "쿨다운: 남은 30분 0초 | 충전 1/3 (관측 시점 기준)")
    end)
    local silent = { ids = { 7 }, fn = { GetRecipeCooldown = function() end } }
    WithGlobals({ C_TradeSkillUI = trade(silent), C_Item = items() }, function()
        local text, section = run()
        has(text, "쿨다운: <not_collected: API returned no value")
        has(text, "GetRecipeCooldown이 값을 반환하지 않은 제작법이 있습니다")
        assert(section.recipes[1].cooldown.status == "not_collected")
    end)
    local unsupported = trade({ ids = { 7 } })
    unsupported.GetRecipeCooldown = nil
    WithGlobals({ C_TradeSkillUI = unsupported, C_Item = items() }, function()
        local text = run()
        has(text, "쿨다운: <unsupported")
    end)
end

Tests["collector.professions.shortage_and_bag_crafts"] = function()
    reset()
    local altSlot = { reagents = { { itemID = 100 }, { itemID = 101 } }, reagentType = 1, quantityRequired = 4,
        required = true, slotIndex = 1 }
    local o = {
        ids = { 1, 2, 3, 4 },
        schematic = {
            [1] = { outputItemID = 9, quantityMin = 1, quantityMax = 3, reagentSlotSchematics = { altSlot,
                { reagents = { { itemID = 200 } }, quantityRequired = 2, required = true, reagentType = 1 },
                { reagents = { { itemID = 300 } }, quantityRequired = 1, required = false, reagentType = 2 } } },
            [2] = { reagentSlotSchematics = { { reagents = { { currencyID = 7 } }, quantityRequired = 5,
                required = true, reagentType = 1 } } },
            [3] = { reagentSlotSchematics = {} },
            [4] = { reagentSlotSchematics = { { reagents = { { itemID = 200 } }, quantityRequired = 2,
                reagentType = 1 } } },
        },
    }
    o.calls = {}
    local counts = { calls = o.calls, counts = { [100] = 1, [101] = 2, [200] = 9 }, names = { [100] = "Rough Stone",
        [101] = "Coarse Stone" } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items(counts) }, function()
        openWindow()
        local text, section = run()
        -- recipe 1: alternative reagents are summed (1+2=3 of 4 -> short 1); slot 2 has 9 of 2; optional slot has 0 of 1
        local d1 = section.recipes[1].derived
        assert(d1.slots[1].owned == 3 and d1.slots[1].shortage == 1)
        assert(d1.slots[2].owned == 9 and d1.slots[2].shortage == 0)
        assert(d1.slots[3].required == false and d1.slots[3].shortage == 1)
        assert(d1.bagCrafts == 0, "optional slot must not limit the count; floor(3/4)=0, floor(9/2)=4 -> 0")
        has(text, "필요 4 | 부족 1 | Rough Stone (itemID 100) 보유 1 / Coarse Stone (itemID 101) 보유 2")
        has(text, "재료칸 3 [선택, 유형(원시)=2] 필요 1 | 부족 1")
        has(text, "결과 itemID 9 x1-3")
        -- recipe 2: a currency reagent cannot be counted
        local d2 = section.recipes[2].derived
        assert(d2.bagCrafts == nil and d2.slots[1].owned == nil and d2.slots[1].shortage == nil)
        has(text, "화폐 currencyID 7 (수량 읽지 않음)")
        has(text, "부족량 <not_collected>")
        has(text, "가방 기준 계산 <not_collected: a required slot has an unread owned count")
        -- recipe 3: no slots at all is not "craftable 0"
        assert(section.recipes[3].derived.bagCrafts == nil)
        assert(section.recipes[3].derived.bagCraftsReason == "no required reagent slot")
        -- recipe 4: the required flag is missing -> unknown
        assert(section.recipes[4].derived.bagCrafts == nil)
        assert(string.find(section.recipes[4].derived.bagCraftsReason, "required flag", 1, true))
        has(text, "[필수 여부 불명")
        -- each item is counted once per report
        assert(count(o.calls, "GetItemCount") == 4)
    end)
end

Tests["collector.professions.unread_owned_count_is_not_zero"] = function()
    reset()
    local o = { ids = { 1 } }
    local item = { GetItemCount = function() end, GetItemNameByID = function() end }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = item }, function()
        openWindow()
        local text, section = run()
        local d = section.recipes[1].derived
        assert(d.slots[1].owned == nil and d.slots[1].shortage == nil and d.bagCrafts == nil)
        has(text, "보유 <not_collected>")
        hasNot(text, "보유 0")
    end)
    local absent = { ids = { 1 } }
    WithGlobals({ C_TradeSkillUI = trade(absent), C_Item = false }, function()
        local text, section = run()
        assert(section.recipes[1].derived.bagCrafts == nil)
        has(text, "부족량 <not_collected>")
    end)
end

Tests["collector.professions.many_slots_and_alternatives_are_capped"] = function()
    reset()
    local slots = {}
    for index = 1, 20 do
        slots[index] = { reagents = { { itemID = 10 + index } }, quantityRequired = 1, required = true, reagentType = 1 }
    end
    local many = {}
    for index = 1, 12 do many[index] = { itemID = 500 + index } end
    local o = { ids = { 1, 2 }, schematic = {
        [1] = { reagentSlotSchematics = slots },
        [2] = { reagentSlotSchematics = { { reagents = many, quantityRequired = 1, required = true, reagentType = 1 } } },
    } }
    o.calls = {}
    local counts = { calls = o.calls, counts = {} }
    for index = 1, 20 do counts.counts[10 + index] = 5 end
    for index = 1, 12 do counts.counts[500 + index] = 5 end
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items(counts) }, function()
        openWindow()
        local text, section = run()
        assert(#section.recipes[1].derived.slots == 12 and section.recipes[1].derived.slotsTruncated == true)
        assert(section.recipes[1].derived.bagCrafts == nil, "unread slots must not produce a craft count")
        has(text, "재료칸이 12개를 넘어 나머지는 읽지 않음")
        local slot = section.recipes[2].derived.slots[1]
        assert(#slot.reagents == 8 and slot.reagentsTruncated == true and slot.owned == nil)
        has(text, "대체 재료 일부만 읽음")
    end)
end

Tests["collector.professions.recipe_info_nil_keeps_the_rest"] = function()
    reset()
    local o = { ids = { 1, 2 }, info = { [1] = false }, craftable = { [1] = 4, [2] = 1 } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text, section = run()
        assert(section.recipes[1].info.status == "not_collected")
        has(text, "- [recipeID 1] 제작법 정보: <not_collected")
        has(text, "제작 가능 수: API 4")
        has(text, "- [recipeID 2] Recipe 2 |")
    end)
end

Tests["collector.professions.restricted_fields_are_tagged_not_leaked"] = function()
    reset()
    local o = { ids = { 1, 2 },
        info = { [1] = { name = FCE_SECRET, recipeID = 1, learned = true } },
        schematic = { [2] = { outputItemID = 9, reagentSlotSchematics = { { reagents = { { itemID = 200 } },
            quantityRequired = FCE_SECRET, required = true } } } },
        fn = { GetCraftableCount = function(id) if id == 2 then return FCE_SECRET end return 2 end },
    }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text, section = run()
        has(text, "- [recipeID 1] 제작법 정보: <restricted")
        assert(section.recipes[1].info.status == "restricted")
        has(text, "제작 가능 수: API 2")
        has(text, "제작 가능 수: API <restricted")
        -- the secret schematic is unreadable as a whole: no partial derivation
        assert(section.recipes[2].schematic.status == "restricted" and section.recipes[2].derived == nil)
    end)
end

Tests["collector.professions.a_failing_recipe_does_not_remove_the_others"] = function()
    reset()
    local o = { ids = { 1, 2 }, fn = { GetRecipeSchematic = function(id)
        if id == 1 then error("blocked: crafting data") end
        return { reagentSlotSchematics = {} }
    end } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text, section = run()
        has(text, "- [recipeID 1] Recipe 1")
        has(text, "- [recipeID 2] Recipe 2")
        assert(section.recipes[1].schematic.status == "error" and section.recipes[1].derived == nil)
        assert(section.recipes[2].derived ~= nil)
    end)
end

Tests["collector.professions.malformed_schematic_does_not_throw"] = function()
    reset()
    local o = { ids = { 1, 2, 3 }, schematic = {
        [1] = { reagentSlotSchematics = 5 },
        [2] = { reagentSlotSchematics = { 7, { reagents = 3, quantityRequired = 1, required = true } } },
        [3] = { reagentSlotSchematics = { { reagents = { 4, {} }, quantityRequired = 1, required = true } } },
    } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text, section = run()
        has(text, "schematic has no reagentSlotSchematics table")
        has(text, "<error: unexpected slot shape>")
        has(text, "<error: malformed reagent>")
        assert(section.recipes[2].derived.slots[2].reagentsMissing == true)
        assert(section.recipes[1].derived.bagCrafts == nil and section.recipes[3].derived.bagCrafts == nil)
    end)
end

Tests["collector.professions.requirements_variants"] = function()
    reset()
    local o = { ids = { 1, 2, 3 }, fn = { GetRecipeRequirements = function(id)
        if id == 1 then return {} end
        if id == 2 then return end
        return 5
    end } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text = run()
        has(text, "조건 없음(API 반환 목록이 빈 표)")
        has(text, "조건: <not_collected")
        has(text, "조건: <error: unexpected return type number>")
    end)
end

Tests["collector.professions.recipe_names_are_cleaned"] = function()
    reset()
    local o = { ids = { 1 }, info = { [1] = { name = "|cffff0000Red|r\nName", recipeID = 1 } } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local text = run()
        has(text, "Red Name")
        hasNot(text, "|cff")
    end)
end

Tests["collector.professions.section_survives_diag_export_and_tally"] = function()
    reset()
    local o = { ids = { 1, 2 }, craftable = { [1] = 1 } }
    WithGlobals({ C_TradeSkillUI = trade(o), C_Item = items() }, function()
        openWindow()
        local _, section = run()
        local counts = Addon:Tally(section)
        assert(counts.ok > 5)
        local text = Addon:Export({ sections = { professions = section } }, false)
        assert(string.find(text, "professions", 1, true) and string.find(text, "completeness", 1, true))
        -- the full report path
        local report = { schema = 2, sections = {}, build = Addon:Probe("GetBuildInfo") }
        for _, name in ipairs(Addon.order) do report.sections[name] = Addon:State("not_collected", "test") end
        report.sections.professions = section
        report.startedAt = Addon:Timestamp()
        local full = Addon:Report(report, false)
        assert(string.find(full, "## professions", 1, true))
        assert(string.find(full, "recipeID 1", 1, true))
    end)
end

Tests["collector.professions.registered_in_order_and_events"] = function()
    assert(type(Addon.collectors.professions) == "function" and type(Addon.formatters.professions) == "function")
    local found = false
    for _, name in ipairs(Addon.order) do found = found or name == "professions" end
    assert(found)
    assert(type(Addon.handlers.TRADE_SKILL_SHOW) == "table" and type(Addon.handlers.TRADE_SKILL_CLOSE) == "table")
end
