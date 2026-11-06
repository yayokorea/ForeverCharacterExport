local _, Addon = ...
-- luacheck: read globals date

-- Readable-report helpers. Every unread value is printed as a tag, never as a blank, so the reader can tell
-- "the API returned nothing" (<empty>) from "not read" (<not_collected: why>).

local KNOWN = { ok = true, empty = true, not_collected = true, unsupported = true, restricted = true, error = true }
Addon.knownStatus = KNOWN
Addon.statusOrder = { "ok", "empty", "not_collected", "unsupported", "restricted", "error" }

-- nil when the result is a usable ok value, otherwise a tag such as <not_collected: reason>.
function Addon:Describe(result)
    if type(result) ~= "table" or not KNOWN[result.status] then
        return "<not_collected: no result>"
    end
    if result.status == "ok" then
        return nil
    end
    local text = "<" .. result.status
    if result.reason then text = text .. ": " .. result.reason end
    if result.api then text = text .. " [" .. result.api .. "]" end
    return text .. ">"
end

-- Strip color/hyperlink escapes so copied text stays plain; leftover pipes become slashes.
function Addon:Clean(text)
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    text = string.gsub(text, "|H.-|h(.-)|h", "%1")
    text = string.gsub(text, "|T.-|t", "")
    text = string.gsub(text, "[\r\n]+", " ")
    return (string.gsub(text, "|", "/"))
end

-- Compact scalar/table formatting. Tables print as {k=v,...} with sorted keys, depth- and size-limited.
function Addon:Fmt(value, depth)
    local kind = type(value)
    if value == nil then
        return "<nil>"
    elseif kind == "string" then
        return self:Clean(value)
    elseif kind ~= "table" then
        return tostring(value)
    end
    depth = depth or 0
    if depth >= 3 then
        return "{...}"
    end
    local keys, parts = {}, {}
    for key in pairs(value) do
        if key ~= "n" then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) < type(b)
    end)
    for index, key in ipairs(keys) do
        if index > 40 then
            parts[#parts + 1] = "..."
            break
        end
        local child = self:Fmt(value[key], depth + 1)
        if type(key) == "number" and key == index then
            parts[#parts + 1] = child
        else
            parts[#parts + 1] = tostring(key) .. "=" .. child
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- name, id from an item link such as "|cff...|Hitem:1234:...|h[Name]|h|r".
function Addon:LinkInfo(link)
    if type(link) ~= "string" then return nil, nil end
    local name = string.match(link, "%[(.-)%]")
    local id = string.match(link, "item:(%d+)")
    return name, id and tonumber(id) or nil
end

function Addon:Date(epoch)
    if type(epoch) ~= "number" then return "unknown time" end
    if type(date) == "function" then
        local ok, text = pcall(date, "%Y-%m-%d %H:%M:%S", epoch)
        if ok and type(text) == "string" then return text .. " (client local)" end
    end
    return "epoch " .. epoch
end

function Addon:Age(epoch)
    local now = self:Now()
    if type(epoch) ~= "number" or type(now) ~= "number" or now < epoch then return "age unknown" end
    local seconds = now - epoch
    if seconds < 90 then return seconds .. "s ago" end
    if seconds < 5400 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 172800 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

local Writer = {}
Writer.__index = Writer

function Addon:NewWriter()
    return setmetatable({ lines = {} }, Writer)
end

function Writer:Add(text)
    self.lines[#self.lines + 1] = text
end

function Writer:Section(title, detail)
    self:Add("")
    self:Add("## " .. title .. (detail and ("  " .. detail) or ""))
end

-- "label: value". A nil value prints <nil> so a missing field is never a silent blank.
function Writer:KV(label, value)
    self:Add(label .. ": " .. Addon:Fmt(value))
end

-- Prints the first value of a Probe result, or its status tag. fmt(value, values) may return a custom string.
function Writer:Result(label, result, fmt)
    local tag = Addon:Describe(result)
    if tag then
        self:Add(label .. ": " .. tag)
        return
    end
    local values = result.values
    local text
    if fmt then
        local ok, formatted = pcall(fmt, values[1], values)
        text = ok and tostring(formatted) or "<error: formatter failed>"
    else
        text = Addon:Fmt(values[1])
    end
    self:Add(label .. ": " .. text)
end

-- For State() tables without values (for example section.traversal).
function Writer:State(label, state)
    self:Add(label .. ": " .. (Addon:Describe(state) or "ok"))
end

-- A persisted (stale) snapshot header line. Returns the data table, or nil when none was stored.
function Writer:Stale(label, entry)
    if type(entry) ~= "table" or type(entry.data) ~= "table" then
        self:Add(label .. ": <not_collected: no snapshot stored yet>")
        return nil
    end
    self:Add(label .. ": [stale snapshot captured " .. Addon:Date(entry.capturedAt) .. ", "
        .. Addon:Age(entry.capturedAt) .. "; not a live read]")
    return entry.data
end

function Writer:Output()
    return table.concat(self.lines, "\n")
end

-- Walk a raw section and count every status-carrying node (Probe results and State tables).
function Addon:Tally(section)
    local counts, problems, seen = {}, {}, {}
    for status in pairs(KNOWN) do counts[status] = 0 end
    local function walk(node, depth)
        if type(node) ~= "table" or depth > 10 or seen[node] then return end
        seen[node] = true
        -- okReads: successful reads whose raw Probe results were not kept (bags/bank store plain tables).
        if type(node.okReads) == "number" then counts.ok = counts.ok + node.okReads end
        -- info = true: an informational note, not an unread value (kept out of the counts).
        if KNOWN[node.status] and not node.info and (node.api or node.reason or node.values) then
            counts[node.status] = counts[node.status] + 1
            if node.status ~= "ok" then
                problems[#problems + 1] = { status = node.status, api = node.api, reason = node.reason }
            end
        end
        for key, child in pairs(node) do
            if key ~= "values" or not node.api then
                walk(child, depth + 1)
            end
        end
    end
    walk(section, 0)
    return counts, problems
end
