local _, Addon = ...

-- Trait tree of the active spec group.
--   C_SpecializationInfo.GetActiveSpecGroup / GetCombatConfigIDForSpecGroup  (Camelot ClassTalents frame :112,:120)
--   C_Traits.GetConfigInfo / GetTreeNodes / GetNodeInfo / GetEntryInfo / GetDefinitionInfo / GetTreeCurrencyInfo
--     (SharedTraitsDocumentation.lua; the UI calls them in Blizzard_SharedTalentFrame.lua:1219,1210,1359)
--   C_Spell.GetSpellName(spellID) (SpellDocumentation.lua:518; Blizzard_SharedTalentUtil.lua:63)
-- "Points spent / available" come from the tree currency (TreeCurrencyInfo.spent / .quantity, as the UI reads them in
-- Blizzard_SharedTalentUtil.lua:148-155), never from counting nodes.


local function isNumber(v)
    return type(v) == "number"
end

-- Rank of a node info table (the larger of currentRank / ranksPurchased), or nil when neither is a number.
local function nodeRank(info)
    if type(info) ~= "table" then return nil end
    local current, bought = info.currentRank, info.ranksPurchased
    if isNumber(current) and isNumber(bought) then return math.max(current, bought) end
    if isNumber(current) then return current end
    if isNumber(bought) then return bought end
    return nil
end

-- Entry that represents the purchased state of a node: the active entry, else the first committed one.
local function pickEntryID(info)
    if type(info.activeEntry) == "table" and isNumber(info.activeEntry.entryID) then
        return info.activeEntry.entryID
    end
    local committed = info.entryIDsWithCommittedRanks
    if type(committed) == "table" and isNumber(committed[1]) then
        return committed[1]
    end
    if type(info.entryIDs) == "table" and #info.entryIDs == 1 and isNumber(info.entryIDs[1]) then
        return info.entryIDs[1]
    end
end

-- Resolves the talent of one purchased node: entry -> definition -> spellID -> spell name. Every step is its own
-- Probe so one failing lookup keeps the numeric IDs that were already found.
local function resolveNode(self, configID, node, info)
    local entryID = pickEntryID(info)
    if not entryID then
        node.entry = self:State("not_collected", "node has no identifiable purchased entry")
        return
    end
    node.entryID = entryID
    node.entry = self:Probe("C_Traits.GetEntryInfo", configID, entryID)
    local entry = self:Val(node.entry)
    if type(entry) ~= "table" then return end
    if isNumber(entry.subTreeID) then
        node.subTreeID = entry.subTreeID
    end
    if not isNumber(entry.definitionID) then
        if not node.subTreeID then
            node.definition = self:State("not_collected", "entry has no definitionID")
        end
        return
    end
    node.definitionID = entry.definitionID
    node.definition = self:Probe("C_Traits.GetDefinitionInfo", entry.definitionID)
    local definition = self:Val(node.definition)
    if type(definition) ~= "table" then return end
    node.overrideName = type(definition.overrideName) == "string" and definition.overrideName ~= ""
        and definition.overrideName or nil
    if isNumber(definition.spellID) then
        node.spellID = definition.spellID
        node.spellName = self:Probe("C_Spell.GetSpellName", definition.spellID)
    end
end

Addon:RegisterCollector("talents", function(self)
    local section = {}
    local group = self:Read(section, "activeGroup", "C_SpecializationInfo.GetActiveSpecGroup")
    if not isNumber(group) then
        section.traversal = self:State("not_collected", "active spec group unavailable; not evidence of zero talents")
        return section
    end
    local configID = self:Read(section, "configID", "C_SpecializationInfo.GetCombatConfigIDForSpecGroup", group)
    if not isNumber(configID) then
        section.traversal = self:State("not_collected", "no config ID for active group; not evidence of zero talents")
        return section
    end
    section.configIDValue = configID
    local config = self:Read(section, "config", "C_Traits.GetConfigInfo", configID)
    if type(config) ~= "table" or type(config.treeIDs) ~= "table" or #config.treeIDs == 0 then
        section.traversal = self:State("not_collected", "config/tree list unavailable; not evidence of zero talents")
        return section
    end
    section.staged = self:Probe("C_Traits.ConfigHasStagedChanges", configID)
    section.trees = {}
    for _, treeID in ipairs(config.treeIDs) do
        local tree = { treeID = treeID, nodes = {} }
        section.trees[#section.trees + 1] = tree
        -- excludeStagedChanges = true: committed state only.
        tree.currency = self:Probe("C_Traits.GetTreeCurrencyInfo", configID, treeID, true)
        local nodeIDs = self:Read(tree, "nodeIDs", "C_Traits.GetTreeNodes", treeID)
        if type(nodeIDs) == "table" then
            for _, nodeID in ipairs(nodeIDs) do
                local node = { nodeID = nodeID, info = self:Probe("C_Traits.GetNodeInfo", configID, nodeID) }
                tree.nodes[#tree.nodes + 1] = node
                local info = self:Val(node.info)
                local rank = nodeRank(info)
                if rank then
                    node.rank = rank
                    node.maxRanks = isNumber(info.maxRanks) and info.maxRanks or nil
                    node.ranksPurchased = isNumber(info.ranksPurchased) and info.ranksPurchased or nil
                    if rank > 0 then
                        resolveNode(self, configID, node, info)
                    end
                elseif node.info.status == "ok" then
                    node.info = self:State("error", "node info lacks numeric currentRank/ranksPurchased")
                    node.info.api = "C_Traits.GetNodeInfo"
                end
            end
        end
    end
    return section
end, function(self, section, out)
    if section.traversal then
        out:Result("active spec group", section.activeGroup)
        out:Result("config ID", section.configID)
        if section.config then out:Result("config", section.config) end
        out:State("talents", section.traversal)
        return
    end
    out:Result("active spec group", section.activeGroup)
    out:Result("config", section.config, function(config)
        if type(config) ~= "table" then return self:Fmt(config) end
        return self:Fmt(config.name) .. " (config ID " .. self:Fmt(config.ID or section.configIDValue) .. ", type "
            .. self:Fmt(config.type) .. ", trees " .. self:Fmt(config.treeIDs) .. ")"
    end)
    out:Result("uncommitted staged changes", section.staged)

    -- Pass 1: node/currency totals.
    local spent, available, currencyOk = 0, 0, true
    local currencyProblem
    local purchased, unreadable, totalNodes, totalRead = {}, {}, 0, 0
    for _, tree in ipairs(section.trees or {}) do
        local currencies = self:Val(tree.currency)
        local counted = 0
        if type(currencies) == "table" then
            for _, currency in ipairs(currencies) do
                if type(currency) == "table" and isNumber(currency.spent) and isNumber(currency.quantity) then
                    spent = spent + currency.spent
                    available = available + currency.quantity
                    counted = counted + 1
                end
            end
        end
        if counted == 0 then
            currencyOk = false
            currencyProblem = currencyProblem or (self:Describe(tree.currency)
                or "<not_collected: no usable currency entry returned for tree " .. tostring(tree.treeID) .. ">")
        end
        for _, node in ipairs(tree.nodes) do
            totalNodes = totalNodes + 1
            if isNumber(node.rank) then
                totalRead = totalRead + 1
                if node.rank > 0 then purchased[#purchased + 1] = { tree = tree, node = node } end
            else
                unreadable[#unreadable + 1] = { tree = tree, node = node }
            end
        end
    end

    if currencyOk and #(section.trees or {}) > 0 then
        out:Add("points: " .. spent .. " spent / " .. available .. " available")
    else
        out:Add("points: " .. (currencyProblem or "<not_collected: no tree read>"))
    end
    for _, tree in ipairs(section.trees or {}) do
        local currencies = self:Val(tree.currency)
        if type(currencies) == "table" then
            for _, currency in ipairs(currencies) do
                out:Add("  tree " .. tostring(tree.treeID) .. " currency " .. self:Fmt(currency))
            end
        else
            out:Add("  tree " .. tostring(tree.treeID) .. " currency: " .. (self:Describe(tree.currency) or "<error>"))
        end
    end

    for _, tree in ipairs(section.trees or {}) do
        local nodeTag = self:Describe(tree.nodeIDs)
        if nodeTag then
            out:Add("tree " .. tostring(tree.treeID) .. ": node list " .. nodeTag)
        else
            local failed = 0
            for _, node in ipairs(tree.nodes) do
                if not isNumber(node.rank) then failed = failed + 1 end
            end
            out:Add("tree " .. tostring(tree.treeID) .. ": " .. #tree.nodes .. " nodes read ("
                .. (#tree.nodes - failed) .. " ok, " .. failed .. " unreadable)")
        end
    end

    if #purchased > 0 then
        out:Add("purchased talents: " .. #purchased .. " nodes")
        for _, item in ipairs(purchased) do
            local node = item.node
            local text = "  node " .. tostring(node.nodeID) .. " rank " .. tostring(node.rank) .. "/"
                .. tostring(node.maxRanks or "?")
            if node.ranksPurchased and node.ranksPurchased ~= node.rank then
                text = text .. " (purchased " .. node.ranksPurchased .. ")"
            end
            local name = node.overrideName
            if not name then
                local resolved = self:Val(node.spellName)
                if type(resolved) == "string" and resolved ~= "" then name = resolved end
            end
            if name then
                text = text .. ": " .. self:Clean(name)
            elseif node.spellID then
                local resolvedTag = node.spellName and node.spellName.status ~= "not_collected"
                local tag = resolvedTag and self:Describe(node.spellName)
                text = text .. ": " .. (tag or "<not_collected: spell name not cached>")
            elseif node.subTreeID then
                text = text .. ": sub tree selection"
            else
                text = text .. ": " .. (self:Describe(node.definition) or self:Describe(node.entry)
                    or "<not_collected: name unresolved>")
            end
            if node.spellID then text = text .. " (spellID " .. node.spellID .. ")" end
            if node.subTreeID then text = text .. " (subTreeID " .. node.subTreeID .. ")" end
            if node.entryID then text = text .. " [entry " .. node.entryID .. "]" end
            out:Add(text)
        end
    end
    for index, item in ipairs(unreadable) do
        if index > 10 then
            out:Add("  ... " .. (#unreadable - 10) .. " more unreadable nodes")
            break
        end
        out:Add("unreadable node " .. tostring(item.node.nodeID) .. ": "
            .. (self:Describe(item.node.info) or "<error: no rank fields>"))
    end

    -- Verdict. "none purchased" requires every node read AND a successful currency lookup.
    if #purchased == 0 then
        if totalNodes == 0 then
            out:Add("talent verdict: <not_collected: no nodes were read; cannot tell whether talents are purchased>")
        elseif #unreadable > 0 then
            out:Add("talent verdict: <not_collected: " .. #unreadable .. " of " .. totalNodes
                .. " nodes unreadable; cannot confirm that none are purchased>")
        elseif not currencyOk then
            out:Add("talent verdict: <not_collected: all " .. totalRead
                .. " nodes show 0 ranks but the point currency was not read; cannot confirm>")
        else
            out:Add("no talents purchased (" .. spent .. " spent, " .. available .. " available)")
            if spent > 0 then
                out:Add("note: currency reports " .. spent .. " spent but no node shows purchased ranks (inconsistent)")
            end
        end
    elseif currencyOk and spent == 0 then
        out:Add("note: nodes show purchased ranks but the currency reports 0 spent (inconsistent)")
    end
end)
