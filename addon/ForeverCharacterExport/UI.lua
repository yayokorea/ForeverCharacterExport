local _, Addon = ...
-- luacheck: read globals Minimap GameTooltip GetCursorPosition
-- luacheck: globals SLASH_FOREVERCHARACTEREXPORT1 SLASH_FOREVERCHARACTEREXPORT2

local TITLES = {
    report = "ForeverCharacterExport - Ctrl+C to copy, then paste to your assistant",
    diag = "ForeverCharacterExport - raw diagnostic / Ctrl+C",
}

function Addon:ShowText(text, kind)
    if not self.window then
        local frame = CreateFrame("Frame", "ForeverCharacterExportWindow", UIParent)
        frame:SetSize(760, 540)
        frame:SetPoint("CENTER")
        frame:SetFrameStrata("DIALOG")
        frame:EnableMouse(true)
        local background = frame:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints()
        background:SetColorTexture(0.04, 0.04, 0.04, 0.98)
        local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 16, -16)
        frame.title = title
        local function button(label, width, anchorTo, onClick)
            local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            b:SetSize(width, 24)
            b:SetText(label)
            b:SetScript("OnClick", onClick)
            if anchorTo then
                b:SetPoint("RIGHT", anchorTo, "LEFT", -4, 0)
            else
                b:SetPoint("TOPRIGHT", -12, -10)
            end
            return b
        end
        local close = button("Close", 60, nil, function() frame:Hide() end)
        local raw = button("Raw", 50, close, function() Addon:Run("diag") end)
        button("Refresh", 64, raw, function() Addon:Run("report") end)
        local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 16, -48)
        scroll:SetPoint("BOTTOMRIGHT", -36, 16)
        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetWidth(700)
        edit:SetFontObject("ChatFontNormal")
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetMaxLetters(0)
        edit:SetScript("OnEscapePressed", function() frame:Hide() end)
        scroll:SetScrollChild(edit)
        frame.edit = edit
        self.window = frame
    end
    self.window.title:SetText(TITLES[kind or "report"] or TITLES.report)
    self.window:Show()
    self.window.edit:SetText(text)
    self.window.edit:SetCursorPosition(0)
    self.window.edit:SetFocus()
    self.window.edit:HighlightText()
end

-- One click: collect everything, build the readable text, select it for Ctrl+C.
-- mode: "report" (default, readable), "diag" (raw Lua-style dump), "last" (previous session snapshot, stale),
-- "force" (readable report even when the build is not the verified target).
function Addon:Run(mode)
    mode = mode or "report"
    if mode == "last" then
        if self.lastReport then
            self:ShowText(self:Report(self.lastReport, true), "report")
        else
            self:ShowText("<not_collected: no session snapshot; run /fce first>", "report")
        end
    elseif mode == "diag" then
        self:ShowText(self:Export(self:Collect(), false), "diag")
    else
        self:ShowText(self:Report(self:Collect({ force = mode == "force" }), false), "report")
    end
end

-- Draggable minimap launcher. Left click: full export. Right click: raw diagnostic. Position is saved per character.
local function placeButton(button)
    local db = Addon.db
    local angle = db and db.minimap and db.minimap.angle or 215
    local radius = Minimap:GetWidth() / 2 + 5
    local rad = math.rad(angle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * radius, math.sin(rad) * radius)
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
    button:SetScript("OnClick", function(_, which)
        Addon:Run(which == "RightButton" and "diag" or "report")
    end)
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
        GameTooltip:AddLine("ForeverCharacterExport")
        GameTooltip:AddLine("Left click: export everything (Ctrl+C)", 1, 1, 1)
        GameTooltip:AddLine("Right click: raw diagnostic", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    placeButton(button)
    self.launcher = button
end

Addon:On("PLAYER_LOGIN", function(self) self:CreateLauncher() end)

SLASH_FOREVERCHARACTEREXPORT1 = "/fce"
SLASH_FOREVERCHARACTEREXPORT2 = "/charexport"
SlashCmdList.FOREVERCHARACTEREXPORT = function(message)
    local command = string.lower(string.match(message, "^%s*(%S*)") or "")
    if command == "hide" then
        if Addon.window then Addon.window:Hide() end
    elseif command == "button" then
        local db = Addon.db
        if db and db.minimap then
            db.minimap.hide = not db.minimap.hide
            if db.minimap.hide and Addon.launcher then
                Addon.launcher:Hide()
            elseif Addon.launcher then
                Addon.launcher:Show()
            else
                Addon:CreateLauncher()
            end
        end
    elseif command == "last" or command == "diag" or command == "force" then
        Addon:Run(command)
    elseif command == "" or command == "export" or command == "all" then
        Addon:Run("report")
    else
        Addon:ShowText("/fce - export everything (readable)\n/fce diag - raw diagnostic dump\n"
            .. "/fce last - previous snapshot of this session (stale)\n"
            .. "/fce force - export even if the build is not 1.60.1/70790\n"
            .. "/fce button - show/hide the minimap button\n/fce hide - close", "report")
    end
end
