-- Build Ahead: ban/unban toggles for material types in the build window.
-- The ban list itself (BuildAhead.getBans, per player ModData) has no window;
-- these toggles are the only way to see and change it:
--   - each input of the recipe (ISWidgetInput): a small "X" button at the top
--     left of the icon box toggles the item type the box shows right now
--     (the icon cycles through the alternatives); a banned type is drawn dimmed
--     and red with a red border
--   - the item list for manual input selection (ISCraftInventoryPanel): an
--     "X" box at the right of every item type row; banned rows are tinted red
-- Only in the build window (BuildLogic), not in other crafting windows.

require "BuildAhead"

BuildAheadBanUI = BuildAheadBanUI or {}

local COLOR_BAN = { r = 0.9, g = 0.15, b = 0.15 }

local function isBuildLogic(logic)
    local ok, yes = pcall(function() return logic ~= nil and instanceof(logic, "BuildLogic") end)
    return ok and yes
end

local function scriptFullType(script)
    if not script then return nil end
    local ok, name = pcall(function() return script:getFullName() end)
    if ok and name then return name end
    ok, name = pcall(function() return script:getScriptObjectFullType() end)
    return ok and name or nil
end

local function displayName(fullType)
    local item = fullType and getScriptManager():getItem(fullType)
    return item and item:getDisplayName() or tostring(fullType)
end

-- ---------------------------------------------------------------- recipe inputs

-- the item type the input box shows now
function BuildAheadBanUI.widgetFullType(widget)
    return widget.primary and widget.primary.inputFullName
end

function BuildAheadBanUI.onWidgetBanClicked(widget)
    local fullType = BuildAheadBanUI.widgetFullType(widget)
    if not fullType then return end
    BuildAhead.toggleBan(widget.player, fullType)
    widget:updateValues()
end

local function hookWidgetInput()
    local origCreate = ISWidgetInput.createChildren
    function ISWidgetInput:createChildren(...)
        origCreate(self, ...)
        if not isBuildLogic(self.logic) or self.displayAsOutput
            or self.inputScript:getResourceType() ~= ResourceType.Item then return end
        local size = self.labelIconSize
        local b = ISButton:new(0, 0, size, size, "X", self, BuildAheadBanUI.onWidgetBanClicked)
        b.font = UIFont.Small
        b.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 0.8 }
        b:initialise()
        b:instantiate()
        self:addChild(b)
        self.buildAheadBanButton = b
    end

    -- a click on the ban button must not also open the manual input selection
    local origDownOutside = ISWidgetInput.onMouseDownOutside
    function ISWidgetInput:onMouseDownOutside(...)
        if self.buildAheadBanButton and self.buildAheadBanButton:isMouseOver() then return end
        return origDownOutside(self, ...)
    end
    local origDown = ISWidgetInput.onMouseDown
    function ISWidgetInput:onMouseDown(...)
        if self.buildAheadBanButton and self.buildAheadBanButton:isMouseOver() then return end
        return origDown(self, ...)
    end

    local origLayout = ISWidgetInput.calculateLayout
    function ISWidgetInput:calculateLayout(...)
        origLayout(self, ...)
        if self.buildAheadBanButton then
            self.buildAheadBanButton:setX(2)
            self.buildAheadBanButton:setY(2)
        end
    end

    local origUpdate = ISWidgetInput.updateValues
    function ISWidgetInput:updateValues(...)
        origUpdate(self, ...)
        local b = self.buildAheadBanButton
        if not b then return end
        local fullType = BuildAheadBanUI.widgetFullType(self)
        local banned = BuildAhead.isBanned(self.player, fullType)
        self.buildAheadBanned = banned
        local icon = self.primary.icon
        local bg = icon.backgroundColor
        if banned then
            if not self.buildAheadTint then self.buildAheadTint = { r = bg.r, g = bg.g, b = bg.b } end
            bg.a, bg.r, bg.g, bg.b = 0.35, 1, 0.4, 0.4
            self.borderColor = COLOR_BAN
            b.backgroundColor = { r = COLOR_BAN.r, g = COLOR_BAN.g, b = COLOR_BAN.b, a = 0.9 }
            b.textColor = { r = 1, g = 1, b = 1, a = 1 }
            b.mouseovertext = getText("IGUI_BuildAhead_Unban", displayName(fullType))
        else
            local t = self.buildAheadTint
            if t then bg.r, bg.g, bg.b = t.r, t.g, t.b; self.buildAheadTint = nil end
            b.backgroundColor = { r = 0.15, g = 0.15, b = 0.15, a = 0.7 }
            b.textColor = { r = 0.7, g = 0.7, b = 0.7, a = 1 }
            b.mouseovertext = getText("IGUI_BuildAhead_Ban", displayName(fullType))
        end
    end
end

-- ---------------------------------------------------------------- manual selection list

-- the item type of a list row (type rows and single item rows), nil for headers
local function rowFullType(data)
    if not data or data.isHeader or data.fluid then return nil end
    return scriptFullType(data.script)
end
BuildAheadBanUI.rowFullType = rowFullType

local function toggleBox(box)
    local width = box.width
    if box:isVScrollBarVisible() then width = width - box.vscroll:getWidth() end
    local s = box.itemheight - 6
    return width - s - 4, s
end

function BuildAheadBanUI.toggleListRow(panel, row)
    local entry = panel.itemListBox.items[row]
    local fullType = entry and rowFullType(entry.item)
    if not fullType then return false end
    BuildAhead.toggleBan(panel.player, fullType)
    return true
end

local function hookInventoryPanel()
    local origDraw = ISCraftInventoryPanel.drawListItem
    function ISCraftInventoryPanel.drawListItem(box, y, item, alt)
        local nextY = origDraw(box, y, item, alt)
        local panel = box.target
        local fullType = panel and panel.buildAheadBans and rowFullType(item.item)
        if fullType then
            local banned = BuildAhead.isBanned(panel.player, fullType)
            local bx, s = toggleBox(box)
            if banned then
                box:drawRect(2, y, bx - 4, box.itemheight - 1, 0.3, COLOR_BAN.r, COLOR_BAN.g, COLOR_BAN.b)
                box:drawRect(bx, y + 3, s, s, 0.9, COLOR_BAN.r, COLOR_BAN.g, COLOR_BAN.b)
            else
                box:drawRect(bx, y + 3, s, s, 0.6, 0.15, 0.15, 0.15)
            end
            box:drawRectBorder(bx, y + 3, s, s, 0.8, 0.6, 0.6, 0.6)
            local tw = getTextManager():MeasureStringX(UIFont.Small, "X")
            local th = getTextManager():getFontHeight(UIFont.Small)
            local c = banned and 1 or 0.7
            box:drawText("X", bx + (s - tw) / 2, y + 3 + (s - th) / 2, c, c, c, 1, UIFont.Small)
        end
        return nextY
    end

    local origCreate = ISCraftInventoryPanel.createChildren
    function ISCraftInventoryPanel:createChildren(...)
        origCreate(self, ...)
        if not isBuildLogic(self.logic) then return end
        self.buildAheadBans = true
        local panel = self
        local box = self.itemListBox
        local origDown = box.onMouseDown
        box.onMouseDown = function(b, x, y)
            local bx = toggleBox(b)
            if x >= bx then
                local row = b:rowAt(x, y)
                if row >= 1 and BuildAheadBanUI.toggleListRow(panel, row) then
                    getSoundManager():playUISound("UIActivateButton")
                    return true
                end
            end
            return origDown(b, x, y)
        end
    end
end

local function install()
    if BuildAheadBanUI.hooked or not ISWidgetInput or not ISCraftInventoryPanel then return end
    BuildAheadBanUI.hooked = true
    hookWidgetInput()
    hookInventoryPanel()
end

Events.OnGameStart.Add(install)
