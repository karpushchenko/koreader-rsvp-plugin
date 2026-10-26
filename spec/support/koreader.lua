-- Only external KOReader APIs are doubled. main.lua is loaded unchanged into
-- a new environment per test; unknown imports fail instead of silently passing.
local Harness = {}

function Harness.key(name)
    -- device/key.lua: Key:new produces a table, not a bare key-name string.
    return { key = name, modifiers = {}, [name] = true }
end

local function split_chars(text)
    local chars = {}
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = char
    end
    return chars
end

local Class = {}
function Class:extend(properties)
    return setmetatable(properties or {}, { __index = self })
end
function Class:new(properties)
    local object = self:extend(properties)
    if object.init then object:init() end
    return object
end
function Class:getSize()
    if self.dimen then return self.dimen end
    if self[1] then return self[1]:getSize() end
    return { w = 0, h = 0 }
end

function Harness.new(options)
    options = options or {}
    local h = {
        now = 0, queue = {}, shown = {}, closed = {}, dirty = {}, painted = {},
        draws = {}, actions = {}, settings_data = {}, saved = {}, flushes = 0,
        repaints = 0, logs = {},
    }
    for key, value in pairs(options.settings or {}) do h.settings_data[key] = value end

    h.screen = { w = 600, h = 800 }
    function h.screen:getWidth() return self.w end
    function h.screen:getHeight() return self.h end
    function h.screen:scaleBySize(value) return value end

    h.manager = {}
    function h.manager:scheduleIn(delay, callback)
        assert(type(delay) == "number" and delay >= 0 and delay < math.huge)
        assert(type(callback) == "function")
        h.queue[#h.queue + 1] = { at = h.now + delay, callback = callback }
    end
    function h.manager:unschedule(callback)
        for i = #h.queue, 1, -1 do
            if h.queue[i].callback == callback then table.remove(h.queue, i) end
        end
    end
    function h.manager:show(widget, mode, region)
        h.shown[#h.shown + 1] = { widget = widget, mode = mode, region = region }
    end
    function h.manager:close(widget, mode, region)
        h.closed[#h.closed + 1] = { widget = widget, mode = mode, region = region }
    end
    function h.manager:setDirty(widget, mode, region)
        h.dirty[#h.dirty + 1] = { widget = widget, mode = mode, region = region }
    end
    function h.manager:forceRePaint() h.repaints = h.repaints + 1 end

    function h:advance(seconds)
        local target, steps = self.now + seconds, 0
        while true do
            local next_index
            for i, task in ipairs(self.queue) do
                if task.at <= target
                    and (not next_index or task.at < self.queue[next_index].at) then
                    next_index = i
                end
            end
            if not next_index then break end
            local task = table.remove(self.queue, next_index)
            self.now = task.at
            task.callback()
            steps = steps + 1
            assert(steps < 10000, "scheduler runaway")
        end
        self.now = target
    end

    h.settings = {}
    function h.settings:readSetting(key) return h.settings_data[key] end
    function h.settings:saveSetting(key, value)
        h.settings_data[key] = value
        h.saved[key] = value
    end
    function h.settings:flush() h.flushes = h.flushes + 1 end

    local TextWidget = Class:extend{}
    function TextWidget:setText(text) self.text = text end
    function TextWidget:setMaxWidth(width) self.max_width = width end
    function TextWidget:getSize()
        local width = #split_chars(self.text) * 10
        return { w = self.max_width and math.min(width, self.max_width) or width,
            h = self.face.size }
    end
    function TextWidget:getBaseline() return self.face.size * 0.8 end
    function TextWidget:paintTo(_, x, y)
        h.painted[#h.painted + 1] = {
            text = self.text, x = x, y = y, w = self:getSize().w, bold = self.bold,
        }
    end
    function TextWidget:free() self.freed = true end

    h.bb = {}
    function h.bb:paintRect(x, y, w, height, color)
        h.draws[#h.draws + 1] = { kind = "rect", x = x, y = y, w = w,
            h = height, color = color }
    end
    function h.bb:paintBorder(x, y, w, height, size, color, radius, antialias)
        h.draws[#h.draws + 1] = { kind = "border", x = x, y = y, w = w,
            h = height, size = size, color = color, radius = radius, antialias = antialias }
    end

    local modules = {
        ["dispatcher"] = { registerAction = function(_, name, action)
            h.actions[name] = action
        end },
        ["ui/uimanager"] = h.manager,
        ["ui/widget/container/widgetcontainer"] = Class,
        ["ui/widget/container/inputcontainer"] = Class,
        ["ui/widget/inputcontainer"] = Class,
        ["ui/widget/textwidget"] = TextWidget,
        ["ui/widget/infomessage"] = Class,
        ["ui/widget/spinwidget"] = Class,
        ["ui/widget/container/framecontainer"] = Class,
        ["ui/widget/overlapgroup"] = Class,
        ["ui/geometry"] = Class,
        ["ui/gesturerange"] = Class,
        ["ui/font"] = { getFace = function(_, name, size)
            return { name = name, size = size }
        end },
        ["ui/rendertext"] = { sizeUtf8Text = function(_, _, _, _, text)
            return { x = #split_chars(text) * 10 }
        end },
        ["ffi/blitbuffer"] = { COLOR_WHITE = "white", COLOR_BLACK = "black",
            COLOR_DARK_GRAY = "dark_gray" },
        ["device"] = { screen = h.screen, hasKeys = function() return options.keys end },
        ["luasettings"] = { open = function(_, path)
            h.settings_path = path
            return h.settings
        end },
        ["datastorage"] = { getSettingsDir = function() return "/test/settings" end },
        ["util"] = { splitToChars = split_chars },
        ["gettext"] = function(text) return text end,
        ["ffi/util"] = { template = function(text, ...)
            local args = { ... }
            return (text:gsub("%%(%d+)", function(i) return tostring(args[tonumber(i)]) end))
        end },
        ["ui/event"] = { new = function(_, name, ...)
            return { handler = "on" .. name, args = { ... } }
        end },
    }
    local logger = {}
    for _, level in ipairs({ "dbg", "info", "warn", "err" }) do
        logger[level] = function(...)
            h.logs[#h.logs + 1] = { level = level, args = { ... } }
        end
    end
    modules.logger = logger
    local environment = setmetatable({ require = function(name)
        if options.legacy_input and name == "ui/widget/container/inputcontainer" then
            error("module unavailable on this KOReader version")
        end
        assert(modules[name], "unconfigured KOReader dependency: " .. name)
        return modules[name]
    end }, { __index = _G })
    local chunk = assert(loadfile(os.getenv("FASTREADER_SOURCE") or "main.lua"))
    setfenv(chunk, environment)
    h.plugin_class = chunk()

    h.pages = options.pages or { "one two three", "four five", "six" }
    h.page = 1
    h.document = { file = "/books/test.epub", provider = options.rolling and "crengine"
        or "mupdf" }
    function h.document:getPageText(page)
        local text = h.pages[page]
        if type(text) ~= "string" or options.string_page_text then return text end
        -- Mirror the native MuPDF return shape even in lifecycle tests.
        local boxes = {}
        for line in text:gmatch("[^\n]+") do
            local words = {}
            for word in line:gmatch("%S+") do words[#words + 1] = { word = word } end
            boxes[#boxes + 1] = words
        end
        return boxes
    end
    function h.document:getPageCount() return #h.pages end
    function h.document:getTextFromPositions() return { text = h.pages[h.page] } end
    function h.document:getTextFromXPointers() return h.pages[h.page] end
    h.ui = { document = h.document, menu = {}, view = { footer_visible = false } }
    function h.ui.menu:registerToMainMenu(plugin) h.menu_plugin = plugin end
    function h.ui:registerPostReaderReadyCallback(callback) h.ready_callback = callback end
    function h.ui:registerTouchZones(zones) h.zones = zones end
    function h.ui.view:screenToPageTransform(pos) return { x = pos.x, y = pos.y, page = h.page } end
    h.ui.view.footer = { getHeight = function() return 40 end }
    if options.rolling then
        h.ui.rolling = { getBookLocation = function() return "/body/" .. h.page end }
    else
        h.ui.paging = { current_page = 1 }
        function h.ui.paging:onGotoPage(page)
            h.page, self.current_page = page, page
        end
    end
    function h.ui:handleEvent(event)
        h.last_event = event
        if h.page >= #h.pages then return false end
        h.page = h.page + 1
        return true
    end
    function h:newPlugin() return self.plugin_class:new{ ui = self.ui } end
    h.plugin = h:newPlugin()
    function h:menu()
        local items = {}
        self.plugin:addToMainMenu(items)
        return items.fastreader.sub_item_table
    end
    function h:paint()
        self.painted, self.draws = {}, {}
        self.plugin.rsvp_widget:paintTo(self.bb, 0, 0)
        return self.painted
    end
    return h
end

return Harness
