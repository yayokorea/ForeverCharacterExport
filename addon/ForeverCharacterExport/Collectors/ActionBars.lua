local _, Addon = ...

-- Action bar section: which spell / item / macro sits in every action slot, plus the pet bar.
-- Evidence (paths under references/upstream/Interface/AddOns/):
--  * GetPetActionInfo(i) -> name, texture, isToken, isActive, autoCastAllowed, autoCastEnabled, spellID
--    (Blizzard_ActionBar/Shared/PetActionBar.lua:110,354,370). NUM_PET_ACTION_SLOTS = 10 (:1). A nil first return
--    means "no action" (PetActionButtonMixin:HasAction, :348-349). When isToken is true, name/texture are global
--    string names that the UI resolves through _G (:371-376).
--  * C_ActionBar.GetActionBarPage() (Blizzard_ChatFrameBase/Shared/SlashCommands.lua:467).
--  * C_Spell.GetSpellName (SpellDocumentation.lua:518), C_Item.GetItemNameByID (ItemDocumentation.lua:846).
--  * NO SOURCE in the mirror: HasAction(slot), GetActionInfo(slot) -> actionType, id, subType, GetMacroInfo(index)
--    and the 120-slot range. They are the long-standing client globals; every read goes through Probe, so a
--    missing or different function shows up as <unsupported>/<error>, never as an empty bar. In-game verification
--    is pending (docs/game-validation.md).
--  * Which slot range belongs to which on-screen bar is NOT verified, so slots are grouped by 12 only.

local SLOTS = 120
local GROUP = 12
local PET_SLOTS = 10
local NO_VALUE = "returned no value"

local function noValue(result)
    return result.status == "not_collected" and string.find(result.reason or "", NO_VALUE, 1, true) ~= nil
end

-- The id is resolved to a name only for the three kinds whose lookup is known; others keep the raw id.
local function nameProbe(self, kind, id)
    if type(id) ~= "number" then return nil end
    if kind == "spell" then
        return self:Probe("C_Spell.GetSpellName", id)
    elseif kind == "item" then
        return self:Probe("C_Item.GetItemNameByID", id)
    elseif kind == "macro" then
        return self:Probe("GetMacroInfo", id)
    end
end

local function collectSlots(self, section)
    local slots = { entries = {}, okReads = 0, emptyByNil = 0 }
    section.slots = slots
    for slot = 1, SLOTS do
        local has = self:Probe("HasAction", slot)
        local filled = false
        local info
        if has.status == "ok" then
            slots.okReads = slots.okReads + 1
            filled = has.values[1] ~= false and has.values[1] ~= nil
            if filled then info = self:Probe("GetActionInfo", slot) end
        elseif noValue(has) then
            -- HasAction answered nil: ask GetActionInfo; nil from both is read as an empty slot (noted in output).
            info = self:Probe("GetActionInfo", slot)
            if info.status == "ok" then
                filled = true
            elseif noValue(info) then
                slots.emptyByNil = slots.emptyByNil + 1
                info = nil
            end
        else
            -- unsupported / restricted / error: this slot is unknown; an unsupported function stops the sweep.
            slots.entries[#slots.entries + 1] = { slot = slot, has = has }
            if has.status == "unsupported" then
                slots.stoppedAt = slot
                break
            end
        end
        if filled or (info and info.status ~= "ok") then
            local entry = { slot = slot, info = info }
            if info.status == "ok" then
                entry.name = nameProbe(self, info.values[1], info.values[2])
            end
            slots.entries[#slots.entries + 1] = entry
        end
    end
end

local function collectPet(self, section)
    local pet = { entries = {}, okReads = 0 }
    section.pet = pet
    pet.exists = self:Probe("UnitExists", "pet")
    local exists = self:Val(pet.exists)
    if exists == false then
        pet.state = self:State("empty", "UnitExists(\"pet\") is false: no pet bar to read")
        pet.state.api = "UnitExists"
        return
    elseif exists ~= true then
        return
    end
    for slot = 1, PET_SLOTS do
        local info = self:Probe("GetPetActionInfo", slot)
        local first = info.status == "ok" and info.values[1]
        if info.status == "ok" and not first then
            pet.okReads = pet.okReads + 1 -- nil name = no action (PetActionBar.lua:348-349)
        elseif noValue(info) then
            pet.okReads = pet.okReads + 1
        else
            pet.entries[#pet.entries + 1] = { slot = slot, info = info }
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Formatting

local function describeSlot(self, entry)
    local label = "slot " .. entry.slot .. ": "
    if entry.has then return label .. self:Describe(entry.has) end
    local tag = self:Describe(entry.info)
    if tag then return label .. tag end
    local kind, id, sub = entry.info.values[1], entry.info.values[2], entry.info.values[3]
    local text = label .. "[" .. self:Fmt(kind) .. "]"
    if entry.name then
        local nameTag = self:Describe(entry.name)
        local nameText = nameTag or self:Fmt(entry.name.values[1])
        text = text .. " " .. nameText
    end
    text = text .. " (" .. (kind == "spell" and "spellID" or kind == "item" and "itemID"
        or kind == "macro" and "macroIndex" or "id") .. " " .. self:Fmt(id) .. ")"
    if sub ~= nil and sub ~= "" and sub ~= kind then text = text .. " subType=" .. self:Fmt(sub) end
    return text
end

local function formatSlots(self, section, out)
    local slots = section.slots
    out:Add("### Action slots (1-" .. SLOTS .. "; only slots holding an action are listed)")
    out:Result("current action bar page (C_ActionBar.GetActionBarPage)", section.page)
    local byGroup, counts, filled = {}, {}, 0
    for _, entry in ipairs(slots.entries) do
        local group = math.floor((entry.slot - 1) / GROUP)
        byGroup[group] = byGroup[group] or {}
        byGroup[group][#byGroup[group] + 1] = entry
        local kind = entry.info and entry.info.status == "ok" and entry.info.values[1]
        if kind then
            filled = filled + 1
            counts[kind] = (counts[kind] or 0) + 1
        end
    end
    local parts = {}
    for kind, count in pairs(counts) do parts[#parts + 1] = tostring(kind) .. " " .. count end
    table.sort(parts)
    out:Add("filled slots: " .. filled .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""))
    local groups = {}
    for group in pairs(byGroup) do groups[#groups + 1] = group end
    table.sort(groups)
    for _, group in ipairs(groups) do
        out:Add("-- slots " .. (group * GROUP + 1) .. "-" .. ((group + 1) * GROUP))
        for _, entry in ipairs(byGroup[group]) do out:Add(describeSlot(self, entry)) end
    end
    if slots.stoppedAt then
        out:Add("incomplete: sweep stopped at slot " .. slots.stoppedAt .. " because HasAction is unsupported; "
            .. "the rest is NOT proof of empty slots")
    end
    if slots.emptyByNil > 0 then
        out:Add("note: " .. slots.emptyByNil .. " slots where HasAction and GetActionInfo both returned no value "
            .. "are read as empty (the nil contract is not documented in the source mirror)")
    end
    out:Add("note: slots are grouped by 12 only; the mapping to on-screen bars / stance pages is not verified.")
end

local function petLine(self, entry)
    local label = "pet slot " .. entry.slot .. ": "
    local tag = self:Describe(entry.info)
    if tag then return label .. tag end
    local v = entry.info.values
    local name = v[1]
    -- The UI tests isToken for truthiness (PetActionBar.lua:371), so a non-boolean truthy value counts too.
    local token = v[3] and v[3] ~= 0
    local raw = name
    if token and type(name) == "string" then
        local global = rawget(_G, name)
        if type(global) == "string" then name = global end -- token: name is a global string key
    end
    local text = label .. self:Fmt(name)
    if token and name == raw then text = text .. " <not_collected: token key has no global text>" end
    if v[7] ~= nil then text = text .. " (spellID " .. self:Fmt(v[7]) .. ")" end
    if token then text = text .. " token=" .. self:Fmt(v[3]) end
    if v[5] and v[5] ~= 0 then text = text .. " autocast=" .. (v[6] and v[6] ~= 0 and "on" or "off") end
    return text
end

local function formatPet(self, section, out)
    local pet = section.pet
    out:Add("### Pet bar (GetPetActionInfo, " .. PET_SLOTS .. " slots; only slots holding an action are listed)")
    if pet.state then
        out:State("pet bar", pet.state)
        return
    end
    local tag = self:Describe(pet.exists)
    if tag then
        out:Add("UnitExists('pet'): " .. tag)
        return
    end
    for _, entry in ipairs(pet.entries) do
        out:Add(petLine(self, entry))
    end
    if #pet.entries == 0 then
        out:Add("pet bar: <empty: all " .. PET_SLOTS .. " slots returned no action>")
    end
end

Addon:RegisterCollector("actionbars", function(self)
    local section = {
        scope = "player action slots and the pet bar; keybinds and macro bodies are not read",
    }
    self:Read(section, "page", "C_ActionBar.GetActionBarPage")
    collectSlots(self, section)
    collectPet(self, section)
    -- Successful empty-slot reads keep only a counter (Tally counts okReads), not 130 raw nodes.
    section.okReads = section.slots.okReads + section.pet.okReads
    section.slots.okReads, section.pet.okReads = nil, nil
    return section
end, function(self, section, out)
    formatSlots(self, section, out)
    formatPet(self, section, out)
end)
