local _, Addon = ...

-- Evidence:
--  * C_UnitAuras.GetAuraDataByIndex(unit, index, filter) -> AuraData|nil
--    (Blizzard_APIDocumentationGenerated/UnitAuraDocumentation.lua:208-225).
--  * nil ends the iteration: Blizzard_FrameXMLUtil/AuraUtil.lua:63-66 (FindAuraRecurse) calls this same function
--    with index 1, 2, ... and treats nil as "not found / no more auras". The declaration itself only says Nilable.
--  * Filters "HELPFUL" / "HARMFUL": Blizzard_BuffFrame/BuffFrame.lua:732,1040.
--  * AuraData fields (name, applications, duration, expirationTime, sourceUnit, spellId, dispelName, isHelpful,
--    isHarmful): AuraUtil.lua:40-61,356-370. duration == 0 or expirationTime == 0 means no expiry
--    (BuffFrame.lua:733-734); remaining = expirationTime - GetTime().
--  * GetTime(): SystemTimeDocumentation.lua:57 (read through Probe, so no global is declared here).
--  * Unit auras are guarded by RequiresUnitAuraAccess (failure mode Error) and SecretWhenUnitAuraRestricted
--    (UnitAuraDocumentation.lua:210-211, SecretPredicatesDocumentation.lua:48-52). In combat or instances the
--    call can therefore raise or return secret fields; the Probe reports error/restricted and we stop there.
--  * UnitExists(unit) -> bool: UnitDocumentation.lua:1192 (pet auras are only read when a pet unit exists).

local API = "C_UnitAuras.GetAuraDataByIndex"

local function readGroup(self, unit, filter)
    local group = { unit = unit, filter = filter, auras = {} }
    -- The list ends at the first nil return (every non-ok branch below returns).
    local index = 0
    while true do
        index = index + 1
        local result = self:Probe(API, unit, index, filter)
        if result.status == "ok" then
            group.auras[#group.auras + 1] = result
        elseif result.status == "not_collected" and type(result.values) == "table" then
            -- A real nil return: the end of the list (AuraUtil.FindAuraRecurse).
            if index == 1 then
                group.state = self:State("empty", "index 1 returned nil: no " .. filter .. " auras on " .. unit)
                group.state.api = API
            end
            group.complete = true
            return group
        else
            -- unsupported / error / restricted (or guards missing): the rest of the list is unknown.
            group.stopped = result
            group.stoppedAt = index
            return group
        end
    end
end

local function readUnit(self, unit)
    return {
        buffs = readGroup(self, unit, "HELPFUL"),
        debuffs = readGroup(self, unit, "HARMFUL"),
    }
end

local function seconds(value)
    value = math.floor(value)
    if value >= 3600 then
        return math.floor(value / 3600) .. "h " .. math.floor((value % 3600) / 60) .. "m"
    elseif value >= 60 then
        return math.floor(value / 60) .. "m " .. (value % 60) .. "s"
    end
    return value .. "s"
end

local function timeText(aura, now, nowTag)
    local duration, expires = aura.duration, aura.expirationTime
    if type(duration) ~= "number" or type(expires) ~= "number" then
        return "time=<not_collected: duration/expirationTime missing>"
    end
    if duration <= 0 or expires <= 0 then
        return "no expiry"
    end
    if type(now) ~= "number" then
        return "remaining=" .. (nowTag or "<not_collected: GetTime unavailable>") .. " duration=" .. seconds(duration)
    end
    local left = expires - now
    if left < 0 then left = 0 end
    return seconds(left) .. " left of " .. seconds(duration)
end

local function auraLine(self, result, now, nowTag)
    local aura = result.values and result.values[1]
    if type(aura) ~= "table" then
        return "- <error: unexpected aura value of type " .. type(aura) .. " [" .. API .. "]>"
    end
    local name = type(aura.name) == "string" and self:Clean(aura.name) or "<not_collected: name missing>"
    local id = type(aura.spellId) == "number" and aura.spellId or "?"
    local parts = { name .. " (" .. id .. ")" }
    if type(aura.applications) == "number" and aura.applications > 1 then
        parts[#parts + 1] = "stacks=" .. aura.applications
    end
    parts[#parts + 1] = timeText(aura, now, nowTag)
    parts[#parts + 1] = "source=" .. (type(aura.sourceUnit) == "string" and self:Clean(aura.sourceUnit)
        or "<not provided>")
    if type(aura.dispelName) == "string" and aura.dispelName ~= "" then
        parts[#parts + 1] = "dispel=" .. self:Clean(aura.dispelName)
    end
    return "- " .. table.concat(parts, " | ")
end

local function writeGroup(self, out, label, group, now, nowTag)
    local tag = group.state and self:Describe(group.state)
    local head = "### " .. label .. " (" .. group.filter .. ")"
    if tag then
        out:Add(head .. ": " .. tag)
        return
    end
    if group.stopped and #group.auras == 0 then
        out:Add(head .. ": " .. self:Describe(group.stopped)
            .. " (possibly combat/instance restriction on unit auras; NOT proof of none)")
        return
    end
    out:Add(head .. ": " .. #group.auras .. (group.complete and "" or " read (incomplete)"))
    for _, result in ipairs(group.auras) do
        out:Add(auraLine(self, result, now, nowTag))
    end
    if group.stopped then
        out:Add("incomplete: aura list stopped at index " .. group.stoppedAt .. " after " .. #group.auras
            .. " readable: " .. self:Describe(group.stopped)
            .. " (possibly combat/instance restriction on unit auras; the rest is NOT proof of none)")
    end
end

Addon:RegisterCollector("auras", function(self)
    local section = { time = self:Probe("GetTime") }
    section.player = readUnit(self, "player")
    -- Pet auras only when a pet unit exists; a nil at index 1 for a missing unit would otherwise look like "none".
    local exists = self:Probe("UnitExists", "pet")
    section.pet = { exists = exists }
    if self:Val(exists) == true then
        section.pet.buffs = readGroup(self, "pet", "HELPFUL")
        section.pet.debuffs = readGroup(self, "pet", "HARMFUL")
    elseif self:Val(exists) == false then
        section.pet.state = self:State("empty", "UnitExists(\"pet\") is false: no pet unit")
        section.pet.state.api = "UnitExists"
    end
    return section
end, function(self, section, out)
    local now = self:Val(section.time)
    local nowTag = self:Describe(section.time)
    out:Add("(player buffs/debuffs; remaining = expirationTime - GetTime(); fields can be secret in combat)")
    writeGroup(self, out, "Player buffs", section.player.buffs, now, nowTag)
    writeGroup(self, out, "Player debuffs", section.player.debuffs, now, nowTag)
    local pet = section.pet
    local petTag = self:Describe(pet.exists)
    if petTag then
        out:Add("### Pet auras: " .. petTag)
    elseif pet.state then
        out:Add("### Pet auras: " .. self:Describe(pet.state))
    else
        writeGroup(self, out, "Pet buffs", pet.buffs, now, nowTag)
        writeGroup(self, out, "Pet debuffs", pet.debuffs, now, nowTag)
    end
end)
