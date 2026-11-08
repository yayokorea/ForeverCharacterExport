local _, Addon = ...

-- Professions collector: the crafting list the profession window reads, observed only while a trade skill is
-- open. Read-only: nothing is opened, closed, selected, filtered or requested; no Set*/Open*/Close* call exists
-- in this file. The existing `skills` section owns skill levels, which are out of scope here.
--
-- Evidence. The brief named references/upstream, but the TradeSkill declarations and Blizzard_Professions* are NOT
-- stored there (only PaperDollFrame.lua:2133 uses C_TradeSkillUI). They are in the research cache
-- dev/.tools/forever-research/Interface/AddOns/ (same pinned commit eac30af597e5aaa43a60f6675ef5fdcea100375f,
-- docs/collection-expansion-research.md "U" sources). Paths below are relative to that Interface/AddOns/ folder:
--   Doc = Blizzard_APIDocumentationGenerated/TradeSkillUIDocumentation.lua   (retail superset: not proof of Forever)
--   Types = Blizzard_APIDocumentationGenerated/TradeSkillUITypesDocumentation.lua
--   PRO = Blizzard_ProfessionsTemplates/Blizzard_Professions.lua
--   FORM = Blizzard_ProfessionsTemplates/Blizzard_ProfessionsRecipeSchematicForm.lua
--   FRAME = Blizzard_Professions/Blizzard_ProfessionsFrame.lua
--   CRAFT = Blizzard_Professions/Blizzard_ProfessionsCrafting.lua
--   CAM = Blizzard_ProfessionsTemplates/Camelot/Blizzard_Professions.lua
--   CAMFRAME = Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.lua
--
-- DECLARED (Doc has the function; shape from Doc/Types):
--   C_TradeSkillUI.GetRecipeInfo(recipeID) -> TradeSkillRecipeInfo|nil   Doc:639; Types:388-436 (learned, canSkillUp,
--     relativeDifficulty, craftable, disabled, disabledReason, previousRecipeID, nextRecipeID, name, recipeID)
--   C_TradeSkillUI.GetRecipeSchematic(recipeID, isRecraft:bool non-nilable) -> CraftingRecipeSchematic   Doc:753;
--     Types:281-296 (outputItemID, quantityMin/Max, reagentSlotSchematics); slot Types:243-259 (reagents[],
--     reagentType, quantityRequired, required, slotIndex); CraftingReagent Types:214-221 (itemID|currencyID,
--     both Nilable)
--   C_TradeSkillUI.GetRecipeRequirements(recipeID) -> CraftingRecipeRequirement[]   Doc:738; Types:271-278 (name, met,
--     type); RecipeRequirementType Types:17-28 (SpellFocus 0, Totem 1, Area 2) - the raw type is printed, not mapped
--   C_TradeSkillUI.GetCraftableCount(recipeID) -> number   Doc:172; UI call RecipeList.lua:337
--   C_TradeSkillUI.GetChildProfessionInfo() / GetBaseProfessionInfo() -> ProfessionInfo   Doc:130-145; Types:361-376
--     (professionID, professionName, parentProfessionID, parentProfessionName)
--   C_TradeSkillUI.IsNPCCrafting() -> bool   Doc:932
--   C_TradeSkillUI.GetShowLearned() / GetShowUnlearned() -> bool   Doc:840/849
--   C_TradeSkillUI.IsRecipeInSkillLine(recipeID, skillLineID) -> bool   Doc:1001
--   C_Item.GetItemCount(itemInfo, includeBank, includeUses, includeReagentBank, includeAccountBank) -> number
--     references/upstream/.../ItemDocumentation.lua:451-468 (all four flags default false)
--   C_Item.GetItemNameByID(itemInfo) -> string|nil   references/upstream/.../ItemDocumentation.lua:846 (nil = not read)
-- UI-CALL-ONLY (no declaration in Doc; return shape inferred from the call site, so treat as UNVERIFIED shape):
--   C_TradeSkillUI.GetFilteredRecipeIDs() -> array of recipeID, iterated with ipairs: PRO:847. It is the FILTERED
--     list the window builds from, never a full recipe list. No GetAllRecipeIDs is used or assumed.
--   C_TradeSkillUI.GetRecipeCooldown(recipeID) -> cooldown, isDayCooldown, charges, maxCharges: PRO:1571-1580
--     (nil cooldown = no cooldown there), FORM:563-585 (charges/maxCharges, isDayCooldown, cooldown in seconds)
--   C_TradeSkillUI.IsTradeSkillGuild() / IsTradeSkillGuildMember() / IsTradeSkillLinked() -> linked, linkedName:
--     PRO:377-379 (IsViewingExternalCraftingList), FRAME:264-267
--   C_TradeSkillUI.IsTradeSkillReady(): PRO:285.   C_TradeSkillUI.IsDataSourceChanging(): FRAME:152,180
--   Filter getters (read only): GetRecipeItemNameFilter, GetOnlyShowMakeableRecipes, GetOnlyShowSkillUpRecipes,
--     GetOnlyShowFirstCraftRecipes: PRO:1174-1177; AnyRecipeCategoriesFiltered, AreAnyInventorySlotsFiltered: PRO:1098
-- UI SEMANTICS used:
--   * Which profession is selected: GetChildProfessionInfo(), falling back to GetBaseProfessionInfo() when the child
--     professionID is 0 (PRO:1665-1675); effective skill line = parentProfessionID or professionID (PRO:1678-1681);
--     CAMFRAME:28,93,97 treats an effective skill line of 0 as "no trade skill open".
--   * Window events: TRADE_SKILL_SHOW / TRADE_SKILL_CLOSE (FRAME:3-11, handlers FRAME:172,210).
--   * Data source: external list = guild or guild member or linked (PRO:377-379); local = not NPC and not external
--     (PRO:381-383). The list is rebuilt per data source (CRAFT:304-306).
--   * The window list: GetFilteredRecipeIDs, kept only if searching, NPC crafting, or
--     IsRecipeInSkillLine(recipeID, professionInfo.professionID) (PRO:845-849; CRAFT:915). Forever additionally forces
--     SetShowUnlearned(false) whenever it rebuilds the list (CAM:15-21), so the default list is learned-only.
--   * Reagents: the UI sums owned counts over every reagent of a slot against quantityRequired (PRO:648-662) and its
--     own craft count is floor(owned / required) minimised over slots (CRAFT:507).
-- NOT collected: camping crafts (no API evidence found), persisted snapshots, any Set*/Open*/Close* call.

local TS = "C_TradeSkillUI."
local DEFAULT_MAX_RECIPES = 15 -- recipes expanded in one report
local HARD_MAX_RECIPES = 200
local MAX_SLOTS = 12 -- reagent slots read per recipe
local MAX_SLOT_REAGENTS = 8 -- alternative reagents read per slot
local MAX_REQUIREMENTS = 8
local DETAIL_SUMMARY, DETAIL_REAGENTS = "summary", "reagents"

local function isCount(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function tableOf(self, result)
    local value = self:Val(result, 1)
    if type(value) == "table" then return value end
end

-- Limits are file constants. A saved-variable override is accepted but never required:
--   /run ForeverCharacterExportDB.professions = { maxRecipes = 100, detail = "summary" }
local function readLimits(self)
    local limits = { maxRecipes = DEFAULT_MAX_RECIPES, hardMax = HARD_MAX_RECIPES, detail = DETAIL_REAGENTS,
        source = "default" }
    local override = type(self.db) == "table" and self.db.professions or nil
    if type(override) == "table" then
        local n = override.maxRecipes
        if type(n) == "number" and n >= 1 and n % 1 == 0 then
            limits.maxRecipes = math.min(n, HARD_MAX_RECIPES)
            limits.source = "ForeverCharacterExportDB.professions"
        end
        if override.detail == DETAIL_SUMMARY or override.detail == DETAIL_REAGENTS then
            limits.detail = override.detail
            limits.source = "ForeverCharacterExportDB.professions"
        end
    end
    return limits
end

-- ---------------------------------------------------------------------------------------------------------------
-- Window events. Session memory only: nothing is persisted. A window that was open before a reload is not seen.

local function windowEvent(open)
    return function(self, event)
        self.tradeSkillWindow = { open = open, event = event, at = self:Now() }
    end
end
Addon:On("TRADE_SKILL_SHOW", windowEvent(true))
Addon:On("TRADE_SKILL_CLOSE", windowEvent(false))

local function eventSignal(self)
    local seen = self.tradeSkillWindow
    if type(seen) ~= "table" then return "unseen" end
    return seen.open == true and "open" or "closed"
end

-- ---------------------------------------------------------------------------------------------------------------
-- Which profession is selected (PRO:1665-1681)

local function infoTable(self, result)
    local info = tableOf(self, result)
    if info and type(info.professionID) == "number" then return info end
end

local function readProfession(self)
    local prof = {
        child = self:Probe(TS .. "GetChildProfessionInfo"),
        base = self:Probe(TS .. "GetBaseProfessionInfo"),
    }
    local child, base = infoTable(self, prof.child), infoTable(self, prof.base)
    local chosen
    if child and child.professionID ~= 0 then
        chosen, prof.source = child, "child"
    elseif base then
        -- The UI falls back to the base info when the child id is 0 (or the child info is not available).
        chosen, prof.source = base, "base"
    end
    if chosen then
        local parent = chosen.parentProfessionID
        prof.effectiveId = type(parent) == "number" and parent or chosen.professionID
        prof.skillLineId = chosen.professionID
        if type(chosen.professionName) == "string" then prof.name = chosen.professionName end
        if type(parent) == "number" then prof.parentId = parent end
        if type(chosen.parentProfessionName) == "string" then prof.parentName = chosen.parentProfessionName end
        prof.api = prof.effectiveId == 0 and "closed" or "open"
    else
        prof.api = "unknown"
    end
    return prof
end

-- "open" / "closed" / "conflict" / "unknown" from the two independent signals.
local function windowVerdict(apiSignal, events)
    if apiSignal == "unknown" then return "unknown" end
    if apiSignal == "open" then
        return events == "closed" and "conflict" or "open"
    end
    return events == "open" and "conflict" or "closed"
end

-- ---------------------------------------------------------------------------------------------------------------
-- Data source and filters

-- guild/guildMember/linked => external list; npc => NPC list; own only when every signal is a readable false.
local function readSource(self)
    local source = {
        guild = self:Probe(TS .. "IsTradeSkillGuild"),
        guildMember = self:Probe(TS .. "IsTradeSkillGuildMember"),
        linked = self:Probe(TS .. "IsTradeSkillLinked"),
        npc = self:Probe(TS .. "IsNPCCrafting"),
        ready = self:Probe(TS .. "IsTradeSkillReady"),
        changing = self:Probe(TS .. "IsDataSourceChanging"),
    }
    local active, allFalse = {}, true
    for _, key in ipairs({ "guild", "guildMember", "linked", "npc" }) do
        local value = self:Val(source[key], 1)
        if value == true then
            active[#active + 1] = key
        elseif value ~= false then
            allFalse = false
        end
    end
    source.active = active
    -- linkedName (second return, FRAME:267) is another player's name: only its presence is recorded.
    local linkedName = self:Val(source.linked, 2)
    source.linkedNamePresent = type(linkedName) == "string" and linkedName ~= ""
    if type(source.linked.values) == "table" then source.linked.values[2] = nil end
    if #active > 1 then
        source.kind = "mixed"
    elseif #active == 1 then
        source.kind = active[1] == "npc" and "npc" or (active[1] == "linked" and "linked" or "guild")
    elseif allFalse then
        source.kind = "own"
    else
        source.kind = "unknown"
    end
    return source
end

local FILTER_APIS = {
    { "textFilter", "GetRecipeItemNameFilter" },
    { "onlyMakeable", "GetOnlyShowMakeableRecipes" },
    { "onlySkillUps", "GetOnlyShowSkillUpRecipes" },
    { "onlyFirstCraft", "GetOnlyShowFirstCraftRecipes" },
    { "showUnlearned", "GetShowUnlearned" },
    { "showLearned", "GetShowLearned" },
    { "categoriesFiltered", "AnyRecipeCategoriesFiltered" },
    { "slotsFiltered", "AreAnyInventorySlotsFiltered" },
}

local function readFilters(self)
    local filters = {}
    local active, unreadable = {}, 0
    for _, spec in ipairs(FILTER_APIS) do
        local key = spec[1]
        local result = self:Probe(TS .. spec[2])
        filters[key] = result
        local value = self:Val(result, 1)
        if result.status ~= "ok" then
            unreadable = unreadable + 1
        elseif key == "textFilter" then
            if type(value) == "string" and value ~= "" then active[#active + 1] = key end
        elseif key == "showUnlearned" or key == "showLearned" then
            if value == false then active[#active + 1] = key .. "=false" end
        elseif value == true then
            active[#active + 1] = key
        end
    end
    filters.summary = { active = active, unreadable = unreadable }
    return filters
end

-- ---------------------------------------------------------------------------------------------------------------
-- Recipe list

-- Whether the window would drop recipes outside the selected skill line (PRO:845-849).
local function skillLineMode(self, filters, source)
    local text = self:Val(filters.textFilter, 1)
    local npc = self:Val(source.npc, 1)
    if (type(text) == "string" and text ~= "") or npc == true then return "not_applied" end
    if type(text) == "string" and npc == false then return "applied" end
    return "unknown"
end

local function readList(self, prof, filters, source, limits)
    local list = { api = self:Probe(TS .. "GetFilteredRecipeIDs"), completeness = "filtered", ids = {} }
    -- Always a filtered view: Forever hides unlearned recipes by default and the window also applies search,
    -- category, slot, skill-line and source filters. This is NEVER the full recipe list of the profession.
    local ids = tableOf(self, list.api)
    if list.api.status == "ok" and not ids then
        list.state = self:State("error", "GetFilteredRecipeIDs returned a non-table value")
        list.state.api = TS .. "GetFilteredRecipeIDs"
    end
    if not ids then return list end
    list.mode = skillLineMode(self, filters, source)
    list.total, list.invalid, list.duplicates, list.excluded, list.unreadable = 0, 0, 0, 0, 0
    local seen, skillLine = {}, {}
    local checking = list.mode ~= "not_applied"
    for _, id in ipairs(ids) do
        list.total = list.total + 1
        if not isCount(id) then
            list.invalid = list.invalid + 1
        elseif seen[id] then
            list.duplicates = list.duplicates + 1
        else
            seen[id] = true
            local keep = true
            if checking then
                local result = self:Probe(TS .. "IsRecipeInSkillLine", id, prof.skillLineId)
                if result.status == "unsupported" then
                    checking, list.mode = false, "unavailable"
                    list.modeProbe = result
                else
                    skillLine[id] = result
                    local inLine = self:Val(result, 1)
                    if inLine == false and list.mode == "applied" then
                        keep = false
                        list.excluded = list.excluded + 1
                    elseif result.status ~= "ok" then
                        list.unreadable = list.unreadable + 1
                    end
                end
            end
            if keep then list.ids[#list.ids + 1] = id end
        end
    end
    list.eligible = #list.ids
    list.shown = math.min(list.eligible, limits.maxRecipes)
    list.truncated = list.eligible > list.shown
    list.skillLine = skillLine
    return list
end

-- ---------------------------------------------------------------------------------------------------------------
-- Reagents

local function itemFacts(self, section, itemID)
    local facts = section.items[itemID]
    if not facts then
        facts = {
            count = self:Probe("C_Item.GetItemCount", itemID, false, false, false, false),
            name = self:Probe("C_Item.GetItemNameByID", itemID),
        }
        section.items[itemID] = facts
    end
    return facts
end

local function deriveSlot(self, section, index, slot)
    local entry = { index = index, quantity = slot.quantityRequired, required = slot.required,
        reagentType = slot.reagentType, reagents = {} }
    local total, readable = 0, true
    if type(slot.reagents) ~= "table" then
        entry.reagentsMissing = true
        readable = false
    else
        for position, reagent in ipairs(slot.reagents) do
            if position > MAX_SLOT_REAGENTS then
                entry.reagentsTruncated = true
                readable = false -- unread alternatives could change the owned total
                break
            end
            local item = {}
            if type(reagent) ~= "table" then
                item.kind = "malformed"
                readable = false
            elseif type(reagent.itemID) == "number" then
                item.kind, item.id = "item", reagent.itemID
                local count = self:Val(itemFacts(self, section, reagent.itemID).count, 1)
                if isCount(count) then
                    item.owned = count
                    total = total + count
                else
                    readable = false
                end
            elseif type(reagent.currencyID) == "number" then
                item.kind, item.id = "currency", reagent.currencyID
                readable = false -- currency amounts are not read by this collector
            else
                item.kind = "malformed"
                readable = false
            end
            entry.reagents[#entry.reagents + 1] = item
        end
    end
    if #entry.reagents == 0 then readable = false end
    if readable then
        entry.owned = total
        if type(entry.quantity) == "number" then entry.shortage = math.max(0, entry.quantity - total) end
    end
    return entry
end

-- Bag-based craft count: floor(owned / required) minimised over required slots (the UI does the same, CRAFT:507).
-- It ignores tools/requirements/cooldown and is not the client's GetCraftableCount.
local function deriveReagents(self, section, recipe)
    local schematic = tableOf(self, recipe.schematic)
    if not schematic then return nil end
    local derived = { slots = {}, outputItemID = schematic.outputItemID, quantityMin = schematic.quantityMin,
        quantityMax = schematic.quantityMax, recipeType = schematic.recipeType }
    if type(schematic.reagentSlotSchematics) ~= "table" then
        derived.state = self:State("error", "schematic has no reagentSlotSchematics table")
        return derived
    end
    for index, slot in ipairs(schematic.reagentSlotSchematics) do
        if index > MAX_SLOTS then
            derived.slotsTruncated = true
            break
        end
        if type(slot) == "table" then
            derived.slots[#derived.slots + 1] = deriveSlot(self, section, index, slot)
        else
            derived.slots[#derived.slots + 1] = { index = index, malformed = true }
        end
    end
    local crafts, requiredSlots, reason = nil, 0, nil
    for _, entry in ipairs(derived.slots) do
        if entry.malformed then
            reason = "a reagent slot was malformed"
        elseif entry.required == true then
            requiredSlots = requiredSlots + 1
            if entry.owned == nil or type(entry.quantity) ~= "number" or entry.quantity <= 0 then
                reason = "a required slot has an unread owned count (currency, unreadable item, or no quantity)"
            else
                local slotCrafts = math.floor(entry.owned / entry.quantity)
                crafts = crafts and math.min(crafts, slotCrafts) or slotCrafts
            end
        elseif entry.required ~= false then
            reason = "a slot's required flag is not a boolean"
        end
    end
    if derived.slotsTruncated then reason = reason or "more reagent slots than were read" end
    if requiredSlots == 0 then reason = reason or "no required reagent slot" end
    if reason then
        derived.bagCraftsReason = reason
    else
        derived.bagCrafts = crafts
    end
    return derived
end

-- ---------------------------------------------------------------------------------------------------------------
-- One recipe

local function readRecipe(self, section, id, detail, skillLine)
    local recipe = {
        id = id,
        info = self:Probe(TS .. "GetRecipeInfo", id),
        craftable = self:Probe(TS .. "GetCraftableCount", id),
        cooldown = self:Probe(TS .. "GetRecipeCooldown", id),
        skillLine = skillLine,
    }
    if detail == DETAIL_REAGENTS then
        recipe.schematic = self:Probe(TS .. "GetRecipeSchematic", id, false)
        recipe.requirements = self:Probe(TS .. "GetRecipeRequirements", id)
        local ok, derived = pcall(deriveReagents, self, section, recipe)
        if ok then
            recipe.derived = derived
        else
            recipe.deriveState = self:Failure(derived)
        end
    end
    return recipe
end

-- ---------------------------------------------------------------------------------------------------------------

local function noteState(self, reason, kind)
    return self:State(kind or "not_collected", reason)
end

Addon:RegisterCollector("professions", function(self)
    local section = {
        scope = "열려 있는 전문기술 창이 읽는 제작 목록만 (라이브 읽기). 창을 열거나 전문기술·필터를 바꾸지 않고, "
            .. "저장본 없음. 숙련도는 skills 구역 담당",
        observedAt = self:Timestamp(),
        limits = readLimits(self),
        items = {},
    }
    local events = eventSignal(self)
    local prof = readProfession(self)
    section.profession = prof
    section.window = {
        verdict = windowVerdict(prof.api, events),
        api = prof.api,
        events = events,
        eventAt = type(self.tradeSkillWindow) == "table" and self.tradeSkillWindow.at or nil,
        eventRegistration = {
            TRADE_SKILL_SHOW = self.eventStatus.TRADE_SKILL_SHOW,
            TRADE_SKILL_CLOSE = self.eventStatus.TRADE_SKILL_CLOSE,
        },
    }
    local verdict = section.window.verdict
    if verdict == "closed" then
        section.state = noteState(self, "profession window not open: no trade skill selected; observed nothing "
            .. "(this is NOT a statement about the recipes the character knows)")
        return section
    elseif verdict == "conflict" then
        section.state = noteState(self, "window signals disagree (API " .. prof.api .. ", events " .. events
            .. "); observed nothing")
        return section
    elseif verdict == "unknown" then
        local unsupported = prof.child.status == "unsupported" and prof.base.status == "unsupported"
        section.state = noteState(self, unsupported and "C_TradeSkillUI profession info unavailable at runtime"
            or "selected profession could not be read; observed nothing", unsupported and "unsupported" or nil)
        return section
    end

    section.source = readSource(self)
    if self:Val(section.source.changing, 1) == true then
        section.state = noteState(self, "trade skill data source is changing (IsDataSourceChanging); observed nothing")
        return section
    end
    section.filters = readFilters(self)
    section.list = readList(self, prof, section.filters, section.source, section.limits)
    section.recipes = {}
    local list = section.list
    for position = 1, list.shown or 0 do
        local id = list.ids[position]
        section.recipes[position] = readRecipe(self, section, id, section.limits.detail, list.skillLine[id])
    end
    list.skillLine = nil -- only the entries of shown recipes are kept (recipe.skillLine)
    return section
end, function(self, section, out)
    local function yn(value)
        if value == true then return "예" elseif value == false then return "아니오" end
        return self:Fmt(value)
    end
    local function flag(label, result)
        local tag = self:Describe(result)
        return label .. "=" .. (tag or yn(result.values[1]))
    end
    local function seconds(value)
        value = math.floor(value)
        if value >= 3600 then return math.floor(value / 3600) .. "시간 " .. math.floor((value % 3600) / 60) .. "분" end
        if value >= 60 then return math.floor(value / 60) .. "분 " .. (value % 60) .. "초" end
        return value .. "초"
    end

    out:Add("범위: " .. section.scope)
    local observed = self:Val(section.observedAt, 1)
    out:Add("관측 시각: " .. self:Date(observed) .. " (" .. self:Age(observed) .. ") | 캐릭터 저장본 아님, 창이 열린 순간의 읽기")
    local limits = section.limits
    out:Add("제한: 상세 수준=" .. limits.detail .. " (summary=제작법 정보·제작 가능 수·쿨다운 / reagents=재료·부족량·조건 추가), "
        .. "최대 " .. limits.maxRecipes .. "개 표시 (상한 " .. limits.hardMax .. "), 출처=" .. limits.source)

    out:Add("### 전문기술 창")
    local window, prof = section.window, section.profession
    local verdictText = { open = "열림", closed = "열려 있지 않음", conflict = "신호 충돌", unknown = "확인 불가" }
    out:Add("창 상태: " .. verdictText[window.verdict] .. " | API 신호=" .. window.api .. " | 이벤트 신호=" .. window.events
        .. (window.eventAt and (" (" .. self:Date(window.eventAt) .. ")") or "")
        .. " | TRADE_SKILL_SHOW/CLOSE 등록=" .. self:Fmt(window.eventRegistration.TRADE_SKILL_SHOW) .. "/"
        .. self:Fmt(window.eventRegistration.TRADE_SKILL_CLOSE))
    out:Result("선택된 전문기술 정보 (자식)", prof.child, function(value)
        if type(value) ~= "table" then return self:Fmt(value) end
        return self:Fmt(value.professionName) .. " (id " .. self:Fmt(value.professionID) .. ")"
    end)
    out:Result("선택된 전문기술 정보 (기본)", prof.base, function(value)
        if type(value) ~= "table" then return self:Fmt(value) end
        return self:Fmt(value.professionName) .. " (id " .. self:Fmt(value.professionID) .. ")"
    end)
    if prof.source then
        out:Add("사용한 전문기술: " .. self:Fmt(prof.name) .. " (스킬라인 id " .. self:Fmt(prof.skillLineId) .. ", 유효 id "
            .. self:Fmt(prof.effectiveId) .. ", 상위 " .. self:Fmt(prof.parentName) .. " " .. self:Fmt(prof.parentId)
            .. ", 출처=" .. prof.source .. ")")
    end
    if section.state then
        out:State("제작 목록", section.state)
        if section.window.verdict == "closed" then
            out:Add("창 열리지 않음, 관측 없음: 제작법 0개라는 뜻이 아니라 읽지 않았다는 뜻입니다. "
            .. "전문기술 책 페이지만 열려 있고 제작 목록이 선택되지 않았을 때도 같은 상태입니다. 제작 목록을 연 상태에서 다시 내보내세요.")
        end
        return
    end

    out:Add("### 데이터 소스")
    local source = section.source
    local kindText = {
        own = "이 캐릭터의 제작 목록으로 보임 (외부·NPC 신호가 모두 읽힌 거짓)",
        linked = "링크로 본 다른 사람의 제작 목록 — 이 캐릭터의 제작법이 아님",
        guild = "길드 제작 목록 — 이 캐릭터의 제작법이 아님",
        npc = "NPC 제작 목록 — 이 캐릭터의 제작법이 아님",
        mixed = "여러 외부 신호가 동시에 참 (" .. table.concat(source.active, ",") .. ") — 이 캐릭터의 제작법으로 간주하지 않음",
        unknown = "확인 불가 — 일부 신호를 읽지 못해 이 캐릭터의 목록이라고 단정하지 않음",
    }
    out:Add("데이터 소스: " .. kindText[source.kind])
    out:Add("신호: " .. flag("길드 목록", source.guild) .. " | " .. flag("길드원 목록", source.guildMember) .. " | "
        .. flag("링크 목록", source.linked) .. (source.linkedNamePresent and " (링크 대상 이름 있음, 기록 안 함)" or "")
        .. " | " .. flag("NPC 제작", source.npc))
    out:Add("준비 상태: " .. flag("IsTradeSkillReady", source.ready) .. " | "
        .. flag("IsDataSourceChanging", source.changing)
        .. (self:Val(source.ready, 1) == false and " | 준비되지 않았을 수 있어 목록이 덜 채워졌을 수 있음" or ""))

    out:Add("### 필터")
    local filters = section.filters
    local parts = {}
    for _, spec in ipairs(FILTER_APIS) do
        local result = filters[spec[1]]
        local tag = self:Describe(result)
        parts[#parts + 1] = spec[1] .. "=" .. (tag or self:Fmt(result.values[1]))
    end
    out:Add("읽은 필터: " .. table.concat(parts, " | "))
    out:Add("활성 필터: " .. (#filters.summary.active > 0 and table.concat(filters.summary.active, ", ") or "없음(읽은 범위)")
        .. " | 읽지 못한 필터 " .. filters.summary.unreadable .. "개")
    out:Add("참고: Forever 창은 목록을 만들 때마다 미학습 제작법 숨김(SetShowUnlearned(false))을 적용하므로 기본 목록은 배운 것만입니다.")

    out:Add("### 제작법")
    local list = section.list
    if list.state then
        out:State("제작 목록", list.state)
        return
    end
    local listTag = self:Describe(list.api)
    if listTag then
        out:Add("GetFilteredRecipeIDs: " .. listTag)
        return
    end
    out:Add("완전성: 필터된 목록입니다 — 전문기술의 전체 제작법이 아닙니다 (검색·분류·슬롯·학습 여부·스킬라인 필터가 적용된 창 기준).")
    local modeText = {
        applied = "적용 (스킬라인 밖 제작법 제외)",
        not_applied = "미적용 (검색 중이거나 NPC 제작)",
        unknown = "판단 불가 (검색어/NPC 신호를 읽지 못함) — 제외하지 않고 표시만 함",
        unavailable = "IsRecipeInSkillLine 사용 불가 — 제외하지 않음",
    }
    out:Add("필터된 ID " .. list.total .. "개 중 스킬라인 제외 " .. list.excluded .. "개, 표시 후보 " .. list.eligible
        .. "개 (스킬라인 필터: " .. modeText[list.mode] .. ", 스킬라인 판정 못 읽음 " .. list.unreadable
        .. ", 잘못된 ID " .. list.invalid .. ", 중복 " .. list.duplicates .. ")")
    if list.eligible == 0 then
        out:Add("<empty: 현재 창의 필터된 목록이 비어 있음 [C_TradeSkillUI.GetFilteredRecipeIDs]> 전체 제작법이 없다는 뜻이 아님")
        return
    end
    if list.truncated then
        out:Add("표시 " .. list.shown .. " / " .. list.eligible .. " — 잘림(truncated): 나머지 "
            .. (list.eligible - list.shown) .. "개는 읽지 않음 (API 반환 순서의 앞부분)")
    else
        out:Add("표시 " .. list.shown .. " / " .. list.eligible .. " — 필터된 목록 안에서는 모두 표시(complete within filter)")
    end

    local noCooldownValue = false
    for _, recipe in ipairs(section.recipes) do
        local head = "- [recipeID " .. recipe.id .. "] "
        local infoTag = self:Describe(recipe.info)
        if infoTag then
            out:Add(head .. "제작법 정보: " .. infoTag)
        else
            local info = recipe.info.values[1]
            if type(info) ~= "table" then
                out:Add(head .. "<error: unexpected return type " .. type(info) .. " ["
                    .. tostring(recipe.info.api) .. "]>")
            else
                local line = head .. self:Fmt(info.name) .. " | 학습=" .. yn(info.learned) .. " | 숙련 상승 가능="
                    .. yn(info.canSkillUp) .. " | 난이도(원시)=" .. self:Fmt(info.relativeDifficulty)
                    .. " | 제작 가능 표시=" .. yn(info.craftable)
                if info.disabled == true then
                    line = line .. " | 비활성: " .. self:Fmt(info.disabledReason)
                end
                if info.previousRecipeID ~= nil or info.nextRecipeID ~= nil then
                    line = line .. " | 이전/다음 랭크 ID=" .. self:Fmt(info.previousRecipeID) .. "/"
                        .. self:Fmt(info.nextRecipeID)
                end
                out:Add(line)
            end
        end
        local craftTag = self:Describe(recipe.craftable)
        local derived = recipe.derived
        local bagText
        if derived == nil then
            local schematicTag = recipe.schematic and self:Describe(recipe.schematic)
            bagText = recipe.schematic and ("<not_collected: " .. (schematicTag or "schematic not derived") .. ">")
                or "계산 안 함(summary)"
        elseif derived.bagCrafts ~= nil then
            bagText = tostring(derived.bagCrafts)
        else
            bagText = "<not_collected: " .. tostring(derived.bagCraftsReason or "schematic unavailable") .. ">"
        end
        local cooldownText
        local cooldownTag = self:Describe(recipe.cooldown)
        if cooldownTag then
            noCooldownValue = noCooldownValue or (recipe.cooldown.status == "not_collected")
            cooldownText = cooldownTag
        else
            local v = recipe.cooldown.values
            local cooldown, isDay, charges, maxCharges = v[1], v[2], v[3], v[4]
            if type(cooldown) == "number" then
                cooldownText = "남은 " .. seconds(cooldown) .. (isDay == true and " (일 단위 쿨다운: 자정 기준)" or "")
            elseif cooldown == nil then
                cooldownText = "없음(API가 시간을 주지 않음)"
            else
                cooldownText = "<error: cooldown " .. type(cooldown) .. ">"
            end
            if type(charges) == "number" and type(maxCharges) == "number" and maxCharges > 0 then
                cooldownText = cooldownText .. " | 충전 " .. charges .. "/" .. maxCharges
            end
            cooldownText = cooldownText .. " (관측 시점 기준)"
        end
        local requirementText, requirementLine
        if recipe.requirements then
            local reqTag = self:Describe(recipe.requirements)
            local requirements = not reqTag and recipe.requirements.values[1]
            if reqTag then
                requirementLine = reqTag
            elseif type(requirements) ~= "table" then
                requirementLine = "<error: unexpected return type " .. type(requirements) .. ">"
            elseif #requirements == 0 then
                requirementText = "조건 없음(API 반환 목록이 빈 표)"
            else
                local items = {}
                for index, requirement in ipairs(requirements) do
                    if index > MAX_REQUIREMENTS then
                        items[#items + 1] = "..."
                        break
                    end
                    items[#items + 1] = type(requirement) == "table" and (self:Fmt(requirement.name) .. " (충족="
                        .. yn(requirement.met) .. ", 유형(원시)=" .. self:Fmt(requirement.type) .. ")") or "<error>"
                end
                requirementLine = table.concat(items, " / ")
            end
        end
        local derivedOutput = derived and derived.outputItemID ~= nil and (" | 결과 itemID "
            .. self:Fmt(derived.outputItemID) .. " x" .. self:Fmt(derived.quantityMin)
            .. (derived.quantityMax ~= derived.quantityMin and ("-" .. self:Fmt(derived.quantityMax)) or "")) or ""
        out:Add("    제작 가능 수: API " .. (craftTag or self:Fmt(recipe.craftable.values[1]))
            .. " (은행 포함 여부 미검증) | 가방 기준 계산 " .. bagText .. " | 쿨다운: " .. cooldownText
            .. (requirementText and (" | " .. requirementText) or "") .. derivedOutput)
        if requirementLine then out:Add("    조건: " .. requirementLine) end

        if recipe.deriveState then
            out:State("    재료 분석", recipe.deriveState)
        elseif not derived and recipe.schematic then
            out:Add("    재료: " .. (self:Describe(recipe.schematic) or "<not_collected: schematic not derived>"))
        elseif derived then
            local schematicTag = nil
            if derived.state then schematicTag = self:Describe(derived.state) end
            if schematicTag then out:Add("    재료: " .. schematicTag) end
            for _, entry in ipairs(derived.slots) do
                if entry.malformed then
                    out:Add("    재료칸 " .. entry.index .. ": <error: unexpected slot shape>")
                else
                    local names = {}
                    for _, item in ipairs(entry.reagents) do
                        if item.kind == "item" then
                            local facts = section.items[item.id]
                            local name = facts and self:Val(facts.name, 1)
                            local label = type(name) == "string" and self:Clean(name) or "이름 못 읽음"
                            names[#names + 1] = label .. " (itemID "
                                .. item.id .. ") 보유 " .. (item.owned ~= nil and item.owned or "<not_collected>")
                        elseif item.kind == "currency" then
                            names[#names + 1] = "화폐 currencyID " .. item.id .. " (수량 읽지 않음)"
                        else
                            names[#names + 1] = "<error: malformed reagent>"
                        end
                    end
                    local need = type(entry.quantity) == "number" and entry.quantity or "?"
                    local kind = entry.required == true and "필수" or (entry.required == false and "선택" or "필수 여부 불명")
                    local shortage
                    if entry.shortage ~= nil then
                        shortage = entry.shortage > 0 and ("부족 " .. entry.shortage) or "충분"
                    else
                        shortage = "부족량 <not_collected>"
                    end
                    out:Add("    재료칸 " .. entry.index .. " [" .. kind .. ", 유형(원시)=" .. self:Fmt(entry.reagentType)
                        .. "] 필요 " .. need .. " | " .. shortage .. " | " .. table.concat(names, " / ")
                        .. (entry.reagentsTruncated and " | 대체 재료 일부만 읽음" or ""))
                end
            end
            if derived.slotsTruncated then out:Add("    재료칸이 " .. MAX_SLOTS .. "개를 넘어 나머지는 읽지 않음") end
        end
    end
    if noCooldownValue then
        out:Add("참고: GetRecipeCooldown이 값을 반환하지 않은 제작법이 있습니다. Blizzard UI는 값이 없으면 쿨다운 없음으로 다루지만"
            .. "(Professions.lua:1571-1574) 이 애드온은 그렇게 단정하지 않고 not_collected로 둡니다.")
    end
    out:Add("참고: '가방 기준 계산'은 C_Item.GetItemCount(itemID, includeBank=false)로 센 보유량을 재료칸 필요량으로 나눈 값입니다. "
        .. "도구·조건·쿨다운은 반영하지 않으며, 착용 중인 아이템이 세어지는지는 미검증입니다.")
end)
