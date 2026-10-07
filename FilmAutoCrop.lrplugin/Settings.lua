-- Settings.lua: the options, kept in the plugin preferences, and their dialog

local LrBinding = import "LrBinding"
local LrColor = import "LrColor"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrPrefs = import "LrPrefs"
local LrView = import "LrView"

local M = {}

-- long side / short side; 0 = keep the detected frame's own proportions
M.ASPECTS = {
	{ title = "3:2 (35 mm, 6x9)", value = 1.5 },
	{ title = "4:3 (6x4.5, half frame)", value = 4 / 3 },
	{ title = "5:4 (6x7)", value = 1.25 },
	{ title = "1:1 (6x6)", value = 1 },
	{ title = "65:24 (XPan)", value = 65 / 24 },
	{ title = "As detected", value = 0 },
}

M.MODES = {
	{ title = "The picture", value = "picture" },
	{ title = "The film edge (keep the rebate)", value = "rebate" },
	{ title = "Nothing: only measure the NLP Border Buffer", value = "measure" },
}

M.DEFAULTS = {
	mode = "picture",
	aspect = 1.5,
	inset = 1.0,        -- % of the frame's short side, each side
	straighten = true,
	rollPrior = true,
	keystone = true,
	keystoneMin = 0.005, -- 0.5 % difference between opposite sides
	verify = true,
}

function M.load()
	local prefs = LrPrefs.prefsForPlugin()
	local s = {}
	for k, v in pairs(M.DEFAULTS) do
		if prefs[k] == nil then s[k] = v else s[k] = prefs[k] end
	end
	return s
end

function M.save(s)
	local prefs = LrPrefs.prefsForPlugin()
	for k in pairs(M.DEFAULTS) do prefs[k] = s[k] end
end

-- returns the chosen settings, or nil when cancelled
function M.dialog()
	local result
	LrFunctionContext.callWithContext("FilmAutoCropSettings", function(context)
		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)
		for k, v in pairs(M.load()) do props[k] = v end
		local bind = LrView.bind
		-- aspect and margin only apply to the picture crop
		local pictureMode = bind { key = "mode", transform = function(v) return v == "picture" end }

		local contents = f:column {
			bind_to_object = props,
			spacing = f:control_spacing(),
			f:row {
				f:static_text { title = "Crop to:", width = LrView.share "label" },
				f:popup_menu { items = M.MODES, value = bind "mode", width_in_chars = 30 },
			},
			f:row {
				f:static_text { title = "Aspect ratio:", width = LrView.share "label" },
				f:popup_menu { items = M.ASPECTS, value = bind "aspect", width_in_chars = 22, enabled = pictureMode },
			},
			f:row {
				f:static_text { title = "Safety margin:", width = LrView.share "label" },
				f:slider { value = bind "inset", min = 0, max = 5, integral = false, width_in_chars = 16,
					enabled = pictureMode },
				f:edit_field { value = bind "inset", precision = 1, min = 0, max = 5, width_in_chars = 4,
					enabled = pictureMode },
				f:static_text { title = "% of the frame" },
			},
			f:separator { fill_horizontal = 1 },
			f:checkbox { title = "Straighten (follow the frame's rotation)", value = bind "straighten" },
			f:checkbox { title = "Learn the frame size from the whole selection (one roll)", value = bind "rollPrior" },
			f:checkbox { title = "Correct keystone when the whole roll shows it", value = bind "keystone" },
			f:checkbox { title = "Check every crop afterwards for border left inside", value = bind "verify" },
			f:separator { fill_horizontal = 1 },
			f:static_text {
				title = "Works on negatives and positives, before or after Negative Lab Pro.\n"
					.. "Crop before converting. Each frame gets the Border Buffer NLP needs\n"
					.. "(Metadata panel, Film Auto-Crop): 0 % after a picture crop.\n"
					.. "The film-edge crop keeps the film's own shape (no aspect ratio, no margin).",
				text_color = LrColor(0.45, 0.45, 0.45),
			},
		}
		local answer = LrDialogs.presentModalDialog {
			title = "Film Auto-Crop", contents = contents, actionVerb = "Crop",
		}
		if answer == "ok" then
			result = {}
			for k in pairs(M.DEFAULTS) do result[k] = props[k] end
			M.save(result)
		end
	end)
	return result
end

return M
