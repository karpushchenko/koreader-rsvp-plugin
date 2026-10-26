-- Reader-facing controls and settings dialogs.
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("gettext")
local T = require("ffi/util").template
local Menu = {}

function Menu:addToMainMenu(menu_items)
    menu_items.fastreader = {
        text = _("FastReader"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Start/Stop RSVP"),
                callback = function()
                    self:toggleRSVP()
                end,
            },
            {
                text = _("Tap on Text to Launch RSVP"),
                checked_func = function()
                    return self.tap_to_launch_enabled
                end,
                callback = function()
                    self.tap_to_launch_enabled = not self.tap_to_launch_enabled
                    self:saveSettings()

                    if self.tap_to_launch_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("Tap-to-launch RSVP enabled. Tap on text to start RSVP reading."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Tap-to-launch RSVP disabled"),
                            timeout = 2,
                        })
                    end
                end,
                help_text = _("When enabled, tapping on text will automatically start RSVP reading without going through the menu."),
            },
            {
                text = _("Show Reading Position"),
                checked_func = function()
                    return self.show_position_indicator
                end,
                callback = function()
                    self.show_position_indicator = not self.show_position_indicator
                    self:saveSettings()

                    if self.show_position_indicator then
                        UIManager:show(InfoMessage:new{
                            text = _("Position indicator enabled. Shows reading progress when resuming."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Position indicator disabled"),
                            timeout = 2,
                        })
                    end
                end,
                help_text = _("When enabled, shows reading position indicator when resuming RSVP on the same page."),
            },
            {
                text = _("Optimal Alignment (OVP)"),
                checked_func = function()
                    return self.ovp_alignment_enabled
                end,
                callback = function()
                    self.ovp_alignment_enabled = not self.ovp_alignment_enabled
                    self:saveSettings()

                    if self.ovp_alignment_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("Optimal alignment enabled. Words align to the focus crosshair."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Optimal alignment disabled. Words center in the widget."),
                            timeout = 3,
                        })
                    end
                end,
                help_text = _("Aligns each word to its optimal recognition point and shows the subtle crosshair guide."),
            },
            {
                text_func = function()
                    return T(_("Preview Words: %1"), self.words_preview_count)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local spin_widget = SpinWidget:new{
                        title_text = _("RSVP Preview Words"),
                        info_text = _("Number of words to show in RSVP widget (1-10)"),
                        width = math.floor(Screen:getWidth() * 0.6),
                        value = self.words_preview_count,
                        value_min = 1,
                        value_max = 10,
                        value_step = 1,
                        value_hold_step = 2,
                        default_value = 3,
                        unit = _("words"),
                        callback = function(spin)
                            self.words_preview_count = spin.value
                            self:saveSettings()
                            touchmenu_instance:updateItems()
                            UIManager:show(InfoMessage:new{
                                text = T(_("Preview words set to %1"), self.words_preview_count),
                                timeout = 2,
                            })
                        end
                    }
                    UIManager:show(spin_widget)
                end,
                help_text = _("Controls how many words are shown in the RSVP widget. The current word is highlighted, upcoming words are dimmed."),
            },
            {
                text = _("RSVP Speed"),
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("Current: %1 WPM"), self.rsvp_speed)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                title_text = _("RSVP Reading Speed"),
                                info_text = _("Words per minute (50-1000)"),
                                width = math.floor(Screen:getWidth() * 0.6),
                                value = self.rsvp_speed,
                                value_min = 50,
                                value_max = 1000,
                                value_step = 25,
                                value_hold_step = 100,
                                default_value = 250,
                                unit = "WPM",
                                callback = function(spin)
                                    self.rsvp_speed = spin.value
                                    self:saveSettings()
                                    touchmenu_instance:updateItems()
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("RSVP speed set to %1 WPM"), self.rsvp_speed),
                                        timeout = 1,
                                    })
                                end
                            }
                            UIManager:show(spin_widget)
                        end,
                        separator = true,
                    },
                    {
                        text = _("100 WPM (Very slow)"),
                        callback = function()
                            self.rsvp_speed = 100
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 100 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("150 WPM (Slow)"),
                        callback = function()
                            self.rsvp_speed = 150
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 150 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("200 WPM (Normal)"),
                        callback = function()
                            self.rsvp_speed = 200
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 200 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("250 WPM (Fast)"),
                        callback = function()
                            self.rsvp_speed = 250
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 250 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("300 WPM (Very fast)"),
                        callback = function()
                            self.rsvp_speed = 300
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 300 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("400 WPM (Extreme)"),
                        callback = function()
                            self.rsvp_speed = 400
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 400 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("500 WPM (Ultra fast)"),
                        callback = function()
                            self.rsvp_speed = 500
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 500 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                },
            },
        },
    }
end

return Menu
