local _, Addon = ...

-- Skill list (professions, secondary skills, weapon skills, armor, languages, class skills).
-- Evidence:
--   C_SkillInfo.GetNumSkillLines / GetSkillLineInfo(index) / GetSkillLineInfoByID(id):
--     SkillInfoDocumentation.lua:41,59,74 (SkillLineAttributes struct :113-133),
--     UI loop Camelot/SkillsFrame.lua:153-154,176-177.
--   GetSkillLineInfoByID(skillID) in the paper doll: Camelot/PaperDollFrame.lua:730.
--   UnitDefenseSkill(unit) -> base, modifier: UnitDocumentation.lua:1069; the skills UI replaces the defense row
--     modifier with it: Camelot/SkillsFrame.lua:181-183.
--   Weapon skill line IDs: Camelot/SkillsFrame.lua:11-28.
-- The list is flat and a header row carries isCollapsed (SkillsFrame.lua:303-321). A collapsed header hides its
-- children, and ExpandSkillHeader/CollapseSkillHeader would change UI state, so they are never called here.
-- A collapsed header is therefore reported as not_collected, never as an empty or complete list.

local DEFENSE_SKILL_ID = 95 -- SkillsFrame.lua:34
-- SkillsFrame.lua:11-28 (Swords, Axes, Bows, Guns, Maces, 2H Swords, Staves, 2H Maces, 2H Axes, Daggers, Thrown,
-- Crossbows, Wands, Polearms, Fist/Unarmed, Feral Combat).
local WEAPON_IDS = { 43, 44, 45, 46, 54, 55, 136, 160, 162, 172, 173, 176, 226, 228, 229, 3014 }

-- Info table of an ok probe result, else nil plus a status tag.
local function infoOf(self, result)
    local tag = self:Describe(result)
    if tag then return nil, tag end
    local info = result.values[1]
    if type(info) ~= "table" then
        return nil, "<error: unexpected skill line shape [" .. tostring(result.api) .. "]>"
    end
    return info
end

local function newGroup(index, header)
    return { index = index, header = header, entries = {} }
end

-- Groups the flat rows under their header row. Pure function of the raw section (also used by the formatter).
local function scan(self, section)
    local model = { groups = {}, collapsed = {}, unknownCollapse = {}, unreadable = {}, ids = {} }
    local current
    for index = 1, type(section.read) == "number" and section.read or 0 do
        local row = type(section.rows) == "table" and section.rows[index] or nil
        local info, tag = infoOf(self, row)
        if info and info.isHeader == true then
            current = newGroup(index, info)
            model.groups[#model.groups + 1] = current
            if info.isCollapsed == true then
                model.collapsed[#model.collapsed + 1] = current
            elseif info.isCollapsed ~= false then
                model.unknownCollapse[#model.unknownCollapse + 1] = current
            end
        else
            if not current then
                current = newGroup(nil, nil)
                model.groups[#model.groups + 1] = current
            end
            current.entries[#current.entries + 1] = { index = index, info = info, tag = tag }
            if tag then
                model.unreadable[#model.unreadable + 1] = { index = index, tag = tag }
            end
        end
        if info and type(info.skillID) == "number" then
            model.ids[info.skillID] = true
        end
    end
    return model
end

Addon:RegisterCollector("skills", function(self)
    local section = { rows = {}, read = 0 }
    section.count = self:Probe("C_SkillInfo.GetNumSkillLines")
    if section.count.status ~= "ok" then
        return section
    end
    local total = self:Val(section.count)
    if type(total) ~= "number" or total ~= total or total < 0 or total % 1 ~= 0 then
        section.list = self:State("error", "GetNumSkillLines returned an invalid number")
        return section
    end
    if total == 0 then
        section.list = self:State("empty", "GetNumSkillLines returned 0")
        return section
    end
    section.total = total
    section.read = total
    for index = 1, section.read do
        section.rows[index] = self:Probe("C_SkillInfo.GetSkillLineInfo", index)
    end

    local model = scan(self, section)
    if model.ids[DEFENSE_SKILL_ID] then
        section.defense = self:Probe("UnitDefenseSkill", "player")
    end
    -- A collapsed header (or an unreadable row) can hide weapon skills. Ask for them by ID as a read-only extra check.
    if #model.collapsed > 0 or #model.unknownCollapse > 0 or #model.unreadable > 0 then
        section.byId = {}
        for _, id in ipairs(WEAPON_IDS) do
            if not model.ids[id] then
                section.byId[#section.byId + 1] = {
                    id = id,
                    info = self:Probe("C_SkillInfo.GetSkillLineInfoByID", id),
                }
            end
        end
    end
    return section
end, function(self, section, out)
    out:Result("skill lines reported", section.count)
    if section.list then
        out:State("skill list", section.list)
        return
    end
    if section.count.status ~= "ok" then
        out:Add("skill list: <not_collected: line count unavailable, no rows requested>")
        return
    end

    local model = scan(self, section)
    local function signed(value)
        if type(value) == "number" and value > 0 then return "+" .. value end
        return self:Fmt(value)
    end
    local function nameOf(info)
        if type(info.name) == "string" and info.name ~= "" then return self:Clean(info.name) end
        return "<not_collected: name missing>"
    end
    local function describe(info)
        local text = nameOf(info) .. " " .. self:Fmt(info.rank) .. "/" .. self:Fmt(info.maxRank)
        if info.modifier ~= nil and info.modifier ~= 0 then text = text .. " (" .. signed(info.modifier) .. ")" end
        if info.tempPoints ~= nil and info.tempPoints ~= 0 then text = text .. " temp " .. signed(info.tempPoints) end
        local meta = "id " .. self:Fmt(info.skillID)
        if info.skillLineCategoryID ~= nil then meta = meta .. " cat " .. self:Fmt(info.skillLineCategoryID) end
        if info.parentSkillLineID ~= nil and info.parentSkillLineID ~= 0 then
            meta = meta .. " parent " .. self:Fmt(info.parentSkillLineID)
        end
        return text .. " [" .. meta .. "]"
    end
    local function collapsedTag(group)
        return "<not_collected: header " .. nameOf(group.header) .. " collapsed, children not listed>"
    end

    -- Coverage first: the reader must know whether this list can be trusted before reading it.
    local read = section.read or 0
    local incomplete = {}
    for _, group in ipairs(model.collapsed) do incomplete[#incomplete + 1] = collapsedTag(group) end
    for _, group in ipairs(model.unknownCollapse) do
        incomplete[#incomplete + 1] = "<not_collected: header " .. nameOf(group.header)
            .. " collapse state unreadable, children may be missing>"
    end
    for _, bad in ipairs(model.unreadable) do
        incomplete[#incomplete + 1] = "line " .. bad.index .. ": " .. bad.tag
    end
    if #incomplete == 0 then
        out:Add("coverage: complete (" .. read .. " lines read, " .. #model.groups .. " groups, no collapsed headers)")
    else
        out:Add("coverage: INCOMPLETE (" .. read .. " lines read); missing parts are listed below, not assumed empty")
        for _, text in ipairs(incomplete) do out:Add("- " .. text) end
        if #model.collapsed > 0 then
            out:Add("- note: this export never expands headers; expand them in the Skills window and run again")
        end
    end

    for _, group in ipairs(model.groups) do
        if group.header then
            local header = group.header
            local state = header.isCollapsed == true and " [collapsed]" or ""
            local parent = (header.parentSkillLineID ~= nil and header.parentSkillLineID ~= 0)
                and (" parent " .. self:Fmt(header.parentSkillLineID)) or ""
            out:Add("### " .. nameOf(header) .. " [id " .. self:Fmt(header.skillID) .. parent .. "]" .. state)
        else
            out:Add("### (rows before the first header)")
        end
        for _, entry in ipairs(group.entries) do
            if entry.info then
                out:Add("- " .. describe(entry.info))
                if entry.info.skillID == DEFENSE_SKILL_ID and section.defense then
                    local modifier = self:Val(section.defense, 2)
                    if modifier ~= nil then
                        out:Add("  defense modifier shown by the UI (UnitDefenseSkill): " .. signed(modifier))
                    else
                        out:Result("  defense modifier (UnitDefenseSkill)", section.defense)
                    end
                end
            else
                out:Add("- line " .. entry.index .. ": " .. entry.tag)
            end
        end
        if group.header and group.header.isCollapsed == true then
            out:Add("- " .. collapsedTag(group))
        elseif group.header and #group.entries == 0 and group.header.isCollapsed == false then
            out:Add("- <empty: no rows listed under this expanded header>")
        end
    end

    if section.byId then
        out:Add("### Weapon skills looked up by ID (extra check because the list above is incomplete)")
        out:Add("- GetSkillLineInfoByID may also describe skills the character has not learned; rank 0 is not proof")
        for _, item in ipairs(section.byId) do
            local info, tag = infoOf(self, item.info)
            if info then
                out:Add("- " .. describe(info) .. " (by ID " .. item.id .. ", not in the list above)")
            else
                out:Add("- id " .. item.id .. ": " .. tag)
            end
        end
    end
end)
