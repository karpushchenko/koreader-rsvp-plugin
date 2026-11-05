describe("FastReader widget #unit", function()
    local Harness = require("support/koreader")
    local function reader(options)
        local h = Harness.new(options)
        h.plugin:startRSVP()
        return h, h.plugin.rsvp_widget
    end

    it("widget: ignores absent and empty words", function()
        local h = Harness.new()
        h.plugin:showRSVPWord(nil)
        h.plugin:showRSVPWord("")
        assert.are.equal(nil, h.plugin.rsvp_widget)
        assert.are.equal(0, #h.shown)
    end)

    it("widget: paints white wipe and crisp black border before words", function()
        local h, widget = reader()
        h:paint()
        local box = widget.box_dimen
        assert.are.same({ kind = "rect", x = box.x, y = box.y, w = box.w, h = box.h,
            color = "white" }, h.draws[1])
        assert.are.same({ kind = "border", x = box.x, y = box.y, w = box.w, h = box.h,
            size = 2, color = "black", radius = 0, antialias = false }, h.draws[2])
        assert.are.equal(4, #h.draws) -- two fixation ticks
        assert.are.equal("one", h.painted[1].text)
        assert.are.equal(true, h.painted[1].bold)
    end)

    it("widget: an invalid current index still clears stale pixels", function()
        local h, widget = reader()
        widget:updateWord({}, 1)
        h:paint()
        assert.are.equal(2, #h.draws)
        assert.are.equal(0, #h.painted)
    end)

    for _, count in ipairs({ 1, 2, 3, 10 }) do
        local preview = count
        it("widget: preview count " .. preview .. " limits displayed words", function()
            local h, widget = reader({ pages = { "a b c d e f g h i j k" },
                settings = { words_preview_count = preview } })
            h.screen.w = 2000
            widget:handleResize()
            h:paint()
            assert.are.equal(preview, #h.painted)
            assert.are.equal("a", h.painted[1].text)
            for i = 2, #h.painted do
                assert.are.equal(false, h.painted[i].bold)
                assert(h.painted[i].x > h.painted[i - 1].x)
            end
        end)
    end

    it("widget: preview stops at last word of page", function()
        local h, widget = reader({ settings = { words_preview_count = 10 } })
        widget:updateWord(h.plugin.words, 3)
        h:paint()
        assert.are.equal(1, #h.painted)
        assert.are.equal("three", h.painted[1].text)
    end)

    it("widget: overflowing preview words are removed", function()
        local h = reader({ pages = { "one " .. string.rep("x", 60) .. " end" } })
        h:paint()
        assert.are.equal(1, #h.painted)
        assert.are.equal("one", h.painted[1].text)
    end)

    it("widget: long current word stays within box and next word resets clipping", function()
        local h, widget = reader({ pages = { string.rep("x", 120) .. " short" } })
        h:paint()
        local word = h.painted[1]
        local box, pad = widget.box_dimen, widget.text_padding
        assert(word.x >= box.x + pad)
        assert(word.x + word.w <= box.x + box.w - pad)
        local cached = widget.word_widgets[1]
        widget:updateWord(h.plugin.words, 2)
        h:paint()
        assert.are.equal(cached, widget.word_widgets[1])
        assert.are.equal("short", h.painted[1].text)
        assert.are.equal(50, h.painted[1].w)
    end)

    -- Ten-pixel character metrics make the OVP position observable through
    -- drawing; the private anchoring helper stays private.
    for _, sample in ipairs({ { "a", 1 }, { "ab", 1 }, { "abc", 2 }, { "abcd", 2 },
        { "abcde", 3 }, { "abcdef", 3 }, { "abcdefg", 4 }, { "abcdefgh", 4 },
        { "abcdefghi", 5 }, { "abcdefghijklm", 5 }, { "Привет", 3 }, { "日本語", 2 } }) do
        local word, index = sample[1], sample[2]
        it("widget: OVP anchors character " .. index .. " in " .. word, function()
            local h = reader({ pages = { word } })
            h:paint()
            local guide = h.draws[3]
            assert.are.equal("black", guide.color)
            assert.are.equal(2, guide.w)
            assert.are.equal(12, guide.h)
            assert.are.equal(h.painted[1].x + (index - 1) * 10 + 5, guide.x + 1)
            assert.are.equal(guide.x, h.draws[4].x)
        end)
    end

    it("widget: centered mode uses proportional face and omits fixation guides", function()
        local h, widget = reader({ settings = { ovp_alignment_enabled = false } })
        h:paint()
        assert.are.equal("cfont", widget.anchor_face.name)
        assert.are.equal(2, #h.draws)
        assert.are.equal("one", h.painted[1].text)
    end)

    it("widget: word widgets are reused between frames and freed on stop", function()
        local h, widget = reader()
        h:paint()
        local first, second = widget.word_widgets[1], widget.word_widgets[2]
        assert(second)
        assert.are.equal("infont", first.face.name)
        assert.are.equal(28, first.face.size)
        assert.are.equal(24, second.face.size)
        h:advance(0.24)
        h:paint()
        assert.are.equal(first, widget.word_widgets[1])
        assert.are.equal(second, widget.word_widgets[2])
        assert.are.equal("two", first.text)
        h.plugin:stopRSVP()
        assert.are.equal(true, first.freed)
        assert.are.equal(true, second.freed)
        assert.are.same({}, widget.word_widgets)
    end)

    for _, handler in ipairs({ "onSetDimensions", "onScreenResize" }) do
        local event = handler
        it("widget: " .. event .. " resizes, frees cache and fully refreshes", function()
            local h, widget = reader()
            h:paint()
            local cached = widget.word_widgets[1]
            h.plugin[event](h.plugin, { w = 800, h = 600 })
            assert.are.equal(800, widget.dimen.w)
            assert.are.equal(600, widget.dimen.h)
            assert.are.equal(720, widget.box_dimen.w)
            assert.are.equal(240, widget.box_dimen.y)
            assert.are.equal(true, cached.freed)
            assert.are.equal("full", h.dirty[#h.dirty].mode)
            assert.are.equal(nil, h.dirty[#h.dirty].widget)
            assert.are.same(widget.dimen, widget.ges_events.Tap[1].range)
            local dirty = #h.dirty
            assert.are.equal(false, widget[event](widget, { w = 800, h = 600 }))
            assert.are.equal(dirty, #h.dirty)
        end)
    end

    it("widget: detects screen rotation while updating words", function()
        local h, widget = reader()
        h.screen.w, h.screen.h = 800, 600
        h:advance(0.24)
        assert.are.equal(widget, h.plugin.rsvp_widget)
        assert.are.equal(800, widget.dimen.w)
        assert.are.equal(600, widget.dimen.h)
        assert.are.equal("full", h.dirty[1].mode)
        assert.are.equal("fast", h.dirty[2].mode)
    end)

    it("widget: width honors preview mode and minimum on small screens", function()
        local h, widget = reader({ settings = { words_preview_count = 1 } })
        assert.are.equal(420, widget.box_dimen.w)
        widget:handleResize({ w = 300, h = 500 })
        assert.are.equal(260, widget.box_dimen.w)
        assert.are.equal(20, widget.box_dimen.x)
        h.plugin.words_preview_count = 3
        widget:handleResize({ w = 600, h = 800 })
        assert.are.equal(540, widget.box_dimen.w)
    end)

    for _, handler in ipairs({ "onTap", "onClose" }) do
        local event = handler
        it("widget: " .. event .. " stops and consumes input", function()
            local h, widget = reader({ keys = true })
            assert.are.equal("Back", widget.key_events.Close[1][1])
            assert.are.equal(true, widget[event](widget))
            assert.are.equal(false, h.plugin.rsvp_enabled)
            assert.are.equal(0, #h.queue)
        end)
    end

    it("widget: legacy InputContainer import works", function()
        local h, widget = reader({ legacy_input = true })
        assert(widget)
        h:paint()
        assert.are.equal("one", h.painted[1].text)
    end)

    it("widget: resize notifications before launch are harmless", function()
        local h = Harness.new()
        h.plugin:onSetDimensions({ w = 800, h = 600 })
        h.plugin:onScreenResize({ w = 800, h = 600 })
        assert.are.equal(0, #h.dirty)
    end)
end)
