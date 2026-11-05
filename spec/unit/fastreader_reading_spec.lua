describe("FastReader reading #unit", function()
    local Harness = require("support/koreader")
    it("reading: starts immediately and advances once per WPM interval", function()
        local h = Harness.new()
        local p = h.plugin
        p:startRSVP()
        assert.are.equal(true, p.rsvp_enabled)
        assert.are.equal(1, p.current_word_index)
        assert.are.equal(1, p.rsvp_widget.current_index)
        assert.are.equal("fast", h.shown[1].mode)
        assert.are.equal(p.rsvp_widget.box_dimen, h.shown[1].region)
        assert.are.equal(1, #h.queue)
        assert.is.near(0.24, h.queue[1].at, 0.000001)
        h:advance(0.239)
        assert.are.equal(1, p.current_word_index)
        h:advance(0.001)
        assert.are.equal(2, p.current_word_index)
        assert.are.equal(2, p.rsvp_widget.current_index)
        assert.are.equal(1, #h.queue)
        assert.are.equal("fast", h.dirty[#h.dirty].mode)
        assert.are.equal(p.rsvp_widget.box_dimen, h.dirty[#h.dirty].region)
    end)

    it("reading: duplicate start preserves timer and widget", function()
        local h = Harness.new()
        h.plugin:startRSVP()
        local timer, widget = h.plugin.rsvp_timer, h.plugin.rsvp_widget
        h.plugin:startRSVP()
        assert.are.equal(timer, h.plugin.rsvp_timer)
        assert.are.equal(widget, h.plugin.rsvp_widget)
        assert.are.equal(1, #h.queue)
        assert.are.equal(1, #h.shown)
    end)

    it("reading: speed change affects the next scheduled interval", function()
        local h = Harness.new()
        h.plugin:startRSVP()
        h.plugin.rsvp_speed = 500
        h:advance(0.24)
        assert.is.near(0.36, h.queue[1].at, 0.000001)
        h:advance(0.12)
        assert.are.equal(3, h.plugin.current_word_index)
    end)

    it("reading: stop saves position, closes region and cancels future work", function()
        local h = Harness.new()
        local p = h.plugin
        p:startRSVP()
        h:advance(0.24)
        local widget = p.rsvp_widget
        h:paint()
        local word_widget = widget.word_widgets[1]
        p:stopRSVP()
        assert.are.equal(false, p.rsvp_enabled)
        assert.are.equal(2, p.last_word_index)
        assert.are.equal("page_1_/books/test.epub", p.last_page_hash)
        assert.are.equal(nil, p.rsvp_timer)
        assert.are.equal(nil, p.rsvp_widget)
        assert.are.equal(nil, p.original_view_mode)
        assert.are.equal(true, word_widget.freed)
        assert.are.equal(widget, h.closed[1].widget)
        assert.are.equal("ui", h.closed[1].mode)
        assert.are.equal(widget.box_dimen, h.closed[1].region)
        assert.are.equal(0, #h.queue)
        h:advance(20)
        assert.are.equal(1, h.page)
        local shown = #h.shown
        p:stopRSVP()
        assert.are.equal(shown, #h.shown)
    end)

    it("reading: stopped and empty ticks do nothing", function()
        local h = Harness.new()
        h.plugin:rsvpTick()
        h.plugin.rsvp_enabled = true
        h.plugin:rsvpTick()
        assert.are.equal(1, h.plugin.current_word_index)
        assert.are.equal(0, #h.queue)
        assert.are.equal(0, #h.shown)
    end)

    for _, rolling in ipairs({ false, true }) do
        local is_rolling = rolling
        local kind = is_rolling and "rolling" or "paged"
        it("reading: " .. kind .. " crosses pages and stops at end of book", function()
            local h = Harness.new({ rolling = is_rolling, pages = { "one two", "three" } })
            local p = h.plugin
            p:startRSVP()
            h:advance(0.48)
            assert.are.equal(2, h.page)
            assert.are.equal(true, p.rsvp_enabled)
            assert.are.equal(nil, p.rsvp_timer)
            assert(p.pending_resume_task)
            assert.is.near(0.58, h.queue[1].at, 0.000001)
            if is_rolling then
                assert.are.equal("onGotoViewRel", h.last_event.handler)
                assert.are.same({ 1 }, h.last_event.args)
            end
            h:advance(0.1)
            assert.are.same({ "three" }, p.words)
            assert.are.equal(1, p.current_word_index)
            assert.are.equal(nil, p.pending_resume_task)
            assert.are.equal(nil, p.last_page_hash)
            assert.are.equal(1, p.last_word_index)
            assert.are.equal(1, #h.queue)
            h:advance(0.24)
            assert.are.equal(false, p.rsvp_enabled)
            assert.are.equal(nil, p.rsvp_widget)
            assert.are.equal(0, #h.queue)
            assert.are.equal("End of document reached", h.shown[#h.shown].widget.text)
        end)

        it("reading: " .. kind .. " skips empty pages and continues", function()
            local h = Harness.new({ rolling = is_rolling,
                pages = { "one", "", " \n", "last word" } })
            h.plugin:startRSVP()
            h:advance(0.54)
            assert.are.equal(4, h.page)
            assert.are.same({ "last", "word" }, h.plugin.words)
            assert.are.equal(1, h.plugin.current_word_index)
            assert.are.equal(true, h.plugin.rsvp_enabled)
            h:advance(0.48)
            assert.are.equal(false, h.plugin.rsvp_enabled)
            assert.are.equal(0, #h.queue)
        end)
    end

    it("reading: stop during page render cancels pending continuation", function()
        local h = Harness.new({ pages = { "one", "two" } })
        local p = h.plugin
        p:startRSVP()
        h:advance(0.24)
        local pending = p.pending_resume_task
        assert(pending)
        p:stopRSVP()
        assert.are.equal(nil, p.pending_resume_task)
        assert.are.equal(0, #h.queue)
        h:advance(5)
        -- Even an already dispatched callback must not restart a stopped reader.
        pending()
        assert.are.equal(false, p.rsvp_enabled)
        assert.are.equal(nil, p.rsvp_widget)
        assert.are.equal(0, #h.queue)
    end)

    it("reading: repeated page transition replaces pending task", function()
        local h = Harness.new({ pages = { "one", "two", "three" } })
        local p = h.plugin
        p:startRSVP()
        h:advance(0.24)
        local first = p.pending_resume_task
        p:goToNextPageAndContinueRSVP()
        assert(first ~= p.pending_resume_task)
        assert.are.equal(1, #h.queue)
        h:advance(0.1)
        assert.are.same({ "three" }, p.words)
        assert.are.equal(1, #h.queue)
    end)

    it("reading: unknown navigation mode stops cleanly", function()
        local h = Harness.new()
        h.plugin:startRSVP()
        h.ui.paging = nil
        h.plugin:goToNextPageAndContinueRSVP()
        assert.are.equal(false, h.plugin.rsvp_enabled)
        assert.are.equal(0, #h.queue)
    end)

    it("reading: a consumed rolling event without movement stops at end of book", function()
        local h = Harness.new({ rolling = true })
        h.ui.handleEvent = function() return true end
        h.plugin:startRSVP()
        h.plugin.current_word_index = #h.plugin.words
        h:advance(0.24)
        assert.is_false(h.plugin.rsvp_enabled)
        assert.is_nil(h.plugin.pending_resume_task)
        assert.is_nil(h.plugin.rsvp_widget)
    end)

    it("resume: same page resumes at saved word and shows position", function()
        local h = Harness.new()
        local p = h.plugin
        p:startRSVP()
        h:advance(0.24)
        p:stopRSVP()
        p:startRSVP()
        assert.are.equal(2, p.current_word_index)
        assert.are.equal(2, p.rsvp_widget.current_index)
        assert(p.position_indicator_widget)
        assert.are.equal("📖 2/3", p.position_indicator_widget[1][1].text)
        assert.are.equal(2, #h.queue)
        p:stopRSVP()
        assert.are.equal(nil, p.position_indicator_widget)
        assert.are.equal(nil, p.indicator_timer)
        assert.are.equal(0, #h.queue)
    end)

    it("resume: changed page and document do not reuse saved word", function()
        local h = Harness.new()
        local p = h.plugin
        p:startRSVP()
        h:advance(0.24)
        p:stopRSVP()
        h.ui.paging:onGotoPage(2)
        p:startRSVP()
        assert.are.equal(1, p.current_word_index)
        assert.are.equal(nil, p.position_indicator_widget)
        p:stopRSVP()
        h.ui.paging:onGotoPage(1)
        h.document.file = "/books/other.epub"
        assert.are.equal(false, p:shouldResumeFromLastPosition())
    end)

    it("resume: restarting after end of book displays the first word", function()
        local h = Harness.new({ pages = { "only" } })
        local p = h.plugin
        p:startRSVP()
        h:advance(0.24)
        assert.are.equal(false, p.rsvp_enabled)
        p:startRSVP()
        assert.are.equal(true, p.rsvp_enabled)
        assert.are.equal(1, p.current_word_index)
        assert(p.rsvp_widget, "restarted reader must display a word")
        assert.are.equal("only", h:paint()[1].text)
        assert.are.equal(nil, p.position_indicator_widget)
    end)

    it("resume: shorter reflowed page rejects an out-of-range saved position", function()
        local h = Harness.new({ rolling = true, pages = { "one two three" } })
        local p = h.plugin
        p:startRSVP()
        h:advance(0.48)
        p:stopRSVP()
        h.pages[1] = "shorter page"
        p:startRSVP()
        assert.are.equal(1, p.current_word_index)
        assert.are.equal("shorter", h:paint()[1].text)
        assert.are.equal(nil, p.position_indicator_widget)
    end)

    it("resume: rolling identity includes position and document path", function()
        local h = Harness.new({ rolling = true })
        local p = h.plugin
        assert.are.equal("rolling_/body/1_/books/test.epub", p:getCurrentPageHash())
        p.words = { "one", "two", "three" }
        p.current_word_index = 2
        p:updateLastReadPosition()
        assert.are.equal(true, p:shouldResumeFromLastPosition())
        h.page = 2
        assert.are.equal(false, p:shouldResumeFromLastPosition())
        h.ui.rolling.getBookLocation = function() return nil end
        assert.are.equal("rolling_unknown_/books/test.epub", p:getCurrentPageHash())
        h.ui.rolling, h.document.file = nil, nil
        assert.are.equal("", p:getCurrentPageHash())
    end)

    it("resume: first word does not trigger resume or an indicator", function()
        local h = Harness.new()
        local p = h.plugin
        p.last_page_hash = p:getCurrentPageHash()
        assert.are.equal(false, p:shouldResumeFromLastPosition())
        p:showPositionIndicator()
        assert.are.equal(nil, p.position_indicator_widget)
        p:startRSVP()
        p:stopRSVP()
        assert.are.equal(1, p.last_word_index)
    end)

    it("resume: indicator is replaced and auto-hides after three seconds", function()
        local h = Harness.new()
        local p = h.plugin
        p.words, p.current_word_index = { "a", "b", "c" }, 2
        p:showPositionIndicator()
        local old = p.position_indicator_widget
        p:showPositionIndicator()
        assert.are.equal(old, h.closed[1].widget)
        assert.are.equal(1, #h.queue)
        local indicator = p.position_indicator_widget
        assert.are.equal("ui", h.shown[#h.shown].mode)
        assert.are.equal(indicator.dimen, h.shown[#h.shown].region)
        h:advance(2.99)
        assert.are.equal(indicator, p.position_indicator_widget)
        local repaints = h.repaints
        h:advance(0.01)
        assert.are.equal(nil, p.position_indicator_widget)
        assert.are.equal(nil, p.indicator_timer)
        assert.are.equal(0, #h.queue)
        assert.are.equal(indicator.dimen, h.closed[#h.closed].region)
        assert.are.equal(repaints + 1, h.repaints)
        p:hidePositionIndicator()
        assert.are.equal(repaints + 1, h.repaints)
    end)

    it("resume: disabled indicator is never shown", function()
        local h = Harness.new()
        h.plugin.words, h.plugin.current_word_index = { "a", "b" }, 2
        h.plugin.show_position_indicator = false
        h.plugin:showPositionIndicator()
        assert.are.equal(0, #h.shown)
        assert.are.equal(0, #h.queue)
    end)

    for _, event in ipairs({ "onCloseDocument", "onExit" }) do
        local handler = event
        it("lifecycle: " .. handler .. " cancels active reading", function()
            local h = Harness.new()
            h.plugin:startRSVP()
            h.plugin[handler](h.plugin)
            h:advance(10)
            assert.are.equal(false, h.plugin.rsvp_enabled)
            assert.are.equal(nil, h.plugin.rsvp_widget)
            assert.are.equal(0, #h.queue)
            if handler == "onCloseDocument" then assert.are.equal(false, h.plugin.enabled) end
        end)
    end

    it("view: rolling, paged and unsupported modes are recognized", function()
        local h = Harness.new({ rolling = true })
        assert.are.equal(true, h.plugin:enableContinuousView())
        assert.are.equal(nil, h.plugin.original_view_mode)
        h.ui.rolling, h.ui.paging = nil, {}
        assert.are.equal(true, h.plugin:enableContinuousView())
        assert.are.equal("paging", h.plugin.original_view_mode)
        h.plugin:restoreOriginalView()
        assert.are.equal(nil, h.plugin.original_view_mode)
        h.ui.paging = nil
        assert.are.equal(false, h.plugin:enableContinuousView())
    end)
end)
