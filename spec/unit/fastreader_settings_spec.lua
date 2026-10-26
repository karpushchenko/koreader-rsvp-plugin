describe("FastReader settings #unit", function()
    local Harness = require("support/koreader")
    it("settings: defaults and deferred touch registration", function()
        local h = Harness.new()
        local p = h.plugin
        assert.are.equal(250, p.rsvp_speed)
        assert.are.equal(3, p.words_preview_count)
        assert.are.equal(false, p.tap_to_launch_enabled)
        assert.are.equal(true, p.ovp_alignment_enabled)
        assert.are.equal(true, p.show_position_indicator)
        assert.are.equal(false, p.rsvp_enabled)
        assert.are.equal(nil, p.rsvp_timer)
        assert.are.equal(nil, p.pending_resume_task)
        assert.are.equal(1, p.current_word_index)
        assert.are.same({}, p.words)
        assert.are.equal(p, h.menu_plugin)
        assert.are.equal("/test/settings/fastreader.lua", h.settings_path)
        assert.are.equal(nil, h.zones)
        h.ready_callback()
        assert.are.equal("fastreader_tap_to_launch", h.zones[1].id)
        assert.are.equal("tap", h.zones[1].ges)
        assert.are.same({ ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            h.zones[1].screen_zone)
        assert.are.equal("FastReaderRSVP", h.actions.fastreader_rsvp.event)
        assert.are.equal("FastReader", h.actions.fastreader_action.event)
    end)

    it("settings: saved false values survive restart", function()
        local h = Harness.new()
        local p = h.plugin
        p.rsvp_speed, p.words_preview_count = 475, 7
        p.tap_to_launch_enabled = true
        p.ovp_alignment_enabled, p.show_position_indicator = false, false
        p:saveSettings()
        assert.are.equal(1, h.flushes)
        assert.are.same({ rsvp_speed = 475, words_preview_count = 7, tap_to_launch_enabled = true,
            ovp_alignment_enabled = false, show_position_indicator = false }, h.saved)
        local restarted = h:newPlugin()
        assert.are.equal(475, restarted.rsvp_speed)
        assert.are.equal(7, restarted.words_preview_count)
        assert.are.equal(true, restarted.tap_to_launch_enabled)
        assert.are.equal(false, restarted.ovp_alignment_enabled)
        assert.are.equal(false, restarted.show_position_indicator)
    end)

    it("settings: saving before settings are available is harmless", function()
        local h = Harness.new()
        h.plugin.settings = nil
        h.plugin:saveSettings()
        assert.are.equal(0, h.flushes)
    end)

    for _, entry in ipairs({ { 2, "tap_to_launch_enabled" },
        { 3, "show_position_indicator" }, { 4, "ovp_alignment_enabled" } }) do
        local index, key = entry[1], entry[2]
        it("menu: toggles and persists " .. key, function()
            local h = Harness.new()
            local item = h:menu()[index]
            local initial = h.plugin[key]
            assert.are.equal(initial, item.checked_func())
            item.callback()
            assert.are.equal(not initial, item.checked_func())
            assert.are.equal(not initial, h.saved[key])
            item.callback()
            assert.are.equal(initial, item.checked_func())
            assert.are.equal(initial, h.saved[key])
            assert.are.equal(2, h.flushes)
        end)
    end

    it("menu: start-stop callback controls the actual reader", function()
        local h = Harness.new()
        local item = h:menu()[1]
        item.callback()
        assert.are.equal(true, h.plugin.rsvp_enabled)
        item.callback()
        assert.are.equal(false, h.plugin.rsvp_enabled)
        assert.are.equal(0, #h.queue)
    end)

    for _, speed in ipairs({ 100, 150, 200, 250, 300, 400, 500 }) do
        local wpm = speed
        it("menu: speed preset " .. wpm .. " is persisted", function()
            local h = Harness.new()
            local found = false
            for _, item in ipairs(h:menu()[6].sub_item_table) do
                if item.text and item.text:match("^" .. wpm .. " WPM") then
                    item.callback()
                    found = true
                end
            end
            assert.are.equal(true, found)
            assert.are.equal(wpm, h.plugin.rsvp_speed)
            assert.are.equal(wpm, h.saved.rsvp_speed)
        end)
    end

    for _, entry in ipairs({ { name = "preview", index = 5, min = 1, max = 10,
        value = 8, key = "words_preview_count" },
        { name = "speed", index = 6, min = 50, max = 1000,
            value = 625, key = "rsvp_speed" } }) do
        local config = entry
        it("menu: custom " .. config.name .. " updates settings and menu", function()
            local h = Harness.new()
            local item = h:menu()[config.index]
            if config.name == "speed" then item = item.sub_item_table[1] end
            local menu = { updates = 0, updateItems = function(self)
                self.updates = self.updates + 1
            end }
            assert(item.text_func():find(tostring(h.plugin[config.key]), 1, true))
            item.callback(menu)
            local spin = h.shown[#h.shown].widget
            assert.are.equal(config.min, spin.value_min)
            assert.are.equal(config.max, spin.value_max)
            assert.are.equal(h.plugin[config.key], spin.value)
            spin.callback({ value = config.value })
            assert.are.equal(config.value, h.plugin[config.key])
            assert.are.equal(config.value, h.saved[config.key])
            assert.are.equal(1, menu.updates)
            assert(item.text_func():find(tostring(config.value), 1, true))
        end)
    end

    it("metadata: plugin identity is available with gettext", function()
        local chunk = assert(loadfile("_meta.lua"))
        setfenv(chunk, { require = function(name)
            assert.are.equal("gettext", name)
            return function(text) return text end
        end })
        local meta = chunk()
        assert.are.equal("fastreader", meta.name)
        assert.are.equal("FastReader", meta.fullname)
        assert(type(meta.description) == "string" and #meta.description > 0)
    end)
end)
