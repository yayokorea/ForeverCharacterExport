-- Mocked contract tests for Settings.lua and the Core/Export parts it drives (not a WoW runtime).
local Addon = AddonUnderTest

local function withDb(db, fn)
    local savedDb, savedDetail = Addon.db, Addon.detail
    Addon.db = db
    local ok, err = pcall(fn)
    Addon.db, Addon.detail = savedDb, savedDetail
    if not ok then error(err, 0) end
end

local function freshDb()
    return { snapshots = {}, minimap = {}, sections = {}, detail = {}, window = {}, ui = {} }
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

Tests["settings.sections_default_on_and_persist_in_db"] = function()
    withDb(freshDb(), function()
        for _, name in ipairs(Addon.order) do assert(Addon:IsSectionEnabled(name), name) end
        assert(Addon:SetSectionEnabled("legacy", false))
        assert(Addon.db.sections.legacy == false and not Addon:IsSectionEnabled("legacy"))
        assert(Addon:IsSectionEnabled("planning"), "other sections stay on")
        Addon:SetSectionEnabled("legacy", true)
        assert(Addon.db.sections.legacy == nil and Addon:IsSectionEnabled("legacy"))
        Addon:SetAllSections(false)
        for _, name in ipairs(Addon.order) do assert(not Addon:IsSectionEnabled(name)) end
        Addon:SetAllSections(true)
        for _, name in ipairs(Addon.order) do assert(Addon:IsSectionEnabled(name)) end
    end)
end

Tests["settings.without_db_everything_is_on_and_setters_report_failure"] = function()
    withDb(nil, function()
        assert(Addon:IsSectionEnabled("legacy"))
        assert(Addon:SetSectionEnabled("legacy", false) == false)
        assert(Addon:SetDetailFull("legacy", true) == false)
        assert(Addon:LeftClickAction() == "window")
    end)
end

Tests["settings.detail_toggle_updates_the_table_collectors_read"] = function()
    withDb(freshDb(), function()
        Addon.detail = Addon.db.detail
        assert(not Addon:IsDetailFull("spelldetails"))
        Addon:SetDetailFull("spelldetails", true)
        assert(Addon.db.detail.spelldetails == "full" and Addon.detail == Addon.db.detail)
        -- the collector really switches mode without a reload
        local text = Addon:Report(Addon:Collect(), false)
        assert(Addon.lastReport.sections.spelldetails ~= nil and text ~= nil)
        Addon:SetDetailFull("spelldetails", false)
        assert(Addon.db.detail.spelldetails == nil and not Addon:IsDetailFull("spelldetails"))
    end)
end

Tests["settings.professions_values_match_what_the_collector_reads"] = function()
    withDb(freshDb(), function()
        local max, detail = Addon:ProfessionSettings()
        assert(max == 15 and detail == "reagents", "defaults equal the collector defaults")
        Addon:SetProfessionDetail("summary")
        assert(Addon.db.professions.detail == "summary")
        assert(Addon:CycleProfessionMax() == 50 and Addon:CycleProfessionMax() == 100
            and Addon:CycleProfessionMax() == 200 and Addon:CycleProfessionMax() == 15)
        -- the saved table is exactly the shape Collectors/Professions.lua reads
        local section = Addon.collectors.professions(Addon)
        assert(section.limits.detail == "summary" and section.limits.maxRecipes == 15)
        Addon:CycleProfessionMax()
        assert(Addon.collectors.professions(Addon).limits.maxRecipes == 50)
    end)
end

Tests["settings.left_click_action_toggles"] = function()
    withDb(freshDb(), function()
        assert(Addon:LeftClickAction() == "window")
        assert(Addon:ToggleLeftClickAction() == "export" and Addon:LeftClickAction() == "export")
        assert(Addon:ToggleLeftClickAction() == "window")
    end)
end

Tests["settings.addon_loaded_creates_missing_tables_and_shares_detail"] = function()
    local savedDb, savedGlobal, savedDetail = Addon.db, ForeverCharacterExportDB, Addon.detail
    local ok, err = pcall(function()
        ForeverCharacterExportDB = { sections = "bad", detail = 5, snapshots = {} }
        Addon.Dispatch(nil, "ADDON_LOADED", "ForeverCharacterExport")
        local db = ForeverCharacterExportDB
        assert(type(db.sections) == "table" and type(db.detail) == "table" and type(db.window) == "table"
            and type(db.ui) == "table" and type(db.minimap) == "table")
        assert(Addon.db == db and Addon.detail == db.detail, "Addon.detail must be the saved table itself")
        -- existing values survive
        ForeverCharacterExportDB = { sections = { legacy = false }, detail = { planning = "full" } }
        Addon.Dispatch(nil, "ADDON_LOADED", "ForeverCharacterExport")
        assert(not Addon:IsSectionEnabled("legacy") and Addon:IsDetailFull("planning"))
    end)
    Addon.db, ForeverCharacterExportDB, Addon.detail = savedDb, savedGlobal, savedDetail
    assert(ok, err)
end

Tests["settings.disabled_section_is_never_silently_skipped"] = function()
    withDb(freshDb(), function()
        Addon:SetSectionEnabled("legacy", false)
        local called = false
        local original = Addon.collectors.legacy
        Addon.collectors.legacy = function() called = true return {} end
        local ok, report = pcall(function() return Addon:Collect() end)
        Addon.collectors.legacy = original
        assert(ok, report)
        assert(not called, "a disabled collector must not run")
        local section = report.sections.legacy
        assert(section.disabled == true and section.info == true and section.status == "not_collected")
        assert(report.disabled[1] == "legacy")
        local text = Addon:Report(report, false)
        has(text, "# switched off in the settings window")
        has(text, "## legacy  [off]")
        has(text, "switched off in the settings window; this is NOT proof")
        has(text, "- legacy: off (switched off in the settings window)")
        -- not counted as an unread value
        local counts = Addon:Tally(section)
        assert(counts.not_collected == 0)
        assert(not string.find(text, "- legacy: not_collected", 1, true))
    end)
end

Tests["settings.summary_levels_follow_the_tally_rule"] = function()
    local report = { sections = {} }
    local ok = { status = "ok", api = "A", values = { n = 1, 1 } }
    local missing = { status = "unsupported", api = "B", reason = "x" }
    local failed = { status = "error", api = "C", reason = "x" }
    local unread = { status = "not_collected", api = "D", reason = "x" }
    report.sections = {
        character = { a = ok },
        equipment = { a = ok, b = unread },
        bags = { a = missing },
        bank = { a = failed },
        quests = { status = "unsupported", reason = "x" },
        talents = { status = "error", reason = "x" },
        spells = { status = "not_collected", reason = "x" },
        pet = { status = "not_collected", reason = "off", info = true, disabled = true },
        actionbars = { a = ok, b = missing, c = failed },
    }
    local by = {}
    for _, entry in ipairs(Addon:SectionSummary(report)) do by[entry.name] = entry end
    assert(by.character.level == "ok" and by.character.text == "정상")
    assert(by.equipment.level == "warn" and by.equipment.text:find("못 읽음 1", 1, true))
    assert(by.bags.level == "unsupported")
    assert(by.bank.level == "error")
    assert(by.quests.level == "unsupported" and by.talents.level == "error" and by.spells.level == "warn")
    assert(by.pet.level == "off")
    assert(by.actionbars.level == "warn" and by.actionbars.text:find("미지원 1", 1, true)
        and by.actionbars.text:find("오류 1", 1, true))
    assert(by.reputation.level == "warn" and by.reputation.text == "아직 수집 안 함", "missing section")
    assert(#Addon:SectionSummary(report) == #Addon.order)
end

Tests["settings.needs_action_lists_window_and_trainer_hints"] = function()
    withDb(freshDb(), function()
        local report = { sections = {
            professions = { window = { verdict = "closed" } },
            planning = { trainer = { open = false } },
            bank = {}, flightpaths = {},
            spelldetails = { spells = { { description = { status = "not_collected",
                reason = "description not loaded yet (x)" } } } },
        } }
        local text = table.concat(Addon:NeedsAction(report), "\n")
        has(text, "전문기술 창을 열고 다시 내보내세요")
        has(text, "상급자(교관) 창을 연 채로 내보내세요")
        has(text, "은행을 한 번 열어 두세요")
        has(text, "비행 조련사 지도를 한 번 열어 두세요")
        has(text, "주문 설명이 아직 로딩되지 않았습니다")
        -- nothing to say once those windows were open / snapshots exist
        Addon:Persist("bank", { x = 1 })
        Addon:Persist("flightpaths", { x = 1 })
        local quiet = Addon:NeedsAction({ sections = {
            professions = { window = { verdict = "open" } }, planning = { trainer = { open = true } },
            bank = {}, flightpaths = {}, spelldetails = { spells = {} },
        } })
        assert(#quiet == 0, table.concat(quiet, "|"))
        -- a switched-off section gives no hint
        local off = Addon:NeedsAction({ sections = { professions = { disabled = true, window = { verdict = "closed" } } } })
        assert(#off == 0)
    end)
end

Tests["settings.export_footer_mentions_professions_and_trainer"] = function()
    local order = Addon.order
    Addon.order = { "zz_none" }
    local ok, text = pcall(function() return Addon:Report(Addon:Collect(), false) end)
    Addon.order = order
    assert(ok, text)
    has(text, "professions: open the profession (trade skill) window")
    has(text, "planning trainer block: open a class trainer window")
end
