-- Test-only prelude: access guards, harmless UI stubs, and helpers shared by every test file.
-- It never imitates the WoW runtime; each test sets the exact API returns it needs with WithGlobals.
FCE_SECRET = {}
FCE_DENIED = {}
issecretvalue = function(value) return value == FCE_SECRET end
canaccessvalue = function(value) return value ~= FCE_DENIED end
GetServerTime = function() return 123456 end
GetBuildInfo = function() return "1.60.1", "70790", "Nov 3 2026", 16001 end
SlashCmdList = {}
Enum = {}
date = os.date

local noop = function() end
CreateFrame = function()
    return setmetatable({}, { __index = function() return noop end })
end

Tests = {}

-- Temporarily set globals (nil removes one), run fn, always restore, then rethrow any error.
function WithGlobals(overrides, fn)
    local saved, present = {}, {}
    for key, value in pairs(overrides) do
        saved[key] = _G[key]
        present[key] = true
        _G[key] = value
    end
    local ok, err = pcall(fn)
    for key in pairs(present) do _G[key] = saved[key] end
    if not ok then error(err, 0) end
end

function RunAllTests()
    local names = {}
    for name in pairs(Tests) do names[#names + 1] = name end
    table.sort(names)
    local failures = 0
    for _, name in ipairs(names) do
        local ok, err = pcall(Tests[name])
        if ok then
            print("  ok   " .. name)
        else
            failures = failures + 1
            print("  FAIL " .. name .. ": " .. tostring(err))
        end
    end
    return failures, #names
end
