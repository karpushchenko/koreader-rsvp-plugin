-- luacheck: globals disable_plugins load_plugin G_reader_settings
describe("FastReader KOReader integration #integration", function()
    local ReaderUI, DocumentRegistry, UIManager, Screen, DataStorage, LuaSettings
    local MockTime, Event, Key, Geom, Blitbuffer, saved_settings, ffiUtil, util
    local reader, plugin, fixture_dir

    local function has_task(callback)
        for _, task in ipairs(UIManager._task_queue) do
            if task.action == callback then return true end
        end
        return false
    end

    local function start()
        plugin:startRSVP()
        assert.is_true(plugin.rsvp_enabled)
        assert.is.truthy(plugin.rsvp_widget)
    end

    local function advance(seconds)
        MockTime:increase(seconds)
        UIManager:_checkTasks()
    end

    local function find_text_tap()
        -- Use the real provider independently of the plugin's hit detector.
        reader.view:paintTo(Screen.bb, 0, 0)
        local margin = Screen:scaleBySize(40)
        for y = margin, Screen:getHeight() - margin * 2, Screen:scaleBySize(30) do
            for x = margin, Screen:getWidth() - margin, Screen:scaleBySize(30) do
                local position = reader.view:screenToPageTransform(Geom:new{ x = x, y = y })
                local result = position
                    and reader.document:getTextFromPositions(position, position)
                if result and result.text and result.text:match("%S") then
                    return { ges = "tap", pos = Geom:new{ x = x, y = y } }
                end
            end
        end
        error("fixture must contain a visible text hit")
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        load_plugin("fastreader.koplugin")
        ReaderUI = require("apps/reader/readerui")
        DocumentRegistry = require("document/documentregistry")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen
        DataStorage = require("datastorage")
        LuaSettings = require("luasettings")
        MockTime = require("mock_time")
        Event = require("ui/event")
        Key = require("device/key")
        Geom = require("ui/geometry")
        Blitbuffer = require("ffi/blitbuffer")
        util = require("util")
        ffiUtil = require("ffi/util")
        saved_settings = util.tableDeepCopy(G_reader_settings.data)
    end)

    teardown(function()
        G_reader_settings:reset(saved_settings)
        disable_plugins()
    end)

    for _, format in ipairs({ "epub", "pdf" }) do
        local kind = format
        describe(kind, function()
            before_each(function()
                UIManager:quit()
                G_reader_settings:reset{
                    document_metadata_folder = "dir",
                    end_document_action = "nothing",
                    reader_footer_mode = 0,
                }
                local settings = DataStorage:getSettingsDir() .. "/fastreader.lua"
                os.remove(settings)
                os.remove(settings .. ".old")
                MockTime:install()
                local file = kind == "epub" and "juliet.epub" or "paper.pdf"
                fixture_dir = DataStorage:getDataDir() .. "/fastreader-integration"
                assert.is_true(util.makePath(fixture_dir))
                assert.is_nil(ffiUtil.copyFile("spec/front/unit/data/" .. file,
                    fixture_dir .. "/" .. file))
                reader = ReaderUI:new{
                    dimen = Screen:getSize(),
                    document = DocumentRegistry:openDocument(fixture_dir .. "/" .. file),
                }
                if reader.rolling then reader.rolling:onGotoPage(10) end
                if reader.paging then reader.paging:onGotoPage(1) end
                plugin = reader.fastreader
                UIManager:show(reader)
                UIManager:_checkTasks()
            end)

            after_each(function()
                if plugin then plugin:stopRSVP() end
                if reader then reader:onClose() end
                UIManager:quit()
                MockTime:uninstall()
                if fixture_dir then assert.is_true(ffiUtil.purgeDir(fixture_dir)) end
                reader, plugin = nil, nil
                fixture_dir = nil
            end)

            it("loads through PluginLoader and registers real tap zones", function()
                assert.is.table(plugin)
                assert.are.equal(reader, plugin.ui)
                assert.are.equal("readerfastreader", plugin.name)
                local meta = dofile("plugins/fastreader.koplugin/_meta.lua")
                for _, field in ipairs({ "fullname", "description", "version",
                    "author", "license", "url" }) do
                    assert.is.string(meta[field])
                    assert.are.equal(meta[field], plugin[field])
                end
                assert.is.truthy(reader._zones.fastreader_tap_to_launch)
                if kind == "epub" then assert.is.truthy(reader.rolling)
                else assert.is.truthy(reader.paging) end
            end)

            it("extracts provider text and displays it in a real TextWidget", function()
                start()
                assert.is_true(plugin.rsvp_enabled)
                assert.is_true(#plugin.words > 1)
                assert.is_true(has_task(plugin.rsvp_timer))
                assert.is_true(UIManager:isWidgetShown(plugin.rsvp_widget))
                plugin.rsvp_widget:paintTo(Screen.bb, 0, 0)
                local word = plugin.rsvp_widget.word_widgets[1]
                assert.are.equal(plugin.words[1], word.text)
                assert.is_true(word:getSize().w > 0)
            end)

            it("persists menu changes through real LuaSettings files", function()
                local items = {}
                plugin:addToMainMenu(items)
                local menu = items.fastreader.sub_item_table
                menu[2].callback() -- tap-to-launch
                menu[3].callback() -- position indicator
                menu[4].callback() -- OVP
                menu[6].sub_item_table[2].callback() -- 100 WPM
                local saved = LuaSettings:open(plugin.settings_file)
                assert.is_true(saved:readSetting("tap_to_launch_enabled"))
                assert.is_false(saved:readSetting("show_position_indicator"))
                assert.is_false(saved:readSetting("ovp_alignment_enabled"))
                assert.are.equal(100, saved:readSetting("rsvp_speed"))
                local file = reader.document.file
                reader:onClose()
                reader = ReaderUI:new{
                    dimen = Screen:getSize(),
                    document = DocumentRegistry:openDocument(file),
                }
                plugin = reader.fastreader
                UIManager:show(reader)
                local reloaded = plugin
                assert.is_false(reloaded.show_position_indicator)
                assert.is_false(reloaded.ovp_alignment_enabled)
                assert.is_true(reloaded.tap_to_launch_enabled)
                assert.are.equal(100, reloaded.rsvp_speed)
            end)

            it("advances on the real UIManager queue using configured WPM", function()
                plugin.rsvp_speed = 120
                start()
                local timer = plugin.rsvp_timer
                advance(0.499)
                assert.are.equal(1, plugin.current_word_index)
                assert.is_true(has_task(timer))
                advance(0.001)
                assert.are.equal(2, plugin.current_word_index)
                assert.is_false(has_task(timer))
                assert.is_true(has_task(plugin.rsvp_timer))
                assert.are.equal(2, plugin.rsvp_widget.current_index)
            end)

            it("routes pause, resume and previous-word keys through the visible widget", function()
                start()
                advance(0.24)
                assert.are.equal(2, plugin.current_word_index)
                UIManager:sendEvent(Event:new("KeyPress", Key:new("Press", {})))
                assert.is_nil(plugin.rsvp_timer)
                advance(1)
                assert.are.equal(2, plugin.current_word_index)
                UIManager:sendEvent(Event:new("KeyPress", Key:new("LPgBack", {})))
                assert.are.equal(1, plugin.current_word_index)
                UIManager:sendEvent(Event:new("KeyPress", Key:new("Press", {})))
                assert.is_true(has_task(plugin.rsvp_timer))
                advance(0.24)
                assert.are.equal(2, plugin.current_word_index)
            end)

            for _, key in ipairs({ "Menu", "Back" }) do
                local button = key
                it("routes " .. button .. " through UIManager and removes RSVP", function()
                    start()
                    local widget, timer = plugin.rsvp_widget, plugin.rsvp_timer
                    UIManager:sendEvent(Event:new("KeyPress", Key:new(button, {})))
                    assert.is_false(plugin.rsvp_enabled)
                    assert.is_nil(plugin.rsvp_widget)
                    assert.is_false(UIManager:isWidgetShown(widget))
                    assert.is_false(has_task(timer))
                end)
            end

            it("leaves unrelated keys to the underlying InputContainer", function()
                start()
                local timer = plugin.rsvp_timer
                UIManager:sendEvent(Event:new("KeyPress", Key:new("UnboundKey", {})))
                assert.is_true(plugin.rsvp_enabled)
                assert.are.equal(timer, plugin.rsvp_timer)
                assert.are.equal(1, plugin.current_word_index)
            end)

            it("launches from a provider text hit and stops on the next tap", function()
                local gesture = find_text_tap()
                plugin.tap_to_launch_enabled = true
                UIManager:sendEvent(Event:new("Gesture", gesture))
                assert.is_true(plugin.rsvp_enabled)
                local widget = plugin.rsvp_widget
                UIManager:sendEvent(Event:new("Gesture", {
                    ges = "tap", pos = Geom:new{ x = 5, y = 5 },
                }))
                assert.is_false(plugin.rsvp_enabled)
                assert.is_false(UIManager:isWidgetShown(widget))
            end)

            it("paints long Unicode words within the box using actual font metrics", function()
                start()
                local widget = plugin.rsvp_widget
                widget:updateWord({ string.rep("Привет", 40), "日本語", "café" }, 1)
                local bb = Blitbuffer.new(Screen:getWidth(), Screen:getHeight(),
                    Blitbuffer.TYPE_BB8)
                finally(function() bb:free() end)
                bb:fill(Blitbuffer.COLOR_WHITE)
                widget:paintTo(bb, 0, 0)
                local box = widget.box_dimen
                assert.are.equal(0, bb:getPixel(box.x, box.y).a)
                local ink = 0
                -- Exclude fixation ticks as well as the border: only text can
                -- make pixels dark in this horizontal band.
                local pad = widget.text_padding
                local guide_height = Screen:scaleBySize(12)
                for y = box.y + pad + guide_height,
                    box.y + box.h - pad - guide_height - 1 do
                    for x = box.x + pad, box.x + box.w - pad - 1 do
                        if bb:getPixel(x, y).a < 255 then ink = ink + 1 end
                    end
                end
                assert.is_true(ink > 0)
                for y = 0, bb:getHeight() - 1 do
                    assert.are.equal(255, bb:getPixel(box.x - 1, y).a)
                    assert.are.equal(255, bb:getPixel(box.x + box.w, y).a)
                end
                widget:updateWord({ "日本語", "café" }, 1)
                widget:paintTo(bb, 0, 0)
                assert.are.equal("日本語", widget.word_widgets[1].text)
            end)

            it("rebuilds real word widgets on resize and frees them on stop", function()
                start()
                local widget = plugin.rsvp_widget
                widget:paintTo(Screen.bb, 0, 0)
                local previous = widget.word_widgets[1]
                plugin:onSetDimensions(Geom:new{ w = 800, h = 600 })
                assert.are.equal(800, widget.dimen.w)
                assert.are.equal(600, widget.dimen.h)
                assert.are.same({}, widget.word_widgets)
                local bb = Blitbuffer.new(800, 600, Blitbuffer.TYPE_BB8)
                finally(function() bb:free() end)
                widget:paintTo(bb, 0, 0)
                assert.are_not.equal(previous, widget.word_widgets[1])
                plugin:stopRSVP()
                assert.are.same({}, widget.word_widgets)
                assert.is_false(UIManager:isWidgetShown(widget))
            end)

            it("crosses a real page boundary and resumes after rendering", function()
                start()
                local page_hash = plugin:getCurrentPageHash()
                plugin.current_word_index = #plugin.words
                advance(0.24)
                assert.are_not.equal(page_hash, plugin:getCurrentPageHash())
                assert.is_true(has_task(plugin.pending_resume_task))
                advance(0.1)
                assert.is_nil(plugin.pending_resume_task)
                assert.are.equal(1, plugin.current_word_index)
                assert.is_true(#plugin.words > 0)
                assert.is_true(has_task(plugin.rsvp_timer))
            end)

            it("cancels the real pending page continuation when stopped", function()
                start()
                plugin.current_word_index = #plugin.words
                advance(0.24)
                local pending = plugin.pending_resume_task
                assert.is_true(has_task(pending))
                plugin:stopRSVP()
                assert.is_false(has_task(pending))
                advance(1)
                assert.is_false(plugin.rsvp_enabled)
                assert.is_nil(plugin.rsvp_widget)
            end)

            it("resumes on the same page and closes its real position indicator", function()
                start()
                advance(0.24)
                plugin:stopRSVP()
                start()
                assert.are.equal(2, plugin.current_word_index)
                local indicator = plugin.position_indicator_widget
                local timer = plugin.indicator_timer
                assert.is_true(UIManager:isWidgetShown(indicator))
                plugin:stopRSVP()
                assert.is_false(UIManager:isWidgetShown(indicator))
                assert.is_nil(plugin.indicator_timer)
                assert.is_false(has_task(timer))
            end)

            it("expires the real position indicator on the UIManager timer", function()
                start()
                advance(0.24)
                plugin:stopRSVP()
                start()
                local indicator = plugin.position_indicator_widget
                local timer = plugin.indicator_timer
                assert.is_truthy(indicator)
                assert.is_truthy(timer)
                assert.is_true(UIManager:isWidgetShown(indicator))
                assert.is_true(has_task(timer))
                advance(2.999)
                assert.is_true(plugin.rsvp_enabled)
                assert.are.equal(indicator, plugin.position_indicator_widget)
                assert.is_true(UIManager:isWidgetShown(indicator))
                assert.is_true(has_task(timer))
                advance(0.001)
                assert.is_true(plugin.rsvp_enabled)
                assert.is_false(UIManager:isWidgetShown(indicator))
                assert.is_nil(plugin.position_indicator_widget)
                assert.is_nil(plugin.indicator_timer)
                assert.is_false(has_task(timer))
            end)

            it("starts at the first word after navigating to a different page", function()
                start()
                advance(0.24)
                plugin:stopRSVP()
                if reader.rolling then reader.rolling:onGotoPage(11)
                else reader.paging:onGotoPage(2) end
                start()
                assert.are.equal(1, plugin.current_word_index)
                assert.is_nil(plugin.position_indicator_widget)
            end)

            if kind == "epub" then
                it("continues across actual scroll-view screens", function()
                    reader:handleEvent(Event:new("SetViewMode", "scroll"))
                    start()
                    local position = reader.rolling.current_pos
                    plugin.current_word_index = #plugin.words
                    advance(0.24)
                    assert.is_true(reader.rolling.current_pos > position)
                    assert.is_true(has_task(plugin.pending_resume_task))
                    advance(0.1)
                    assert.is_true(plugin.rsvp_enabled)
                    assert.are.equal(1, plugin.current_word_index)
                    assert.is_true(has_task(plugin.rsvp_timer))
                end)

                it("stops at end of book in actual scroll view", function()
                    reader:handleEvent(Event:new("SetViewMode", "scroll"))
                    reader.rolling:onGotoPercent(100)
                    start()
                    plugin.current_word_index = #plugin.words
                    advance(0.24)
                    assert.is_false(plugin.rsvp_enabled)
                    assert.is_nil(plugin.pending_resume_task)
                end)

                it("accepts the real string returned by the XPointer fallback", function()
                    local selected = reader.document:getTextFromPositions(
                        { x = 0, y = 0 }, { x = Screen:getWidth(), y = Screen:getHeight() }, true)
                    local raw = reader.document:getTextFromXPointers(
                        selected.pos0, selected.pos0, false)
                    assert.is.string(raw)
                    assert.is.truthy(raw:match("%w"))
                    -- Force only the primary selection to fail. The fallback
                    -- still calls the real crengine method on a real XPointer.
                    local selection = stub(reader.document, "getTextFromPositions")
                    local location = stub(reader.rolling, "getBookLocation")
                    location.returns(selected.pos0)
                    finally(function()
                        selection:revert()
                        location:revert()
                    end)
                    assert.are.same({ raw }, plugin:extractWordsFromCurrentPage())
                end)
            end

            it("stops at the actual end of book instead of repeating its last page", function()
                local last_page = reader.document:getPageCount()
                if reader.rolling then reader.rolling:onGotoPage(last_page)
                else reader.paging:onGotoPage(last_page) end
                start()
                assert.is_true(plugin.rsvp_enabled)
                plugin.current_word_index = #plugin.words
                advance(0.24)
                assert.is_false(plugin.rsvp_enabled)
                assert.is_nil(plugin.pending_resume_task)
                assert.is_nil(plugin.rsvp_widget)
            end)

            it("closes the document without a scheduled reading callback", function()
                start()
                local active, timer = plugin, plugin.rsvp_timer
                reader:onClose()
                reader = nil
                assert.is_false(active.rsvp_enabled)
                assert.is_false(has_task(timer))
                assert.is_nil(active.rsvp_widget)
                advance(1)
                assert.is_false(active.rsvp_enabled)
            end)
        end)
    end
end)
