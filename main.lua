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
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local logger = require("logger")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local _ = require("gettext")
local T = require("ffi/util").template

local FastReader = WidgetContainer:extend{
    name = "fastreader",
    is_doc_only = true,
}

function FastReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("fastreader_action", {category="none", event="FastReader", title=_("Fast Reader"), general=true,})
    Dispatcher:registerAction("fastreader_rsvp", {category="none", event="FastReaderRSVP", title=_("RSVP Reading"), general=true,})
end

function FastReader:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    
    -- Load settings
    self.settings_file = DataStorage:getSettingsDir() .. "/fastreader.lua"
    self.settings = LuaSettings:open(self.settings_file)
    
    -- RSVP state
    self.rsvp_enabled = false
    self.rsvp_timer = nil
    
    -- Tap-to-launch RSVP settings
    self.tap_to_launch_enabled = self.settings:readSetting("tap_to_launch_enabled") or false
    self.rsvp_speed = self.settings:readSetting("rsvp_speed") or 250  -- words per minute
    self.current_word_index = 1
    self.words = {}
    self.original_view_mode = nil
    
    -- Position tracking for resume functionality
    self.last_page_hash = nil -- Hash to identify current page content
    self.last_word_index = 1  -- Last read word index on this page
    self.show_position_indicator = self.settings:readSetting("show_position_indicator") or true
    
    -- Register for document events to setup callbacks when document is ready
    self.ui:registerPostReaderReadyCallback(function()
        self:setupTapHandler()
    end)
end

function FastReader:saveSettings()
    if self.settings then
        self.settings:saveSetting("rsvp_speed", self.rsvp_speed)
        self.settings:saveSetting("tap_to_launch_enabled", self.tap_to_launch_enabled)
        self.settings:saveSetting("show_position_indicator", self.show_position_indicator)
        self.settings:flush()
    end
end

function FastReader:enableContinuousView()
    -- Save original view mode
    if self.ui.rolling then
        -- Already in continuous mode for reflowable documents
        logger.info("FastReader: Document already in rolling mode")
        return true
    elseif self.ui.paging then
        -- For paged documents, save original mode
        self.original_view_mode = "paging"
        logger.info("FastReader: Document in paging mode, will use page-by-page navigation")
        
        -- Try to enable scroll mode if document supports it
        if self.ui.document.provider == "crengine" then
            -- This is a reflowable document in paging mode, could switch to scroll
            logger.info("FastReader: Could potentially switch to scroll mode for crengine document")
        elseif self.ui.document.provider == "mupdf" then
            -- PDF document - can't really switch to continuous, but we'll handle page navigation
            logger.info("FastReader: PDF document - will use page-by-page navigation")
        end
        
        return true
    end
    logger.warn("FastReader: Unknown document type")
    return false
end

function FastReader:restoreOriginalView()
    if self.original_view_mode and self.original_view_mode == "paging" then
        -- Restore paging mode if it was originally used
        -- Implementation would depend on KOReader's internal APIs
        self.original_view_mode = nil
    end
end

function FastReader:extractWordsFromCurrentPage()
    if not self.ui.document then
        logger.warn("FastReader: No document available")
        return {}
    end
    
    local text = ""
    local debug_info = {}
    
    logger.info("FastReader: Starting text extraction")
    logger.info("FastReader: Document type: " .. tostring(self.ui.document.provider))
    
    if self.ui.rolling then
        -- For reflowable documents (EPUB, FB2, etc.)
        -- Use the same method as readerview.lua getCurrentPageLineWordCounts()
        logger.info("FastReader: Rolling document - using getTextFromPositions")
        
        local success, text_result = pcall(function()
            local Screen = require("device").screen
            local res = self.ui.document:getTextFromPositions(
                {x = 0, y = 0},
                {x = Screen:getWidth(), y = Screen:getHeight()}, 
                true -- do not highlight
            )
            
            if res and res.text then
                logger.info("FastReader: getTextFromPositions success: " .. string.len(res.text) .. " characters")
                return res.text
            else
                logger.warn("FastReader: getTextFromPositions returned empty result")
                return nil
            end
        end)
        
        if success and text_result and text_result ~= "" then
            text = text_result
            table.insert(debug_info, "SUCCESS: getTextFromPositions returned " .. string.len(text_result) .. " chars")
            logger.info("FastReader: Text extraction success: " .. string.len(text_result) .. " characters")
        else
            table.insert(debug_info, "FAILED: getTextFromPositions - " .. tostring(text_result))
            logger.warn("FastReader: getTextFromPositions failed: " .. tostring(text_result))
            
            -- Fallback: try to get text from XPointers
            local fallback_success, fallback_text = pcall(function()
                -- For rolling documents, try XPointer method
                if self.ui.rolling and self.ui.document.getTextFromXPointers then
                    local current_xpointer = self.ui.rolling:getBookLocation()
                    if current_xpointer then
                        local text_result = self.ui.document:getTextFromXPointers(current_xpointer, current_xpointer, true)
                        if text_result and text_result.text and text_result.text ~= "" then
                            return text_result.text
                        end
                    end
                end
                return nil
            end)
            
            if fallback_success and fallback_text and fallback_text ~= "" then
                text = fallback_text
                table.insert(debug_info, "SUCCESS: XPointer fallback returned " .. string.len(fallback_text) .. " chars")
                logger.info("FastReader: XPointer fallback success: " .. string.len(fallback_text) .. " characters")
            else
                table.insert(debug_info, "FAILED: XPointer fallback - " .. tostring(fallback_text))
                logger.warn("FastReader: XPointer fallback failed: " .. tostring(fallback_text))
            end
        end
        
    elseif self.ui.paging then
        -- For paged documents (PDF, DjVu, etc.)
        local page = self.ui.paging.current_page
        table.insert(debug_info, "Document type: paging (PDF/DjVu/etc), page: " .. tostring(page))
        logger.info("FastReader: Paging document, page: " .. tostring(page))
        
        if page and self.ui.document.getPageText then
            local success, page_text = pcall(self.ui.document.getPageText, self.ui.document, page)
            if success and page_text and page_text ~= "" then
                text = page_text
                table.insert(debug_info, "SUCCESS: getPageText returned " .. string.len(page_text) .. " chars")
                logger.info("FastReader: Successfully extracted " .. string.len(page_text) .. " characters")
            else
                table.insert(debug_info, "FAILED: getPageText - " .. tostring(page_text))
                logger.warn("FastReader: getPageText failed: " .. tostring(page_text))
            end
        end
    else
        table.insert(debug_info, "ERROR: Unknown document type - neither rolling nor paging")
        logger.warn("FastReader: Unknown document type")
    end
    
    logger.info("FastReader: Final text extraction result: " .. (text and string.len(text) or 0) .. " characters")
    
    -- Show debug info if no text was found
    if not text or text == "" then
        logger.warn("FastReader: Text extraction completely failed")
        logger.info("FastReader: Debug info: " .. table.concat(debug_info, " | "))
        
        UIManager:show(InfoMessage:new{
            text = _("Cannot extract text from this document type"),
            timeout = 3,
        })
        
        return {}
    end
    
    -- Split text into words, removing punctuation and extra spaces
    local words = {}
    for word in text:gmatch("%S+") do
        -- Clean up word (remove some punctuation but keep basic structure)
        word = word:gsub("^[%p]*", ""):gsub("[%p]*$", "")
        if word and word ~= "" then
            table.insert(words, word)
        end
    end
    
    logger.info("FastReader: Successfully extracted " .. #words .. " words")
    return words
end

function FastReader:showRSVPWord(word)
    if not word or word == "" then
        return
    end
    
    -- Create a centered overlay for the RSVP word
    local Screen = require("device").screen
    local word_widget = TextWidget:new{
        text = word,
        face = Font:getFace("cfont", 32),
        bold = true,
    }
    
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 2,
        padding = 10,
        word_widget,
    }
    
    local container = CenterContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        },
        frame,
    }
    
    -- Add tap/touch handlers to stop RSVP
    container.onTapClose = function()
        self:stopRSVP()
        return true
    end
    
    container.onTap = function()
        self:stopRSVP()
        return true
    end
    
    container.onGesture = function()
        self:stopRSVP()
        return true
    end
    
    frame.onTap = function()
        self:stopRSVP()
        return true
    end
    
    -- Remove previous RSVP widget if exists
    if self.rsvp_widget then
        UIManager:close(self.rsvp_widget)
    end
    
    self.rsvp_widget = container
    UIManager:show(self.rsvp_widget)
end

function FastReader:startRSVP()
    if self.rsvp_enabled then
        logger.info("FastReader: RSVP already enabled, ignoring start request")
        return
    end
    
    logger.info("FastReader: Starting RSVP mode")
    
    -- Enable continuous view mode
    self:enableContinuousView()
    
    -- Extract words from current page
    self.words = self:extractWordsFromCurrentPage()
    
    logger.info("FastReader: Extracted " .. #self.words .. " words from current page")
    
    if #self.words == 0 then
        -- Show error message and abort
        UIManager:show(InfoMessage:new{
            text = _("Cannot extract text from this document. Check logs for details."),
            timeout = 5,
        })
        logger.warn("FastReader: Cannot start RSVP - no words extracted")
        return
    end
    
    self.rsvp_enabled = true
    
    -- Check if we can resume from last position on this page
    if self:shouldResumeFromLastPosition() then
        self.current_word_index = self.last_word_index
        logger.info("FastReader: Resuming from word " .. self.current_word_index .. " of " .. #self.words)
        
        -- Show position indicator if enabled
        if self.show_position_indicator then
            self:showPositionIndicator()
        end
    else
        self.current_word_index = 1
        logger.info("FastReader: Starting from beginning")
    end
    
    -- Calculate interval in milliseconds
    local interval = 60000 / self.rsvp_speed  -- Convert WPM to milliseconds per word
    logger.info("FastReader: RSVP interval set to " .. interval .. "ms for " .. self.rsvp_speed .. " WPM")
    
    -- Start RSVP timer
    self.rsvp_timer = UIManager:scheduleIn(interval / 1000, function()
        self:rsvpTick()
    end)
    
    -- Show first word
    self:showRSVPWord(self.words[self.current_word_index])
    
    logger.info("FastReader: RSVP started successfully")
end

function FastReader:stopRSVP()
    if not self.rsvp_enabled then
        return
    end
    
    logger.info("FastReader: Stopping RSVP mode")
    
    -- Save current position before stopping
    if #self.words > 0 and self.current_word_index > 1 then
        self:updateLastReadPosition()
    end
    
    self.rsvp_enabled = false
    
    -- Stop timer
    if self.rsvp_timer then
        UIManager:unschedule(self.rsvp_timer)
        self.rsvp_timer = nil
    end
    
    -- Remove RSVP widget
    if self.rsvp_widget then
        UIManager:close(self.rsvp_widget)
        self.rsvp_widget = nil
    end
    
    -- Remove position indicator if shown
    self:hidePositionIndicator()
    
    -- Restore original view mode
    self:restoreOriginalView()
    
    UIManager:show(InfoMessage:new{
        text = _("RSVP stopped"),
    })
end

function FastReader:rsvpTick()
    if not self.rsvp_enabled or #self.words == 0 then
        return
    end
    
    self.current_word_index = self.current_word_index + 1
    
    if self.current_word_index <= #self.words then
        -- Show next word
        self:showRSVPWord(self.words[self.current_word_index])
        
        -- Schedule next tick
        local interval = 60000 / self.rsvp_speed
        self.rsvp_timer = UIManager:scheduleIn(interval / 1000, function()
            self:rsvpTick()
        end)
    else
        -- End of current page reached, try to go to next page
        logger.info("FastReader: End of current page, attempting to go to next page")
        self:goToNextPageAndContinueRSVP()
    end
end

function FastReader:goToNextPageAndContinueRSVP()
    -- Try to go to next page
    local success = false
    
    if self.ui.paging then
        -- For paged documents (PDF, DjVu, etc.)
        local current_page = self.ui.paging.current_page
        local total_pages = self.ui.document:getPageCount()
        
        if current_page < total_pages then
            self.ui.paging:onGotoPage(current_page + 1)
            success = true
            logger.info("FastReader: Moved to page " .. (current_page + 1))
        else
            logger.info("FastReader: Already at last page")
            self:stopRSVP()
            UIManager:show(InfoMessage:new{
                text = _("End of document reached"),
                timeout = 2,
            })
            return
        end
        
    elseif self.ui.rolling then
        -- For reflowable documents (EPUB, FB2, etc.)
        -- Try to scroll down by one screen
        local Event = require("ui/event")
        local ret = self.ui:handleEvent(Event:new("GotoViewRel", 1))
        if ret then
            success = true
            logger.info("FastReader: Scrolled to next screen in rolling mode")
        else
            logger.info("FastReader: Could not scroll further in rolling mode")
            self:stopRSVP()
            UIManager:show(InfoMessage:new{
                text = _("End of document reached"),
                timeout = 2,
            })
            return
        end
    else
        logger.warn("FastReader: Unknown document type")
        self:stopRSVP()
        return
    end
    
    if success then
        -- Small delay to let the page render, then extract words and continue
        UIManager:scheduleIn(0.1, function()
            self:continueRSVPWithNewPage()
        end)
    end
end

function FastReader:continueRSVPWithNewPage()
    -- Extract words from new page/position
    local new_words = self:extractWordsFromCurrentPage()
    
    if #new_words > 0 then
        self.words = new_words
        self.current_word_index = 1
        -- Reset position tracking for new page
        self.last_page_hash = nil
        self.last_word_index = 1
        logger.info("FastReader: Extracted " .. #new_words .. " words from new page")
        
        -- Continue with first word of new page
        self:showRSVPWord(self.words[self.current_word_index])
        
        -- Schedule next tick
        local interval = 60000 / self.rsvp_speed
        self.rsvp_timer = UIManager:scheduleIn(interval / 1000, function()
            self:rsvpTick()
        end)
    else
        logger.warn("FastReader: No words extracted from new page, trying next page")
        -- Try one more page if this one is empty
        self:goToNextPageAndContinueRSVP()
    end
end

function FastReader:toggleRSVP()
    if self.rsvp_enabled then
        self:stopRSVP()
    else
        self:startRSVP()
    end
end

function FastReader:addToMainMenu(menu_items)
    menu_items.fastreader = {
        text = _("FastReader"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Start/Stop RSVP"),
                callback = function()
                    self:toggleRSVP()
                end,
            },
            {
                text = _("Tap on Text to Launch RSVP"),
                checked_func = function()
                    return self.tap_to_launch_enabled
                end,
                callback = function()
                    self.tap_to_launch_enabled = not self.tap_to_launch_enabled
                    self:saveSettings()
                    
                    if self.tap_to_launch_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("Tap-to-launch RSVP enabled. Tap on text to start RSVP reading."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Tap-to-launch RSVP disabled"),
                            timeout = 2,
                        })
                    end
                end,
                help_text = _("When enabled, tapping on text will automatically start RSVP reading without going through the menu."),
            },
            {
                text = _("Show Reading Position"),
                checked_func = function()
                    return self.show_position_indicator
                end,
                callback = function()
                    self.show_position_indicator = not self.show_position_indicator
                    self:saveSettings()
                    
                    if self.show_position_indicator then
                        UIManager:show(InfoMessage:new{
                            text = _("Position indicator enabled. Shows reading progress when resuming."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Position indicator disabled"),
                            timeout = 2,
                        })
                    end
                end,
                help_text = _("When enabled, shows reading position indicator when resuming RSVP on the same page."),
            },
            {
                text = _("RSVP Speed"),
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("Current: %1 WPM"), self.rsvp_speed)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                title_text = _("RSVP Reading Speed"),
                                info_text = _("Words per minute (50-1000)"),
                                width = math.floor(Screen:getWidth() * 0.6),
                                value = self.rsvp_speed,
                                value_min = 50,
                                value_max = 1000,
                                value_step = 25,
                                value_hold_step = 100,
                                default_value = 250,
                                unit = "WPM",
                                callback = function(spin)
                                    self.rsvp_speed = spin.value
                                    self:saveSettings()
                                    touchmenu_instance:updateItems()
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("RSVP speed set to %1 WPM"), self.rsvp_speed),
                                        timeout = 1,
                                    })
                                end
                            }
                            UIManager:show(spin_widget)
                        end,
                        separator = true,
                    },
                    {
                        text = _("100 WPM (Very slow)"),
                        callback = function()
                            self.rsvp_speed = 100
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 100 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("150 WPM (Slow)"),
                        callback = function()
                            self.rsvp_speed = 150
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 150 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("200 WPM (Normal)"),
                        callback = function()
                            self.rsvp_speed = 200
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 200 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("250 WPM (Fast)"),
                        callback = function()
                            self.rsvp_speed = 250
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 250 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("300 WPM (Very fast)"),
                        callback = function()
                            self.rsvp_speed = 300
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 300 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("400 WPM (Extreme)"),
                        callback = function()
                            self.rsvp_speed = 400
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 400 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("500 WPM (Ultra fast)"),
                        callback = function()
                            self.rsvp_speed = 500
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 500 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                },
            },
        },
    }
end

function FastReader:onFastReaderRSVP()
    self:toggleRSVP()
end

-- Key event handlers for RSVP control
function FastReader:onKeyPress(key)
    if not self.rsvp_enabled then
        return false
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
            self.rsvp_timer = UIManager:scheduleIn(interval / 1000, function()
                self:rsvpTick()
            end)
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

function FastReader:getCurrentPageHash()
    -- Create a hash to identify current page content and position
    local hash_data = ""
    
    if self.ui.paging then
        -- For paged documents, use page number
        hash_data = "page_" .. tostring(self.ui.paging.current_page)
    elseif self.ui.rolling then
        -- For rolling documents, use xpointer or position
        local xpointer = self.ui.rolling:getBookLocation()
        hash_data = "rolling_" .. tostring(xpointer or "unknown")
    end
    
    -- Add document file path to make hash unique per document
    if self.ui.document and self.ui.document.file then
        hash_data = hash_data .. "_" .. self.ui.document.file
    end
    
    return hash_data
end

function FastReader:shouldResumeFromLastPosition()
    local current_hash = self:getCurrentPageHash()
    return self.last_page_hash == current_hash and self.last_word_index > 1
end

function FastReader:updateLastReadPosition()
    self.last_page_hash = self:getCurrentPageHash()
    self.last_word_index = self.current_word_index
    logger.info("FastReader: Updated last read position to word " .. self.last_word_index)
end

function FastReader:showPositionIndicator()
    if not self.show_position_indicator or self.current_word_index <= 1 then
        return
    end
    
    -- Hide any existing indicator first
    self:hidePositionIndicator()
    
    -- Create a small indicator showing reading progress
    local progress_text = string.format("📖 %d/%d", self.current_word_index, #self.words)
    local percentage = math.floor((self.current_word_index / #self.words) * 100)
    
    local indicator_widget = TextWidget:new{
        text = progress_text,
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_WHITE,
    }
    
    local indicator_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        bordersize = 1,
        padding = 4,
        margin = 0,
        radius = 4,
        indicator_widget,
    }
    
    -- Position in top-right corner
    local Screen = require("device").screen
    local margin = Screen:scaleBySize(10)
    
    self.position_indicator_widget = OverlapGroup:new{
        dimen = Geom:new{
            x = Screen:getWidth() - indicator_frame:getSize().w - margin,
            y = margin,
            w = indicator_frame:getSize().w,
            h = indicator_frame:getSize().h,
        },
        indicator_frame,
    }
    
    UIManager:show(self.position_indicator_widget)
    
    -- Auto-hide after 3 seconds
    self.indicator_timer = UIManager:scheduleIn(3, function()
        self:hidePositionIndicator()
    end)
end

function FastReader:hidePositionIndicator()
    if self.position_indicator_widget then
        UIManager:close(self.position_indicator_widget)
        self.position_indicator_widget = nil
    end
    
    if self.indicator_timer then
        UIManager:unschedule(self.indicator_timer)
        self.indicator_timer = nil
    end
end

return FastReader
