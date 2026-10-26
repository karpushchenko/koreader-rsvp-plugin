-- RSVP session control. State stays on the plugin instance so existing
-- handlers, resume positions and widget callbacks keep their interface.
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")
local RSVPWidget = require("fastreader/widget")
local _ = require("gettext")
local Reader = {}

function Reader:enableContinuousView()
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

function Reader:restoreOriginalView()
    if self.original_view_mode and self.original_view_mode == "paging" then
        -- Restore paging mode if it was originally used
        -- Implementation would depend on KOReader's internal APIs
        self.original_view_mode = nil
    end
end

function Reader:showRSVPWord(current_word)
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

function Reader:onSetDimensions(dimen)
    if self.rsvp_widget then
        self.rsvp_widget:onSetDimensions(dimen)
    end
end

function Reader:onScreenResize(dimen)
    if self.rsvp_widget then
        self.rsvp_widget:onScreenResize(dimen)
    end
end

function Reader:startRSVP()
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

function Reader:stopRSVP()
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

function Reader:rsvpTick()
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

function Reader:goToNextPageAndContinueRSVP()
    -- Try to go to next page
    local success

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
        local previous_page_hash = self:getCurrentPageHash()
        local ret = self.ui:handleEvent(Event:new("GotoViewRel", 1))
        -- ReaderRolling consumes this event even when already at the end.
        if ret and self:getCurrentPageHash() ~= previous_page_hash then
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

function Reader:continueRSVPWithNewPage()
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

function Reader:toggleRSVP()
    if self.rsvp_enabled then
        self:stopRSVP()
    else
        self:startRSVP()
    end
end

function Reader:getCurrentPageHash()
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

function Reader:shouldResumeFromLastPosition()
    local current_hash = self:getCurrentPageHash()
    return self.last_page_hash == current_hash and self.last_word_index > 1
        and self.last_word_index <= #self.words
end

function Reader:updateLastReadPosition()
    self.last_page_hash = self:getCurrentPageHash()
    self.last_word_index = self.current_word_index
    logger.info("FastReader: Updated last read position to word " .. self.last_word_index)
end

return Reader
