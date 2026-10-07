--[[ AutoCropCore.lua
Batch logic, kept free of Lightroom so I can test it outside: analyse each
frame, learn the roll's frame size from the clear ones, solve every frame
again with that size, crop, grade. AutoCropLr.lua does the Lightroom side.

settings: mode ("picture" | "rebate" | "measure"), aspect (0 = the frame's
own), inset, straighten, rollPrior, rebateInset, detect (FrameDetect options).
]]

local FrameDetect = require "FrameDetect"
local CropMath = require "CropMath"

local M = {}

local MAX_ANGLE = 5 -- degrees; a frame turned more than this gets a look

function M.median(t)
	local s = {}
	for i = 1, #t do s[i] = t[i] end
	table.sort(s)
	local n = #s
	if n == 0 then return nil end
	if n % 2 == 1 then return s[(n + 1) / 2] end
	return 0.5 * (s[n / 2] + s[n / 2 + 1])
end

-- one frame's pixels -> its candidates; the image is dropped afterwards, so
-- a batch holds one image at a time
function M.analyseItem(it, img, settings)
	local dopt = settings.detect or {}
	it.an = FrameDetect.analyse(img, dopt)
	it.det = FrameDetect.select(it.an, dopt)
	it.w, it.h = img.w, img.h
end

-- every analysed frame -> det, picture, crop, buffer, status ("ok" | "check"
-- | "skip"), reason
function M.finishBatch(items, settings)
	local dopt = settings.detect or {}

	-- the roll's frame size (long, short) from frames with four edges
	local longs, shorts = {}, {}
	for _, it in ipairs(items) do
		if it.det.edgesFound == 4 then
			local a, b = it.det.frameW, it.det.frameH
			longs[#longs + 1] = math.max(a, b)
			shorts[#shorts + 1] = math.min(a, b)
		end
	end
	local roll = nil
	if settings.rollPrior ~= false and #longs >= 5 then
		local L, S = M.median(longs), M.median(shorts)
		-- only a consistent roll (one camera, one scanning setup) gives a prior
		local dev = {}
		for i = 1, #longs do dev[i] = math.abs(longs[i] / L - 1) + math.abs(shorts[i] / S - 1) end
		if M.median(dev) <= 0.02 then roll = { long = L, short = S } end
	end

	local mode = settings.mode or "picture"
	for _, it in ipairs(items) do
		if roll then
			local o = {}
			for k, v in pairs(dopt) do o[k] = v end
			if it.w >= it.h then o.expectSize = { roll.long, roll.short }
			else o.expectSize = { roll.short, roll.long } end
			it.det = FrameDetect.select(it.an, o)
		end
		it.an = nil
		local d = it.det
		-- the whole picture: what the Border Buffer is measured against
		it.picture = CropMath.cropFromFrame(d, { aspect = 0, inset = 0, straighten = settings.straighten })
		if mode == "rebate" then
			it.film = FrameDetect.filmFrame(d, dopt)
			it.crop = CropMath.cropFromFrame(it.film, { aspect = 0, inset = settings.rebateInset or 0.003,
				straighten = settings.straighten })
		else
			it.crop = CropMath.cropFromFrame(d, settings)
		end
		if mode ~= "measure" then
			it.buffer = CropMath.borderBuffer(CropMath.quadPx(it.crop), it.picture)
		end
		if d.edgesFound <= 1 then
			it.status, it.reason = "skip", "no film frame found"
		elseif d.edgesFound == 2 then
			it.status, it.reason = "check", "only two frame edges found"
		elseif math.abs(d.angle) > MAX_ANGLE then
			it.status, it.reason = "check", "large rotation"
		else
			it.status = "ok"
		end
		d.candidates, d.selected = nil, nil
	end
end

return M
