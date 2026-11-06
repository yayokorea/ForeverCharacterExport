-- Mocked contract tests for the talents collector (not a WoW runtime).
local function run()
    local addon = AddonUnderTest
    local section = addon.collectors.talents(addon)
    local out = addon:NewWriter()
    addon.formatters.talents(addon, section, out)
    return out:Output(), section
end

local function has(text, needle)
    assert(string.find(text, needle, 1, true), "missing '" .. needle .. "' in:\n" .. text)
end

local function lacks(text, needle)
    assert(not string.find(text, needle, 1, true), "unexpected '" .. needle .. "' in:\n" .. text)
end

-- Fixture: tree 20 with nodes 30 (2/5 ranks), 31 (0 ranks), 32 (choice node, committed entry 52).
local function fixture(options)
    options = options or {}
    local nodes = options.nodes or {
        [30] = { ID = 30, currentRank = 2, ranksPurchased = 2, maxRanks = 5, activeEntry = { entryID = 50, rank = 2 },
            entryIDs = { 50 }, entryIDsWithCommittedRanks = { 50 } },
        [31] = { ID = 31, currentRank = 0, ranksPurchased = 0, maxRanks = 1, entryIDs = { 51 },
            entryIDsWithCommittedRanks = {} },
        [32] = { ID = 32, currentRank = 1, ranksPurchased = 1, maxRanks = 1, entryIDs = { 52, 53 },
            entryIDsWithCommittedRanks = { 52 } },
    }
    local order = options.order or { 30, 31, 32 }
    local entries = options.entries or {
        [50] = { definitionID = 60, maxRanks = 5 },
        [51] = { definitionID = 61, maxRanks = 1 },
        [52] = { definitionID = 62, maxRanks = 1 },
    }
    local definitions = options.definitions or {
        [60] = { spellID = 100 },
        [61] = { spellID = 101 },
        [62] = { spellID = 102, overrideName = "Override Name" },
    }
    local names = options.names or { [100] = "Bite", [101] = "Claw", [102] = "Spell 102" }
    return {
        C_SpecializationInfo = {
            GetActiveSpecGroup = options.group or function() return 1 end,
            GetCombatConfigIDForSpecGroup = function(group)
                assert(group == 1)
                return 10
            end,
        },
        C_Traits = {
            GetConfigInfo = function(id)
                assert(id == 10)
                return { ID = 10, name = "Hunter", type = 4, treeIDs = { 20 } }
            end,
            ConfigHasStagedChanges = function() return false end,
            GetTreeNodes = function(id)
                assert(id == 20)
                return order
            end,
            GetTreeCurrencyInfo = options.currency or function(config, tree, exclude)
                assert(config == 10 and tree == 20 and exclude == true)
                return { { traitCurrencyID = 1, quantity = 9, spent = 2 } }
            end,
            GetNodeInfo = options.nodeInfo or function(config, node)
                assert(config == 10)
                return nodes[node]
            end,
            GetEntryInfo = function(config, entry)
                assert(config == 10)
                return entries[entry]
            end,
            GetDefinitionInfo = function(def) return definitions[def] end,
        },
        C_Spell = { GetSpellName = function(id) return names[id] end },
    }
end

local function zeroNodes()
    local nodes = {}
    for id = 30, 34 do
        nodes[id] = { ID = id, currentRank = 0, ranksPurchased = 0, maxRanks = 1, entryIDs = { id + 100 },
            entryIDsWithCommittedRanks = {} }
    end
    return nodes, { 30, 31, 32, 33, 34 }
end

Tests["collector.talents.purchased_nodes_with_points"] = function()
    WithGlobals(fixture(), function()
        local text = run()
        has(text, "Hunter (config ID 10")
        has(text, "active spec group: 1")
        has(text, "points: 2 spent / 9 available")
        has(text, "tree 20: 3 nodes read (3 ok, 0 unreadable)")
        has(text, "purchased talents: 2 nodes")
        has(text, "node 30 rank 2/5: Bite (spellID 100) [entry 50]")
        has(text, "node 32 rank 1/1: Override Name (spellID 102) [entry 52]")
        lacks(text, "node 31 rank")
        lacks(text, "no talents purchased")
    end)
end

Tests["collector.talents.explicit_none_purchased"] = function()
    local nodes, order = zeroNodes()
    local mocks = fixture({ nodes = nodes, order = order, currency = function()
        return { { traitCurrencyID = 1, quantity = 11, spent = 0 } }
    end })
    WithGlobals(mocks, function()
        local text = run()
        has(text, "points: 0 spent / 11 available")
        has(text, "tree 20: 5 nodes read (5 ok, 0 unreadable)")
        has(text, "no talents purchased (0 spent, 11 available)")
        lacks(text, "purchased talents:")
    end)
end

Tests["collector.talents.currency_failure_is_not_none"] = function()
    local nodes, order = zeroNodes()
    WithGlobals(fixture({ nodes = nodes, order = order, currency = function() end }), function()
        local text = run()
        has(text, "points: <not_collected")
        has(text, "talent verdict: <not_collected")
        lacks(text, "no talents purchased")
    end)
end

Tests["collector.talents.empty_currency_list_is_not_none"] = function()
    local nodes, order = zeroNodes()
    WithGlobals(fixture({ nodes = nodes, order = order, currency = function() return {} end }), function()
        local text = run()
        has(text, "points: <not_collected")
        lacks(text, "no talents purchased")
    end)
end

Tests["collector.talents.missing_api_is_unsupported"] = function()
    WithGlobals({ C_SpecializationInfo = fixture().C_SpecializationInfo, C_Traits = false }, function()
        local text, section = run()
        has(text, "unsupported")
        has(text, "C_Traits.GetConfigInfo")
        lacks(text, "no talents purchased")
        assert(section.config.status == "unsupported")
    end)
end

Tests["collector.talents.nil_group_stays_not_collected"] = function()
    WithGlobals(fixture({ group = function() end }), function()
        local text, section = run()
        assert(section.activeGroup.status == "not_collected")
        has(text, "not_collected")
        lacks(text, "no talents purchased")
        lacks(text, "points: 0")
    end)
end

Tests["collector.talents.partial_failure_keeps_other_nodes"] = function()
    local mocks = fixture({ order = { 30, 31, 32, 33, 34 }, nodeInfo = function(_, node)
        if node == 31 then error("node unavailable", 0) end
        if node == 32 then return { ID = 32, currentRank = FCE_SECRET, ranksPurchased = 1 } end
        if node == 33 then return nil end
        if node == 34 then return { ID = 34, maxRanks = 1 } end
        return { ID = 30, currentRank = 3, ranksPurchased = 3, maxRanks = 5, activeEntry = { entryID = 50, rank = 3 } }
    end })
    WithGlobals(mocks, function()
        local text = run()
        has(text, "node 30 rank 3/5: Bite (spellID 100)")
        has(text, "tree 20: 5 nodes read (1 ok, 4 unreadable)")
        has(text, "unreadable node 31: <error: node unavailable [C_Traits.GetNodeInfo]>")
        has(text, "unreadable node 32: <restricted")
        has(text, "unreadable node 33: <not_collected")
        has(text, "unreadable node 34: <error: node info lacks numeric")
    end)
end

Tests["collector.talents.unreadable_node_blocks_none_verdict"] = function()
    local nodes, order = zeroNodes()
    nodes[33] = nil
    local mocks = fixture({ nodes = nodes, order = order })
    WithGlobals(mocks, function()
        local text = run()
        has(text, "unreadable node 33")
        has(text, "talent verdict: <not_collected: 1 of 5 nodes unreadable")
        lacks(text, "no talents purchased")
    end)
end

Tests["collector.talents.uncached_names_keep_ids"] = function()
    local mocks = fixture({ names = {}, definitions = { [60] = { spellID = 100 }, [62] = { spellID = 102 } },
        entries = { [50] = { definitionID = 60 }, [52] = {} } })
    WithGlobals(mocks, function()
        local text = run()
        has(text, "node 30 rank 2/5: <not_collected")
        has(text, "(spellID 100) [entry 50]")
        has(text, "node 32 rank 1/1: <not_collected: entry has no definitionID")
        has(text, "[entry 52]")
    end)
end

Tests["collector.talents.currency_node_mismatch_is_flagged"] = function()
    WithGlobals(fixture({ currency = function()
        return { { traitCurrencyID = 1, quantity = 9, spent = 0 } }
    end }), function()
        local text = run()
        has(text, "nodes show purchased ranks but the currency reports 0 spent")
    end)
end
