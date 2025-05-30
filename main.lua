--[[--
FastReader plugin for KOReader

@module koplugin.FastReader
--]]--

-- This is a debug plugin, remove the following if block to enable it
-- if true then
--     return { disabled = true, }
-- end

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local TextWidget = require("ui/widget/textwidget")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local logger = require("logger")
local _ = require("gettext")

local FastReader = WidgetContainer:extend{
    name = "fastreader",
    is_doc_only = true,
}

function FastReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("fastreader_action", {category="none", event="FastReader", title=_("Fast Reader"), general=true,})
end

function FastReader:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    
    -- Initialize progress display state
    self.progress_widget = nil
    self.enabled = false
    
    -- Register for document events to setup callbacks when document is ready
    self.ui:registerPostReaderReadyCallback(function()
        self:setupProgressDisplay()
    end)
end

function FastReader:setupProgressDisplay()
    -- Don't auto-enable, let user activate manually
end

function FastReader:updateProgressDisplay()
    if not self.enabled or not self.ui.document then
        return
    end
    
    local total_pages = 0
    local current_page = 0
    local progress_percent = 0

    if self.ui.paging then
        total_pages = self.ui.document:getPageCount()
        current_page = self.ui.paging.current_page
        progress_percent = current_page / total_pages * 100
    elseif self.ui.rolling then
        total_pages = self.ui.document:getPageCount()
        current_page = self.ui.document:getCurrentPage()
        progress_percent = current_page / total_pages * 100
    else
        return
    end
    
    if current_page > 0 and total_pages > 0 then
        local progress_text = string.format("%d / %d (%.1f%%)", current_page, total_pages, progress_percent)
        
        -- Use a simple InfoMessage that doesn't stay on screen
        UIManager:show(InfoMessage:new{
            text = progress_text,
            timeout = 1.5,  -- show for 1.5 seconds then auto-hide
        })
    end
end

function FastReader:toggleProgressDisplay()
    self.enabled = not self.enabled
    
    if not self.enabled then
        UIManager:show(InfoMessage:new{
            text = _("FastReader progress display disabled"),
        })
    else
        if self.ui.document then
            self:updateProgressDisplay()
            UIManager:show(InfoMessage:new{
                text = _("FastReader progress display enabled"),
            })
        end
    end
end

function FastReader:addToMainMenu(menu_items)
    menu_items.fastreader = {
        text = _("FastReader"),
        sorting_hint = "more_tools",
        callback = function()
            self:toggleProgressDisplay()
        end,
    }
end

function FastReader:onFastReaderAction()
    self:toggleProgressDisplay()
end

-- Event handlers for page/position updates
function FastReader:onPageUpdate(pageno)
    if self.enabled and self.ui.document and pageno then
        self:updateProgressDisplay()
    end
end

function FastReader:onPosUpdate(pos, pageno)
    if self.enabled and self.ui.document and pageno then
        self:updateProgressDisplay()
    end
end

return FastReader
