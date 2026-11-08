local _, Addon = ...

-- Evidence: Blizzard_APIDocumentationGenerated/AddOnsDocumentation.lua (line numbers below); the numeric-index
-- calls follow Blizzard_AddOnList/AddonList.lua:
--  * C_AddOns.GetNumAddOns() -> number                                   :256-263  (AddonList.lua:199)
--  * C_AddOns.GetAddOnInfo(nameOrIndex) -> name, title, notes, loadable, reason, security
--                                                                        :114-132  (AddonList.lua:201)
--  * C_AddOns.IsAddOnLoaded(nameOrIndex) -> loadedOrLoading, loaded       :322-334  (AddonList.lua:607)
--  * C_AddOns.GetAddOnMetadata(nameOrIndex, "Version") -> string          :165-179  (AddonList.lua:862)
-- Purpose: tell the assistant which other addons (especially other exporters) are running. Only loaded addons are
-- listed; Blizzard_* addons are collapsed into one count. Everything else is a count.


local function isBlizzard(name)
    return type(name) == "string" and string.sub(name, 1, 9) == "Blizzard_"
end

Addon:RegisterCollector("addons", function(self)
    local section = { count = self:Probe("C_AddOns.GetNumAddOns"), entries = {} }
    local total = self:Val(section.count)
    if type(total) ~= "number" or total < 0 or total ~= math.floor(total) then
        return section
    end
    for index = 1, total do
        local entry = {
            index = index,
            info = self:Probe("C_AddOns.GetAddOnInfo", index),
            loaded = self:Probe("C_AddOns.IsAddOnLoaded", index),
        }
        local name = self:Val(entry.info, 1)
        local loaded = self:Val(entry.loaded, 2) == true or self:Val(entry.loaded, 1) == true
        -- The version is only needed for the third-party addons that are actually running.
        if loaded and not isBlizzard(name) then
            entry.version = self:Probe("C_AddOns.GetAddOnMetadata", index, "Version")
        end
        section.entries[#section.entries + 1] = entry
    end
    return section
end, function(self, section, out)
    local total = self:Val(section.count)
    if type(total) ~= "number" then
        out:Result("installed addons", section.count)
        return
    end
    local listed, blizzardLoaded, notLoaded, unreadable = {}, 0, {}, {}
    local notLoadedTotal, firstUnreadable = 0, nil
    for _, entry in ipairs(section.entries) do
        local name = self:Val(entry.info, 1)
        local loadedTag = self:Describe(entry.loaded)
        local state = self:Val(entry.loaded, 2) == true and "loaded"
            or (self:Val(entry.loaded, 1) == true and "loading") or nil
        if loadedTag or not self:Val(entry.info, 1) then
            unreadable[#unreadable + 1] = entry.index
            firstUnreadable = firstUnreadable or (loadedTag or self:Describe(entry.info))
        end
        if state then
            if isBlizzard(name) then
                blizzardLoaded = blizzardLoaded + 1
            else
                listed[#listed + 1] = { entry = entry, name = name, state = state }
            end
        elseif not loadedTag then
            local reason = self:Val(entry.info, 5)
            reason = type(reason) == "string" and reason ~= "" and self:Clean(reason) or "unspecified"
            notLoaded[reason] = (notLoaded[reason] or 0) + 1
            notLoadedTotal = notLoadedTotal + 1
        end
    end
    out:Add("installed: " .. total .. " | running: " .. (#listed + blizzardLoaded) .. " (third-party "
        .. #listed .. ", Blizzard_* " .. blizzardLoaded .. " collapsed) | not running: " .. notLoadedTotal)
    local reasons = {}
    for reason, count in pairs(notLoaded) do reasons[#reasons + 1] = reason .. "=" .. count end
    table.sort(reasons)
    if #reasons > 0 then
        out:Add("not running by reason (client codes, listed addons omitted): " .. table.concat(reasons, ", "))
    end
    if #unreadable > 0 then
        out:Add("unreadable addon entries: " .. #unreadable .. " (first index " .. unreadable[1] .. "): "
            .. tostring(firstUnreadable))
    end
    if #listed == 0 then
        out:Add("running third-party addons: none (count above is from the API, not a guess)")
        return
    end
    out:Add("### running third-party addons (" .. #listed .. ")")
    for _, item in ipairs(listed) do
        local info = item.entry.info
        local name = item.name and self:Clean(item.name) or ("<index " .. item.entry.index .. ", name unreadable>")
        local title = self:Val(info, 2)
        local parts = { name }
        if type(title) == "string" and title ~= "" and self:Clean(title) ~= name then
            local cleaned = self:Clean(title)
            if #cleaned > 60 then cleaned = string.sub(cleaned, 1, 60) .. "..." end
            parts[#parts + 1] = "\"" .. cleaned .. "\""
        end
        local version = item.entry.version
        if version then
            if self:Describe(version) == nil then
                local text = self:Fmt(version.values[1])
                parts[#parts + 1] = string.find(text, "^[vV]%d") and text or ("v" .. text)
            elseif version.status == "not_collected" and version.values then
                parts[#parts + 1] = "version=<not_collected: no Version field returned>"
            else
                parts[#parts + 1] = "version=" .. self:Describe(version)
            end
        end
        if item.state == "loading" then parts[#parts + 1] = "(still loading)" end
        if item.name == self.name then parts[#parts + 1] = "(this addon)" end
        local haystack = string.lower((type(item.name) == "string" and item.name or "") .. " "
            .. (type(title) == "string" and title or ""))
        if item.name ~= self.name and string.find(haystack, "export", 1, true) then
            parts[#parts + 1] = "[exporter?]"
        end
        out:Add("- " .. table.concat(parts, " | "))
    end
end)
