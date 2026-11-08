local _, Addon = ...

-- Settings logic (no widgets; UI.lua only calls these). Everything is stored in SavedVariablesPerCharacter
-- (ForeverCharacterExportDB, created in Core.lua):
--   db.sections[name] = false      section switched off (a missing entry means on, so new sections default on)
--   db.detail[name]   = "full"     long text for legacy / spelldetails / planning (anything else = summary)
--   db.professions    = { maxRecipes = n, detail = "summary"|"reagents" }  read by Collectors/Professions.lua
--   db.window         = { point, relPoint, x, y, width, height }
--   db.ui             = { leftClick = "window"|"export" }
--   db.minimap        = { angle, hide }

Addon.sectionLabels = {
    character = "캐릭터", equipment = "장비", bags = "가방", bank = "은행", quests = "퀘스트", talents = "특성",
    spells = "주문서", pet = "소환수", actionbars = "행동 단축바", skills = "기술", reputation = "평판",
    currency = "화폐/명예", auras = "버프/디버프", flightpaths = "비행 경로", addons = "애드온",
    legacy = "유산(Legacy)", classstate = "직업 상태", combatdetails = "전투 상세", professions = "전문기술 제작",
    spelldetails = "주문 상세", planning = "계획(상급자/세트/flyout/쿨다운/PvP)",
}

-- Sections with a summary/full switch. Each collector or formatter reads Addon.detail[name] (true or "full" = full).
Addon.detailSections = { "legacy", "spelldetails", "planning" }

-- Choices cycled by the UI; same limits as Collectors/Professions.lua (DEFAULT_MAX_RECIPES 15, HARD_MAX_RECIPES 200).
Addon.professionRecipeChoices = { 15, 50, 100, 200 }

local function db(self)
    return type(self.db) == "table" and self.db or nil
end

function Addon:IsSectionEnabled(name)
    local d = db(self)
    return not (d and type(d.sections) == "table" and d.sections[name] == false)
end

function Addon:SetSectionEnabled(name, enabled)
    local d = db(self)
    if not d then return false end
    if type(d.sections) ~= "table" then d.sections = {} end
    if enabled then d.sections[name] = nil else d.sections[name] = false end
    return true
end

function Addon:SetAllSections(enabled)
    for _, name in ipairs(self.order) do self:SetSectionEnabled(name, enabled) end
end

function Addon:IsDetailFull(name)
    local d = db(self)
    local value = d and type(d.detail) == "table" and d.detail[name]
    return value == true or value == "full"
end

function Addon:SetDetailFull(name, full)
    local d = db(self)
    if not d then return false end
    if type(d.detail) ~= "table" then d.detail = {} end
    d.detail[name] = full and "full" or nil
    self.detail = d.detail
    return true
end

-- Professions: the effective values are the collector defaults until the player changes something.
function Addon:ProfessionSettings()
    local d = db(self)
    local saved = d and type(d.professions) == "table" and d.professions or {}
    local maxRecipes = type(saved.maxRecipes) == "number" and saved.maxRecipes or 15
    local detail = saved.detail == "summary" and "summary" or "reagents"
    return maxRecipes, detail
end

function Addon:SetProfessionDetail(detail)
    local d = db(self)
    if not d then return false end
    if type(d.professions) ~= "table" then d.professions = {} end
    d.professions.detail = detail == "summary" and "summary" or "reagents"
    return true
end

function Addon:CycleProfessionMax()
    local d = db(self)
    if not d then return nil end
    if type(d.professions) ~= "table" then d.professions = {} end
    local current = self:ProfessionSettings()
    local choices, nextValue = self.professionRecipeChoices, nil
    for _, value in ipairs(choices) do
        if value > current then
            nextValue = value
            break
        end
    end
    d.professions.maxRecipes = nextValue or choices[1]
    return d.professions.maxRecipes
end

function Addon:LeftClickAction()
    local d = db(self)
    if d and type(d.ui) == "table" and d.ui.leftClick == "export" then return "export" end
    return "window"
end

function Addon:ToggleLeftClickAction()
    local d = db(self)
    if not d then return nil end
    if type(d.ui) ~= "table" then d.ui = {} end
    d.ui.leftClick = self:LeftClickAction() == "export" and "window" or "export"
    return d.ui.leftClick
end

-- ---------------------------------------------------------------------------------------------------------------
-- Report-derived status (used by the window and by tests; no API calls)

-- One entry per section in Addon.order: { name, level = off|ok|warn|unsupported|error, text }.
-- Rule: a disabled section is "off". A section that returned a bare non-ok state maps by that status. Otherwise
-- the Tally counts decide: no unread value = ok; unread values with at least one successful read = warn;
-- nothing read and every read unsupported = unsupported; nothing read and the rest failed = error.
function Addon:SectionSummary(report)
    local result = {}
    for _, name in ipairs(self.order) do
        local section = report and report.sections and report.sections[name]
        local entry = { name = name }
        if type(section) == "table" and section.disabled then
            entry.level, entry.text = "off", "꺼짐"
        elseif type(section) ~= "table" then
            entry.level, entry.text = "warn", "아직 수집 안 함"
        elseif self.knownStatus[section.status] and section.status ~= "ok" then
            if section.status == "unsupported" then
                entry.level, entry.text = "unsupported", "미지원"
            elseif section.status == "empty" then
                entry.level, entry.text = "ok", "비어 있음"
            elseif section.status == "not_collected" then
                entry.level, entry.text = "warn", "못 읽음"
            else
                entry.level, entry.text = "error", "오류/제한"
            end
        else
            local counts = self:Tally(section)
            local unread = counts.not_collected + counts.unsupported + counts.restricted + counts.error
            if unread == 0 then
                entry.level, entry.text = "ok", "정상"
            elseif counts.ok == 0 and counts.empty == 0 then
                if counts.unsupported > 0 and counts.unsupported >= unread then
                    entry.level, entry.text = "unsupported", "미지원 " .. counts.unsupported
                else
                    entry.level, entry.text = "error", "읽기 실패 " .. unread
                end
            else
                local parts = {}
                if counts.not_collected > 0 then parts[#parts + 1] = "못 읽음 " .. counts.not_collected end
                if counts.unsupported > 0 then parts[#parts + 1] = "미지원 " .. counts.unsupported end
                if counts.restricted > 0 then parts[#parts + 1] = "제한 " .. counts.restricted end
                if counts.error > 0 then parts[#parts + 1] = "오류 " .. counts.error end
                entry.level, entry.text = "warn", "주의: " .. table.concat(parts, ", ")
            end
        end
        result[#result + 1] = entry
    end
    return result
end

-- Player actions that would fill or complete sections, derived from the report. Strings are Korean UI text.
function Addon:NeedsAction(report)
    local list = {}
    local sections = report and report.sections or {}
    local function on(name)
        return type(sections[name]) == "table" and not sections[name].disabled
    end
    if on("professions") then
        local window = sections.professions.window
        if type(window) == "table" and window.verdict ~= "open" then
            list[#list + 1] = "전문기술 창을 열고 다시 내보내세요 (제작 목록은 창이 열려 있을 때만 읽힘)"
        end
    end
    if on("planning") then
        local trainer = sections.planning.trainer
        if type(trainer) == "table" and trainer.open == false then
            list[#list + 1] = "직업 상급자(교관) 창을 연 채로 내보내세요 (상급자 목록 수집. 이 빌드에 상급자 API가 "
                .. "있는지 확인하는 방법이기도 함)"
        end
    end
    if on("bank") and not self:Persisted("bank") then
        list[#list + 1] = "은행을 한 번 열어 두세요 (내용이 저장돼 다음부터 '저장본'으로 표시됨)"
    end
    if on("flightpaths") and not self:Persisted("flightpaths") then
        list[#list + 1] = "비행 조련사 지도를 한 번 열어 두세요 (알려진 비행 경로가 저장됨)"
    end
    if on("spelldetails") and type(sections.spelldetails.spells) == "table" then
        for _, spell in ipairs(sections.spelldetails.spells) do
            local description = spell.description
            if type(description) == "table" and description.status == "not_collected"
                and type(description.reason) == "string"
                and string.find(description.reason, "not loaded yet", 1, true) then
                list[#list + 1] = "일부 주문 설명이 아직 로딩되지 않았습니다. 잠시 뒤 다시 내보내세요"
                break
            end
        end
    end
    return list
end
