-- Core framework contracts only. Per-collector tests live in tests/collectors/<name>.lua.
local Addon = AddonUnderTest

local function withTestCollector(collect, format, fn)
    local order, savedCollector, savedFormatter = Addon.order, Addon.collectors.zz_test, Addon.formatters.zz_test
    Addon.order = { "zz_test" }
    Addon:RegisterCollector("zz_test", collect, format)
    local ok, err = pcall(fn)
    Addon.order, Addon.collectors.zz_test, Addon.formatters.zz_test = order, savedCollector, savedFormatter
    if not ok then error(err, 0) end
end

Tests["core.probe_preserves_nil_and_false"] = function()
    WithGlobals({ ProbeApi = function() return false, nil, "x" end }, function()
        local r = Addon:Probe("ProbeApi")
        assert(r.status == "ok" and r.values.n == 3 and r.values[1] == false and r.values[2] == nil)
        assert(Addon:Val(r, 1) == false and Addon:Val(r, 3) == "x")
    end)
end

Tests["core.probe_states"] = function()
    assert(Addon:Probe("NoSuchApi.Nope").status == "unsupported")
    WithGlobals({ ProbeNothing = function() end }, function()
        assert(Addon:Probe("ProbeNothing").status == "not_collected")
    end)
    WithGlobals({ ProbeDenied = function() return FCE_DENIED end }, function()
        assert(Addon:Probe("ProbeDenied").status == "restricted")
    end)
    WithGlobals({ ProbeNested = function() return { name = FCE_SECRET } end }, function()
        assert(Addon:Probe("ProbeNested").status == "restricted")
    end)
    WithGlobals({ ProbeThrows = function() error("boom") end }, function()
        assert(Addon:Probe("ProbeThrows").status == "error")
    end)
    WithGlobals({ ProbeThrowsSecret = function() error(FCE_SECRET) end }, function()
        assert(Addon:Probe("ProbeThrowsSecret").status == "restricted")
    end)
    WithGlobals({ issecretvalue = false, ProbeAny = function() return 1 end }, function()
        assert(Addon:Probe("ProbeAny").status == "not_collected")
    end)
end

Tests["core.collect_isolates_failures"] = function()
    withTestCollector(function() error("collector exploded") end, function() end, function()
        local report = Addon:Collect()
        assert(report.sections.zz_test.status == "error")
    end)
end

Tests["core.collects_on_any_build"] = function()
    local other = function() return "1.60.1", "99999", "other", 16001 end
    withTestCollector(function() return { marker = true } end, function() end, function()
        WithGlobals({ GetBuildInfo = other }, function()
            assert(Addon:Collect().sections.zz_test.marker == true)
        end)
        WithGlobals({ GetBuildInfo = false }, function()
            -- an unsupported build probe must not crash or block the collection
            assert(Addon:Collect().sections.zz_test.marker == true)
        end)
    end)
end

Tests["core.missing_collector_is_reported"] = function()
    local order = Addon.order
    Addon.order = { "zz_missing" }
    local ok, text = pcall(function() return Addon:Report(Addon:Collect(), false) end)
    Addon.order = order
    assert(ok, text)
    assert(text:find("collector not registered", 1, true) and text:find("## coverage", 1, true))
end

Tests["core.report_format"] = function()
    WithGlobals({ ProbeBad = function() end, ProbeGood = function() return "|cff112233Name|r", 5 end }, function()
        withTestCollector(function(self)
            local section = {}
            self:Read(section, "good", "ProbeGood")
            self:Read(section, "bad", "ProbeBad")
            section.none = self:State("empty", "nothing here")
            return section
        end, function(_, section, out)
            out:Result("good", section.good)
            out:Result("bad", section.bad)
            out:State("none", section.none)
            out:KV("missing", nil)
        end, function()
            local text = Addon:Report(Addon:Collect(), false)
            assert(text:find("good: Name", 1, true) and not text:find("|c", 1, true), text)
            assert(text:find("bad: <not_collected: API returned no value", 1, true), text)
            assert(text:find("none: <empty: nothing here>", 1, true) and text:find("missing: <nil>", 1, true))
            assert(text:find("## coverage", 1, true) and text:find("Unknowable", 1, true) and text:find("# end", 1, true))
            assert(text == Addon:Report(Addon.lastReport, false), "report must be deterministic")
            assert(Addon:Report(Addon.lastReport, true):find("STALE", 1, true))
        end)
    end)
end

Tests["core.formatter_error_is_contained"] = function()
    withTestCollector(function() return {} end, function() error("bad format") end, function()
        local text = Addon:Report(Addon:Collect(), false)
        assert(text:find("formatter failed", 1, true))
    end)
end

Tests["core.raw_export_is_stable"] = function()
    withTestCollector(function() return { value = Addon:Probe("GetServerTime") } end, function() end, function()
        local report = Addon:Collect()
        local text = Addon:Export(report, true)
        assert(text:find('"stale"', 1, true) and text == Addon:Export(report, true))
    end)
end

Tests["core.persist_roundtrip_and_guard"] = function()
    local saved = Addon.db
    Addon.db = { snapshots = {}, minimap = {} }
    assert(Addon:Persist("k", { items = { 1, 2 } }) == true)
    local entry = Addon:Persisted("k")
    assert(entry.capturedAt == 123456 and entry.data.items[2] == 2)
    assert(select(1, Addon:Persist("k", { bad = FCE_SECRET })) == false)
    assert(Addon:Persisted("k").data.items[2] == 2, "failed persist must not clobber the previous snapshot")
    Addon.db = nil
    assert(select(1, Addon:Persist("k", {})) == false)
    Addon.db = saved
end

Tests["core.events_are_contained"] = function()
    local before = #Addon.handlerErrors
    Addon:On("FCE_TEST_EVENT", function() error("handler failed") end)
    Addon.Dispatch(nil, "FCE_TEST_EVENT")
    assert(#Addon.handlerErrors == before + 1)
    Addon.handlerErrors[#Addon.handlerErrors] = nil
    Addon.handlers.FCE_TEST_EVENT = nil
    Addon.eventStatus.FCE_TEST_EVENT = nil
end

Tests["core.addon_loaded_creates_db"] = function()
    WithGlobals({ ForeverCharacterExportDB = false }, function()
        local saved = Addon.db
        Addon.Dispatch(nil, "ADDON_LOADED", "SomeOtherAddon")
        assert(Addon.db == saved)
        Addon.Dispatch(nil, "ADDON_LOADED", Addon.name)
        assert(type(ForeverCharacterExportDB.snapshots) == "table" and Addon.db == ForeverCharacterExportDB)
        Addon.db = saved
    end)
end
