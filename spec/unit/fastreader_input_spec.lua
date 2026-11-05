describe("FastReader input #unit", function()
    local Harness = require("support/koreader")
    for _, key in ipairs({ "Press", "LPgFwd" }) do
        local button = key
        it("keys: " .. button .. " pauses and resumes with a single timer", function()
            local h = Harness.new()
            local p = h.plugin
            p:startRSVP()
            assert.are.equal(true, p:onKeyPress(Harness.key(button)))
            assert.are.equal(true, p.rsvp_enabled)
            assert.are.equal(nil, p.rsvp_timer)
            assert.are.equal(0, #h.queue)
            h:advance(10)
            assert.are.equal(1, p.current_word_index)
            assert.are.equal(true, p:onKeyPress(Harness.key(button)))
            assert.are.equal(1, #h.queue)
            h:advance(0.24)
            assert.are.equal(2, p.current_word_index)
            assert.are.equal(1, #h.queue)
        end)
    end

    for _, key in ipairs({ "Menu", "Back" }) do
        local button = key
        it("keys: " .. button .. " stops reading", function()
            local h = Harness.new()
            h.plugin:startRSVP()
            assert.are.equal(true, h.plugin:onKeyPress(Harness.key(button)))
            assert.are.equal(false, h.plugin.rsvp_enabled)
            assert.are.equal(0, #h.queue)
        end)
    end

    it("keys: previous word never moves before first word", function()
        local h = Harness.new()
        h.plugin:startRSVP()
        h:advance(0.24)
        assert.are.equal(true, h.plugin:onKeyPress(Harness.key("LPgBack")))
        assert.are.equal(1, h.plugin.current_word_index)
        assert.are.equal(1, h.plugin.rsvp_widget.current_index)
        h.plugin:onKeyPress(Harness.key("LPgBack"))
        assert.are.equal(1, h.plugin.current_word_index)
        assert.are.equal(1, #h.queue)
    end)

    it("keys: inactive and unknown keys propagate", function()
        local h = Harness.new()
        assert.are.equal(false, h.plugin:onKeyPress(Harness.key("Back")))
        h.plugin:startRSVP()
        local timer = h.plugin.rsvp_timer
        assert.are.equal(false, h.plugin:onKeyPress(Harness.key("Unknown")))
        assert.are.equal(timer, h.plugin.rsvp_timer)
    end)

    it("keys: bare key names remain supported", function()
        local h = Harness.new()
        h.plugin:startRSVP()
        assert.are.equal(true, h.plugin:onKeyPress("Press"))
        assert.are.equal(nil, h.plugin.rsvp_timer)
        assert.are.equal(true, h.plugin:onKeyPress("Back"))
        assert.are.equal(false, h.plugin.rsvp_enabled)
    end)

    it("dispatcher: RSVP action toggles reading", function()
        local h = Harness.new()
        h.plugin:onFastReaderRSVP()
        assert.are.equal(true, h.plugin.rsvp_enabled)
        h.plugin:onFastReaderRSVP()
        assert.are.equal(false, h.plugin.rsvp_enabled)
    end)

    it("tap: disabled launch propagates without querying document", function()
        local h = Harness.new()
        h.document.getTextFromPositions = function() error("must not query text") end
        assert.are.equal(false, h.plugin:onTapToLaunchRSVP({ pos = { x = 300, y = 400 } }))
        assert.are.equal(false, h.plugin.rsvp_enabled)
    end)

    it("tap: registered text tap launches once and consumes the gesture", function()
        local h = Harness.new({ settings = { tap_to_launch_enabled = true } })
        h.ready_callback()
        local handler = h.zones[1].handler
        assert.are.equal(true, handler({ pos = { x = 300, y = 400 } }))
        assert.are.equal(true, h.plugin.rsvp_enabled)
        local timer = h.plugin.rsvp_timer
        assert.are.equal(false, handler({ pos = { x = 300, y = 400 } }))
        assert.are.equal(timer, h.plugin.rsvp_timer)
    end)

    for _, point in ipairs({ { 30, 400 }, { 570, 400 }, { 300, 30 },
        { 300, 770 }, { 0, 0 }, { 600, 800 } }) do
        local x, y = point[1], point[2]
        it("tap: excludes screen margins at " .. x .. "," .. y, function()
            local h = Harness.new({ settings = { tap_to_launch_enabled = true } })
            h.document.getTextFromPositions = function() error("margin queried") end
            assert.are.equal(false, h.plugin:onTapToLaunchRSVP({ pos = { x = x, y = y } }))
            assert.are.equal(false, h.plugin.rsvp_enabled)
        end)
    end

    it("tap: excludes visible footer and accepts text just inside margins", function()
        local h = Harness.new()
        h.ui.view.footer_visible = true
        assert.are.equal(false, h.plugin:isTapOnTextArea({ pos = { x = 300, y = 730 } }))
        assert.are.equal(true, h.plugin:isTapOnTextArea({ pos = { x = 31, y = 729 } }))
        h.ui.view.footer_visible = false
        assert.are.equal(true, h.plugin:isTapOnTextArea({ pos = { x = 300, y = 750 } }))
    end)

    for _, failure in ipairs({ "whitespace", "empty", "nil", "no transform", "no document" }) do
        local mode = failure
        it("tap: propagates when hit detection has " .. mode, function()
            local h = Harness.new({ settings = { tap_to_launch_enabled = true } })
            if mode == "whitespace" then
                h.document.getTextFromPositions = function() return { text = " \t\n" } end
            elseif mode == "empty" then
                h.document.getTextFromPositions = function() return {} end
            elseif mode == "nil" then
                h.document.getTextFromPositions = function() return nil end
            elseif mode == "no transform" then
                h.ui.view.screenToPageTransform = function() return nil end
            else h.ui.document = nil end
            assert.are.equal(false, h.plugin:onTapToLaunchRSVP({ pos = { x = 300, y = 400 } }))
            assert.are.equal(false, h.plugin.rsvp_enabled)
        end)
    end

    it("tap: text lookup uses transformed page coordinates", function()
        local h = Harness.new()
        local transformed = { x = 12, y = 34, page = 1 }
        h.ui.view.screenToPageTransform = function() return transformed end
        h.document.getTextFromPositions = function(_, start, finish)
            assert.are.equal(transformed, start)
            assert.are.equal(transformed, finish)
            return { text = "word" }
        end
        assert.are.equal(true, h.plugin:isTapOnTextArea({ pos = { x = 300, y = 400 } }))
    end)
end)
