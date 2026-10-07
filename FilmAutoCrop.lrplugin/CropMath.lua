--[[ CropMath.lua
From a detected frame to a crop, to Lightroom's crop settings, and to the
Border Buffer Negative Lab Pro needs. Pure Lua 5.1, no Lightroom calls.

Two frames: "visual" is the analysis export (orientation applied, pixel
centres at integers, y down); "stored" is the photo's pixel array before
orientation, where Lightroom's crop lives.

Lightroom's crop (John Ellis, Adobe forum, "SDK: computing the corners of a
crop rectangle"; darktable src/develop/lightroom.c agrees): CropLeft/Top is
the real upper-left corner and CropRight/Bottom the real lower-right one, in
the stored frame, 0..1; CropAngle turns the rectangle about its centre,
clockwise. I rotate in pixels, never in normalised units.
]]

local M = {}

local cos, sin, rad, min, max = math.cos, math.sin, math.rad, math.min, math.max

local function rot(x, y, a) -- clockwise on screen (y down) for a > 0
	local c, s = cos(a), sin(a)
	return x * c - y * s, x * s + y * c
end

--[[ cropFromFrame(det, opt) -> { cx, cy, W, H, angle, w, h, quad }
opt.aspect long/short ratio to impose (1.5 = 3:2), 0 = the frame's own;
opt.inset margin per side, share of the frame's short side;
opt.straighten follow the frame's rotation (default true).
quad: the four corners normalised to the export.
]]
function M.cropFromFrame(det, opt)
	opt = opt or {}
	local aspect = opt.aspect or 1.5
	local inset = opt.inset or 0.01
	local straighten = (opt.straighten == nil) and true or opt.straighten
	local w, h = det.w, det.h
	local P = det.cornersPx
	local th = straighten and rad(det.angle) or 0

	-- frame centre, then the corners turned back by the angle
	local cx = (P.tl[1] + P.tr[1] + P.br[1] + P.bl[1]) / 4
	local cy = (P.tl[2] + P.tr[2] + P.br[2] + P.bl[2]) / 4
	local q = {}
	for _, k in ipairs({ "tl", "tr", "br", "bl" }) do
		local x, y = rot(P[k][1] - cx, P[k][2] - cy, -th)
		q[k] = { x, y }
	end
	-- largest axis-aligned rectangle inside the near-rectangular quad
	local x0 = max(q.tl[1], q.bl[1])
	local x1 = min(q.tr[1], q.br[1])
	local y0 = max(q.tl[2], q.tr[2])
	local y1 = min(q.bl[2], q.br[2])

	local m = inset * min(x1 - x0, y1 - y0)
	local E = det.edges or {}
	local function bulge(s) return (E[s] and E[s].found and E[s].bulge) or 0 end
	x0, x1 = x0 + m + bulge("L"), x1 - m - bulge("R")
	y0, y1 = y0 + m + bulge("T"), y1 - m - bulge("B")
	local W, H = x1 - x0, y1 - y0
	local ox, oy = (x0 + x1) / 2, (y0 + y1) / 2

	if aspect and aspect > 0 then
		local r = (W >= H) and aspect or 1 / aspect
		if W / H > r then W = H * r else H = W / r end
	end

	local dx, dy = rot(ox, oy, th)
	local ccx, ccy = cx + dx, cy + dy

	-- keep the turned rectangle inside the image (Lightroom would clamp it)
	local s = 1
	for _, sg in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
		local ux, uy = rot(sg[1] * W / 2, sg[2] * H / 2, th)
		local lx, hx, ly, hy = -0.5 - ccx, w - 0.5 - ccx, -0.5 - ccy, h - 0.5 - ccy
		if ux < lx then s = min(s, lx / ux) end
		if ux > hx then s = min(s, hx / ux) end
		if uy < ly then s = min(s, ly / uy) end
		if uy > hy then s = min(s, hy / uy) end
	end
	W, H = W * s, H * s

	local quad = {}
	for i, sg in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
		local ux, uy = rot(sg[1] * W / 2, sg[2] * H / 2, th)
		quad[i] = { (ccx + ux + 0.5) / w, (ccy + uy + 0.5) / h }
	end
	return { cx = ccx, cy = ccy, W = W, H = H, angle = th * 180 / math.pi, w = w, h = h, quad = quad }
end

-- visual point -> stored point (both normalised), per orientation code (the
-- two letters along the bottom edge; AB = as stored)
local toStored = {
	AB = function(x, y) return x, y end,
	BC = function(x, y) return y, 1 - x end,
	CD = function(x, y) return 1 - x, 1 - y end,
	DA = function(x, y) return 1 - y, x end,
	BA = function(x, y) return 1 - x, y end,
	DC = function(x, y) return x, 1 - y end,
	AD = function(x, y) return y, x end,
	CB = function(x, y) return 1 - y, 1 - x end,
}
local mirrored = { BA = true, DC = true, AD = true, CB = true }
local quarterTurn = { BC = true, DA = true, AD = true, CB = true }

-- toLightroom(crop, orientation) -> crop settings. Only proportions matter,
-- so I take the stored frame as the export with width and height swapped on
-- a quarter turn.
function M.toLightroom(crop, orientation)
	orientation = orientation or "AB"
	local f = toStored[orientation]
	if not f then return nil, "unknown orientation " .. tostring(orientation) end
	local vw, vh = crop.w, crop.h
	local sw, sh = vw, vh
	if quarterTurn[orientation] then sw, sh = vh, vw end
	local nx, ny = f((crop.cx + 0.5) / vw, (crop.cy + 0.5) / vh)
	local scx, scy = nx * sw, ny * sh
	local W, H = crop.W, crop.H
	if quarterTurn[orientation] then W, H = crop.H, crop.W end
	local a = crop.angle
	if mirrored[orientation] then a = -a end
	local th = rad(a)
	local ulx, uly = rot(-W / 2, -H / 2, th)
	local lrx, lry = rot(W / 2, H / 2, th)
	return {
		CropLeft = (scx + ulx) / sw,
		CropTop = (scy + uly) / sh,
		CropRight = (scx + lrx) / sw,
		CropBottom = (scy + lry) / sh,
		CropAngle = a,
	}
end

-- fromLightroom(settings, orientation, vw, vh) -> the crop's four corners,
-- visual, normalised: the inverse of toLightroom
function M.fromLightroom(d, orientation, vw, vh)
	local sw, sh = vw, vh
	if quarterTurn[orientation] then sw, sh = vh, vw end
	local th = rad(d.CropAngle or 0)
	local ulx, uly = d.CropLeft * sw, d.CropTop * sh
	local lrx, lry = d.CropRight * sw, d.CropBottom * sh
	local cx, cy = (ulx + lrx) / 2, (uly + lry) / 2
	-- level the diagonal to get W, H back
	local ax, ay = rot(ulx - cx, uly - cy, -th)
	local W, H = -2 * ax, -2 * ay
	local inv = { AB = "AB", BC = "DA", CD = "CD", DA = "BC", BA = "BA", DC = "DC", AD = "AD", CB = "CB" }
	local g = toStored[inv[orientation]]
	local out = {}
	for i, sg in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
		local px, py = rot(sg[1] * W / 2, sg[2] * H / 2, th)
		local x, y = g((cx + px) / sw, (cy + py) / sh)
		out[i] = { x, y }
	end
	return out
end

-- a crop's corners in export pixels
function M.quadPx(crop)
	local out = {}
	for i, q in ipairs(crop.quad) do out[i] = { q[1] * crop.w - 0.5, q[2] * crop.h - 0.5 } end
	return out
end

--[[ borderBuffer(quadPx, picture) -> { L, R, T, B, max } in %
How much non-picture a crop holds on each side, as a share of the crop's
size across that side. quadPx: the crop's corners in export pixels, any
order; picture: the picture's rectangle (cropFromFrame, aspect 0, inset 0).
]]
function M.borderBuffer(quadPx, picture)
	local th = rad(picture.angle)
	local x0, x1, y0, y1 = 1e18, -1e18, 1e18, -1e18
	for _, p in ipairs(quadPx) do
		local x, y = rot(p[1] - picture.cx, p[2] - picture.cy, -th)
		x0, x1 = min(x0, x), max(x1, x)
		y0, y1 = min(y0, y), max(y1, y)
	end
	local W, H = x1 - x0, y1 - y0
	local pw, ph = picture.W / 2, picture.H / 2
	local b = {
		L = max(0, -pw - x0) / W * 100,
		R = max(0, x1 - pw) / W * 100,
		T = max(0, -ph - y0) / H * 100,
		B = max(0, y1 - ph) / H * 100,
	}
	b.max = max(b.L, b.R, b.T, b.B)
	return b
end

-- the value to type into Negative Lab Pro: whole percent, rounded up, half a
-- percent to spare; 0 when the crop holds no border
function M.bufferSetting(b)
	if b.max < 0.05 then return 0 end
	return math.ceil(b.max + 0.5)
end

return M
