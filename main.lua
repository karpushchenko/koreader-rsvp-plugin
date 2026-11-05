-- FastReader plugin entry point and KOReader event integration.
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- Load namespaced modules eagerly: PluginLoader restores package.path after
-- loading main.lua. Keep event bindings here for its handler sandbox as well.
local Reader = require("fastreader/reader")
local Text = require("fastreader/text")
local Settings = require("fastreader/settings")
local Menu = require("fastreader/menu")
local Position = require("fastreader/position")

local FastReader = WidgetContainer:extend{
    name = "fastreader",
    is_doc_only = true,
    saveSettings = Settings.saveSettings,
    extractWordsFromCurrentPage = Text.extractWordsFromCurrentPage,
    addToMainMenu = Menu.addToMainMenu,
    showPositionIndicator = Position.showPositionIndicator,
    hidePositionIndicator = Position.hidePositionIndicator,
    enableContinuousView = Reader.enableContinuousView,
    restoreOriginalView = Reader.restoreOriginalView,
    showRSVPWord = Reader.showRSVPWord,
    onSetDimensions = Reader.onSetDimensions,
    onScreenResize = Reader.onScreenResize,
    startRSVP = Reader.startRSVP,
    stopRSVP = Reader.stopRSVP,
    rsvpTick = Reader.rsvpTick,
    goToNextPageAndContinueRSVP = Reader.goToNextPageAndContinueRSVP,
    continueRSVPWithNewPage = Reader.continueRSVPWithNewPage,
    toggleRSVP = Reader.toggleRSVP,
    getCurrentPageHash = Reader.getCurrentPageHash,
    shouldResumeFromLastPosition = Reader.shouldResumeFromLastPosition,
    updateLastReadPosition = Reader.updateLastReadPosition,
}

function FastReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("fastreader_action", {category="none", event="FastReader", title=_("Fast Reader"), general=true,})
    Dispatcher:registerAction("fastreader_rsvp", {category="none", event="FastReaderRSVP", title=_("RSVP Reading"), general=true,})
end

function FastReader:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    Settings.load(self)

    self.rsvp_enabled = false
    self.rsvp_timer = nil
    self.pending_resume_task = nil
    self.rsvp_widget = nil
    self.current_word_index = 1
    self.words = {}
    self.original_view_mode = nil
    self.last_page_hash = nil
    self.last_word_index = 1

    self.ui:registerPostReaderReadyCallback(function()
        self:setupTapHandler()
    end)
end

function FastReader:onFastReaderRSVP()
    self:toggleRSVP()
end

-- Key event handlers for RSVP control

function FastReader:onKeyPress(key)
    if not self.rsvp_enabled then
        return false
    end

    if type(key) == "table" then
        key = key.key
    end

    if key == "Menu" or key == "Back" then
        self:stopRSVP()
        return true
    elseif key == "Press" or key == "LPgFwd" then
        -- Pause/resume RSVP
        if self.rsvp_timer then
            UIManager:unschedule(self.rsvp_timer)
            self.rsvp_timer = nil
            UIManager:show(InfoMessage:new{
                text = _("RSVP paused"),
                timeout = 1,
            })
        else
            local interval = 60000 / self.rsvp_speed
            self.rsvp_timer = function()
                self.rsvp_timer = nil
                self:rsvpTick()
            end
            UIManager:scheduleIn(interval / 1000, self.rsvp_timer)
            UIManager:show(InfoMessage:new{
                text = _("RSVP resumed"),
                timeout = 1,
            })
        end
        return true
    elseif key == "LPgBack" then
        -- Go to previous word
        if self.current_word_index > 1 then
            self.current_word_index = self.current_word_index - 1
            self:showRSVPWord(self.words[self.current_word_index])
        end
        return true
    end

    return false
end

function FastReader:onCloseDocument()
    -- Clean up when document is closed
    self:stopRSVP()
    self.enabled = false
end

function FastReader:onExit()
    -- Clean up when exiting
    self:stopRSVP()
end

function FastReader:setupTapHandler()
    -- Always register the tap handler, but check settings in the handler itself
    self.ui:registerTouchZones({
        {
            id = "fastreader_tap_to_launch",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,  -- Full screen
            },
            overrides = {
                -- Override specific tap handlers to intercept taps on text
                "readerhighlight_tap",
                "tap_top_left_corner",
                "tap_top_right_corner",
                "tap_left_bottom_corner",
                "tap_right_bottom_corner",
                "tap_forward",
                "tap_backward",
            },
            handler = function(ges)
                return self:onTapToLaunchRSVP(ges)
            end,
        },
    })

    logger.info("FastReader: Tap handler registered for RSVP launch")
end

function FastReader:onTapToLaunchRSVP(ges)
    -- Only handle if tap-to-launch is enabled and RSVP is not already running
    if not self.tap_to_launch_enabled or self.rsvp_enabled then
        return false -- Let other handlers process this
    end

    -- Check if we tapped on text area (similar to dictionary mode)
    if self:isTapOnTextArea(ges) then
        logger.info("FastReader: Tap on text area detected, launching RSVP")
        self:startRSVP()
        return true -- Consumed the tap, prevent other handlers
    end

    return false -- Let other handlers process this tap
end

function FastReader:isTapOnTextArea(ges)
    -- More sophisticated check based on DictionaryMode approach
    local Screen = require("device").screen
    local x, y = ges.pos.x, ges.pos.y

    -- Exclude UI areas (similar margins as used in KOReader)
    local ui_margin = Screen:scaleBySize(30)
    local footer_height = self.ui.view.footer_visible and self.ui.view.footer:getHeight() or 0

    -- Check if tap is in main reading area
    if x > ui_margin and x < (Screen:getWidth() - ui_margin) and
       y > ui_margin and y < (Screen:getHeight() - footer_height - ui_margin) then

        -- Additional check: try to get text at tap position to confirm it's over text
        if self.ui.document and self.ui.view then
            local pos = self.ui.view:screenToPageTransform(ges.pos)
            if pos then
                local text_result = self.ui.document:getTextFromPositions(pos, pos)
                if text_result and text_result.text and text_result.text:match("%S") then
                    -- We have non-whitespace text at this position
                    return true
                end
            end
        end
    end

    return false
end

return FastReader
