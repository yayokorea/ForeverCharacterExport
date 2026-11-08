local _, Addon = ...
local unpack = unpack

local function pack(...)
    return { n = select("#", ...), ... }
end

function Addon:State(status, reason)
    return { status = status, reason = reason }
end

-- Check before comparison, formatting, arithmetic, or traversing API values.
local function accessible(value)
    return not issecretvalue(value) and canaccessvalue(value)
end

local function copy(value, seen, depth, budget)
    if not accessible(value) then
        error("FCE_RESTRICTED", 0)
    end
    local kind = type(value)
    if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
        return value
    end
    if kind ~= "table" then
        error("FCE_UNSUPPORTED_VALUE_TYPE", 0)
    end
    if depth > 16 or seen[value] then
        error("FCE_CYCLIC_OR_DEEP_VALUE", 0)
    end
    seen[value] = true
    local result = {}
    for key, child in pairs(value) do
        budget.count = budget.count + 1
        if budget.count > 100000 then
            error("FCE_VALUE_LIMIT", 0)
        end
        local safeKey = copy(key, seen, depth + 1, budget)
        if type(safeKey) ~= "string" and type(safeKey) ~= "number" then
            error("FCE_UNSUPPORTED_KEY_TYPE", 0)
        end
        result[safeKey] = copy(child, seen, depth + 1, budget)
    end
    seen[value] = nil
    return result
end

function Addon:Failure(value)
    if type(issecretvalue) ~= "function" or type(canaccessvalue) ~= "function" then
        return self:State("error", "error detail unavailable: access guards missing")
    end
    if not accessible(value) then
        return self:State("restricted", "inaccessible error value")
    end
    if type(value) == "string" and value == "FCE_RESTRICTED" then
        return self:State("restricted", "API returned a secret or inaccessible value")
    end
    -- Do not infer a restriction merely from a localized error message.
    return self:State("error", type(value) == "string" and value or "non-string error")
end

-- Shared by Probe and ProbeFields. fields == nil copies every return value whole; fields = { "name", ... } copies
-- only those keys of the FIRST return (a table). The other keys are never read, so a struct that also carries
-- function/userdata members (for example a mixin-style color object) does not fail the whole read.
local function probeInternal(self, path, fields, ...)
    local fn = _G
    for part in string.gmatch(path, "[^.]+") do
        if type(fn) ~= "table" then
            fn = nil
            break
        end
        fn = fn[part]
    end
    if type(fn) ~= "function" then
        local result = self:State("unsupported", "function unavailable at runtime")
        result.api = path
        return result
    end
    if type(issecretvalue) ~= "function" or type(canaccessvalue) ~= "function" then
        local result = self:State("not_collected", "access guards unavailable; value not read")
        result.api = path
        return result
    end
    local arguments = pack(...)
    local ok, values = pcall(function()
        local returned = pack(fn(unpack(arguments, 1, arguments.n)))
        if fields then
            local first = returned[1]
            if not accessible(first) then
                error("FCE_RESTRICTED", 0)
            end
            if type(first) == "table" then
                local picked = {}
                for _, key in ipairs(fields) do
                    picked[key] = copy(first[key], {}, 1, { count = 0 })
                end
                returned[1] = picked
            end
        end
        return copy(returned, {}, 0, { count = 0 })
    end)
    local result
    if ok then
        -- nil is unresolved unless the specific API contract says it means empty.
        result = { status = "ok", values = values }
        if values.n == 0 or (values.n == 1 and values[1] == nil) then
            result.status = path == "C_SpellBook.HasPetSpells" and "empty" or "not_collected"
            result.reason = result.status == "empty" and "documented no-pet-spells return"
                or "API returned no value; readiness/availability unresolved"
        end
    else
        result = self:Failure(values)
    end
    result.api = path
    return result
end

function Addon:Probe(path, ...)
    return probeInternal(self, path, nil, ...)
end

-- Probe that keeps only the listed scalar fields of the first (table) return value.
function Addon:ProbeFields(path, fields, ...)
    return probeInternal(self, path, fields, ...)
end

function Addon:First(result)
    if result.status == "ok" then
        return result.values[1]
    end
end

function Addon:Timestamp()
    return self:Probe("GetServerTime")
end

function Addon:Read(section, key, api, ...)
    local result = self:Probe(api, ...)
    section[key] = result
    return self:First(result)
end

-- Value i of an ok result, else nil. Use Describe() (Format.lua) to learn why a value is missing.
function Addon:Val(result, index)
    if type(result) == "table" and result.status == "ok" and type(result.values) == "table" then
        return result.values[index or 1]
    end
end

function Addon:Now()
    return self:First(self:Timestamp())
end

-- Copy through the access guards. Returns ok, value-or-error. Used before anything is persisted.
function Addon:Sanitize(value)
    if type(issecretvalue) ~= "function" or type(canaccessvalue) ~= "function" then
        return false, "access guards unavailable"
    end
    return pcall(copy, value, {}, 0, { count = 0 })
end

-- Persisted snapshots (SavedVariablesPerCharacter). Rules:
--  * Only for data the client can read only while a UI is open (bank, taxi map) or only via an event (played time).
--  * Always read back with its capture time and printed as stale. Never a fallback for a failed live read.
function Addon:Persist(key, data)
    local db = self.db
    if type(db) ~= "table" then
        return false, "saved variables not loaded"
    end
    local ok, safe = self:Sanitize(data)
    if not ok then
        return false, tostring(safe)
    end
    db.snapshots[key] = { capturedAt = self:Now(), data = safe }
    return true
end

function Addon:Persisted(key)
    local db = self.db
    if type(db) == "table" and type(db.snapshots) == "table" then
        local entry = db.snapshots[key]
        if type(entry) == "table" and type(entry.data) == "table" then
            return entry
        end
    end
end
