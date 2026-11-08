local _, Addon = ...
-- luacheck: read globals Constants EVALUATION_TREE_FLAG_PROGRESS_BAR
-- luacheck: read globals LEGACY_TREE_PROFESSIONS LEGACY_TREE_ADVENTURE LEGACY_TREE_PROGRESSION

-- Legacy section: Forever's account-wide challenge / point / perk-tree / reward-track system. Live read only;
-- nothing is opened, loaded, filtered, searched or requested (no LoadAddOn, no SetAchievementSearchString, no tree
-- changes).
--
-- Evidence. "F:" = dev/.tools/forever-research/Interface/AddOns/ (dev cache of the pinned commit
-- eac30af597e5aaa43a60f6675ef5fdcea100375f, not shipped), "U:" = references/upstream/Interface/AddOns/.
--  * Forever-only system: F:Blizzard_LegacySystem/Blizzard_LegacySystem.toc:3 (AllowLoadGameType: camelot) and :2
--    (LoadOnDemand).
--  * Constants.LegacyConsts.* (reward faction, points currency, tree IDs, default class categories):
--    F:Blizzard_APIDocumentationGenerated/LegacyConstantsDocumentation.lua:8-26. Read from the table at run time;
--    the numbers in this addon's tests are fixtures only.
--  * Source tree keys PROFESSIONS / ADVENTURE / PROGRESSION and display names LEGACY_TREE_*:
--    F:Blizzard_LegacySystem/Blizzard_LegacySystemConstants.lua:1-16.
--  * Default category per class (classFile -> LEGACY_DEFAULT_CATEGORY_*): Blizzard_LegacySystemConstants.lua:24-33;
--    the UI takes classFile from the 2nd return of UnitClass (Blizzard_LegacyChallenges.lua:97). This addon reads the
--    same classFilename through UnitClassBase (U:Blizzard_APIDocumentationGenerated/UnitDocumentation.lua:930-944,
--    first return).
--  * Challenge categories: GetCategoryList() (array of IDs) Blizzard_LegacyChallenges.lua:139; GetCategoryInfo(id) ->
--    name, parentID, top level parent is -1 (Blizzard_LegacyChallenges.lua:168,
--    Blizzard_LegacyChallengeTracker.lua:5,29); GetCategoryNumAchievements(id) -> total, complete, incomplete
--    (Blizzard_LegacyChallenges.lua:105, Blizzard_LegacySystemUtil.lua:20). These globals have NO generated
--    declaration in the mirror; the call sites are the only evidence, so each is read through Probe and reports
--    unsupported when absent.
--  * GetAchievementInfo(categoryID, index): 1 id, 2 name, 3 points, 4 completed, 8 description
--    (Blizzard_LegacyChallengeButton.lua:284), 11 rewardText (Blizzard_LegacyAchievementOverrides.lua:44),
--    13 wasEarnedByMe (Blizzard_LegacyChallengeDetailPane.lua:44). Other positions are not used (unverified).
--    "completed and not wasEarnedByMe" = done on another character, shown as incomplete by the Legacy UI
--    (Blizzard_LegacySystemUtil.lua:7-8 comment "Achievements earned by other characters count as incomplete",
--    Blizzard_LegacyAchievementOverrides.lua:21-23).
--  * Criteria: GetAchievementNumCriteria(id) (may be nil, UI uses "or 0": Blizzard_LegacyChallengeButton.lua:162);
--    GetAchievementCriteriaInfo(id, i) -> 1 text, 2 type, 3 completed, 4 quantity, 5 reqQuantity, 6 charName,
--    7 flags (Blizzard_LegacyChallengeButton.lua:172). The UI shows quantity/reqQuantity only when
--    bit.band(flags, EVALUATION_TREE_FLAG_PROGRESS_BAR) == that flag and reqQuantity > 0 (:46-49). The flag's numeric
--    value is not in the mirror, so it is read from the global and, when absent, raw counts are printed with a
--    "progress-bar flag unverified" note.
--  * Challenge points: C_Traits.GetTraitCurrencyForAchievement(currencyID, achievementID) -> amount
--    (U:SharedTraitsDocumentation.lua:454-466; shown as the challenge's points by
--    Blizzard_LegacyAchievementOverrides.lua:25-27).
--  * Trees / currency: C_Traits.GetConfigIDByTreeID (MayReturnNothing) U:SharedTraitsDocumentation.lua:185-198,
--    GetTreeCurrencyInfo(configID, treeID, excludeStagedChanges) :537-551 with TreeCurrencyInfo{traitCurrencyID,
--    quantity, maxQuantity?, spent, spentInTree?} :1188-1197, GetMaxAvailableTraitCurrency(currencyID,
--    limitBySourcedMax) :338-352, ConfigHasStagedChanges :107-118, GetTreeNodes :586-601, GetNodeInfo :370-385.
--    The UI reads tree currency with excludeStagedChanges=false and uses the first entry of the first tree
--    (Blizzard_LegacySystemUtil.lua:43-52); this collector reads committed state (true) like Collectors/Talents.lua
--    and only adds the staged view when a staged change exists or is unknown.
--  * Points as the UI shows them: "earned" = renown level of the reward-track faction (renownCurrency,
--    Blizzard_LegacySystemUtil.lua:56), "available" = currency.quantity (Blizzard_LegacyTree.lua:317), "spent in
--    tree" = spentInTree (:102), "seasonal cap" tooltip = maxQuantity (:307), points bar maximum =
--    GetMaxAvailableTraitCurrency(currencyID, false) (Blizzard_LegacyChallenges.lua:364-366). Nothing is hardcoded.
--  * Reward track: C_MajorFactions.GetMajorFactionData(factionID) -> MajorFactionData (nilable)
--    U:MajorFactionsDocumentation.lua:26-39, fields :259-284; GetCurrentRenownLevel :11-24; GetRenownLevels ->
--    MajorFactionRenownLevelInfo{factionID, level, locked, isMilestone, isCapstone} :86-99,:311-321;
--    GetRenownRewardsForLevel(factionID, level) -> MajorFactionRenownRewardInfo[] :110-124,:323-345. UI use:
--    F:Blizzard_LegacySystem/Blizzard_LegacyRewardTrack.lua:36-40,162,169.
--  * Locked state: ToggleLegacySystemUI refuses to open at renown level <= 0
--    (Blizzard_LegacySystem_Bootstrap.lua:7-9).
--  * C_AddOns.IsAddOnLoaded(name) -> loadedOrLoading, loaded U:AddOnsDocumentation.lua:322-335 (informational only).
--  * C_Traits.GetEntryInfo / GetDefinitionInfo / C_Spell.GetSpellName: same evidence as Collectors/Talents.lua.

-- Caps keep the default report small. Anything beyond is counted but not listed and the formatter says so.
Addon.legacyLimits = Addon.legacyLimits or {
    categories = 120, -- categories read
    challenges = 80,  -- challenges listed in detail (class default category and its children first)
    criteria = 5,     -- criteria lines per not-yet-earned challenge
    rewardLevels = 40,
    rewardsPerLevel = 4,
    nodes = 200,      -- tree nodes read per tree
}

local TREES = {
    { key = "PROFESSIONS", constant = "LEGACY_TREE_PROFESSIONS_ID" },
    { key = "ADVENTURE", constant = "LEGACY_TREE_ADVENTURE_ID" },
    { key = "PROGRESSION", constant = "LEGACY_TREE_PROGRESSION_ID" },
}

local DEFAULT_CATEGORY_CONSTANT = {
    WARRIOR = "LEGACY_DEFAULT_CATEGORY_WARRIOR", PALADIN = "LEGACY_DEFAULT_CATEGORY_PALADIN",
    HUNTER = "LEGACY_DEFAULT_CATEGORY_HUNTER", ROGUE = "LEGACY_DEFAULT_CATEGORY_ROGUE",
    PRIEST = "LEGACY_DEFAULT_CATEGORY_PRIEST", SHAMAN = "LEGACY_DEFAULT_CATEGORY_SHAMAN",
    MAGE = "LEGACY_DEFAULT_CATEGORY_MAGE", WARLOCK = "LEGACY_DEFAULT_CATEGORY_WARLOCK",
    DRUID = "LEGACY_DEFAULT_CATEGORY_DRUID",
}

local TOP_LEVEL_CATEGORY = -1 -- GetCategoryInfo parent of a top level category (Blizzard_LegacyChallengeTracker.lua:5)

local function isNumber(v)
    return type(v) == "number"
end

local function legacyConstants()
    if type(Constants) == "table" and type(Constants.LegacyConsts) == "table" then
        return Constants.LegacyConsts
    end
end

local function constantNumber(name)
    local consts = legacyConstants()
    local value = consts and consts[name]
    if isNumber(value) then return value end
end

local function treeDisplayName(key)
    local name
    if key == "PROFESSIONS" then name = LEGACY_TREE_PROFESSIONS
    elseif key == "ADVENTURE" then name = LEGACY_TREE_ADVENTURE
    elseif key == "PROGRESSION" then name = LEGACY_TREE_PROGRESSION end
    if type(name) == "string" and name ~= "" then return name end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Tree nodes (same confirmed-state approach and node reading as Collectors/Talents.lua)

local function nodeRank(info)
    if type(info) ~= "table" then return nil end
    local current, bought = info.currentRank, info.ranksPurchased
    if isNumber(current) and isNumber(bought) then return math.max(current, bought) end
    if isNumber(current) then return current end
    if isNumber(bought) then return bought end
end

local function pickEntryID(info)
    if type(info.activeEntry) == "table" and isNumber(info.activeEntry.entryID) then
        return info.activeEntry.entryID
    end
    local committed = info.entryIDsWithCommittedRanks
    if type(committed) == "table" and isNumber(committed[1]) then return committed[1] end
    if type(info.entryIDs) == "table" and #info.entryIDs == 1 and isNumber(info.entryIDs[1]) then
        return info.entryIDs[1]
    end
end

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
    if not isNumber(entry.definitionID) then
        node.definition = self:State("not_collected", "entry has no definitionID")
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

local function collectTree(self, spec, limits)
    local treeID = constantNumber(spec.constant)
    local tree = { sourceKey = spec.key, displayName = treeDisplayName(spec.key), treeID = treeID, nodes = {} }
    if not treeID then
        tree.traversal = self:State("unsupported", "Constants.LegacyConsts." .. spec.constant .. " unavailable")
        return tree
    end
    tree.config = self:Probe("C_Traits.GetConfigIDByTreeID", treeID)
    local configID = self:Val(tree.config)
    if not isNumber(configID) then
        tree.traversal = self:State("not_collected",
            "no trait config for this tree (Legacy locked or trait data not ready); NOT evidence of zero investment")
        return tree
    end
    tree.configID = configID
    tree.staged = self:Probe("C_Traits.ConfigHasStagedChanges", configID)
    -- excludeStagedChanges = true: committed state, like the talents section.
    tree.currency = self:Probe("C_Traits.GetTreeCurrencyInfo", configID, treeID, true)
    if self:Val(tree.staged) ~= false then
        -- staged state unknown or present: also keep the view the Legacy UI itself shows (excludeStagedChanges=false).
        tree.currencyWithStaged = self:Probe("C_Traits.GetTreeCurrencyInfo", configID, treeID, false)
    end
    tree.nodeList = self:Probe("C_Traits.GetTreeNodes", treeID)
    local nodeIDs = self:Val(tree.nodeList)
    if type(nodeIDs) ~= "table" then return tree end
    tree.nodeTotal = #nodeIDs
    for index, nodeID in ipairs(nodeIDs) do
        if index > limits.nodes then
            tree.nodesTruncated = true
            break
        end
        local node = { nodeID = nodeID, info = self:Probe("C_Traits.GetNodeInfo", configID, nodeID) }
        tree.nodes[#tree.nodes + 1] = node
        local info = self:Val(node.info)
        local rank = nodeRank(info)
        if rank then
            node.rank = rank
            node.maxRanks = isNumber(info.maxRanks) and info.maxRanks or nil
            node.ranksPurchased = isNumber(info.ranksPurchased) and info.ranksPurchased or nil
            if rank > 0 then resolveNode(self, configID, node, info) end
        elseif node.info.status == "ok" then
            node.info = self:State("error", "node info lacks numeric currentRank/ranksPurchased")
            node.info.api = "C_Traits.GetNodeInfo"
        end
    end
    return tree
end

-- ---------------------------------------------------------------------------------------------------------------
-- Points: one shared currency; pick the entry by the points currency constant, else the UI's "first entry".

local function currencyEntries(self, probe)
    local list = self:Val(probe)
    local result = {}
    if type(list) == "table" then
        for _, entry in ipairs(list) do
            if type(entry) == "table" and isNumber(entry.traitCurrencyID) then result[#result + 1] = entry end
        end
    end
    return result
end

local function pickPointsEntry(self, trees, currencyID, field)
    for _, tree in ipairs(trees) do
        local entries = currencyEntries(self, tree[field])
        for _, entry in ipairs(entries) do
            if entry.traitCurrencyID == currencyID then return entry, tree.sourceKey, false end
        end
    end
    -- No entry matches the constant (or it is unavailable): fall back to the first entry, as the UI does.
    for _, tree in ipairs(trees) do
        local entries = currencyEntries(self, tree[field])
        if entries[1] then return entries[1], tree.sourceKey, true end
    end
end

local function collectPoints(self, section)
    local points = { currencyID = constantNumber("LEGACY_POINTS_TRAIT_CURRENCY_ID") }
    local entry, treeKey, viaFirst = pickPointsEntry(self, section.trees, points.currencyID, "currency")
    if entry then
        points.entry, points.fromTree, points.viaFirstEntry = entry, treeKey, viaFirst
        local staged = pickPointsEntry(self, section.trees, entry.traitCurrencyID, "currencyWithStaged")
        points.stagedEntry = staged
    else
        points.state = self:State("not_collected",
            "no Legacy point currency read from any tree (locked, trait data not ready or API unavailable); "
                .. "NOT 0 points")
    end
    local currencyID = entry and entry.traitCurrencyID or points.currencyID
    if currencyID then
        -- limitBySourcedMax=false as the UI passes it (Blizzard_LegacyChallenges.lua:364).
        points.maxAvailable = self:Probe("C_Traits.GetMaxAvailableTraitCurrency", currencyID, false)
    end
    return points
end

-- ---------------------------------------------------------------------------------------------------------------
-- Reward track

local function collectReward(self, limits)
    local factionID = constantNumber("LEGACY_REWARD_TRACK_FACTION_ID")
    local reward = { factionID = factionID, byLevel = {} }
    if not factionID then
        reward.state = self:State("unsupported", "Constants.LegacyConsts.LEGACY_REWARD_TRACK_FACTION_ID unavailable")
        return reward
    end
    reward.level = self:Probe("C_MajorFactions.GetCurrentRenownLevel", factionID)
    reward.data = self:Probe("C_MajorFactions.GetMajorFactionData", factionID)
    reward.levels = self:Probe("C_MajorFactions.GetRenownLevels", factionID)
    local levels = self:Val(reward.levels)
    if type(levels) == "table" then
        reward.levelTotal = #levels
        for index, info in ipairs(levels) do
            if index > limits.rewardLevels then
                reward.truncated = true
                break
            end
            if type(info) == "table" and isNumber(info.level) then
                reward.byLevel[#reward.byLevel + 1] = {
                    level = info.level, locked = info.locked, isMilestone = info.isMilestone,
                    isCapstone = info.isCapstone,
                    rewards = self:Probe("C_MajorFactions.GetRenownRewardsForLevel", factionID, info.level),
                }
            end
        end
    end
    return reward
end

-- ---------------------------------------------------------------------------------------------------------------
-- Challenges

local function categoryDescendsFrom(byID, id, ancestor)
    local current, steps = id, 0
    while isNumber(current) and current ~= TOP_LEVEL_CATEGORY and steps < 12 do
        if current == ancestor then return true end
        local entry = byID[current]
        current = entry and entry.parent
        steps = steps + 1
    end
    return false
end

local function parseChallenge(info)
    local values = info.values
    local fields = {}
    if not isNumber(values[1]) then return nil end
    fields.id = values[1]
    fields.name = type(values[2]) == "string" and values[2] or nil
    -- Not "boolean and v or nil": that turns false into nil.
    if type(values[4]) == "boolean" then fields.completed = values[4] end
    if type(values[13]) == "boolean" then fields.earnedByMe = values[13] end
    fields.description = type(values[8]) == "string" and values[8] or nil
    fields.rewardText = type(values[11]) == "string" and values[11] ~= "" and values[11] or nil
    return fields
end

local function readCriteria(self, entry, limits)
    entry.numCriteria = self:Probe("GetAchievementNumCriteria", entry.id)
    local count = self:Val(entry.numCriteria)
    entry.criteria = {}
    if not isNumber(count) then return end
    entry.criteriaTotal = count
    for index = 1, math.min(count, limits.criteria) do
        entry.criteria[#entry.criteria + 1] = self:Probe("GetAchievementCriteriaInfo", entry.id, index)
    end
end

local function collectChallenges(self, limits, pointsCurrencyID)
    local ch = { categories = {}, listed = {} }
    ch.categoryList = self:Probe("GetCategoryList")
    local ids = self:Val(ch.categoryList)
    if type(ids) ~= "table" or #ids == 0 then
        ch.traversal = self:State("not_collected",
            "challenge category list unavailable or empty (achievement data not ready?); "
                .. "NOT evidence of zero challenges")
        return ch
    end
    ch.class = self:Probe("UnitClassBase", "player")
    local classFile = self:Val(ch.class)
    local defaultConstant = type(classFile) == "string" and DEFAULT_CATEGORY_CONSTANT[classFile] or nil
    ch.defaultCategoryID = defaultConstant and constantNumber(defaultConstant) or nil

    local byID = {}
    ch.categoryTotal = #ids
    for index, id in ipairs(ids) do
        if index > limits.categories then
            ch.categoriesTruncated = true
            break
        end
        if isNumber(id) then
            local category = { id = id }
            category.info = self:Probe("GetCategoryInfo", id)
            category.counts = self:Probe("GetCategoryNumAchievements", id)
            local name, parent = self:Val(category.info, 1), self:Val(category.info, 2)
            category.name = type(name) == "string" and name or nil
            category.parent = isNumber(parent) and parent or nil
            category.total = self:Val(category.counts, 1)
            category.complete = self:Val(category.counts, 2)
            category.incomplete = self:Val(category.counts, 3)
            category.listed = 0
            ch.categories[#ch.categories + 1] = category
            byID[id] = category
        end
    end

    -- Detail order: the player's class default category and its children first, then the rest in list order.
    local ordered, rest = {}, {}
    for _, category in ipairs(ch.categories) do
        if ch.defaultCategoryID and categoryDescendsFrom(byID, category.id, ch.defaultCategoryID) then
            category.priority = true
            ordered[#ordered + 1] = category
        else
            rest[#rest + 1] = category
        end
    end
    for _, category in ipairs(rest) do ordered[#ordered + 1] = category end

    for _, category in ipairs(ordered) do
        if isNumber(category.total) and category.total > 0 then
            for index = 1, category.total do
                if #ch.listed >= limits.challenges then
                    ch.truncated = true
                    break
                end
                local entry = { category = category.id, index = index }
                entry.read = self:Probe("GetAchievementInfo", category.id, index)
                local fields = entry.read.status == "ok" and parseChallenge(entry.read) or nil
                if fields then
                    for key, value in pairs(fields) do entry[key] = value end
                    if pointsCurrencyID then
                        entry.legacyPoints = self:Probe("C_Traits.GetTraitCurrencyForAchievement",
                            pointsCurrencyID, entry.id)
                    end
                    if entry.earnedByMe ~= true then readCriteria(self, entry, limits) end
                elseif entry.read.status == "ok" then
                    entry.read = self:State("error", "GetAchievementInfo returned no numeric achievement ID")
                    entry.read.api = "GetAchievementInfo"
                end
                ch.listed[#ch.listed + 1] = entry
                category.listed = category.listed + 1
            end
        end
    end
    return ch
end

Addon:RegisterCollector("legacy", function(self)
    local limits = Addon.legacyLimits
    local section = {
        observedAt = self:Timestamp(),
        scope = "live read at collection time; challenge flags are account-wide (completed) or this character "
            .. "(wasEarnedByMe); trees and points are this character's committed state",
    }
    if not legacyConstants() then
        section.constants = self:State("unsupported", "Constants.LegacyConsts unavailable at runtime")
    end
    section.uiLoaded = self:Probe("C_AddOns.IsAddOnLoaded", "Blizzard_LegacySystem")
    section.uiLoaded.info = true -- informational: none of the reads below need the Legacy UI addon loaded
    section.reward = collectReward(self, limits)
    section.trees = {}
    for _, spec in ipairs(TREES) do
        section.trees[#section.trees + 1] = collectTree(self, spec, limits)
    end
    section.points = collectPoints(self, section)
    section.challenges = collectChallenges(self, limits, constantNumber("LEGACY_POINTS_TRAIT_CURRENCY_ID"))
    return section
end, function(self, section, out)
    local limits = Addon.legacyLimits or {}
    local reward, points, ch = section.reward, section.points, section.challenges
    out:Add("(Legacy: live read, nothing opened or changed. 'completed' = challenge done on the account; "
        .. "'earned by this character' = wasEarnedByMe)")
    out:Result("observed at (server epoch)", section.observedAt)
    if section.constants then out:State("Constants.LegacyConsts", section.constants) end
    out:Result("Blizzard_LegacySystem UI addon loaded (informational; reads below do not need it)", section.uiLoaded,
        function(loadedOrLoading, values)
            return "loadedOrLoading=" .. tostring(loadedOrLoading) .. " loaded=" .. tostring(values[2])
        end)

    -- Reward track -------------------------------------------------------------------------------------------
    out:Add("### Reward track (renown)")
    if reward.state then
        out:State("reward track", reward.state)
    else
        out:Add("faction ID: " .. tostring(reward.factionID)
            .. " (Constants.LegacyConsts.LEGACY_REWARD_TRACK_FACTION_ID)")
        out:Result("renown level", reward.level, function(level)
            local text = tostring(level)
            if isNumber(level) and level <= 0 then
                text = text .. " (the Legacy UI refuses to open at renown level <= 0: system not unlocked/started)"
            end
            return text
        end)
        out:Result("faction data", reward.data, function(data)
            if type(data) ~= "table" then return self:Fmt(data) end
            return "name=" .. self:Fmt(data.name) .. " isUnlocked=" .. self:Fmt(data.isUnlocked)
                .. " renownLevel=" .. self:Fmt(data.renownLevel) .. " maxLevel=" .. self:Fmt(data.maxLevel)
                .. " progress=" .. self:Fmt(data.renownReputationEarned) .. "/" .. self:Fmt(data.renownLevelThreshold)
        end)
        local current = self:Val(reward.level)
        local levelsTag = self:Describe(reward.levels)
        if levelsTag then
            out:Add("track levels: " .. levelsTag)
        elseif #reward.byLevel == 0 then
            out:Add("track levels: <not_collected: GetRenownLevels returned no levels; track not loaded or locked, "
                .. "NOT proof of an empty track>")
        else
            local nextLevel
            for _, item in ipairs(reward.byLevel) do
                if isNumber(current) and item.level > current and (not nextLevel or item.level < nextLevel) then
                    nextLevel = item.level
                end
            end
            out:Add("track levels: " .. reward.levelTotal .. " total, " .. #reward.byLevel .. " listed"
                .. (reward.truncated and " (TRUNCATED at " .. tostring(limits.rewardLevels) .. ")" or " (complete)"))
            for _, item in ipairs(reward.byLevel) do
                local marks = {}
                if item.locked ~= nil then marks[#marks + 1] = "locked=" .. tostring(item.locked) end
                if item.isMilestone == true then marks[#marks + 1] = "milestone" end
                if item.isCapstone == true then marks[#marks + 1] = "capstone" end
                if isNumber(current) and item.level == current then marks[#marks + 1] = "<- current level" end
                if item.level == nextLevel then marks[#marks + 1] = "<- next reward" end
                local text = "  level " .. item.level .. " [" .. table.concat(marks, ", ") .. "]: "
                local rewardTag = self:Describe(item.rewards)
                if rewardTag then
                    text = text .. rewardTag
                else
                    local list = self:Val(item.rewards)
                    local names = {}
                    for index, r in ipairs(type(list) == "table" and list or {}) do
                        if index > (limits.rewardsPerLevel or 4) then
                            names[#names + 1] = "+" .. (#list - index + 1) .. " more"
                            break
                        end
                        local label = "<no name>"
                        if type(r) == "table" and type(r.name) == "string" then label = self:Clean(r.name) end
                        if type(r) == "table" then
                            local ids = {}
                            if r.itemID then ids[#ids + 1] = "item " .. tostring(r.itemID) end
                            if r.spellID then ids[#ids + 1] = "spell " .. tostring(r.spellID) end
                            if r.mountID then ids[#ids + 1] = "mount " .. tostring(r.mountID) end
                            if r.isAccountUnlock == true then ids[#ids + 1] = "account unlock" end
                            if r.isCollected ~= nil then ids[#ids + 1] = "collected=" .. tostring(r.isCollected) end
                            if #ids > 0 then label = label .. " (" .. table.concat(ids, ", ") .. ")" end
                        end
                        names[#names + 1] = label
                    end
                    text = text .. (#names > 0 and table.concat(names, "; ")
                        or "<empty: no rewards listed for this level>")
                end
                out:Add(text)
            end
        end
    end

    -- Points -------------------------------------------------------------------------------------------------
    out:Add("### Legacy points")
    if points.state then
        out:State("points", points.state)
    else
        local entry = points.entry
        local why = "; matches LEGACY_POINTS_TRAIT_CURRENCY_ID"
        if points.viaFirstEntry then
            why = "; no entry matched LEGACY_POINTS_TRAIT_CURRENCY_ID (" .. tostring(points.currencyID)
                .. "), using the first entry as the UI does"
        end
        out:Add("pool: traitCurrencyID " .. tostring(entry.traitCurrencyID) .. " (read from tree "
            .. tostring(points.fromTree) .. why .. ")")
        local earned = self:Val(reward.level)
        out:Add("earned (UI shows renown level as points): "
            .. (isNumber(earned) and tostring(earned) or (self:Describe(reward.level) or "<not_collected>")))
        out:Add("available (unspent, quantity): " .. self:Fmt(entry.quantity))
        out:Add("spent (committed, pool-wide): " .. self:Fmt(entry.spent))
        out:Add("maxQuantity (UI tooltip 'seasonal cap'): " .. self:Fmt(entry.maxQuantity))
        out:Result("max available (GetMaxAvailableTraitCurrency, limitBySourcedMax=false)", points.maxAvailable)
        if points.stagedEntry and (points.stagedEntry.quantity ~= entry.quantity
            or points.stagedEntry.spent ~= entry.spent) then
            out:Add("staged (unapplied) view differs: available=" .. self:Fmt(points.stagedEntry.quantity) .. " spent="
                .. self:Fmt(points.stagedEntry.spent) .. " (the numbers above are committed state)")
        end
    end

    -- Trees --------------------------------------------------------------------------------------------------
    out:Add("### Legacy trees (source keys; display names are separate)")
    local pools, poolOrder = {}, {}
    for _, tree in ipairs(section.trees) do
        local head = "tree " .. tree.sourceKey .. " [display=" .. (tree.displayName and self:Clean(tree.displayName)
            or "<not_collected: LEGACY_TREE_* string unavailable>") .. "] treeID=" .. tostring(tree.treeID)
            .. " configID=" .. tostring(tree.configID)
        if tree.traversal then
            out:Add(head .. ": " .. self:Describe(tree.traversal))
        else
            out:Add(head)
            out:Result("  uncommitted staged changes", tree.staged)
            local currencyTag = self:Describe(tree.currency)
            if currencyTag then
                out:Add("  currency: " .. currencyTag)
            else
                local entries = currencyEntries(self, tree.currency)
                if #entries == 0 then
                    out:Add("  currency: <not_collected: no usable currency entry returned>")
                end
                for _, e in ipairs(entries) do
                    out:Add("  currency " .. e.traitCurrencyID .. ": spentInTree=" .. self:Fmt(e.spentInTree))
                    local pool = pools[e.traitCurrencyID]
                    if not pool then
                        pool = { id = e.traitCurrencyID, trees = {}, first = e, differs = false }
                        pools[e.traitCurrencyID] = pool
                        poolOrder[#poolOrder + 1] = pool
                    elseif e.quantity ~= pool.first.quantity or e.spent ~= pool.first.spent
                        or e.maxQuantity ~= pool.first.maxQuantity then
                        pool.differs = true
                    end
                    pool.trees[#pool.trees + 1] = tree.sourceKey
                end
            end
            local nodeTag = self:Describe(tree.nodeList)
            if nodeTag then
                out:Add("  nodes: " .. nodeTag)
            else
                local unreadable, purchased = 0, {}
                for _, node in ipairs(tree.nodes) do
                    if not isNumber(node.rank) then unreadable = unreadable + 1
                    elseif node.rank > 0 then purchased[#purchased + 1] = node end
                end
                out:Add("  nodes: " .. tree.nodeTotal .. " in tree, " .. #tree.nodes .. " read ("
                    .. (#tree.nodes - unreadable) .. " ok, " .. unreadable .. " unreadable)"
                    .. (tree.nodesTruncated and " (TRUNCATED)" or " (complete)"))
                if self:Val(tree.staged) ~= false then
                    out:Add("  note: staged-change state is "
                        .. (self:Val(tree.staged) == true and "true" or "unknown")
                        .. "; node ranks below may include unapplied changes")
                end
                if #purchased > 0 then
                    for _, node in ipairs(purchased) do
                        local text = "  invested node " .. node.nodeID .. " rank " .. node.rank .. "/"
                            .. tostring(node.maxRanks or "?")
                        local name = node.overrideName
                        if not name then
                            local resolved = self:Val(node.spellName)
                            if type(resolved) == "string" and resolved ~= "" then name = resolved end
                        end
                        if name then
                            text = text .. ": " .. self:Clean(name)
                        else
                            text = text .. ": " .. (self:Describe(node.definition) or self:Describe(node.entry)
                                or self:Describe(node.spellName) or "<not_collected: name unresolved>")
                        end
                        if node.spellID then text = text .. " (spellID " .. node.spellID .. ")" end
                        out:Add(text)
                    end
                elseif unreadable == 0 and #tree.nodes > 0 and not currencyTag then
                    out:Add("  no invested nodes (all " .. #tree.nodes .. " nodes read with 0 ranks)")
                elseif unreadable > 0 then
                    out:Add("  invested nodes: <not_collected: " .. unreadable
                        .. " unreadable node(s); cannot confirm none>")
                end
                for index, node in ipairs(tree.nodes) do
                    if not isNumber(node.rank) then
                        if index > 10 then break end
                        out:Add("  unreadable node " .. node.nodeID .. ": " .. (self:Describe(node.info) or "<error>"))
                    end
                end
            end
        end
    end
    for _, pool in ipairs(poolOrder) do
        out:Add("shared pool check: currency " .. pool.id .. " seen in trees " .. table.concat(pool.trees, ", ") .. "; "
            .. (#pool.trees > 1 and (pool.differs and "values DIFFER between trees (not merged)"
                or "identical values, counted once, not summed") or "single tree")
            .. " (quantity=" .. self:Fmt(pool.first.quantity) .. " spent=" .. self:Fmt(pool.first.spent) .. ")")
    end

    -- Challenges ---------------------------------------------------------------------------------------------
    out:Add("### Challenges")
    if ch.traversal then
        out:State("challenges", ch.traversal)
        return
    end
    out:Result("player class (default category lookup)", ch.class)
    out:Add("default category ID for class: "
        .. tostring(ch.defaultCategoryID or "<not_collected: no class/constant match>"))
    out:Add("categories: " .. #ch.categories .. " read of " .. ch.categoryTotal
        .. (ch.categoriesTruncated and " (TRUNCATED)" or " (complete)"))
    for _, category in ipairs(ch.categories) do
        local infoTag, countTag = self:Describe(category.info), self:Describe(category.counts)
        local text = "- category " .. category.id .. " " .. (category.name and ('"' .. self:Clean(category.name) .. '"')
            or (infoTag or "<not_collected: name>")) .. " parent=" .. tostring(category.parent or "?")
        if countTag then
            text = text .. " counts: " .. countTag
        else
            text = text .. " total=" .. self:Fmt(category.total) .. " complete=" .. self:Fmt(category.complete)
                .. " incomplete=" .. self:Fmt(category.incomplete) .. " listed=" .. category.listed
        end
        if category.priority then text = text .. " [class default tree]" end
        out:Add(text)
    end
    out:Add("challenge detail: " .. #ch.listed .. " listed (cap " .. tostring(limits.challenges)
        .. ", class default category first)"
        .. (ch.truncated and " -- TRUNCATED: more challenges exist; see per-category listed vs total" or " (complete)"))
    local earnedMe, otherChar, incomplete, unknown = 0, 0, 0, 0
    for _, entry in ipairs(ch.listed) do
        local text
        if not entry.id then
            out:Add("- category " .. entry.category .. " #" .. entry.index .. ": "
                .. (self:Describe(entry.read) or "<error>"))
            unknown = unknown + 1
        else
            local state
            if entry.completed == true and entry.earnedByMe == true then
                state, earnedMe = "EARNED by this character", earnedMe + 1
            elseif entry.completed == true and entry.earnedByMe == false then
                state, otherChar = "complete on account, NOT earned by this character", otherChar + 1
            elseif entry.completed == true then
                state, unknown = "complete on account, this-character flag <not_collected>", unknown + 1
            elseif entry.completed == false then
                state, incomplete = "incomplete", incomplete + 1
            else
                state, unknown = "<not_collected: completed flag missing>", unknown + 1
            end
            local pts = "<not_collected: points currency constant unavailable>"
            if entry.legacyPoints then
                pts = self:Describe(entry.legacyPoints) or tostring(self:Val(entry.legacyPoints))
            end
            text = "- [" .. entry.id .. "] " .. (entry.name and self:Clean(entry.name) or "<name?>") .. " | " .. state
                .. " | legacy points " .. pts
            if entry.description then
                local desc = self:Clean(entry.description)
                if #desc > 140 then desc = string.sub(desc, 1, 140) .. "..." end
                text = text .. " | " .. desc
            end
            out:Add(text)
            if entry.criteriaTotal then
                if entry.criteriaTotal == 0 then
                    out:Add("    criteria: none")
                else
                    out:Add("    criteria: " .. entry.criteriaTotal .. " total, " .. #entry.criteria .. " listed"
                        .. (#entry.criteria < entry.criteriaTotal and " (TRUNCATED)" or " (complete)"))
                    for index, probe in ipairs(entry.criteria) do
                        local tag = self:Describe(probe)
                        if tag then
                            out:Add("    " .. index .. ": " .. tag)
                        else
                            local v = probe.values
                            local done = "<not_collected: done flag>"
                            if v[3] == true then done = "done" elseif v[3] == false then done = "not done" end
                            local line = "    " .. index .. ": "
                                .. (type(v[1]) == "string" and self:Clean(v[1]) or "<no text>") .. " | " .. done
                            if isNumber(v[4]) and isNumber(v[5]) and v[5] > 0 then
                                local flag = EVALUATION_TREE_FLAG_PROGRESS_BAR
                                local isBar
                                if isNumber(flag) and isNumber(v[7]) then
                                    local band = self:Probe("bit.band", v[7], flag)
                                    isBar = self:Val(band) == flag
                                end
                                if isBar == true then
                                    line = line .. " | progress " .. v[4] .. "/" .. v[5]
                                elseif isBar == nil then
                                    line = line .. " | raw count " .. v[4] .. "/" .. v[5]
                                        .. " (progress-bar flag unverified, flags=" .. self:Fmt(v[7]) .. ")"
                                end
                            end
                            out:Add(line)
                        end
                    end
                end
            elseif entry.numCriteria then
                out:Add("    criteria: " .. (self:Describe(entry.numCriteria) or "<not_collected>"))
            end
        end
    end
    out:Add("listed summary: earned by this character " .. earnedMe .. ", complete only on other characters "
        .. otherChar .. ", incomplete " .. incomplete .. ", unreadable/unknown " .. unknown)
end)
