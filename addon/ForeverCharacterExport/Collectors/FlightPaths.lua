-- luacheck: read globals C_TaxiMap
local _, Addon = ...

-- Evidence:
--  * TAXIMAP_OPENED (payload: system) and TAXIMAP_CLOSED: TaxiMapDocumentation.lua:62-82. The flight master map is
--    the only time the node list is readable, so the nodes are snapshotted on this event and persisted.
--  * GetTaxiMapID() -> uiMapID of the open taxi map: Blizzard_FlightMap/Blizzard_FlightMap.lua:87 (UI code only;
--    no generated declaration), so it is Probed and a non-ok result aborts the capture with a visible state.
--  * C_TaxiMap.GetAllTaxiNodes(uiMapID) -> TaxiNodeInfo[] (nodeID, name, state, slotIndex, isMapLayerTransition):
--    TaxiMapDocumentation.lua:10-25,128-142; used by FM_FlightPathDataProvider.lua:34.
--  * C_TaxiMap.GetTaxiNodesForMap(uiMapID) -> MapTaxiNodeInfo[] (nodeID, name, faction, isUndiscovered):
--    TaxiMapDocumentation.lua:26-41,114-126. This is the only source of "not yet discovered"; TaxiNodeInfo has no
--    such flag and state Unreachable must not be read as undiscovered.
--  * Enum.FlightPathState {Current=0, Reachable=1, Unreachable=2}: TaxiMapDocumentation.lua:100-112; used by
--    FM_FlightPathDataProvider.lua:121,247. Map-layer transition nodes are not real flight paths
--    (FM_FlightPathDataProvider.lua:37) and are left out of every count.
--  * C_Map.GetMapInfo(uiMapID) -> {mapID, name, ...} or nothing: MapDocumentation.lua:312-326,696-706.
--  * The node tables carry a vector2 (Vector2DMixin) position, so they are NOT run through Addon:Probe (its deep
--    copy rejects non-data values). The functions are called under pcall here and only scalar fields are kept.

local NODE_CAP = 500
local lastAttempt -- session only: why the latest TAXIMAP_OPENED did not produce a snapshot

local function guards()
    return type(issecretvalue) == "function" and type(canaccessvalue) == "function"
end

local function accessible(value)
    return not issecretvalue(value) and canaccessvalue(value)
end

local TAXI_FIELDS = { nodeID = "number", name = "string", state = "number", isMapLayerTransition = "boolean" }
local MAP_FIELDS = { nodeID = "number", name = "string", faction = "number", isUndiscovered = "boolean" }

-- Returns { status = "ok", api = ..., nodes = { scalar-only tables } } or a failure State carrying .api.
local function readNodes(name, fields, mapID)
    local api = "C_TaxiMap." .. name
    local function fail(status, reason)
        local state = Addon:State(status, reason)
        state.api = api
        return state
    end
    local fn = type(C_TaxiMap) == "table" and C_TaxiMap[name] or nil
    if type(fn) ~= "function" then
        return fail("unsupported", "function unavailable at runtime")
    end
    if not guards() then
        return fail("not_collected", "access guards unavailable; value not read")
    end
    local ok, list = pcall(fn, mapID)
    if not ok then
        local state = Addon:Failure(list)
        state.api = api
        return state
    end
    if list == nil then
        return fail("not_collected", "API returned no value; readiness/availability unresolved")
    end
    if not accessible(list) then
        return fail("restricted", "API returned a secret or inaccessible value")
    end
    if type(list) ~= "table" then
        return fail("error", "unexpected return type " .. type(list))
    end
    local nodes = {}
    for index = 1, NODE_CAP + 1 do
        local node = list[index]
        if node == nil then break end
        if index > NODE_CAP then
            return fail("error", "more than " .. NODE_CAP .. " nodes returned")
        end
        if not accessible(node) or type(node) ~= "table" then
            return fail("restricted", "node " .. index .. " is secret, inaccessible or not a table")
        end
        local item = {}
        for field, kind in pairs(fields) do
            local value = node[field]
            if value ~= nil then
                if not accessible(value) then
                    return fail("restricted", "node " .. index .. " field " .. field .. " is secret or inaccessible")
                end
                if type(value) == kind then item[field] = value end
            end
        end
        nodes[#nodes + 1] = item
    end
    return { status = "ok", api = api, nodes = nodes }
end

local function enumName(enumTable, value)
    if type(enumTable) ~= "table" or type(value) ~= "number" then return nil end
    for key, candidate in pairs(enumTable) do
        if candidate == value and type(key) == "string" then return string.lower(key) end
    end
end

local function describeFailure(result)
    return Addon:Describe(result) or "<not_collected: unknown>"
end

local function capture(self, system)
    local idResult = self:Probe("GetTaxiMapID")
    local mapID = self:Val(idResult)
    if type(mapID) ~= "number" then
        if idResult.status == "ok" then
            lastAttempt = self:State("error", "GetTaxiMapID returned a non-number")
            lastAttempt.api = "GetTaxiMapID"
        else
            lastAttempt = idResult
        end
        return
    end
    local all = readNodes("GetAllTaxiNodes", TAXI_FIELDS, mapID)
    if all.status ~= "ok" then
        lastAttempt = all
        return
    end
    local record = { mapID = mapID, capturedAt = self:Now(), system = type(system) == "number" and system or nil }
    local mapInfo = self:Val(self:Probe("C_Map.GetMapInfo", mapID))
    if type(mapInfo) == "table" and type(mapInfo.name) == "string" then
        record.mapName = mapInfo.name
    end

    local forMap = readNodes("GetTaxiNodesForMap", MAP_FIELDS, mapID)
    local undiscoveredIDs = {}
    if forMap.status == "ok" then
        record.undiscovered = {}
        record.discoveredOnMap = 0
        for _, node in ipairs(forMap.nodes) do
            if not node.isMapLayerTransition then
                if node.isUndiscovered == true then
                    record.undiscovered[#record.undiscovered + 1] =
                        { nodeID = node.nodeID, name = node.name, faction = node.faction,
                          factionName = enumName(Enum and Enum.FlightPathFaction, node.faction) }
                    if node.nodeID then undiscoveredIDs[node.nodeID] = true end
                elseif node.isUndiscovered == false then
                    record.discoveredOnMap = record.discoveredOnMap + 1
                end
            end
        end
    else
        record.undiscoveredNote = describeFailure(forMap)
    end

    record.nodes = {}
    for _, node in ipairs(all.nodes) do
        if not node.isMapLayerTransition and not (node.nodeID and undiscoveredIDs[node.nodeID]) then
            record.nodes[#record.nodes + 1] = {
                nodeID = node.nodeID,
                name = node.name,
                state = node.state,
                stateName = enumName(Enum and Enum.FlightPathState, node.state),
            }
        end
    end
    if #all.nodes == 0 then
        lastAttempt = self:State("not_collected", "GetAllTaxiNodes returned 0 nodes; nothing stored")
        lastAttempt.api = "C_TaxiMap.GetAllTaxiNodes"
        return
    end

    -- Persist replaces the whole entry, so merge: one record per taxi map, other continents are kept.
    local maps = {}
    local existing = self:Persisted("flightpaths")
    if existing and type(existing.data.maps) == "table" then
        for _, old in ipairs(existing.data.maps) do
            if type(old) == "table" and old.mapID ~= mapID then maps[#maps + 1] = old end
        end
    end
    maps[#maps + 1] = record
    local ok, err = self:Persist("flightpaths", { maps = maps })
    if ok then
        lastAttempt = nil
    else
        lastAttempt = self:State("error", "snapshot not stored: " .. tostring(err))
    end
end

Addon:On("TAXIMAP_OPENED", function(self, _, system)
    local ok, err = pcall(capture, self, system)
    if not ok then
        lastAttempt = self:Failure(err)
    end
end)

Addon:RegisterCollector("flightpaths", function(self)
    local section = {}
    local entry = self:Persisted("flightpaths")
    if entry then
        section.snapshot = entry
    else
        section.snapshot = self:State("not_collected", "no snapshot stored yet; open a flight master map once")
    end
    section.lastAttempt = lastAttempt
    return section
end, function(self, section, out)
    local snapshot = section.snapshot
    if type(snapshot) == "table" and snapshot.status then
        out:Add(self:Describe(snapshot))
    else
        local data = out:Stale("flight paths", snapshot)
        local maps = data and data.maps
        if type(maps) ~= "table" or #maps == 0 then
            out:Add("<error: stored snapshot has no usable maps>")
        else
            for _, map in ipairs(maps) do
                local nodes = type(map.nodes) == "table" and map.nodes or {}
                out:Add("### " .. (type(map.mapName) == "string" and self:Clean(map.mapName) or "unnamed map")
                    .. " (taxi mapID " .. tostring(map.mapID) .. "), captured " .. self:Date(map.capturedAt)
                    .. ", " .. self:Age(map.capturedAt))
                out:Add("known flight points: " .. #nodes)
                for _, node in ipairs(nodes) do
                    local state = node.stateName or ("state=" .. tostring(node.state))
                    out:Add("- " .. (type(node.name) == "string" and self:Clean(node.name) or "<no name>")
                        .. " (" .. tostring(node.nodeID) .. ") [" .. state .. "]")
                end
                if type(map.undiscovered) == "table" then
                    out:Add("not yet discovered: " .. #map.undiscovered)
                    local names = {}
                    for index, node in ipairs(map.undiscovered) do
                        if index > 30 then
                            names[#names + 1] = "..."
                            break
                        end
                        local faction = node.factionName or (node.faction and ("faction=" .. node.faction))
                        names[#names + 1] = (type(node.name) == "string" and self:Clean(node.name) or "?")
                            .. " (" .. tostring(node.nodeID) .. (faction and (", " .. faction) or "") .. ")"
                    end
                    if #names > 0 then out:Add("  undiscovered: " .. table.concat(names, "; ")) end
                else
                    out:Add("not yet discovered: " .. tostring(map.undiscoveredNote or "<not_collected: unknown>"))
                end
            end
        end
    end
    if section.lastAttempt then
        out:Add("latest flight master map open this session did not store a snapshot: "
            .. describeFailure(section.lastAttempt))
    end
end)
