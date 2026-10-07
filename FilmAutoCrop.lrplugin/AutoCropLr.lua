--[[ AutoCropLr.lua
The Lightroom side. For the selected photos I:
  1. remember each crop and reset it (an export always renders the crop);
  2. export a small uncompressed TIFF of each, analyse it, delete it;
  3. if the whole roll shows the same keystone, find the Transform slider
     value on one frame by measuring (its maths is not documented), apply it
     to the roll and analyse again;
  4. crop (or, in "measure" mode, put the old crop back);
  5. in "picture" mode, export the crops again and look for border left;
  6. collect frames worth a look in "Film Auto-Crop: check";
  7. write each frame's NLP Border Buffer and status as plugin metadata.
I only ever write Crop* keys and, for keystone, two Perspective sliders.
]]

local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrExportSession = import "LrExportSession"
local LrFileUtils = import "LrFileUtils"
local LrFunctionContext = import "LrFunctionContext"
local LrPathUtils = import "LrPathUtils"
local LrProgressScope = import "LrProgressScope"
local LrTasks = import "LrTasks"
local LrLogger = import "LrLogger"

local TiffReader = require "TiffReader"
local FrameDetect = require "FrameDetect"
local CropMath = require "CropMath"
local Core = require "AutoCropCore"

local log = LrLogger("FilmAutoCrop")
log:enable("logfile")

local M = {}

local CHECK_COLLECTION = "Film Auto-Crop: check"
local ANALYSIS_LONG_EDGE = 1200
local RESET = { CropLeft = 0, CropTop = 0, CropRight = 1, CropBottom = 1, CropAngle = 0 }

local function exportSettings(folder)
	return {
		LR_export_destinationType = "specificFolder",
		LR_export_destinationPathPrefix = folder,
		LR_export_useSubfolder = false,
		LR_collisionHandling = "rename",
		LR_format = "TIFF",
		LR_tiff_compressionMethod = "compressionMethod_None",
		LR_export_bitDepth = 8,
		LR_export_colorSpace = "sRGB",
		LR_size_doConstrain = true,
		LR_size_doNotEnlarge = true,
		LR_size_resizeType = "longEdge",
		LR_size_maxWidth = ANALYSIS_LONG_EDGE,
		LR_size_maxHeight = ANALYSIS_LONG_EDGE,
		LR_size_units = "pixels",
		LR_size_resolution = 72,
		LR_size_resolutionUnits = "inch",
		LR_outputSharpeningOn = false,
		LR_useWatermark = false,
		LR_embeddedMetadataOption = "copyrightOnly",
		LR_minimizeEmbeddedMetadata = true,
		LR_removeLocationMetadata = true,
		LR_reimportExportedPhoto = false,
		LR_export_postProcessing = "doNothing",
		LR_includeVideoFiles = false,
		LR_renamingTokensOn = true,
		LR_tokens = "{{image_name}}",
		LR_extensionCase = "lowercase",
	}
end

-- exports photos and calls onImage(photo, img or nil, error) for each;
-- returns false when cancelled
local function exportAndRead(photos, folder, progress, portion, onImage)
	local session = LrExportSession { photosToExport = photos, exportSettings = exportSettings(folder) }
	for _, rendition in session:renditions { progressScope = progress, renderProgressPortion = portion, stopIfCanceled = true } do
		local ok, pathOrMsg = rendition:waitForRender()
		if ok then
			local data = LrFileUtils.readFile(pathOrMsg) -- safe with non-ASCII paths
			LrFileUtils.delete(pathOrMsg)
			local okp, img, err = pcall(TiffReader.parse, data or "")
			if not okp then img, err = nil, tostring(img) end
			onImage(rendition.photo, img, err)
		else
			onImage(rendition.photo, nil, pathOrMsg)
		end
		LrTasks.yield()
		if progress:isCanceled() then return false end
	end
	return true
end

local function exportOne(photo, folder, progress)
	local got
	exportAndRead({ photo }, folder, progress, 0, function(_, img) got = img end)
	return got
end

local function cropOf(ds)
	return {
		CropLeft = ds.CropLeft or 0, CropTop = ds.CropTop or 0,
		CropRight = ds.CropRight or 1, CropBottom = ds.CropBottom or 1,
		CropAngle = ds.CropAngle or 0,
	}
end

-------------------------------------------------------------------------------
-- keystone, per roll

-- the roll's keystone, when most frames share it and it is worth fixing
local function rollKeystone(items, settings)
	local out = {}
	for _, key in ipairs({ "keystoneV", "keystoneH" }) do
		local ks = {}
		for _, it in ipairs(items) do
			if it.det and it.det.edgesFound == 4 then ks[#ks + 1] = it.det[key] end
		end
		if #ks >= 3 then
			local m = Core.median(ks)
			local same = 0
			for _, k in ipairs(ks) do if (k > 0) == (m > 0) then same = same + 1 end end
			if math.abs(m) >= settings.keystoneMin and same / #ks >= 0.7 then out[key] = m end
		end
	end
	if next(out) then return out end
	return nil
end

-- the slider and the change that remove keystone `key` on one frame, or nil;
-- the photo is left as it was either way
local function calibrateSlider(catalog, photo, key, folder, progress)
	local function measure()
		local img = exportOne(photo, folder, progress)
		if not img then return nil end
		local d = FrameDetect.detect(img)
		if d.edgesFound < 4 then return nil end
		return d[key]
	end
	local function set(name, v)
		catalog:withWriteAccessDo("Film Auto-Crop: keystone", function()
			photo:applyDevelopSettings({ [name] = v }, "Film Auto-Crop: keystone")
		end, { timeout = 30 })
	end
	local k0 = measure()
	if not k0 then return nil end
	-- I probe both sliders and keep the one that moves this keystone most
	local best
	for _, name in ipairs({ "PerspectiveVertical", "PerspectiveHorizontal" }) do
		local s0 = photo:getDevelopSettings()[name] or 0
		local probe = 10
		set(name, s0 + probe)
		local k1 = measure()
		set(name, s0)
		if k1 then
			local slope = (k1 - k0) / probe
			if not best or math.abs(slope) > math.abs(best.slope) then
				best = { name = name, s0 = s0, slope = slope }
			end
		end
	end
	if not best or math.abs(best.slope) < 1e-5 then return nil end
	local function clamp(v) return math.max(-100, math.min(100, v)) end
	local s = clamp(best.s0 - k0 / best.slope)
	set(best.name, s)
	local k2 = measure()
	if not k2 or math.abs(k2) > 0.5 * math.abs(k0) then
		set(best.name, best.s0)
		log:info("keystone " .. key .. ": no improvement, reverted")
		return nil
	end
	local s3 = clamp(s - k2 / best.slope)
	set(best.name, s3)
	local k3 = measure()
	if not k3 or math.abs(k3) >= math.abs(k2) then
		set(best.name, s)
		s3 = s
	end
	set(best.name, best.s0) -- the whole roll, this photo included, gets it next
	log:info(string.format("keystone %s: %s %+0.1f (from %.4f)", key, best.name, s3 - best.s0, k0))
	return best.name, s3 - best.s0
end

-------------------------------------------------------------------------------

function M.run(settings)
	LrFunctionContext.postAsyncTaskWithContext("FilmAutoCrop", function(context)
		LrDialogs.attachErrorDialogToFunctionContext(context)
		local catalog = LrApplication.activeCatalog()
		local photos = {}
		for _, p in ipairs(catalog:getTargetPhotos()) do
			if p:getRawMetadata("fileFormat") ~= "VIDEO" then photos[#photos + 1] = p end
		end
		if #photos == 0 then return end

		local progress = LrProgressScope { title = "Film Auto-Crop", functionContext = context }
		local folder = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), "FilmAutoCrop-" .. tostring(os.time()))
		LrFileUtils.createAllDirectories(folder)
		context:addCleanupHandler(function() LrFileUtils.delete(folder) end)

		local mode = settings.mode or "picture"
		local core = {
			mode = mode,
			aspect = settings.aspect, inset = settings.inset / 100, straighten = settings.straighten,
			rollPrior = settings.rollPrior, rebateInset = 0.003,
			detect = { aspect = (settings.aspect > 0) and settings.aspect or 0 },
		}

		-- 1. remember, reset
		local items, byPhoto = {}, {}
		for i, p in ipairs(photos) do
			local ds = p:getDevelopSettings()
			items[i] = { photo = p, orig = cropOf(ds), orientation = ds.orientation or "AB",
				upright = (ds.PerspectiveUpright or 0) ~= 0 }
			byPhoto[p] = items[i]
		end
		catalog:withWriteAccessDo("Film Auto-Crop: reset crop", function()
			for _, it in ipairs(items) do it.photo:applyDevelopSettings(RESET, "Film Auto-Crop: reset crop") end
		end, { timeout = 60 })

		-- 2. analyse
		local function analyseAll(caption, portion)
			progress:setCaption(caption)
			for _, it in ipairs(items) do it.failed, it.det, it.an = nil, nil, nil end
			return exportAndRead(photos, folder, progress, portion, function(photo, img, err)
				local it = byPhoto[photo]
				if img then Core.analyseItem(it, img, core) else it.failed = err end
			end)
		end
		local completed = analyseAll("Reading frames", 0.6)

		-- 3. keystone (never in "measure" mode, which changes nothing)
		if completed and settings.keystone and mode ~= "measure" then
			local ks = rollKeystone(items, settings)
			if ks then
				local moves = {}
				for key, m in pairs(ks) do
					-- I calibrate on the frame closest to the roll's keystone
					local ref, bestd
					for _, it in ipairs(items) do
						if it.det and it.det.edgesFound == 4 and not it.upright then
							local d = math.abs(it.det[key] - m)
							if not bestd or d < bestd then ref, bestd = it, d end
						end
					end
					if ref then
						progress:setCaption("Measuring keystone")
						local name, delta = calibrateSlider(catalog, ref.photo, key, folder, progress)
						if name then moves[#moves + 1] = { name = name, delta = delta } end
					end
				end
				if #moves > 0 then
					catalog:withWriteAccessDo("Film Auto-Crop: keystone", function()
						for _, it in ipairs(items) do
							if not it.upright then
								local ds = it.photo:getDevelopSettings()
								local s = {}
								for _, mv in ipairs(moves) do
									s[mv.name] = math.max(-100, math.min(100, (ds[mv.name] or 0) + mv.delta))
								end
								it.photo:applyDevelopSettings(s, "Film Auto-Crop: keystone")
							end
						end
					end, { timeout = 60 })
					completed = analyseAll("Reading frames after keystone", 0.2)
				end
			end
		end

		if not completed then
			catalog:withWriteAccessDo("Film Auto-Crop: cancelled", function()
				for _, it in ipairs(items) do it.photo:applyDevelopSettings(it.orig, "Film Auto-Crop: cancelled") end
			end, { timeout = 60 })
			return
		end

		-- 4. crop
		local solvable = {}
		for _, it in ipairs(items) do if it.det then solvable[#solvable + 1] = it end end
		Core.finishBatch(solvable, core)
		catalog:withWriteAccessDo("Film Auto-Crop", function()
			for _, it in ipairs(items) do
				local s
				if it.det and it.status ~= "skip" and mode ~= "measure" then
					s = CropMath.toLightroom(it.crop, it.orientation)
				end
				if mode == "measure" and it.det and it.status ~= "skip" then
					-- the old crop goes back, and I measure the buffer against it
					it.photo:applyDevelopSettings(it.orig, "Film Auto-Crop: measured")
					local q = CropMath.fromLightroom(it.orig, it.orientation, it.w, it.h)
					local px = {}
					for i, pt in ipairs(q) do px[i] = { pt[1] * it.w - 0.5, pt[2] * it.h - 0.5 } end
					it.buffer = CropMath.borderBuffer(px, it.picture)
				elseif s then
					s.CropConstrainAspectRatio = (mode == "picture" and settings.aspect > 0)
					it.photo:applyDevelopSettings(s, "Film Auto-Crop")
				else
					it.photo:applyDevelopSettings(it.orig, "Film Auto-Crop: left as it was")
					it.status = it.status or "skip"
					it.reason = it.reason or it.failed or "could not be read"
				end
			end
		end, { timeout = 60 })

		-- 5. check (the other modes keep border on purpose)
		if settings.verify and mode == "picture" then
			local cropped = {}
			for _, it in ipairs(items) do if it.status == "ok" or it.status == "check" then cropped[#cropped + 1] = it.photo end end
			progress:setCaption("Checking crops")
			exportAndRead(cropped, folder, progress, 0.2, function(photo, img)
				local it = byPhoto[photo]
				if img then
					local sides = FrameDetect.residualBorder(img)
					if #sides > 0 then
						it.status = "check"
						it.reason = "border may remain: " .. table.concat(sides, "")
					end
				end
			end)
		end

		-- 6. tally
		local nOk, nCheck, nSkip = 0, 0, 0
		local toCheck = {}
		for _, it in ipairs(items) do
			if it.status == "ok" then nOk = nOk + 1
			elseif it.status == "check" then nCheck = nCheck + 1; toCheck[#toCheck + 1] = it.photo
			else nSkip = nSkip + 1; toCheck[#toCheck + 1] = it.photo end
			log:info(string.format("%s: %s %s", it.photo:getFormattedMetadata("fileName") or "?",
				tostring(it.status), it.reason or ""))
		end
		-- 7. Border Buffer, per frame and for the selection
		local buffers = {}
		for _, it in ipairs(items) do
			if it.buffer and it.status ~= "skip" then
				it.bufferSetting = CropMath.bufferSetting(it.buffer)
				buffers[#buffers + 1] = it.bufferSetting
			end
		end
		catalog:withWriteAccessDo("Film Auto-Crop: check collection", function()
			local col = catalog:createCollection(CHECK_COLLECTION, nil, true)
			col:removeAllPhotos()
			if #toCheck > 0 then col:addPhotos(toCheck) end
			for _, it in ipairs(items) do
				it.photo:setPropertyForPlugin(_PLUGIN, "nlpBorderBuffer",
					it.bufferSetting and string.format("%d %%", it.bufferSetting) or nil)
				it.photo:setPropertyForPlugin(_PLUGIN, "autoCropStatus",
					(it.status or "skip") .. (it.reason and (": " .. it.reason) or ""))
			end
		end, { timeout = 30 })
		progress:done()

		local verb = (mode == "measure") and "measured" or "cropped"
		local msg = string.format("%d %s.", nOk, verb)
		if nCheck > 0 then msg = msg .. string.format("\n%d %s but worth a look.", nCheck, verb) end
		if nSkip > 0 then msg = msg .. string.format("\n%d left as they were (no film frame found).", nSkip) end
		if nCheck + nSkip > 0 then msg = msg .. "\n\nThey are in the collection \"" .. CHECK_COLLECTION .. "\"." end
		if #buffers > 0 then
			local hi = 0
			for _, b in ipairs(buffers) do if b > hi then hi = b end end
			if hi == 0 then
				msg = msg .. "\n\nNegative Lab Pro Border Buffer: 0 % (no border left in the crops;"
					.. " NLP's default would leave picture out of its analysis)."
			else
				msg = msg .. string.format("\n\nNegative Lab Pro Border Buffer: %d %% for this selection"
					.. " (its widest border; each frame's own value is in the Metadata panel, Film Auto-Crop).", hi)
			end
		end
		LrDialogs.message("Film Auto-Crop", msg, "info")
	end)
end

return M
