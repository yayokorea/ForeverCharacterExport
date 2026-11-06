-- Mocked contract tests for the skills collector. Not a WoW runtime.
local Addon = AddonUnderTest

local function check(condition, message)
    if not condition then error(message, 2) end
end

local function has(text, needle)
    return string.find(text, needle, 1, true) ~= nil
end

-- A SkillLineAttributes struct (SkillInfoDocumentation.lua:113-133) with overridable fields.
local function line(fields)
    local info = {
        skillID = 0, name = "x", isHeader = false, isCollapsed = false, rank = 0, tempPoints = 0, modifier = 0,
        maxRank = 0, isAbandonable = false, stepCost = 0, rankCost = 0, minLevel = 0, costType = 0,
        parentSkillLineID = 0, skillLineCategoryID = 0, description = "",
    }
    for key, value in pairs(fields) do info[key] = value end
    return info
end

local function header(id, name, collapsed)
    return line({ skillID = id, name = name, isHeader = true, isCollapsed = collapsed })
end

local function mockSkills(rows, extra)
    local api = {
        GetNumSkillLines = function() return #rows end,
        GetSkillLineInfo = function(index) return rows[index] end,
    }
    for key, value in pairs(extra or {}) do api[key] = value end
    return api
end

local function render(section)
    local out = Addon:NewWriter()
    Addon.formatters.skills(Addon, section, out)
    return out:Output()
end

local function collectAndRender()
    local section = Addon.collectors.skills(Addon)
    return render(section), section
end

local professions = {
    header(164, "Professions", false),
    line({ skillID = 182, name = "Herbalism", rank = 4, maxRank = 75, skillLineCategoryID = 9 }),
    line({ skillID = 165, name = "Leatherworking", rank = 3, maxRank = 75, skillLineCategoryID = 9 }),
    header(185, "Secondary Skills", false),
    line({ skillID = 129, name = "First Aid", rank = 40, maxRank = 75 }),
    line({ skillID = 185, name = "Cooking", rank = 2, maxRank = 75 }),
}

Tests["collector.skills.normal_groups_ranks_and_modifier"] = function()
    local rows = {}
    for _, r in ipairs(professions) do rows[#rows + 1] = r end
    rows[#rows + 1] = header(1, "Weapon Skills", false)
    rows[#rows + 1] = line({ skillID = 45, name = "Bows", rank = 15, maxRank = 75, modifier = 2, tempPoints = 1 })
    rows[#rows + 1] = line({ skillID = 46, name = "Guns", rank = 1, maxRank = 75 })
    local byIdCalls = 0
    WithGlobals({ C_SkillInfo = mockSkills(rows, {
        GetSkillLineInfoByID = function() byIdCalls = byIdCalls + 1 end,
    }) }, function()
        local text, section = collectAndRender()
        check(has(text, "skill lines reported: 9"), text)
        check(has(text, "coverage: complete (9 lines read, 3 groups"), text)
        check(has(text, "### Professions [id 164]"), text)
        check(has(text, "- Herbalism 4/75 [id 182 cat 9]"), text)
        check(has(text, "- Leatherworking 3/75 "), text)
        check(has(text, "### Secondary Skills"), text)
        check(has(text, "- First Aid 40/75 "), text)
        check(has(text, "- Cooking 2/75 "), text)
        check(has(text, "- Bows 15/75 (+2) temp +1 [id 45"), text)
        check(has(text, "- Guns 1/75 "), text)
        check(not has(text, "INCOMPLETE"), text)
        check(byIdCalls == 0 and section.byId == nil, "ID lookup must not run when the list is complete")
        local counts = Addon:Tally(section)
        check(counts.ok >= 10 and counts.error == 0, "tally should count every row")
    end)
end

Tests["collector.skills.collapsed_header_is_not_collected_not_empty"] = function()
    local rows = {}
    for _, r in ipairs(professions) do rows[#rows + 1] = r end
    rows[#rows + 1] = header(1, "Weapon Skills", true) -- children hidden by the client
    local asked = {}
    WithGlobals({ C_SkillInfo = mockSkills(rows, {
        GetSkillLineInfoByID = function(id)
            asked[#asked + 1] = id
            if id == 45 then return line({ skillID = 45, name = "Bows", rank = 15, maxRank = 75 }) end
            if id == 46 then return line({ skillID = 46, name = "Guns", rank = 0, maxRank = 0 }) end
        end,
        UnitDefenseSkill = function() return 5, 0 end,
    }) }, function()
        local text, section = collectAndRender()
        check(has(text, "coverage: INCOMPLETE"), text)
        check(has(text, "<not_collected: header Weapon Skills collapsed, children not listed>"), text)
        check(has(text, "### Weapon Skills [id 1] [collapsed]"), text)
        check(has(text, "never expands headers"), text)
        -- Supplementary lookup by ID is read-only and tagged as an extra check.
        check(has(text, "Weapon skills looked up by ID"), text)
        check(has(text, "- Bows 15/75 [id 45 cat 0] (by ID 45, not in the list above)"), text)
        check(has(text, "- Guns 0/0 "), text)
        check(has(text, "- id 43: <not_collected: API returned no value"), text) -- nil stays not_collected
        check(#asked == 16 and section.byId ~= nil, "all 16 weapon IDs absent from the list are looked up")
        check(not has(text, "<empty"), "a collapsed header must never read as empty: " .. text)
    end)
end

Tests["collector.skills.expanded_header_without_rows_is_empty_observation"] = function()
    local rows = { header(9, "Languages", false), header(10, "Class Skills", false),
        line({ skillID = 11, name = "Poisons", rank = 1, maxRank = 1 }) }
    WithGlobals({ C_SkillInfo = mockSkills(rows) }, function()
        local text = collectAndRender()
        check(has(text, "<empty: no rows listed under this expanded header>"), text)
        check(has(text, "- Poisons 1/1 "), text)
        check(has(text, "coverage: complete"), text)
    end)
end

Tests["collector.skills.collapse_state_unreadable_is_flagged"] = function()
    local armor = header(1, "Armor", false)
    armor.isCollapsed = nil -- field missing from the struct
    local rows = { armor, line({ skillID = 2, name = "Cloth", rank = 1, maxRank = 1 }) }
    WithGlobals({ C_SkillInfo = mockSkills(rows, { GetSkillLineInfoByID = function() end }) }, function()
        local text = collectAndRender()
        check(has(text, "header Armor collapse state unreadable"), text)
        check(has(text, "coverage: INCOMPLETE"), text)
    end)
end

Tests["collector.skills.empty_count_is_empty"] = function()
    WithGlobals({ C_SkillInfo = mockSkills({}) }, function()
        local text = collectAndRender()
        check(has(text, "skill list: <empty: GetNumSkillLines returned 0>"), text)
    end)
end

Tests["collector.skills.missing_api_is_unsupported"] = function()
    WithGlobals({ C_SkillInfo = false }, function()
        local text = collectAndRender()
        check(has(text, "skill lines reported: <unsupported: function unavailable at runtime [C_SkillInfo.GetNumSkillLines]>"),
            text)
        check(has(text, "<not_collected: line count unavailable"), text)
    end)
end

Tests["collector.skills.nil_count_stays_not_collected"] = function()
    WithGlobals({ C_SkillInfo = { GetNumSkillLines = function() end } }, function()
        local text = collectAndRender()
        check(has(text, "skill lines reported: <not_collected: API returned no value"), text)
        check(not has(text, "<empty"), text)
    end)
end

Tests["collector.skills.invalid_count_is_error"] = function()
    for _, bad in ipairs({ -1, 1.5, 0 / 0, "7" }) do
        local calls = 0
        WithGlobals({ C_SkillInfo = {
            GetNumSkillLines = function() return bad end,
            GetSkillLineInfo = function() calls = calls + 1 end,
        } }, function()
            local text = collectAndRender()
            check(has(text, "<error: GetNumSkillLines returned an invalid number>"), text)
            check(calls == 0, "must not loop on an invalid count")
        end)
    end
end

Tests["collector.skills.restricted_count"] = function()
    WithGlobals({ C_SkillInfo = { GetNumSkillLines = function() return FCE_SECRET end } }, function()
        local text = collectAndRender()
        check(has(text, "skill lines reported: <restricted"), text)
    end)
end

Tests["collector.skills.partial_failure_keeps_other_rows"] = function()
    local rows = {
        header(164, "Professions", false),
        line({ skillID = 182, name = "Herbalism", rank = 4, maxRank = 75 }),
        FCE_SECRET, -- restricted struct
        false, -- placeholder for a nil row (set below)
        line({ skillID = 165, name = "Leatherworking", rank = 3, maxRank = 75 }),
    }
    WithGlobals({ C_SkillInfo = {
        GetNumSkillLines = function() return #rows end,
        GetSkillLineInfo = function(index)
            if index == 4 then return nil end
            if index == 3 then return FCE_SECRET end
            return rows[index]
        end,
        GetSkillLineInfoByID = function() end,
    } }, function()
        local text = collectAndRender()
        check(has(text, "- Herbalism 4/75 "), text)
        check(has(text, "- Leatherworking 3/75 "), text)
        check(has(text, "- line 3: <restricted"), text)
        check(has(text, "- line 4: <not_collected: API returned no value"), text)
        check(has(text, "coverage: INCOMPLETE"), text)
    end)
end

Tests["collector.skills.errors_in_one_row_do_not_erase_the_rest"] = function()
    local rows = { header(1, "Professions", false), line({ skillID = 182, name = "Herbalism", rank = 4, maxRank = 75 }) }
    WithGlobals({ C_SkillInfo = {
        GetNumSkillLines = function() return 3 end,
        GetSkillLineInfo = function(index)
            if index == 3 then error("boom") end
            return rows[index]
        end,
        GetSkillLineInfoByID = function() end,
    } }, function()
        local text = collectAndRender()
        check(has(text, "- Herbalism 4/75 "), text)
        check(has(text, "- line 3: <error: "), text)
    end)
end

Tests["collector.skills.line_count_is_capped"] = function()
    local calls = 0
    WithGlobals({ C_SkillInfo = {
        GetNumSkillLines = function() return 100000 end,
        GetSkillLineInfo = function(index)
            calls = calls + 1
            return line({ skillID = index + 1000, name = "S" .. index, rank = 1, maxRank = 1 })
        end,
        GetSkillLineInfoByID = function() end,
    } }, function()
        local text = collectAndRender()
        check(calls == 500, "loop must stop at the hard cap, got " .. calls)
        check(has(text, "<not_collected: only first 500 of 100000 lines read>"), text)
        check(has(text, "coverage: INCOMPLETE"), text)
    end)
end

Tests["collector.skills.defense_modifier_uses_unit_defense_skill"] = function()
    local rows = { header(1, "Combat", false), line({ skillID = 95, name = "Defense", rank = 5, maxRank = 5 }) }
    WithGlobals({ C_SkillInfo = mockSkills(rows), UnitDefenseSkill = function() return 5, 12 end }, function()
        local text = collectAndRender()
        check(has(text, "- Defense 5/5 [id 95"), text)
        check(has(text, "defense modifier shown by the UI (UnitDefenseSkill): +12"), text)
    end)
end

Tests["collector.skills.defense_unsupported_is_tagged"] = function()
    local rows = { header(1, "Combat", false), line({ skillID = 95, name = "Defense", rank = 5, maxRank = 5 }) }
    WithGlobals({ C_SkillInfo = mockSkills(rows), UnitDefenseSkill = false }, function()
        local text = collectAndRender()
        check(has(text, "- Defense 5/5 "), text)
        check(has(text, "defense modifier (UnitDefenseSkill): <unsupported"), text)
    end)
end

Tests["collector.skills.missing_fields_print_tags_not_blanks"] = function()
    local rows = { header(1, "Odd", false), { skillID = 7, isHeader = false } }
    WithGlobals({ C_SkillInfo = mockSkills(rows) }, function()
        local text = collectAndRender()
        check(has(text, "<not_collected: name missing> <nil>/<nil> [id 7]"), text)
    end)
end

Tests["collector.skills.formatter_survives_bare_section"] = function()
    local out = Addon:NewWriter()
    Addon.formatters.skills(Addon, { count = Addon:State("error", "x") }, out)
    check(has(out:Output(), "<error: x>"), out:Output())
end
