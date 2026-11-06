local _, Addon = ...
-- luacheck: read globals Enum

-- Player spellbook grouped by skill line.
--   C_SpellBook.GetNumSpellBookSkillLines / GetSpellBookSkillLineInfo(index) -> SpellBookSkillLineInfo
--     (SpellBookDocumentation.lua:137,486,1028; UI loop Camelot/SpellBook/Blizzard_SpellBookFrame.lua:118-120)
--   C_SpellBook.GetSpellBookItemInfo(slot, Enum.SpellBookSpellBank.Player) -> SpellBookItemInfo
--     (SpellBookDocumentation.lua:290,1012; SpellBookConstantsDocumentation.lua:35; UI Blizzard_SpellBookItem.lua:87)
--   Slots of a skill line: itemIndexOffset + 1 .. + numSpellBookItems (SpellBookDocumentation.lua:1034).
-- Skipped only by documented fields: skill line shouldHide (UI skips it, Blizzard_SpellBookFrame.lua:120),
-- skill line offSpecID / item isOffSpec (non-active specialization), itemType FutureSpell (not learned yet).
-- SpellBookItemType values (SpellBookConstantsDocumentation.lua:27-31): 1 Spell, 2 FutureSpell, 3 PetAction, 4 Flyout.

local ITEM_SPELL, ITEM_FUTURE, ITEM_PET_ACTION, ITEM_FLYOUT = 1, 2, 3, 4
local MAX_SKILL_LINES = 40
local MAX_ITEMS_PER_LINE = 500
local MAX_ITEMS_TOTAL = 1500
local WRAP = 115

local function isNumber(v)
    return type(v) == "number"
end

local function playerBank()
    local banks = type(Enum) == "table" and Enum.SpellBookSpellBank
    if type(banks) == "table" and isNumber(banks.Player) then
        return banks.Player
    end
end

Addon:RegisterCollector("spells", function(self)
    local section = {}
    local count = self:Read(section, "numSkillLines", "C_SpellBook.GetNumSpellBookSkillLines")
    local bank = playerBank()
    if not bank then
        section.bank = self:State("unsupported", "Enum.SpellBookSpellBank.Player unavailable at runtime")
        return section
    end
    if not isNumber(count) or count < 0 or count ~= math.floor(count) then
        return section
    end
    section.lines = {}
    local total = 0
    for index = 1, math.min(count, MAX_SKILL_LINES) do
        local line = { index = index, info = self:Probe("C_SpellBook.GetSpellBookSkillLineInfo", index), items = {} }
        section.lines[#section.lines + 1] = line
        local info = self:Val(line.info)
        if type(info) == "table" then
            local offset, size = info.itemIndexOffset, info.numSpellBookItems
            if info.shouldHide == true or info.offSpecID ~= nil then
                line.skipped = info.shouldHide == true and "hidden" or "off-spec"
            elseif not isNumber(offset) or not isNumber(size) or offset < 0 or size < 0
                or size > MAX_ITEMS_PER_LINE then
                line.info = self:State("error", "skill line has unusable itemIndexOffset/numSpellBookItems")
                line.info.api = "C_SpellBook.GetSpellBookSkillLineInfo"
            else
                for slot = offset + 1, offset + size do
                    if total >= MAX_ITEMS_TOTAL then
                        section.truncated = true
                        break
                    end
                    total = total + 1
                    line.items[#line.items + 1] = {
                        slot = slot,
                        info = self:Probe("C_SpellBook.GetSpellBookItemInfo", slot, bank),
                    }
                end
            end
        end
    end
    if count > MAX_SKILL_LINES then
        section.truncated = true
    end
    return section
end, function(self, section, out)
    if section.bank then
        out:State("spellbook", section.bank)
        return
    end
    local count = self:Val(section.numSkillLines)
    local tag = self:Describe(section.numSkillLines)
    if tag then
        out:Add("skill lines: " .. tag)
        return
    end
    if not isNumber(count) or not section.lines then
        out:Add("skill lines: <error: unexpected skill line count " .. self:Fmt(count) .. ">")
        return
    end
    if count == 0 then
        out:Add("skill lines: 0 (the API reported no spellbook skill lines)")
        return
    end

    local listed, future, offSpec, unreadable, hiddenLines, offSpecLines = 0, 0, 0, 0, 0, 0
    local body, futureEntries = {}, {}
    local function emit(text)
        body[#body + 1] = text
    end

    for _, line in ipairs(section.lines) do
        local lineTag = self:Describe(line.info)
        local info = self:Val(line.info)
        if lineTag then
            emit("### skill line " .. line.index .. ": " .. lineTag)
        elseif type(info) ~= "table" then
            emit("### skill line " .. line.index .. ": <error: unexpected skill line shape>")
        elseif line.skipped == "hidden" then
            hiddenLines = hiddenLines + 1
        elseif line.skipped == "off-spec" then
            offSpecLines = offSpecLines + 1
            emit("### " .. self:Fmt(info.name) .. " (skill line " .. line.index .. ", off-spec; "
                .. self:Fmt(info.numSpellBookItems) .. " items not listed)")
        else
            local entries, listedHere = {}, 0
            for _, item in ipairs(line.items) do
                local itemTag = self:Describe(item.info)
                local spell = self:Val(item.info)
                if itemTag then
                    unreadable = unreadable + 1
                    entries[#entries + 1] = "slot " .. item.slot .. " " .. itemTag
                elseif type(spell) ~= "table" then
                    unreadable = unreadable + 1
                    entries[#entries + 1] = "slot " .. item.slot .. " <error: unexpected item shape>"
                elseif spell.itemType == ITEM_FUTURE then
                    -- Not learned yet (usually needs a trainer). Own block below, never mixed with known spells.
                    future = future + 1
                    local fname = type(spell.name) == "string" and spell.name ~= "" and self:Clean(spell.name)
                        or "<not_collected: name not cached>"
                    local fparts = {}
                    if type(spell.subName) == "string" and spell.subName ~= "" then
                        fparts[#fparts + 1] = self:Clean(spell.subName)
                    end
                    if isNumber(spell.spellID) then fparts[#fparts + 1] = "id=" .. spell.spellID end
                    futureEntries[#futureEntries + 1] = fname .. "(" .. table.concat(fparts, ",") .. ")"
                elseif spell.isOffSpec == true then
                    offSpec = offSpec + 1
                else
                    listedHere = listedHere + 1
                    local parts = {}
                    if type(spell.subName) == "string" and spell.subName ~= "" then
                        parts[#parts + 1] = self:Clean(spell.subName)
                    end
                    if isNumber(spell.spellID) then
                        parts[#parts + 1] = "id=" .. spell.spellID
                    elseif spell.itemType == ITEM_FLYOUT then
                        parts[#parts + 1] = "flyout=" .. self:Fmt(spell.actionID)
                    elseif spell.itemType == ITEM_PET_ACTION then
                        parts[#parts + 1] = "petaction=" .. self:Fmt(spell.actionID)
                    else
                        parts[#parts + 1] = "action=" .. self:Fmt(spell.actionID)
                    end
                    if spell.isPassive == true then parts[#parts + 1] = "passive" end
                    if spell.itemType ~= ITEM_SPELL and spell.itemType ~= ITEM_FLYOUT
                        and spell.itemType ~= ITEM_PET_ACTION then
                        parts[#parts + 1] = "type=" .. self:Fmt(spell.itemType)
                    end
                    local name = type(spell.name) == "string" and spell.name ~= "" and self:Clean(spell.name)
                        or "<not_collected: name not cached>"
                    entries[#entries + 1] = name .. "(" .. table.concat(parts, ",") .. ")"
                end
            end
            listed = listed + listedHere
            local label = self:Fmt(info.name)
            if info.isGuild == true then label = label .. ", guild" end
            if isNumber(info.specID) then label = label .. ", specID " .. info.specID end
            emit("### " .. label .. " (skill line " .. line.index .. ", " .. listedHere .. " listed)")
            local current = "  "
            for index, entry in ipairs(entries) do
                local piece = entry .. (index < #entries and ", " or "")
                if #current > 2 and #current + #piece > WRAP then
                    emit((string.gsub(current, "%s+$", "")))
                    current = "  "
                end
                current = current .. piece
            end
            if #current > 2 then emit(current) end
        end
    end

    out:Add("skill lines: " .. count .. " reported, spells listed: " .. listed
        .. ", future (not learned, listed separately below): " .. future
        .. ", off-spec skipped: " .. offSpec .. ", unreadable slots: " .. unreadable
        .. (hiddenLines > 0 and (", hidden skill lines skipped: " .. hiddenLines) or "")
        .. (offSpecLines > 0 and (", off-spec skill lines: " .. offSpecLines) or ""))
    out:Add("note: an empty rank text means no rank, or spell data not loaded yet (the API cannot tell)")
    if section.truncated then
        out:Add("<error: spellbook larger than the safety cap; the rest was not read>")
    end
    for _, text in ipairs(body) do
        out:Add(text)
    end
    if #futureEntries > 0 then
        out:Add("### not yet learned (spellbook future entries, " .. #futureEntries .. ")")
        local current = "  "
        for index, entry in ipairs(futureEntries) do
            local piece = entry .. (index < #futureEntries and ", " or "")
            if #current > 2 and #current + #piece > WRAP then
                out:Add((string.gsub(current, "%s+$", "")))
                current = "  "
            end
            current = current .. piece
        end
        if #current > 2 then out:Add(current) end
    elseif future == 0 then
        out:Add("not yet learned: none reported by the spellbook")
    end
end)
