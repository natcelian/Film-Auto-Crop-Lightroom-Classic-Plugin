-- Film Auto-Crop with the last settings, no dialog
local Settings = require "Settings"
local AutoCropLr = require "AutoCropLr"

AutoCropLr.run(Settings.load())
