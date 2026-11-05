-- RSVP overlay, text layout and fixation alignment.
local UIManager = require("ui/uimanager")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local GestureRange = require("ui/gesturerange")
local util = require("util")
local ok_input, InputContainer = pcall(require, "ui/widget/container/inputcontainer")
if not ok_input then
    InputContainer = require("ui/widget/inputcontainer")
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

function RSVPWidget:onKeyPress(key)
    if self.plugin:onKeyPress(key) then
        return true
    end
    return InputContainer.onKeyPress(self, key)
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

return RSVPWidget
