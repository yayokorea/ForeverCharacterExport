local _, Addon = ...
-- luacheck: read globals Minimap GameTooltip GetCursorPosition
-- luacheck: globals SLASH_FOREVERCHARACTEREXPORT1 SLASH_FOREVERCHARACTEREXPORT2

-- Window UI. Only plain (non-secure, non-protected) Frames and Buttons are created, and nothing here touches a
-- protected action, a secure template, UISpecialFrames or a keyboard handler on the frame. The logic (what is
-- switched on, detail levels, status per section, needed actions) lives in Settings.lua and is unit tested; this
-- file only maps it onto widgets.
--
-- Widget evidence (references/upstream/Interface/AddOns/):
--  * Frame methods SetMovable / StartMoving / StopMovingOrSizing / SetClampedToScreen / SetResizable /
--    SetResizeBounds / StartSizing / SetUserPlaced: Blizzard_APIDocumentationGenerated/SimpleFrameAPIDocumentation.lua
--    (:1405, :1437, :1447, :1508, :1559). StartMoving/StartSizing/StopMovingOrSizing are declared protected
--    functions, so they are only used on this addon's own ordinary frame. GetPoint(): Blizzard_SharedTalentUI/
--    Blizzard_SharedTalentUtil.lua:507.
--  * EditBox methods (SetText, SetFocus, HighlightText, SetMultiLine, SetMaxLetters, SetAutoFocus, SetFontObject):
--    SimpleEditBoxAPIDocumentation.lua. FontString SetTextColor / SetJustifyH: used across the upstream UI.
--  * Templates. UICheckButtonTemplate (child FontString key "Text"): Blizzard_SharedXML/Shared/Button/
--    CheckButtonTemplates.xml:50-54, loaded unconditionally (Blizzard_SharedXML.toc:70). UIPanelCloseButton:
--    Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml:148, UIPanelButtonTemplate :315 (the [Family] line of the
--    SharedXML TOC resolves to the only existing family folder, Mainline; the TOC also lists
--    Shared\Button\UIPanelButtonTemplates.xml). UIPanelButtonTemplate was already used by the 0.3.0 window.
--  * UIPanelScrollFrameTemplate: Blizzard_SharedXML/SecureScrollTemplates.xml:44 (listed in Blizzard_SharedXML.toc:185,
--    unconditional); it is also what the 0.3.0 window used in the game. Creation is still guarded with pcall and
--    falls back to a plain ScrollFrame with the mouse wheel. The fallback calls EnableMouseWheel and
--    GetVerticalScroll, which have no Lua call site in references/upstream: UNVERIFIED (fallback only).
--  * Fonts are default font objects only (GameFontNormal, GameFontNormalSmall, GameFontHighlightSmall,
--    ChatFontNormal; all referenced by upstream XML), so Korean text renders with the client's own font.

local WINDOW = { width = 1060, height = 660, minWidth = 920, minHeight = 640, maxWidth = 1700, maxHeight = 1300 }
local LEFT_WIDTH, ROW_HEIGHT, TOP = 540, 21, 44
local STATUS_X, STATUS_WIDTH = 224, 200
local EDIT_X = LEFT_WIDTH + 24
local COLORS = {
    ok = { 0.35, 1, 0.35 }, warn = { 1, 0.82, 0 }, unsupported = { 1, 0.45, 0.45 }, error = { 1, 0.25, 0.25 },
    off = { 0.55, 0.55, 0.55 }, none = { 0.7, 0.7, 0.7 },
}
local TITLES = {
    report = "내보내기 결과 - Ctrl+C로 복사해서 붙여넣으세요",
    diag = "원본 진단(Raw) - Ctrl+C",
    last = "마지막 스냅샷 (이번 접속에서 이전에 수집한 것, 최신 아님)",
    help = "도움말",
}

local function setColor(fontString, color)
    fontString:SetTextColor(color[1], color[2], color[3])
end

-- Button from the template that already worked in 0.3.0.
local function makeButton(parent, label, width, height)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height or 22)
    button:SetText(label)
    return button
end

local function makeLabel(parent, font, text)
    local fontString = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    if text then fontString:SetText(text) end
    return fontString
end

-- Checkbox from UICheckButtonTemplate; if the template is missing, a [켬]/[끔] button does the same job.
local function makeToggle(parent, label, onChange)
    local toggle = {}
    local ok, check = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
    if ok and check then
        check:SetSize(22, 22)
        local text = check.Text or check.text
        if text then
            text:SetText(label)
            toggle.label = text
        end
        check:SetScript("OnClick", function(self) onChange(self:GetChecked() and true or false) end)
        toggle.frame = check
        function toggle.Set(value) check:SetChecked(value and true or false) end
    else
        local button = makeButton(parent, label .. " [켬]", 190, 20)
        local state = true
        button:SetScript("OnClick", function()
            state = not state
            button:SetText(label .. (state and " [켬]" or " [끔]"))
            onChange(state)
        end)
        toggle.frame = button
        function toggle.Set(value)
            state = value and true or false
            button:SetText(label .. (state and " [켬]" or " [끔]"))
        end
    end
    return toggle
end

-- ---------------------------------------------------------------------------------------------------------------
-- Window geometry (saved per character in db.window)

local function validNumber(value)
    return type(value) == "number" and value == value
end

function Addon:SaveWindow()
    local frame, db = self.window, self.db
    if not frame or type(db) ~= "table" then return end
    local point, _, relPoint, x, y = frame:GetPoint()
    if point and validNumber(x) and validNumber(y) then
        db.window = { point = point, relPoint = relPoint or point, x = x, y = y,
            width = frame:GetWidth(), height = frame:GetHeight() }
    end
end

local function applyGeometry(self, frame)
    local saved = self.db and self.db.window
    local width, height = WINDOW.width, WINDOW.height
    if type(saved) == "table" then
        if validNumber(saved.width) then
            width = math.max(WINDOW.minWidth, math.min(WINDOW.maxWidth, saved.width))
        end
        if validNumber(saved.height) then
            height = math.max(WINDOW.minHeight, math.min(WINDOW.maxHeight, saved.height))
        end
    end
    frame:SetSize(width, height)
    frame:ClearAllPoints()
    if type(saved) == "table" and type(saved.point) == "string" and validNumber(saved.x) and validNumber(saved.y) then
        frame:SetPoint(saved.point, UIParent, type(saved.relPoint) == "string" and saved.relPoint or saved.point,
            saved.x, saved.y)
    else
        frame:SetPoint("CENTER")
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Building the window

local function detailText(self, name)
    return self:IsDetailFull(name) and "전체" or "요약"
end

local function buildRows(self, frame, ui)
    ui.rows = {}
    local header = makeLabel(frame, "GameFontNormal", "구역 선택")
    header:SetPoint("TOPLEFT", 16, -TOP)
    local statusHeader = makeLabel(frame, "GameFontNormalSmall", "마지막 수집 상태")
    statusHeader:SetPoint("TOPLEFT", STATUS_X, -TOP - 22)
    local detailHeader = makeLabel(frame, "GameFontNormalSmall", "상세 수준")
    detailHeader:SetPoint("TOPLEFT", LEFT_WIDTH - 130, -TOP - 22)
    local allOn = makeButton(frame, "모두 켜기", 78, 20)
    allOn:SetPoint("TOPLEFT", 150, -TOP + 3)
    allOn:SetScript("OnClick", function()
        self:SetAllSections(true)
        self:RefreshSettingsUI()
    end)
    local allOff = makeButton(frame, "모두 끄기", 78, 20)
    allOff:SetPoint("LEFT", allOn, "RIGHT", 4, 0)
    allOff:SetScript("OnClick", function()
        self:SetAllSections(false)
        self:RefreshSettingsUI()
    end)

    local detailSet = {}
    for _, name in ipairs(self.detailSections) do detailSet[name] = true end
    for index, name in ipairs(self.order) do
        local row = {}
        local y = -TOP - 40 - (index - 1) * ROW_HEIGHT
        row.toggle = makeToggle(frame, self.sectionLabels[name] or name, function(value)
            self:SetSectionEnabled(name, value)
            self:RefreshSettingsUI()
        end)
        row.toggle.frame:SetPoint("TOPLEFT", 12, y + 2)
        row.status = makeLabel(frame, "GameFontNormalSmall", "-")
        row.status:SetPoint("TOPLEFT", STATUS_X, y - 4)
        row.status:SetWidth(STATUS_WIDTH)
        row.status:SetJustifyH("LEFT")
        if detailSet[name] then
            row.detail = makeButton(frame, "요약", 60, 19)
            row.detail:SetPoint("TOPLEFT", LEFT_WIDTH - 130, y + 1)
            row.detail:SetScript("OnClick", function()
                self:SetDetailFull(name, not self:IsDetailFull(name))
                self:RefreshSettingsUI()
            end)
        elseif name == "professions" then
            row.detail = makeButton(frame, "재료", 60, 19)
            row.detail:SetPoint("TOPLEFT", LEFT_WIDTH - 130, y + 1)
            row.detail:SetScript("OnClick", function()
                local _, current = self:ProfessionSettings()
                self:SetProfessionDetail(current == "reagents" and "summary" or "reagents")
                self:RefreshSettingsUI()
            end)
            row.count = makeButton(frame, "15개", 60, 19)
            row.count:SetPoint("TOPLEFT", LEFT_WIDTH - 66, y + 1)
            row.count:SetScript("OnClick", function()
                self:CycleProfessionMax()
                self:RefreshSettingsUI()
            end)
        end
        ui.rows[name] = row
    end
end

local function buildBottom(self, frame, ui)
    local function bottomButton(label, width, anchor, onClick)
        local button = makeButton(frame, label, width, 24)
        if anchor then
            button:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
        else
            button:SetPoint("BOTTOMLEFT", 16, 14)
        end
        button:SetScript("OnClick", onClick)
        return button
    end
    local export = bottomButton("내보내기", 90, nil, function() self:Run("report") end)
    local refresh = bottomButton("새로고침", 80, export, function() self:Run(self.lastMode or "report") end)
    local raw = bottomButton("Raw", 50, refresh, function() self:Run("diag") end)
    local last = bottomButton("마지막 스냅샷", 110, raw, function() self:Run("last") end)
    ui.clickMode = bottomButton("", 190, last, function()
        self:ToggleLeftClickAction()
        self:RefreshSettingsUI()
    end)
    ui.export, ui.refresh, ui.raw, ui.last = export, refresh, raw, last
end

local function buildResultArea(self, frame, ui)
    local scroll
    local ok, created = pcall(CreateFrame, "ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    if ok and created then
        scroll = created
    else
        scroll = CreateFrame("ScrollFrame", nil, frame)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(source, delta)
            local range = source:GetVerticalScrollRange() or 0
            local target = (source:GetVerticalScroll() or 0) - delta * 40
            source:SetVerticalScroll(math.max(0, math.min(range, target)))
        end)
    end
    scroll:SetPoint("TOPLEFT", EDIT_X, -TOP)
    scroll:SetPoint("BOTTOMRIGHT", -36, 52)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetWidth(WINDOW.width - EDIT_X - 52)
    edit:SetFontObject("ChatFontNormal")
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(0)
    edit:SetScript("OnEscapePressed", function() frame:Hide() end)
    scroll:SetScrollChild(edit)
    ui.scroll, ui.edit = scroll, edit
    frame.edit = edit

    ui.title = makeLabel(frame, "GameFontNormalSmall", TITLES.report)
    ui.title:SetPoint("TOPLEFT", EDIT_X, -TOP + 16)
    ui.updated = makeLabel(frame, "GameFontHighlightSmall", "")
    ui.updated:SetPoint("TOPLEFT", EDIT_X, -TOP + 30)

    ui.actions = makeLabel(frame, "GameFontHighlightSmall", "")
    ui.actions:SetPoint("TOPLEFT", 16, -TOP - 40 - #self.order * ROW_HEIGHT - 8)
    ui.actions:SetWidth(LEFT_WIDTH - 8)
    ui.actions:SetJustifyH("LEFT")
end

function Addon:BuildWindow()
    if self.window then return self.window end
    local frame = CreateFrame("Frame", "ForeverCharacterExportWindow", UIParent)
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(WINDOW.minWidth, WINDOW.minHeight, WINDOW.maxWidth, WINDOW.maxHeight)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(source) source:StartMoving() end)
    frame:SetScript("OnDragStop", function(source)
        source:StopMovingOrSizing()
        self:SaveWindow()
    end)
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0.04, 0.04, 0.04, 0.98)
    local ui = {}
    self.ui = ui
    self.window = frame
    applyGeometry(self, frame)

    local title = makeLabel(frame, "GameFontNormal", "포에버 캐릭터 내보내기 " .. self.version)
    title:SetPoint("TOPLEFT", 16, -14)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() frame:Hide() end)

    buildRows(self, frame, ui)
    buildResultArea(self, frame, ui)
    buildBottom(self, frame, ui)

    local grip = makeButton(frame, "크기", 40, 20)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        self:SaveWindow()
        self:ResizeResult()
    end)
    frame:SetScript("OnSizeChanged", function() self:ResizeResult() end)
    self:ResizeResult()
    self:RefreshSettingsUI()
    return frame
end

function Addon:ResizeResult()
    local frame, ui = self.window, self.ui
    if not frame or not ui or not ui.edit then return end
    ui.edit:SetWidth(math.max(120, frame:GetWidth() - EDIT_X - 56))
end

-- ---------------------------------------------------------------------------------------------------------------
-- Refreshing what the window shows

function Addon:RefreshSettingsUI()
    local ui = self.ui
    if not ui or not ui.rows then return end
    local summary = {}
    for _, entry in ipairs(self:SectionSummary(self.lastReport)) do summary[entry.name] = entry end
    for _, name in ipairs(self.order) do
        local row = ui.rows[name]
        row.toggle.Set(self:IsSectionEnabled(name))
        local entry = summary[name]
        if not self.lastReport then
            row.status:SetText("-")
            setColor(row.status, COLORS.none)
        elseif entry.level == "off" then
            row.status:SetText("꺼짐")
            setColor(row.status, COLORS.off)
        elseif not self:IsSectionEnabled(name) then
            -- switched off after the last export: the status below would describe an older read
            row.status:SetText("꺼짐 (다음 내보내기부터)")
            setColor(row.status, COLORS.off)
        else
            row.status:SetText(entry.text)
            setColor(row.status, COLORS[entry.level] or COLORS.none)
        end
        if row.detail then
            if name == "professions" then
                local _, detail = self:ProfessionSettings()
                row.detail:SetText(detail == "reagents" and "재료" or "요약")
            else
                row.detail:SetText(detailText(self, name))
            end
        end
        if row.count then
            row.count:SetText((self:ProfessionSettings()) .. "개")
        end
    end
    if ui.clickMode then
        ui.clickMode:SetText("미니맵 좌클릭: " .. (self:LeftClickAction() == "export" and "바로 내보내기" or "창 열기"))
    end
    local actions
    if not self.lastReport then
        actions = "필요한 행동: 아직 내보내지 않았습니다. [내보내기]를 누르면 상태와 필요한 행동이 여기에 표시됩니다."
    else
        local list = self:NeedsAction(self.lastReport)
        if #list == 0 then
            actions = "필요한 행동: 없음 (지금 수집한 범위에서)"
        else
            actions = "필요한 행동:"
            for _, line in ipairs(list) do actions = actions .. "\n- " .. line end
        end
    end
    ui.actions:SetText(actions)
end

function Addon:ShowWindow()
    local frame = self:BuildWindow()
    frame:Show()
    self:RefreshSettingsUI()
    return frame
end

function Addon:ToggleWindow()
    if self.window and self.window:IsShown() then
        self.window:Hide()
    else
        self:ShowWindow()
    end
end

-- Shows text in the result area. select = true also focuses the box and selects everything for Ctrl+C; that
-- is only done after an export, so opening the settings never steals the keyboard.
function Addon:ShowText(text, kind, select)
    local frame = self:ShowWindow()
    local ui = self.ui
    ui.title:SetText(TITLES[kind or "report"] or TITLES.report)
    frame.edit:SetText(text)
    frame.edit:SetCursorPosition(0)
    if select then
        frame.edit:SetFocus()
        frame.edit:HighlightText()
    end
end

local function enabledCount(self)
    local on = 0
    for _, name in ipairs(self.order) do
        if self:IsSectionEnabled(name) then on = on + 1 end
    end
    return on
end

-- One click: collect, build the readable text, select it for Ctrl+C.
-- mode: "report" (default, readable), "diag" (raw Lua-style dump), "last" (previous session snapshot, stale).
function Addon:Run(mode)
    mode = mode or "report"
    if mode == "last" then
        if self.lastReport then
            self:ShowText(self:Report(self.lastReport, true), "last", true)
        else
            self:ShowText("<not_collected: 이번 접속에서 수집한 스냅샷이 없습니다. 먼저 [내보내기]를 누르세요>", "last")
        end
        self.lastMode = "report"
    else
        local report = self:Collect()
        self.lastMode = mode == "diag" and "diag" or "report"
        if mode == "diag" then
            self:ShowText(self:Export(report, false), "diag", true)
        else
            self:ShowText(self:Report(report, false), "report", true)
        end
    end
    if self.ui and self.ui.updated then
        local at = self:Val(self.lastReport and self.lastReport.startedAt)
        self.ui.updated:SetText("수집 시각: " .. (at and self:Date(at) or "알 수 없음") .. " | 켜진 구역 "
            .. enabledCount(self) .. "/" .. #self.order)
    end
    self:RefreshSettingsUI()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Minimap launcher. Left click: open the window or export at once (setting). Right click: open the window
-- (sections, detail levels). Drag: move around the minimap, saved per character.

local function placeButton(button)
    local db = Addon.db
    local angle = db and db.minimap and db.minimap.angle or 215
    local radius = Minimap:GetWidth() / 2 + 5
    local rad = math.rad(angle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * radius, math.sin(rad) * radius)
end

function Addon:LauncherClick(which)
    if which == "RightButton" then
        self:ShowWindow()
    elseif self:LeftClickAction() == "export" then
        self:Run("report")
    else
        self:ToggleWindow()
    end
end

function Addon:CreateLauncher()
    if self.launcher or type(Minimap) ~= "table" then return end
    local db = self.db
    if db and db.minimap and db.minimap.hide then return end
    local button = CreateFrame("Button", "ForeverCharacterExportLauncher", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\AddOns\\ForeverCharacterExport\\icon")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 0)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)
    button:SetScript("OnClick", function(_, which) Addon:LauncherClick(which) end)
    button:SetScript("OnDragStart", function(source)
        source:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            local angle = math.deg((math.atan2 or math.atan)(py / scale - my, px / scale - mx))
            if Addon.db and Addon.db.minimap then Addon.db.minimap.angle = angle end
            placeButton(source)
        end)
    end)
    button:SetScript("OnDragStop", function(source) source:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(source)
        GameTooltip:SetOwner(source, "ANCHOR_LEFT")
        GameTooltip:AddLine("포에버 캐릭터 내보내기")
        if Addon:LeftClickAction() == "export" then
            GameTooltip:AddLine("왼쪽 클릭: 바로 내보내기 (Ctrl+C로 복사)", 1, 1, 1)
        else
            GameTooltip:AddLine("왼쪽 클릭: 창 열기/닫기", 1, 1, 1)
        end
        GameTooltip:AddLine("오른쪽 클릭: 창 열기 (구역·상세 수준 설정)", 1, 1, 1)
        GameTooltip:AddLine("드래그: 버튼 위치 옮기기", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    placeButton(button)
    self.launcher = button
end

Addon:On("PLAYER_LOGIN", function(self) self:CreateLauncher() end)

-- ---------------------------------------------------------------------------------------------------------------
-- Slash command (kept as a helper; the window is the main way): /fce toggles the window.

local HELP = "/fce - 창 열기/닫기\n/fce export - 바로 내보내기 (창에 결과 표시)\n/fce diag - 원본(Raw) 진단\n"
    .. "/fce last - 이번 접속의 직전 스냅샷 (최신 아님)\n/fce button - 미니맵 버튼 표시/숨김\n/fce hide - 창 닫기"

function Addon:HandleSlash(message)
    local command = string.lower(string.match(message or "", "^%s*(%S*)") or "")
    if command == "" or command == "window" or command == "toggle" then
        self:ToggleWindow()
    elseif command == "hide" then
        if self.window then self.window:Hide() end
    elseif command == "button" then
        local db = self.db
        if db and db.minimap then
            db.minimap.hide = not db.minimap.hide
            if db.minimap.hide and self.launcher then
                self.launcher:Hide()
            elseif self.launcher then
                self.launcher:Show()
            else
                self:CreateLauncher()
            end
        end
    elseif command == "last" or command == "diag" then
        self:Run(command)
    elseif command == "export" or command == "all" then
        self:Run("report")
    else
        self:ShowText(HELP, "help")
    end
end

SLASH_FOREVERCHARACTEREXPORT1 = "/fce"
SLASH_FOREVERCHARACTEREXPORT2 = "/charexport"
SlashCmdList.FOREVERCHARACTEREXPORT = function(message) Addon:HandleSlash(message) end
