describe("FastReader extraction #unit", function()
    local Harness = require("support/koreader")
    it("extraction: paged text removes outer punctuation but keeps word structure", function()
        local h = Harness.new({ string_page_text = true,
            pages = { "  (Hello!),\tworld...\n--- can't well-known 42.  " } })
        assert.are.same({ "Hello", "world", "can't", "well-known", "42" },
            h.plugin:extractWordsFromCurrentPage())
    end)

    it("extraction: preserves UTF-8 words", function()
        local h = Harness.new({ pages = { "Привет мир! café 日本語" } })
        assert.are.same({ "Привет", "мир", "café", "日本語" }, h.plugin:extractWordsFromCurrentPage())
    end)

    it("extraction: native MuPDF line and word boxes preserve reading order", function()
        -- Document:getPageText forwards page:getPageText. Its nested array
        -- contract is also exercised in KOReader base/spec/unit/mupdf_spec.lua.
        local h = Harness.new({ pages = { {
            { { word = "Hello,", x0 = 10, y0 = 10, x1 = 60, y1 = 20 },
                { word = "world!", x0 = 65, y0 = 10, x1 = 120, y1 = 20 },
                x0 = 10, y0 = 10, x1 = 120, y1 = 20 },
            { { word = "Привет", x0 = 10, y0 = 30, x1 = 70, y1 = 40 } },
            size = 256,
        } } })
        assert.are.same({ "Hello", "world", "Привет" }, h.plugin:extractWordsFromCurrentPage())
        h.plugin:startRSVP()
        assert.are.equal(true, h.plugin.rsvp_enabled)
        assert.are.equal("Hello", h:paint()[1].text)
    end)

    it("extraction: empty native page boxes report no text", function()
        local h = Harness.new({ pages = { { size = 0 } } })
        assert.are.same({}, h.plugin:extractWordsFromCurrentPage())
        assert.are.equal(1, #h.shown)
    end)

    it("extraction: rolling selection uses full screen without highlighting", function()
        local h = Harness.new({ rolling = true })
        function h.document:getTextFromPositions(start, finish, no_highlight)
            assert.are.same({ x = 0, y = 0 }, start)
            assert.are.same({ x = 600, y = 800 }, finish)
            assert.are.equal(true, no_highlight)
            return { text = "screen text" }
        end
        function h.document:getTextFromXPointers() error("unnecessary fallback") end
        assert.are.same({ "screen", "text" }, h.plugin:extractWordsFromCurrentPage())
    end)

    for _, failure in ipairs({ "throws", "nil", "empty", "missing text" }) do
        local mode = failure
        it("extraction: rolling fallback when screen selection " .. mode, function()
            local h = Harness.new({ rolling = true })
            function h.document:getTextFromPositions()
                if mode == "throws" then error("selection unavailable") end
                if mode == "empty" then return { text = "" } end
                if mode == "missing text" then return {} end
            end
            function h.document:getTextFromXPointers(start, finish, draw_selection)
                assert.are.equal("/body/1", start)
                assert.are.equal(start, finish)
                assert.are.equal(false, draw_selection)
                return "fallback works"
            end
            assert.are.same({ "fallback", "works" }, h.plugin:extractWordsFromCurrentPage())
        end)
    end

    for _, failure in ipairs({ "missing method", "missing location", "empty", "throws" }) do
        local mode = failure
        it("extraction: rolling failure handles " .. mode, function()
            local h = Harness.new({ rolling = true })
            function h.document:getTextFromPositions() return nil end
            if mode == "missing method" then h.document.getTextFromXPointers = nil end
            if mode == "missing location" then
                h.ui.rolling.getBookLocation = function() return nil end
            end
            if mode == "empty" then
                h.document.getTextFromXPointers = function() return "" end
            end
            if mode == "throws" then
                h.document.getTextFromXPointers = function() error("bad xpointer") end
            end
            assert.are.same({}, h.plugin:extractWordsFromCurrentPage())
            assert.are.equal("Cannot extract text from this document type", h.shown[1].widget.text)
        end)
    end

    for _, failure in ipairs({ "missing method", "missing page", "nil", "empty", "throws" }) do
        local mode = failure
        it("extraction: paged failure handles " .. mode, function()
            local h = Harness.new()
            if mode == "missing method" then h.document.getPageText = nil end
            if mode == "missing page" then h.ui.paging.current_page = nil end
            if mode == "nil" then h.document.getPageText = function() return nil end end
            if mode == "empty" then h.document.getPageText = function() return "" end end
            if mode == "throws" then h.document.getPageText = function() error("bad page") end end
            assert.are.same({}, h.plugin:extractWordsFromCurrentPage())
            assert.are.equal(1, #h.shown)
        end)
    end

    it("extraction: no document returns no words", function()
        local h = Harness.new()
        h.ui.document = nil
        assert.are.same({}, h.plugin:extractWordsFromCurrentPage())
        assert.are.equal(0, #h.shown)
    end)

    it("extraction: unknown document type reports unavailable text", function()
        local h = Harness.new()
        h.ui.paging = nil
        assert.are.same({}, h.plugin:extractWordsFromCurrentPage())
        assert.are.equal(1, #h.shown)
    end)

    it("extraction: whitespace and punctuation alone cannot start reading", function()
        local h = Harness.new({ pages = { " \n... !!! ---\t" } })
        h.plugin:startRSVP()
        assert.are.same({}, h.plugin.words)
        assert.are.equal(false, h.plugin.rsvp_enabled)
        assert.are.equal(nil, h.plugin.rsvp_widget)
        assert.are.equal(0, #h.queue)
    end)
end)
