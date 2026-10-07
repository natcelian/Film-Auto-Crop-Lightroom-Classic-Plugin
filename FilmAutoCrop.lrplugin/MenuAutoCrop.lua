-- Library / File > Plug-in Extras > Film Auto-Crop...
local LrTasks = import "LrTasks"
local Settings = require "Settings"
local AutoCropLr = require "AutoCropLr"

LrTasks.startAsyncTask(function()
	local s = Settings.dialog()
	if s then AutoCropLr.run(s) end
end)
