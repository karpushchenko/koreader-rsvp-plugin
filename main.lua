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
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local _ = require("gettext")

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
    
    -- Initialize progress display state
    self.progress_widget = nil
    self.enabled = self.settings:readSetting("progress_enabled") or false
    
    -- RSVP state
    self.rsvp_enabled = false
    self.rsvp_timer = nil
    self.rsvp_speed = self.settings:readSetting("rsvp_speed") or 250  -- words per minute
    self.current_word_index = 1
    self.words = {}
    self.original_view_mode = nil
    
    -- Register for document events to setup callbacks when document is ready
    self.ui:registerPostReaderReadyCallback(function()
        self:setupProgressDisplay()
    end)
end

function FastReader:saveSettings()
    if self.settings then
        self.settings:saveSetting("progress_enabled", self.enabled)
        self.settings:saveSetting("rsvp_speed", self.rsvp_speed)
        self.settings:flush()
    end
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
    self:saveSettings()
    
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

function FastReader:enableContinuousView()
    -- Save original view mode
    if self.ui.rolling then
        -- Already in continuous mode for reflowable documents
        return true
    elseif self.ui.paging then
        -- For paged documents, try to switch to continuous mode if possible
        self.original_view_mode = "paging"
        -- Note: This may not work for all document types
        -- The actual implementation depends on document format support
        return true
    end
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
    self.current_word_index = 1
    
    -- Calculate interval in milliseconds
    local interval = 60000 / self.rsvp_speed  -- Convert WPM to milliseconds per word
    logger.info("FastReader: RSVP interval set to " .. interval .. "ms for " .. self.rsvp_speed .. " WPM")
    
    -- Start RSVP timer
    self.rsvp_timer = UIManager:scheduleIn(interval / 1000, function()
        self:rsvpTick()
    end)
    
    -- Show first word
    self:showRSVPWord(self.words[self.current_word_index])
    
    UIManager:show(InfoMessage:new{
        text = string.format(_("RSVP started at %d WPM (%d words found)"), self.rsvp_speed, #self.words),
        timeout = 2,
    })
    
    logger.info("FastReader: RSVP started successfully")
end

function FastReader:stopRSVP()
    if not self.rsvp_enabled then
        return
    end
    
    logger.info("FastReader: Stopping RSVP mode")
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
        -- End of page reached
        self:stopRSVP()
        UIManager:show(InfoMessage:new{
            text = _("End of page reached"),
        })
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
                text = _("Toggle Progress Display"),
                callback = function()
                    self:toggleProgressDisplay()
                end,
            },
            {
                text = _("Start/Stop RSVP"),
                callback = function()
                    self:toggleRSVP()
                end,
            },
            {
                text = _("RSVP Speed"),
                sub_item_table = {
                    {
                        text = _("150 WPM"),
                        callback = function()
                            self.rsvp_speed = 150
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 150 WPM"),
                            })
                        end,
                    },
                    {
                        text = _("200 WPM"),
                        callback = function()
                            self.rsvp_speed = 200
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 200 WPM"),
                            })
                        end,
                    },
                    {
                        text = _("250 WPM"),
                        callback = function()
                            self.rsvp_speed = 250
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 250 WPM"),
                            })
                        end,
                    },
                    {
                        text = _("300 WPM"),
                        callback = function()
                            self.rsvp_speed = 300
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 300 WPM"),
                            })
                        end,
                    },
                    {
                        text = _("400 WPM"),
                        callback = function()
                            self.rsvp_speed = 400
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 400 WPM"),
                            })
                        end,
                    },
                },
            },
        },
    }
end

function FastReader:onFastReaderAction()
    self:toggleProgressDisplay()
end

function FastReader:onFastReaderRSVP()
    self:toggleRSVP()
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

return FastReader
