local addonName, Addon = ...
Addon.name = addonName
Addon.version = "0.3.0"
Addon.collectors = {}
Addon.formatters = {}
Addon.handlers = {}
Addon.eventStatus = {}
Addon.handlerErrors = {}
-- Report order. A name without a registered collector is reported as not_collected, never skipped.
Addon.order = {
    "character", "equipment", "bags", "bank", "quests", "talents", "spells", "pet", "actionbars",
    "skills", "reputation", "currency", "auras", "flightpaths", "addons",
}

-- collector(self) -> raw section table (nested Probe results). formatter(self, section, out) writes the readable text.
function Addon:RegisterCollector(name, collector, formatter)
    self.collectors[name] = collector
    self.formatters[name] = formatter
end

-- Event registration. handler(self, event, ...) runs under pcall. Failures are recorded and shown in the
-- coverage footer; an unknown event name never breaks loading.
local frame = type(CreateFrame) == "function" and CreateFrame("Frame") or nil
Addon.eventFrame = frame

function Addon:On(event, handler)
    local list = self.handlers[event]
    if not list then
        list = {}
        self.handlers[event] = list
        if frame then
            local ok, err = pcall(frame.RegisterEvent, frame, event)
            self.eventStatus[event] = ok and "registered" or ("unavailable: " .. tostring(err))
        else
            self.eventStatus[event] = "unavailable: no frame"
        end
    end
    list[#list + 1] = handler
end

local function dispatch(_, event, ...)
    local list = Addon.handlers[event]
    if not list then return end
    for _, handler in ipairs(list) do
        local ok, err = pcall(handler, Addon, event, ...)
        if not ok and #Addon.handlerErrors < 20 then
            Addon.handlerErrors[#Addon.handlerErrors + 1] = event .. ": " .. tostring(err)
        end
    end
end
if frame then
    frame:SetScript("OnEvent", dispatch)
end
Addon.Dispatch = dispatch -- exposed for the mocked tests

-- SavedVariablesPerCharacter. Holds persisted snapshots (see Compat.lua Persist) and the launcher position.
Addon:On("ADDON_LOADED", function(self, _, loaded)
    if loaded ~= addonName then return end
    if type(ForeverCharacterExportDB) ~= "table" then
        ForeverCharacterExportDB = {}
    end
    local db = ForeverCharacterExportDB
    db.schema = 1
    if type(db.snapshots) ~= "table" then db.snapshots = {} end
    if type(db.minimap) ~= "table" then db.minimap = {} end
    self.db = db
end)

function Addon:Collect()
    local report = {
        schema = 2,
        addonVersion = self.version,
        sourceCommit = "eac30af597e5aaa43a60f6675ef5fdcea100375f",
        runtimeVerified = false,
        mode = "snapshot",
        startedAt = self:Timestamp(),
        conditions = "manual command; player only; no UI expansion or data requests",
        sections = {},
    }
    report.build = self:Probe("GetBuildInfo")
    for _, name in ipairs(self.order) do
        local collector = self.collectors[name]
        if not collector then
            report.sections[name] = self:State("not_collected", "collector not registered")
        else
            local ok, result = pcall(collector, self)
            if ok then
                report.sections[name] = result
            else
                report.sections[name] = self:Failure(result)
            end
        end
    end
    report.finishedAt = self:Timestamp()
    self.lastReport = report -- Session only. Never silently replace a failed read with cached data.
    return report
end
