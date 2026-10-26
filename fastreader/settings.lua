-- Persistent preferences. Preserve settings keys and defaults across releases.
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local Settings = {}

function Settings:load()
    self.settings_file = DataStorage:getSettingsDir() .. "/fastreader.lua"
    self.settings = LuaSettings:open(self.settings_file)
    self.tap_to_launch_enabled = self.settings:readSetting("tap_to_launch_enabled") or false
    self.rsvp_speed = self.settings:readSetting("rsvp_speed") or 250
    local ovp_setting = self.settings:readSetting("ovp_alignment_enabled")
    if ovp_setting == nil then
        self.ovp_alignment_enabled = true
    else
        self.ovp_alignment_enabled = ovp_setting
    end
    self.show_position_indicator = self.settings:readSetting("show_position_indicator") ~= false
    self.words_preview_count = self.settings:readSetting("words_preview_count") or 3
end

function Settings:saveSettings()
    if self.settings then
        self.settings:saveSetting("rsvp_speed", self.rsvp_speed)
        self.settings:saveSetting("tap_to_launch_enabled", self.tap_to_launch_enabled)
        self.settings:saveSetting("show_position_indicator", self.show_position_indicator)
        self.settings:saveSetting("words_preview_count", self.words_preview_count)
        self.settings:saveSetting("ovp_alignment_enabled", self.ovp_alignment_enabled)
        self.settings:flush()
    end
end

return Settings
