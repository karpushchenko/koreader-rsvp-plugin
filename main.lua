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
local FrameContainer = require("ui/widget/container/framecontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local ok_input, InputContainer = pcall(require, "ui/widget/container/inputcontainer")
if not ok_input then
    InputContainer = require("ui/widget/inputcontainer")
end
local GestureRange = require("ui/gesturerange")
local logger = require("logger")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local util = require("util")
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
    self.pending_resume_task = nil
    self.rsvp_widget = nil
    
    -- Tap-to-launch RSVP settings
    self.tap_to_launch_enabled = self.settings:readSetting("tap_to_launch_enabled") or false
    self.rsvp_speed = self.settings:readSetting("rsvp_speed") or 250  -- words per minute
    self.current_word_index = 1
    self.words = {}
    self.original_view_mode = nil
    
    local ovp_setting = self.settings:readSetting("ovp_alignment_enabled")
    if ovp_setting == nil then
        self.ovp_alignment_enabled = true
    else
        self.ovp_alignment_enabled = ovp_setting
    end

    -- Position tracking for resume functionality
    self.last_page_hash = nil -- Hash to identify current page content
    self.last_word_index = 1  -- Last read word index on this page
    self.show_position_indicator = self.settings:readSetting("show_position_indicator") or true
    
    -- Multi-word display settings
    self.words_preview_count = self.settings:readSetting("words_preview_count") or 3 -- Show current + 2 next words
    
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
        self.settings:saveSetting("words_preview_count", self.words_preview_count)
        self.settings:saveSetting("ovp_alignment_enabled", self.ovp_alignment_enabled)
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

local function getOptimalRecognitionIndex(char_count)
    if char_count <= 1 then
        return 1
    elseif char_count == 2 then
        return 1
    elseif char_count == 3 then
        return 2
    elseif char_count == 4 then
        return 2
    elseif char_count == 5 then
        return 3
    elseif char_count == 6 then
        return 3
    elseif char_count == 7 then
        return 4
    elseif char_count == 8 then
        return 4
    end
    return 5
end

local function measureTextWidth(face, text, bold)
    if not text or text == "" then
        return 0
    end
    local metrics = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true, bold)
    return math.floor(metrics.x or 0)
end

local function calculateAnchorOffset(word, face, bold)
    if not word or word == "" then
        return 0, 1
    end

    local chars = util.splitToChars(word)
    local char_count = #chars
    if char_count == 0 then
        return 0, 1
    end

    local ovp_index = getOptimalRecognitionIndex(char_count)
    local prefix_text = table.concat(chars, "", 1, ovp_index - 1)
    local key_char = chars[ovp_index] or ""

    local prefix_width = measureTextWidth(face, prefix_text, bold)
    local key_width = measureTextWidth(face, key_char, bold)

    return prefix_width + (key_width / 2), ovp_index
end

local RSVPWidget = InputContainer:extend{
    name = "fastreader_rsvp_widget",
}

function RSVPWidget:init()
    self.word_widgets = {}
    self:updateDimensions()
    if Device:hasKeys() then
        self.key_events = {
            Close = { { "Back" }, doc = "close RSVP reader" },
        }
    end
end

function RSVPWidget:updateDimensions(new_dimen)
    local sw = (new_dimen and new_dimen.w) or Screen:getWidth()
    local sh = (new_dimen and new_dimen.h) or Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    local preview_count = self.plugin.words_preview_count or 3
    local width_ratio = (preview_count <= 2) and 0.7 or 0.9
    local fixed_width = math.floor(sw * width_ratio)
    local max_width = math.max(sw - Screen:scaleBySize(40), Screen:scaleBySize(220))
    local min_width = math.min(Screen:scaleBySize(320), max_width)
    fixed_width = math.max(fixed_width, min_width)
    fixed_width = math.min(fixed_width, max_width)
    local fixed_height = Screen:scaleBySize(120)
    local frame_x = math.floor((sw - fixed_width) / 2)
    local frame_y = math.floor((sh - fixed_height) / 2)

    self.box_dimen = Geom:new{
        x = frame_x,
        y = frame_y,
        w = fixed_width,
        h = fixed_height,
    }

    self.text_padding = Screen:scaleBySize(20)
    self.inter_word_gap = Screen:scaleBySize(15)

    local base_font_name = self.plugin.ovp_alignment_enabled and "infont" or "cfont"
    self.anchor_face = Font:getFace(base_font_name, 28)
    self.secondary_face = Font:getFace(base_font_name, 24)

    self.ges_events = {
        Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen }
        },
    }
end

function RSVPWidget:handleResize(new_dimen)
    local sw = (new_dimen and new_dimen.w) or Screen:getWidth()
    local sh = (new_dimen and new_dimen.h) or Screen:getHeight()
    if self.dimen and self.dimen.w == sw and self.dimen.h == sh then
        return
    end
    self:updateDimensions(new_dimen)
    self:freeWidgets()
    UIManager:setDirty(nil, "full")
end

function RSVPWidget:onSetDimensions(dimen)
    self:handleResize(dimen)
    return false
end

function RSVPWidget:onScreenResize(dimen)
    self:handleResize(dimen)
    return false
end

function RSVPWidget:onTap(arg, ges)
    self.plugin:stopRSVP()
    return true
end

function RSVPWidget:onClose()
    self.plugin:stopRSVP()
    return true
end

function RSVPWidget:freeWidgets()
    if self.word_widgets then
        for _, w in ipairs(self.word_widgets) do
            w:free()
        end
        self.word_widgets = {}
    end
end

function RSVPWidget:getWordWidget(idx)
    local widget = self.word_widgets[idx]
    if not widget then
        local is_current = (idx == 1)
        widget = TextWidget:new{
            text = "",
            face = is_current and self.anchor_face or self.secondary_face,
            bold = is_current,
            fgcolor = Blitbuffer.COLOR_BLACK,
            padding = 0,
        }
        self.word_widgets[idx] = widget
    end
    return widget
end

function RSVPWidget:updateWord(words, current_index)
    self.words = words
    self.current_index = current_index
end

function RSVPWidget:paintTo(bb, x, y)
    local box = self.box_dimen
    local bx, by, bw, bh = box.x, box.y, box.w, box.h
    local pad = self.text_padding
    local inner_w = bw - (pad * 2)
    local inner_h = bh - (pad * 2)
    local inner_x = bx + pad
    local inner_y = by + pad

    -- 1. Wipe the entire RSVP box clean with solid white (erases previous word and anti-aliasing)
    bb:paintRect(bx, by, bw, bh, Blitbuffer.COLOR_WHITE)

    -- 2. Draw crisp 2-pixel black border (anti_alias = false for crisp 1-bit E-ink rendering)
    bb:paintBorder(bx, by, bw, bh, 2, Blitbuffer.COLOR_BLACK, 0, false)

    if not self.words or not self.current_index or not self.words[self.current_index] then
        return
    end

    local current_word = self.words[self.current_index]
    local preview_count = self.plugin.words_preview_count or 3

    -- Gather preview words (current + next words)
    local preview_words = {}
    for i = 0, preview_count - 1 do
        local idx = self.current_index + i
        if idx <= #self.words then
            table.insert(preview_words, self.words[idx])
        end
    end

    local anchor_face = self.anchor_face
    local inter_word_gap = self.inter_word_gap
    local min_left_padding = Screen:scaleBySize(20)
    local base_right_padding = (preview_count <= 2) and Screen:scaleBySize(140) or Screen:scaleBySize(180)
    base_right_padding = math.max(Screen:scaleBySize(80), math.min(base_right_padding, math.floor(inner_w * 0.6)))

    local anchor_offset = 0
    if self.plugin.ovp_alignment_enabled then
        anchor_offset = calculateAnchorOffset(current_word, anchor_face, true)
    end

    local anchor_target
    if self.plugin.ovp_alignment_enabled then
        local target_limit = Screen:scaleBySize((preview_count <= 2) and 90 or 140)
        anchor_target = math.min(inner_w - base_right_padding, target_limit)
        anchor_target = math.max(anchor_target, Screen:scaleBySize(90))
    else
        anchor_target = math.floor(inner_w / 2)
    end

    local leading_padding
    if self.plugin.ovp_alignment_enabled then
        leading_padding = math.max(anchor_target - anchor_offset, min_left_padding)
    else
        leading_padding = math.max(math.floor((inner_w - base_right_padding) * 0.2), min_left_padding)
    end

    -- Setup current word widget (always slot 1)
    local current_widget = self:getWordWidget(1)
    current_widget:setMaxWidth(nil)
    current_widget:setText(current_word)
    local current_w = current_widget:getSize().w

    -- If current word exceeds space from leading_padding to right edge, shift left towards min_left_padding
    if leading_padding + current_w > inner_w and leading_padding > min_left_padding then
        local overflow = (leading_padding + current_w) - inner_w
        leading_padding = math.max(min_left_padding, leading_padding - overflow)
    end

    -- Issue 1: Bound current word so it can never draw outside box_dimen
    local max_current_w = inner_w - leading_padding
    if current_w > max_current_w then
        current_widget:setMaxWidth(max_current_w)
        current_w = current_widget:getSize().w
    end

    local items = {
        {
            widget = current_widget,
            width = current_w,
            is_current = true,
        },
    }
    local total_w = leading_padding + current_w
    local max_allowed_w = inner_w - base_right_padding

    -- Measure and add preview words
    for i = 2, #preview_words do
        local word = preview_words[i]
        local widget = self:getWordWidget(i)
        widget:setMaxWidth(nil)
        widget:setText(word)
        local w = widget:getSize().w
        table.insert(items, {
            widget = widget,
            width = w,
            is_current = false,
        })
        total_w = total_w + inter_word_gap + w
    end

    -- Trim preview words that exceed max allowed width
    while #items > 1 and total_w > max_allowed_w do
        local last = table.remove(items)
        total_w = total_w - last.width - inter_word_gap
    end

    local word_x = inner_x + leading_padding
    local baseline_y = by + math.floor(bh / 2) + math.floor(anchor_face.size * 0.3)

    -- 3. Draw OVP crosshairs / fixation guide if enabled (pure black, crisp 1-bit lines)
    if self.plugin.ovp_alignment_enabled then
        local crosshair_x = math.floor(word_x + anchor_offset)
        crosshair_x = math.max(inner_x + 1, math.min(crosshair_x, inner_x + inner_w - 2))
        local guide_h = Screen:scaleBySize(12)
        -- Top guide tick at fixation point
        bb:paintRect(crosshair_x - 1, inner_y, 2, guide_h, Blitbuffer.COLOR_BLACK)
        -- Bottom guide tick at fixation point
        bb:paintRect(crosshair_x - 1, inner_y + inner_h - guide_h, 2, guide_h, Blitbuffer.COLOR_BLACK)
    end

    -- 4. Render words using TextWidgets via paintTo, ensuring every widget is bounded by remaining box width
    local cur_x = word_x
    for _, item in ipairs(items) do
        local widget = item.widget
        local remaining_w = (inner_x + inner_w) - cur_x
        if remaining_w > 0 then
            widget:setMaxWidth(remaining_w)
            local widget_y = baseline_y - widget:getBaseline()
            widget:paintTo(bb, cur_x, widget_y)
            cur_x = cur_x + widget:getSize().w + inter_word_gap
        end
    end
end

function FastReader:showRSVPWord(current_word)
    if not current_word or current_word == "" then
        return
    end

    if not self.rsvp_widget then
        self.rsvp_widget = RSVPWidget:new{
            plugin = self,
        }
        self.rsvp_widget:updateWord(self.words, self.current_word_index)
        UIManager:show(self.rsvp_widget, "fast", self.rsvp_widget.box_dimen)
        return
    end

    -- Screen rotation / window resize check
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    if self.rsvp_widget.dimen.w ~= sw or self.rsvp_widget.dimen.h ~= sh then
        self.rsvp_widget:handleResize()
    end

    self.rsvp_widget:updateWord(self.words, self.current_word_index)

    -- Use "fast" mode for smooth word updates
    UIManager:setDirty(self.rsvp_widget, "fast", self.rsvp_widget.box_dimen)
end

function FastReader:onSetDimensions(dimen)
    if self.rsvp_widget then
        self.rsvp_widget:onSetDimensions(dimen)
    end
end

function FastReader:onScreenResize(dimen)
    if self.rsvp_widget then
        self.rsvp_widget:onScreenResize(dimen)
    end
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
    if self.rsvp_timer then
        UIManager:unschedule(self.rsvp_timer)
        self.rsvp_timer = nil
    end
    self.rsvp_timer = function()
        self.rsvp_timer = nil
        self:rsvpTick()
    end
    UIManager:scheduleIn(interval / 1000, self.rsvp_timer)
    
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

    if self.pending_resume_task then
        UIManager:unschedule(self.pending_resume_task)
        self.pending_resume_task = nil
    end
    
    -- Remove RSVP widget
    if self.rsvp_widget then
        self.rsvp_widget:freeWidgets()
        local refresh_region = self.rsvp_widget.box_dimen or self.rsvp_widget.dimen
        UIManager:close(self.rsvp_widget, "ui", refresh_region)
        self.rsvp_widget = nil
    end
    
    -- Remove position indicator if shown
    self:hidePositionIndicator()
    
    -- Restore original view mode
    self:restoreOriginalView()
    
    UIManager:show(InfoMessage:new{
        text = _("RSVP stopped"),
        timeout = 1.5,
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
        if self.rsvp_timer then
            UIManager:unschedule(self.rsvp_timer)
            self.rsvp_timer = nil
        end
        self.rsvp_timer = function()
            self.rsvp_timer = nil
            self:rsvpTick()
        end
        UIManager:scheduleIn(interval / 1000, self.rsvp_timer)
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
        if self.pending_resume_task then
            UIManager:unschedule(self.pending_resume_task)
        end
        self.pending_resume_task = function()
            self.pending_resume_task = nil
            self:continueRSVPWithNewPage()
        end
        UIManager:scheduleIn(0.1, self.pending_resume_task)
    end
end

function FastReader:continueRSVPWithNewPage()
    if not self.rsvp_enabled then
        return
    end
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
        if self.rsvp_timer then
            UIManager:unschedule(self.rsvp_timer)
            self.rsvp_timer = nil
        end
        self.rsvp_timer = function()
            self.rsvp_timer = nil
            self:rsvpTick()
        end
        UIManager:scheduleIn(interval / 1000, self.rsvp_timer)
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
                text = _("Optimal Alignment (OVP)"),
                checked_func = function()
                    return self.ovp_alignment_enabled
                end,
                callback = function()
                    self.ovp_alignment_enabled = not self.ovp_alignment_enabled
                    self:saveSettings()

                    if self.ovp_alignment_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("Optimal alignment enabled. Words align to the focus crosshair."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Optimal alignment disabled. Words center in the widget."),
                            timeout = 3,
                        })
                    end
                end,
                help_text = _("Aligns each word to its optimal recognition point and shows the subtle crosshair guide."),
            },
            {
                text_func = function()
                    return T(_("Preview Words: %1"), self.words_preview_count)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local spin_widget = SpinWidget:new{
                        title_text = _("RSVP Preview Words"),
                        info_text = _("Number of words to show in RSVP widget (1-10)"),
                        width = math.floor(Screen:getWidth() * 0.6),
                        value = self.words_preview_count,
                        value_min = 1,
                        value_max = 10,
                        value_step = 1,
                        value_hold_step = 2,
                        default_value = 3,
                        unit = _("words"),
                        callback = function(spin)
                            self.words_preview_count = spin.value
                            self:saveSettings()
                            touchmenu_instance:updateItems()
                            UIManager:show(InfoMessage:new{
                                text = T(_("Preview words set to %1"), self.words_preview_count),
                                timeout = 2,
                            })
                        end
                    }
                    UIManager:show(spin_widget)
                end,
                help_text = _("Controls how many words are shown in the RSVP widget. The current word is highlighted, upcoming words are dimmed."),
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
    
    UIManager:show(self.position_indicator_widget, "ui", self.position_indicator_widget.dimen)
    UIManager:forceRePaint()
    
    -- Auto-hide after 3 seconds
    if self.indicator_timer then
        UIManager:unschedule(self.indicator_timer)
        self.indicator_timer = nil
    end
    self.indicator_timer = function()
        self.indicator_timer = nil
        self:hidePositionIndicator()
    end
    UIManager:scheduleIn(3, self.indicator_timer)
end

function FastReader:hidePositionIndicator()
    if self.position_indicator_widget then
        local refresh_region = self.position_indicator_widget.dimen
        UIManager:close(self.position_indicator_widget, "ui", refresh_region)
        self.position_indicator_widget = nil
        UIManager:forceRePaint()
    end
    
    if self.indicator_timer then
        UIManager:unschedule(self.indicator_timer)
        self.indicator_timer = nil
    end
end

return FastReader
