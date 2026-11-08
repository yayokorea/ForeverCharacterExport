-- Mocked tests for UI.lua. The stub records widgets and handlers; it is NOT the WoW widget system, so these only
-- prove the wiring (clicks change saved settings, text/colour calls happen, geometry is saved), never rendering.
-- luacheck: read globals Minimap
local Addon = AddonUnderTest

local created -- every stub of the current test, in creation order

local function stub(kind, name, parent, template)
    local widget = { kind = kind, name = name, parent = parent, template = template, scripts = {}, texts = {},
        shown = false, points = {}, children = {}, width = 100, height = 20, checked = false, focused = false,
        highlighted = false }
    local methods = {}
    function methods.SetScript(self, event, fn) self.scripts[event] = fn end
    function methods.GetScript(self, event) return self.scripts[event] end
    function methods.SetText(self, text) self.text = text; self.texts[#self.texts + 1] = text end
    function methods.GetText(self) return self.text end
    function methods.Show(self) self.shown = true end
    function methods.Hide(self) self.shown = false end
    function methods.IsShown(self) return self.shown end
    function methods.SetChecked(self, value) self.checked = value and true or false end
    function methods.GetChecked(self) return self.checked end
    function methods.SetSize(self, w, h) self.width, self.height = w, h end
    function methods.SetWidth(self, w) self.width = w end
    function methods.GetWidth(self) return self.width end
    function methods.GetHeight(self) return self.height end
    function methods.SetPoint(self, ...) self.points[#self.points + 1] = { ... } end
    function methods.ClearAllPoints(self) self.points = {} end
    function methods.GetPoint(self)
        local p = self.points[#self.points]
        if p then return p[1], UIParent, p[3] or p[1], p[4] or 0, p[5] or 0 end
        return "CENTER", UIParent, "CENTER", 0, 0
    end
    function methods.SetFocus(self) self.focused = true end
    function methods.HighlightText(self) self.highlighted = true end
    function methods.CreateFontString(self, ...) return stub("FontString", nil, self, ...) end
    function methods.CreateTexture(self, ...) return stub("Texture", nil, self, ...) end
    function methods.GetVerticalScrollRange() return 0 end
    function methods.GetVerticalScroll() return 0 end
    function methods.StartMoving(self) self.moving = true end
    function methods.StartSizing(self, point) self.sizing = point end
    function methods.StopMovingOrSizing(self) self.moving, self.sizing = nil, nil end
    function methods.GetCenter() return 0, 0 end
    setmetatable(widget, { __index = function(_, key)
        if methods[key] then return methods[key] end
        -- Widget methods start with a capital letter; fields (template, text, edit, ...) are lowercase.
        if key == "Text" or not string.find(key, "^%u") then return nil end
        return function() end -- every other widget method is a no-op
    end })
    created[#created + 1] = widget
    return widget
end

local function withUI(options, fn)
    options = options or {}
    local saved = { window = Addon.window, ui = Addon.ui, launcher = Addon.launcher, db = Addon.db,
        detail = Addon.detail, lastReport = Addon.lastReport, lastMode = Addon.lastMode }
    created = {}
    Addon.window, Addon.ui, Addon.launcher, Addon.lastReport, Addon.lastMode = nil, nil, nil, nil, nil
    Addon.db = options.db or { snapshots = {}, minimap = {}, sections = {}, detail = {}, window = {}, ui = {} }
    Addon.detail = Addon.db.detail
    local globals = { CreateFrame = function(kind, name, parent, template)
        if options.failTemplates and options.failTemplates[template] then error("template missing: " .. template) end
        local widget = stub(kind, name, parent, template)
        if template == "UICheckButtonTemplate" then rawset(widget, "Text", stub("FontString", nil, widget)) end
        return widget
    end, UIParent = stub("Frame", "UIParent"), Minimap = stub("Frame", "Minimap"), GameTooltip = stub("Frame") }
    local ok, err = pcall(function() WithGlobals(globals, fn) end)
    Addon.window, Addon.ui, Addon.launcher, Addon.db, Addon.detail = saved.window, saved.ui, saved.launcher,
        saved.db, saved.detail
    Addon.lastReport, Addon.lastMode = saved.lastReport, saved.lastMode
    created = nil
    if not ok then error(err, 0) end
end

local function findButton(label)
    for index = #created, 1, -1 do -- newest first (tests may build the window twice)
        local widget = created[index]
        if widget.kind == "Button" and widget.text == label then return widget end
    end
    error("no button with text '" .. label .. "'")
end

local function click(widget, which)
    assert(widget.scripts.OnClick, "no OnClick on " .. tostring(widget.text))
    widget.scripts.OnClick(widget, which or "LeftButton")
end

Tests["ui.load_time_creates_no_frames_and_registers_slash"] = function()
    -- UI.lua ran at load with the prelude stub; only the slash command and the login handler exist then
    assert(type(SlashCmdList.FOREVERCHARACTEREXPORT) == "function")
    assert(SLASH_FOREVERCHARACTEREXPORT1 == "/fce")
    assert(Addon.handlers.PLAYER_LOGIN ~= nil)
end

Tests["ui.window_has_a_row_per_section_and_only_plain_widgets"] = function()
    withUI(nil, function()
        local frame = Addon:BuildWindow()
        assert(frame.name == "ForeverCharacterExportWindow" and frame.kind == "Frame")
        assert(frame.movable ~= false and frame.scripts.OnDragStart and frame.scripts.OnDragStop)
        for _, name in ipairs(Addon.order) do
            assert(Addon.ui.rows[name], name)
        end
        for _, widget in ipairs(created) do
            -- only these templates; no secure/protected template, no dropdown/menu
            local t = widget.template
            assert(t == nil or t == "UIPanelButtonTemplate" or t == "UICheckButtonTemplate"
                or t == "UIPanelCloseButton" or t == "UIPanelScrollFrameTemplate" or t == "GameFontNormal"
                or t == "GameFontNormalSmall" or t == "GameFontHighlightSmall" or widget.kind == "FontString"
                or widget.kind == "Texture", tostring(t))
            assert(not (t and string.find(t, "Secure", 1, true)))
        end
        -- detail switches exist for exactly legacy / spelldetails / planning / professions
        for _, name in ipairs(Addon.order) do
            local expected = name == "legacy" or name == "spelldetails" or name == "planning" or name == "professions"
            assert((Addon.ui.rows[name].detail ~= nil) == expected, name)
        end
    end)
end

Tests["ui.checkbox_click_saves_section_state"] = function()
    withUI(nil, function()
        Addon:BuildWindow()
        local row = Addon.ui.rows.pet
        row.toggle.frame.checked = false
        row.toggle.frame.scripts.OnClick(row.toggle.frame)
        assert(Addon.db.sections.pet == false and not Addon:IsSectionEnabled("pet"))
        row.toggle.frame.checked = true
        row.toggle.frame.scripts.OnClick(row.toggle.frame)
        assert(Addon.db.sections.pet == nil)
        click(findButton("모두 끄기"))
        for _, name in ipairs(Addon.order) do assert(Addon.db.sections[name] == false) end
        click(findButton("모두 켜기"))
        assert(next(Addon.db.sections) == nil)
    end)
end

Tests["ui.detail_buttons_set_spelldetails_legacy_planning_and_professions"] = function()
    withUI(nil, function()
        Addon:BuildWindow()
        for _, name in ipairs({ "legacy", "spelldetails", "planning" }) do
            local button = Addon.ui.rows[name].detail
            assert(button.text == "요약")
            click(button)
            assert(Addon.db.detail[name] == "full" and Addon.detail[name] == "full" and button.text == "전체", name)
            click(button)
            assert(Addon.db.detail[name] == nil and button.text == "요약")
        end
        local professions = Addon.ui.rows.professions
        assert(professions.detail.text == "재료" and professions.count.text == "15개")
        click(professions.detail)
        assert(Addon.db.professions.detail == "summary" and professions.detail.text == "요약")
        click(professions.count)
        assert(Addon.db.professions.maxRecipes == 50 and professions.count.text == "50개")
        local limits = Addon.collectors.professions(Addon).limits
        assert(limits.detail == "summary" and limits.maxRecipes == 50)
    end)
end

Tests["ui.export_button_collects_shows_text_and_selects_it"] = function()
    withUI(nil, function()
        Addon:BuildWindow()
        assert(not Addon.window.edit.focused, "opening the window must not take the keyboard")
        click(findButton("내보내기"))
        assert(Addon.lastReport ~= nil)
        local text = Addon.window.edit.text
        assert(text:find("# ForeverCharacterExport 0.4.0", 1, true), text:sub(1, 120))
        assert(Addon.window.edit.focused and Addon.window.edit.highlighted)
        assert(Addon.ui.updated.text:find("켜진 구역 21/21", 1, true), Addon.ui.updated.text)
        -- status column and needed actions are filled from the report
        assert(Addon.ui.rows.character.status.text ~= "-")
        assert(Addon.ui.actions.text:find("필요한 행동", 1, true))
        -- Raw and last snapshot
        click(findButton("Raw"))
        assert(Addon.window.edit.text:find("diagnostic", 1, true) and Addon.lastMode == "diag")
        click(findButton("마지막 스냅샷"))
        assert(Addon.window.edit.text:find("STALE", 1, true))
        click(findButton("새로고침"))
        assert(Addon.window.edit.text:find("# ForeverCharacterExport", 1, true))
    end)
end

Tests["ui.last_snapshot_without_a_report_says_so"] = function()
    withUI(nil, function()
        click((function() Addon:BuildWindow() return findButton("마지막 스냅샷") end)())
        assert(Addon.window.edit.text:find("스냅샷이 없습니다", 1, true))
    end)
end

Tests["ui.disabled_section_shows_off_in_the_report_and_status"] = function()
    withUI(nil, function()
        Addon:BuildWindow()
        Addon:SetSectionEnabled("legacy", false)
        click(findButton("내보내기"))
        assert(Addon.window.edit.text:find("## legacy  [off]", 1, true))
        assert(Addon.ui.rows.legacy.status.text == "꺼짐")
        assert(Addon.ui.updated.text:find("켜진 구역 20/21", 1, true))
        -- switching it off after the export marks the stale status
        Addon:SetSectionEnabled("pet", false)
        Addon:RefreshSettingsUI()
        assert(Addon.ui.rows.pet.status.text:find("꺼짐", 1, true))
    end)
end

Tests["ui.window_geometry_is_saved_and_restored"] = function()
    withUI(nil, function()
        local frame = Addon:BuildWindow()
        assert(frame.points[1][1] == "CENTER", "default position")
        frame.points = { { "TOPLEFT", UIParent, "TOPLEFT", 120, -80 } }
        frame.width, frame.height = 1000, 700
        frame.scripts.OnDragStop(frame)
        local saved = Addon.db.window
        assert(saved.point == "TOPLEFT" and saved.x == 120 and saved.y == -80 and saved.width == 1000
            and saved.height == 700, "saved geometry")
        -- a new window built from that DB uses it
        Addon.window, Addon.ui = nil, nil
        local again = Addon:BuildWindow()
        assert(again.width == 1000 and again.height == 700)
        assert(again.points[#again.points][1] == "TOPLEFT" and again.points[#again.points][4] == 120)
        -- the resize grip saves too
        local grip = findButton("크기")
        grip.scripts.OnMouseDown(grip)
        assert(again.sizing == "BOTTOMRIGHT")
        again.width = 900
        grip.scripts.OnMouseUp(grip)
        assert(Addon.db.window.width == 900 and not again.sizing)
        assert(Addon.ui.edit.width == 900 - (424 + 24) - 56, "result box follows the window width")
    end)
end

Tests["ui.bad_saved_geometry_falls_back_to_defaults"] = function()
    withUI({ db = { snapshots = {}, minimap = {}, sections = {}, detail = {}, ui = {},
        window = { point = "TOP", x = "a", y = 0 / 0, width = 5, height = "x" } } }, function()
        local frame = Addon:BuildWindow()
        assert(frame.points[1][1] == "CENTER")
        assert(frame.width == 780 and frame.height == 660, "width clamped to the minimum, bad height ignored")
    end)
end

Tests["ui.missing_checkbox_template_falls_back_to_buttons"] = function()
    withUI({ failTemplates = { UICheckButtonTemplate = true } }, function()
        Addon:BuildWindow()
        local toggle = Addon.ui.rows.pet.toggle
        assert(toggle.frame.kind == "Button")
        click(toggle.frame)
        assert(not Addon:IsSectionEnabled("pet") and toggle.frame.text:find("[끔]", 1, true))
        click(toggle.frame)
        assert(Addon:IsSectionEnabled("pet"))
    end)
end

Tests["ui.missing_scroll_template_falls_back_to_a_plain_scroll_frame"] = function()
    withUI({ failTemplates = { UIPanelScrollFrameTemplate = true } }, function()
        Addon:BuildWindow()
        assert(Addon.ui.scroll.kind == "ScrollFrame" and Addon.ui.scroll.template == nil)
        assert(Addon.ui.scroll.scripts.OnMouseWheel)
    end)
end

Tests["ui.minimap_clicks_follow_the_setting"] = function()
    withUI(nil, function()
        Addon:LauncherClick("LeftButton") -- default: window
        assert(Addon.window and Addon.window:IsShown() and Addon.lastReport == nil)
        Addon:LauncherClick("LeftButton") -- toggles closed
        assert(not Addon.window:IsShown())
        Addon:LauncherClick("RightButton") -- settings
        assert(Addon.window:IsShown() and Addon.lastReport == nil)
        Addon.window:Hide()
        click(findButton("미니맵 좌클릭: 창 열기"))
        assert(Addon:LeftClickAction() == "export")
        assert(Addon.ui.clickMode.text == "미니맵 좌클릭: 바로 내보내기")
        Addon:LauncherClick("LeftButton")
        assert(Addon.lastReport ~= nil and Addon.window:IsShown())
        assert(Addon.window.edit.text:find("# ForeverCharacterExport", 1, true))
    end)
end

Tests["ui.launcher_is_created_with_a_current_tooltip"] = function()
    withUI(nil, function()
        Addon:CreateLauncher()
        local button = Addon.launcher
        assert(button and button.name == "ForeverCharacterExportLauncher")
        local lines = {}
        local tooltip = GameTooltip
        tooltip.AddLine = function(_, text) lines[#lines + 1] = text end
        button.scripts.OnEnter(button)
        local text = table.concat(lines, "\n")
        assert(text:find("왼쪽 클릭: 창 열기/닫기", 1, true) and text:find("오른쪽 클릭: 창 열기", 1, true), text)
        Addon:ToggleLeftClickAction()
        lines = {}
        button.scripts.OnEnter(button)
        assert(table.concat(lines, "\n"):find("왼쪽 클릭: 바로 내보내기", 1, true))
        button.scripts.OnClick(button, "RightButton")
        assert(Addon.window and Addon.window:IsShown())
    end)
end

Tests["ui.slash_commands"] = function()
    withUI(nil, function()
        local slash = SlashCmdList.FOREVERCHARACTEREXPORT
        slash("")
        assert(Addon.window:IsShown())
        slash("")
        assert(not Addon.window:IsShown(), "/fce toggles")
        slash("export")
        assert(Addon.lastReport ~= nil and Addon.window:IsShown())
        slash("hide")
        assert(not Addon.window:IsShown())
        slash("last")
        assert(Addon.window.edit.text:find("STALE", 1, true))
        slash("diag")
        assert(Addon.lastMode == "diag")
        slash("nonsense")
        assert(Addon.window.edit.text:find("/fce export", 1, true))
        slash("button")
        assert(Addon.db.minimap.hide == true)
    end)
end

Tests["ui.escape_in_the_result_box_closes_the_window"] = function()
    withUI(nil, function()
        Addon:ShowWindow()
        Addon.window.edit.scripts.OnEscapePressed()
        assert(not Addon.window:IsShown())
    end)
end
