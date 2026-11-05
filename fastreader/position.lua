-- The transient reading-position overlay and its hide timer.
local TextWidget = require("ui/widget/textwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Position = {}

function Position:showPositionIndicator()
    if not self.show_position_indicator or self.current_word_index <= 1 then
        return
    end

    -- Hide any existing indicator first
    self:hidePositionIndicator()

    -- Create a small indicator showing reading progress
    local progress_text = string.format("📖 %d/%d", self.current_word_index, #self.words)

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

function Position:hidePositionIndicator()
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

return Position
