-- Mocked contract tests for the flightpaths collector (not a WoW runtime).
local Addon = AddonUnderTest

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function hasNot(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

local function run()
    local section = Addon.collectors.flightpaths(Addon)
    local out = Addon:NewWriter()
    Addon.formatters.flightpaths(Addon, section, out)
    return out:Output(), section
end

local FLIGHT_ENUMS = {
    FlightPathState = { Current = 0, Reachable = 1, Unreachable = 2 },
    FlightPathFaction = { Neutral = 0, Horde = 1, Alliance = 2 },
}

-- Each test gets a private saved-variables table and a cleared "latest attempt" state; Addon.db is restored.
local function withDb(fn)
    local savedDb = Addon.db
    Addon.db = { snapshots = {}, minimap = {} }
    -- one successful capture clears the collector's session-only failure note left by an earlier test
    WithGlobals({ Enum = FLIGHT_ENUMS, GetTaxiMapID = function() return 1 end, C_TaxiMap = {
        GetAllTaxiNodes = function() return { { nodeID = 1, name = "x", state = 0 } } end,
        GetTaxiNodesForMap = function() return {} end,
    } }, function() Addon.Dispatch(nil, "TAXIMAP_OPENED", 1) end)
    Addon.db = { snapshots = {}, minimap = {} }
    local ok, err = pcall(fn)
    Addon.db = savedDb
    if not ok then error(err, 0) end
end

-- position is a mixin-like table with a method, as the real vector2 is; it must not break the capture.
local function position() return { x = 0.5, y = 0.5, GetXY = function() return 0.5, 0.5 end } end

local function taxi(mapID, all, forMap)
    return {
        GetAllTaxiNodes = function(id)
            assert(id == mapID, "wrong map id")
            return all
        end,
        GetTaxiNodesForMap = function(id)
            assert(id == mapID, "wrong map id")
            return forMap
        end,
    }
end

local function capture(globals, ...)
    local merged = { Enum = FLIGHT_ENUMS }
    for key, value in pairs(globals) do merged[key] = value end
    local args, count = { ... }, select("#", ...)
    WithGlobals(merged, function() Addon.Dispatch(nil, "TAXIMAP_OPENED", unpack(args, 1, count)) end)
end

local function eastern()
    return taxi(1415, {
        { nodeID = 10, name = "Stormwind, Elwynn", state = 0, position = position(), slotIndex = 1,
          isMapLayerTransition = false },
        { nodeID = 11, name = "Ironforge, Dun Morogh", state = 1, position = position(), slotIndex = 2,
          isMapLayerTransition = false },
        { nodeID = 12, name = "Far Away", state = 2, position = position(), slotIndex = 3,
          isMapLayerTransition = false },
        { nodeID = 99, name = "Layer Hop", state = 1, position = position(), slotIndex = 4,
          isMapLayerTransition = true },
    }, {
        { nodeID = 10, name = "Stormwind, Elwynn", faction = 2, isUndiscovered = false, position = position() },
        { nodeID = 11, name = "Ironforge, Dun Morogh", faction = 2, isUndiscovered = false, position = position() },
        { nodeID = 12, name = "Far Away", faction = 0, isUndiscovered = false, position = position() },
        { nodeID = 13, name = "Darkshire", faction = 2, isUndiscovered = true, position = position() },
        { nodeID = 14, name = "Orgrimmar", faction = 1, isUndiscovered = true, position = position() },
    })
end

Tests["collector.flightpaths.none_stored"] = function()
    withDb(function()
        local text, section = run()
        has(text, "<not_collected: no snapshot stored yet; open a flight master map once>")
        assert(section.snapshot.status == "not_collected")
        local counts = Addon:Tally(section)
        assert(counts.not_collected == 1)
    end)
end

Tests["collector.flightpaths.event_stores_and_formats"] = function()
    withDb(function()
        capture({ GetTaxiMapID = function() return 1415 end, C_TaxiMap = eastern(),
            C_Map = { GetMapInfo = function() return { mapID = 1415, name = "Eastern Kingdoms" } end } }, 1)
        local entry = Addon:Persisted("flightpaths")
        assert(entry and #entry.data.maps == 1, "snapshot was not stored")
        local text = run()
        has(text, "[stale snapshot captured ")
        has(text, "### Eastern Kingdoms (taxi mapID 1415), captured ")
        has(text, "known flight points: 3")
        has(text, "- Stormwind, Elwynn (10) [current]")
        has(text, "- Ironforge, Dun Morogh (11) [reachable]")
        has(text, "- Far Away (12) [unreachable]")
        has(text, "not yet discovered: 2")
        has(text, "Darkshire (13, alliance); Orgrimmar (14, horde)")
        hasNot(text, "Layer Hop")
        hasNot(text, "latest flight master map open")
    end)
end

Tests["collector.flightpaths.second_continent_keeps_first"] = function()
    withDb(function()
        capture({ GetTaxiMapID = function() return 1415 end, C_TaxiMap = eastern(),
            C_Map = { GetMapInfo = function() return { name = "Eastern Kingdoms" } end } })
        local kalimdor = taxi(1414, {
            { nodeID = 20, name = "Orgrimmar, Durotar", state = 0, isMapLayerTransition = false },
        }, {
            { nodeID = 20, name = "Orgrimmar, Durotar", faction = 1, isUndiscovered = false },
        })
        capture({ GetTaxiMapID = function() return 1414 end, C_TaxiMap = kalimdor,
            C_Map = { GetMapInfo = function() return { name = "Kalimdor" } end } }, 1)
        -- same continent again replaces its own record only
        capture({ GetTaxiMapID = function() return 1414 end, C_TaxiMap = kalimdor,
            C_Map = { GetMapInfo = function() return { name = "Kalimdor" } end } }, 1)
        local maps = Addon:Persisted("flightpaths").data.maps
        assert(#maps == 2, "expected 2 maps, got " .. #maps)
        local text = run()
        has(text, "### Eastern Kingdoms (taxi mapID 1415)")
        has(text, "### Kalimdor (taxi mapID 1414)")
        has(text, "- Orgrimmar, Durotar (20) [current]")
    end)
end

Tests["collector.flightpaths.event_without_payload"] = function()
    withDb(function()
        capture({ GetTaxiMapID = function() return 1415 end, C_TaxiMap = eastern() })
        local map = Addon:Persisted("flightpaths").data.maps[1]
        assert(map.mapName == nil and map.system == nil)
        local text = run()
        has(text, "### unnamed map (taxi mapID 1415)")
    end)
end

Tests["collector.flightpaths.unsupported_taxi_api"] = function()
    withDb(function()
        capture({ GetTaxiMapID = function() return 1415 end, C_TaxiMap = false }, 1)
        assert(Addon:Persisted("flightpaths") == nil)
        local text, section = run()
        has(text, "<not_collected: no snapshot stored yet; open a flight master map once>")
        has(text, "did not store a snapshot: <unsupported: function unavailable at runtime [C_TaxiMap.GetAllTaxiNodes]>")
        assert(section.lastAttempt.status == "unsupported")
    end)
end

Tests["collector.flightpaths.missing_map_id_is_not_guessed"] = function()
    withDb(function()
        capture({ GetTaxiMapID = false, C_TaxiMap = eastern() }, 1)
        assert(Addon:Persisted("flightpaths") == nil)
        local text = run()
        has(text, "did not store a snapshot: <unsupported: function unavailable at runtime [GetTaxiMapID]>")
        capture({ GetTaxiMapID = function() end, C_TaxiMap = eastern() }, 1)
        assert(Addon:Persisted("flightpaths") == nil)
        has(run(), "<not_collected: API returned no value")
    end)
end

Tests["collector.flightpaths.restricted_nodes_not_stored"] = function()
    withDb(function()
        local secret = taxi(1415, { { nodeID = 10, name = FCE_SECRET, state = 0 } }, {})
        capture({ GetTaxiMapID = function() return 1415 end, C_TaxiMap = secret }, 1)
        assert(Addon:Persisted("flightpaths") == nil)
        has(run(), "did not store a snapshot: <restricted")
    end)
end

Tests["collector.flightpaths.empty_node_list_not_stored"] = function()
    withDb(function()
        capture({ GetTaxiMapID = function() return 1415 end, C_TaxiMap = taxi(1415, {}, {}) }, 1)
        assert(Addon:Persisted("flightpaths") == nil)
        has(run(), "GetAllTaxiNodes returned 0 nodes")
    end)
end

Tests["collector.flightpaths.undiscovered_failure_keeps_known_nodes"] = function()
    withDb(function()
        local api = eastern()
        api.GetTaxiNodesForMap = function() error("boom") end
        capture({ GetTaxiMapID = function() return 1415 end, C_TaxiMap = api }, 1)
        local text = run()
        has(text, "known flight points: 3")
        has(text, "- Stormwind, Elwynn (10) [current]")
        has(text, "not yet discovered: <error: ")
        hasNot(text, "not yet discovered: 0")
    end)
end

Tests["collector.flightpaths.no_saved_variables"] = function()
    local savedDb = Addon.db
    Addon.db = nil
    local ok, err = pcall(function()
        capture({ GetTaxiMapID = function() return 1415 end, C_TaxiMap = eastern() }, 1)
        local text = run()
        has(text, "snapshot not stored: saved variables not loaded")
    end)
    Addon.db = savedDb
    if not ok then error(err, 0) end
end

Tests["collector.flightpaths.enum_missing_keeps_numeric_state"] = function()
    withDb(function()
        capture({ Enum = {}, GetTaxiMapID = function() return 1415 end, C_TaxiMap = eastern() }, 1)
        local text = run()
        has(text, "- Stormwind, Elwynn (10) [state=0]")
    end)
end
