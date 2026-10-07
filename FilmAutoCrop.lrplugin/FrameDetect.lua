--[[ FrameDetect.lua
Finds the picture of a scanned film frame as four straight edges. Pure Lua
5.1 with no Lightroom calls, so I can test it outside Lightroom.

Per side of the scan:
  1. I search every scanline from the scan edge inward for gradient maxima
     (|dR|+|dG|+|dB| on a 3x3-smoothed image), keeping the step's sign;
  2. a Hough vote over near-axis lines, one per sign, gives straight-edge
     candidates, refitted by least squares;
  3. I describe each candidate: coverage, colour step, and how uniform the
     band outside it is (rebate, holder and scan bed are; picture is not).
Then I score every combination of one candidate per side (or "none": the
frame runs off the scan) as a frame and keep the best.

The sign of a step is kept, never assumed, so negatives, slides, converted
positives and opaque holders all work.

Coordinates: pixel centres at integers, x right, y down; normalised corners
are X = (x + 0.5) / w, Y = (y + 0.5) / h.
]]

local M = {}

local floor, abs, max, min, sqrt, atan, deg =
	math.floor, math.abs, math.max, math.min, math.sqrt, math.atan, math.deg
local tsort = table.sort

M.defaults = {
	searchDepth = 0.30,   -- share of each dimension searched from each side
	maxAngle = 6.0,       -- degrees, largest rotation looked for
	angleStep = 0.1,      -- degrees, Hough slope resolution
	pointsPerLine = 5,    -- strongest gradient maxima kept per scanline
	minGradient = 6,      -- 0..255 units summed over RGB: below this is noise
	minCoverage = 0.25,   -- a candidate must cross this share of scanlines
	candidatesPerSide = 6,
	aspect = 1.5,         -- frame long/short side prior; 0 or nil = none
	minFrameShare = 0.35, -- frame must cover this share of each scan dimension
	bandWidth = 0.006,    -- width of the bands compared either side of an edge
	maxRebate = 0.07,     -- widest rebate/holder band between two nested edges
	plateauTolerance = 36, -- colour match (RGB sum, 0..255) across a rebate plateau
	bulgeWindow = 0.012,  -- how far inside a line I look for a bowed edge
	reslopeCoverage = 0.6, -- below this coverage an edge takes the frame's angle
	parallelSlope = 0.005, -- nested strong edges count as parallel within this slope
	baseTolerance = 0.12, -- film-base colour match for the keep-rebate crop (share of RGB sum)
	baseMin = 0.04,       -- film base is brighter than this (holder black) ...
	baseMax = 0.88,       -- ... and darker than this (scan bed, light) in the render
	uniformVar = 2.5,     -- band counts as uniform below this step-to-step change
	uniformSpread = 45,   -- ... and below this 10-90 % colour range along the edge
	sizeTolerance = 0.03, -- expected-size prior width (log), when expectSize is given
	residualDepth = 0.06, -- check of an applied crop: depth searched per side
	residualStep = 40,    -- ... and the colour step that counts as a border
}

-------------------------------------------------------------------------------
-- image preparation

local function smooth3(src, w, h)
	local tmp, dst = {}, {}
	for y = 0, h - 1 do
		local row = y * w
		tmp[row + 1] = (2 * src[row + 1] + src[row + 2]) / 3
		for x = 2, w - 1 do
			local i = row + x
			tmp[i] = (src[i - 1] + src[i] + src[i + 1]) / 3
		end
		tmp[row + w] = (src[row + w - 1] + 2 * src[row + w]) / 3
	end
	for y = 0, h - 1 do
		local row = y * w
		local up = (y > 0) and -w or 0
		local dn = (y < h - 1) and w or 0
		for x = 1, w do
			local i = row + x
			dst[i] = (tmp[i + up] + tmp[i] + tmp[i + dn]) / 3
		end
	end
	return dst
end

-- scanline k and depth p (both 0-based, p from the scan edge) map to the
-- array index base(k) + p * stride
local function sideGeometry(side, w, h)
	if side == "L" then
		return h, w, function(k) return k * w + 1 end, 1
	elseif side == "R" then
		return h, w, function(k) return k * w + w end, -1
	elseif side == "T" then
		return w, h, function(k) return k + 1 end, w
	else
		return w, h, function(k) return (h - 1) * w + k + 1 end, -w
	end
end

-------------------------------------------------------------------------------
-- step 1: edge points

local function edgePoints(img, side, opt)
	local w, h = img.w, img.h
	local R, G, B = img.sr, img.sg, img.sb
	local nScan, depthMax, base, stride = sideGeometry(side, w, h)
	local D = floor(depthMax * opt.searchDepth)
	local k0 = floor(nScan * 0.03)
	local pts = {}
	local m = {}
	local s = {}
	for k = k0, nScan - 1 - k0 do
		local b0 = base(k)
		for p = 1, D - 1 do
			local i = b0 + p * stride
			local dr = R[i + stride] - R[i - stride]
			local dg = G[i + stride] - G[i - stride]
			local db = B[i + stride] - B[i - stride]
			m[p] = abs(dr) + abs(dg) + abs(db)
			s[p] = dr + dg + db
		end
		m[0], m[D] = 0, 0
		local found = {}
		for p = 1, D - 1 do
			local v = m[p]
			if v >= opt.minGradient and v >= m[p - 1] and v > m[p + 1] then
				found[#found + 1] = p
			end
		end
		if #found > opt.pointsPerLine then
			tsort(found, function(a, b2) return m[a] > m[b2] end)
		end
		for j = 1, min(#found, opt.pointsPerLine) do
			local p = found[j]
			local den = m[p - 1] - 2 * m[p] + m[p + 1]
			local off = 0
			if den < 0 then off = 0.5 * (m[p - 1] - m[p + 1]) / den end
			pts[#pts + 1] = { k = k, p = p + off, w = m[p], sgn = (s[p] >= 0) and 1 or -1 }
		end
	end
	return pts, { nScan = nScan, depthMax = depthMax, D = D, k0 = k0, kc = (nScan - 1) / 2,
		nUsed = nScan - 2 * k0, base = base, stride = stride }
end

-------------------------------------------------------------------------------
-- step 2: Hough vote and refit

local function fitLine(pts, kc)
	local sw, sk, sp, skk, skp = 0, 0, 0, 0, 0
	for i = 1, #pts do
		local q = pts[i]
		local wt = q.w
		local dk = q.k - kc
		sw = sw + wt; sk = sk + wt * dk; sp = sp + wt * q.p
		skk = skk + wt * dk * dk; skp = skp + wt * dk * q.p
	end
	local den = sw * skk - sk * sk
	if sw <= 0 or abs(den) < 1e-9 then return nil end
	local b = (sw * skp - sk * sp) / den
	local a = (sp - b * sk) / sw
	return a, b
end

local function houghCandidates(pts, geo, opt)
	local kc, D = geo.kc, geo.D
	local tmax = math.tan(math.rad(opt.maxAngle))
	local nb = floor(opt.maxAngle / opt.angleStep + 0.5)
	local slopes = {}
	for j = -nb, nb do slopes[#slopes + 1] = j * tmax / nb end
	local NS = #slopes

	local cands = {}
	for _, sgn in ipairs({ 1, -1 }) do
		-- accumulator: acc[(j-1)*(D+2) + bin + 1]
		local acc = {}
		local stride = D + 2
		for i = 1, NS * stride do acc[i] = 0 end
		local mine = {}
		for i = 1, #pts do
			local q = pts[i]
			if q.sgn == sgn then
				mine[#mine + 1] = q
				local dk = q.k - kc
				for j = 1, NS do
					local a = q.p - slopes[j] * dk
					if a >= 0 and a <= D then
						local bin = floor(a + 0.5)
						local ix = (j - 1) * stride + bin + 1
						acc[ix] = acc[ix] + 1
					end
				end
			end
		end
		-- peaks, pooling neighbours (a line straddles two bins)
		local need = opt.minCoverage * geo.nUsed * 0.6
		for _ = 1, opt.candidatesPerSide do
			local best, bj, bbin = need, nil, nil
			for j = 1, NS do
				local row = (j - 1) * stride
				for bin = 1, D - 1 do
					local v = acc[row + bin + 1] + 0.5 * (acc[row + bin] + acc[row + bin + 2])
					if v > best then best, bj, bbin = v, j, bin end
				end
			end
			if not bj then break end
			-- refit on inliers, tightening
			local a0, b0 = bbin, slopes[bj]
			local a, b = a0, b0
			local tol = 1.5
			local inl
			for _ = 1, 3 do
				inl = {}
				for i = 1, #mine do
					local q = mine[i]
					if not q.used and abs(q.p - (a + b * (q.k - kc))) <= tol then inl[#inl + 1] = q end
				end
				local na, nb2 = fitLine(inl, kc)
				if not na then break end
				a, b = na, nb2
				tol = 1.0
			end
			cands[#cands + 1] = { a = a, b = b, sgn = sgn, inliers = inl }
			-- I take this line's points out of the vote, so the next peak is
			-- another edge
			for i = 1, #mine do
				local q = mine[i]
				local dk = q.k - kc
				if not q.used and (abs(q.p - (a + b * dk)) <= 2 or abs(q.p - (a0 + b0 * dk)) <= 2) then
					q.used = true
					for j = 1, NS do
						local av = q.p - slopes[j] * dk
						if av >= 0 and av <= D then
							local ix = (j - 1) * stride + floor(av + 0.5) + 1
							acc[ix] = acc[ix] - 1
						end
					end
				end
			end
			local row = (bj - 1) * stride
			for bin = max(0, bbin - 1), min(D, bbin + 1) do acc[row + bin + 1] = 0 end
		end
	end
	return cands
end

-------------------------------------------------------------------------------
-- step 3: describe a candidate

local function median(t)
	local n = #t
	if n == 0 then return 0 end
	tsort(t)
	if n % 2 == 1 then return t[(n + 1) / 2] end
	return 0.5 * (t[n / 2] + t[n / 2 + 1])
end

local function describe(img, geo, c, opt)
	local R, G, B = img.sr, img.sg, img.sb
	local kc = geo.kc
	-- coverage: distinct scanlines with an inlier, overall and per quarter
	local seen, nSeen = {}, 0
	local quarter = { 0, 0, 0, 0 }
	local span = geo.nUsed
	for i = 1, #c.inliers do
		local k = c.inliers[i].k
		if not seen[k] then
			seen[k] = true
			nSeen = nSeen + 1
			local q = floor((k - geo.k0) / span * 4) + 1
			if q < 1 then q = 1 elseif q > 4 then q = 4 end
			quarter[q] = quarter[q] + 1
		end
	end
	c.coverage = nSeen / span
	local nq = 0
	for q = 1, 4 do if quarter[q] / (span / 4) >= 0.1 then nq = nq + 1 end end
	c.quarters = nq

	-- bands either side of the line, every 2nd scanline
	local bw = max(3, floor(geo.depthMax * opt.bandWidth))
	local gap = 3
	local inner = { {}, {}, {} }
	local steps, outVar, inVar = {}, {}, {}
	local prevO, prevI
	local outer = { {}, {}, {} }
	for k = geo.k0, geo.nScan - 1 - geo.k0, 2 do
		local p0 = c.a + c.b * (k - kc)
		local b0 = geo.base(k)
		local oLo, oHi = floor(p0 - gap - bw + 0.5), floor(p0 - gap + 0.5)
		local iLo, iHi = floor(p0 + gap + 0.5), floor(p0 + gap + bw + 0.5)
		if oLo < 0 then oLo = 0 end
		if iHi > geo.depthMax - 1 then iHi = geo.depthMax - 1 end
		if oHi > geo.depthMax - 1 then oHi = geo.depthMax - 1 end
		if iLo < 0 then iLo = 0 end
		local o, i3 = nil, nil
		if oHi >= oLo then
			local sr, sg, sb, n = 0, 0, 0, 0
			for p = oLo, oHi do
				local ix = b0 + p * geo.stride
				sr = sr + R[ix]; sg = sg + G[ix]; sb = sb + B[ix]; n = n + 1
			end
			o = { sr / n, sg / n, sb / n }
			outer[1][#outer[1] + 1] = o[1]; outer[2][#outer[2] + 1] = o[2]; outer[3][#outer[3] + 1] = o[3]
		end
		if iHi >= iLo then
			local sr, sg, sb, n = 0, 0, 0, 0
			for p = iLo, iHi do
				local ix = b0 + p * geo.stride
				sr = sr + R[ix]; sg = sg + G[ix]; sb = sb + B[ix]; n = n + 1
			end
			i3 = { sr / n, sg / n, sb / n }
			inner[1][#inner[1] + 1] = i3[1]; inner[2][#inner[2] + 1] = i3[2]; inner[3][#inner[3] + 1] = i3[3]
		end
		if o and i3 then
			steps[#steps + 1] = abs(i3[1] - o[1]) + abs(i3[2] - o[2]) + abs(i3[3] - o[3])
		end
		if o and prevO then
			outVar[#outVar + 1] = abs(o[1] - prevO[1]) + abs(o[2] - prevO[2]) + abs(o[3] - prevO[3])
		end
		if i3 and prevI then
			inVar[#inVar + 1] = abs(i3[1] - prevI[1]) + abs(i3[2] - prevI[2]) + abs(i3[3] - prevI[3])
		end
		prevO, prevI = o, i3
	end
	c.step = median(steps)
	c.outerVar = (#outVar > 0) and median(outVar) or nil
	c.innerVar = median(inVar)
	if #outer[1] > 0 then
		-- spread of the outer band along the edge, 10-90 % range
		local spread = 0
		for ch = 1, 3 do
			local t = outer[ch]
			tsort(t)
			local lo = t[max(1, floor(#t * 0.1 + 0.5))]
			local hi = t[max(1, floor(#t * 0.9 + 0.5))]
			spread = spread + (hi - lo)
		end
		c.outerSpread = spread
		c.outerColour = { median(outer[1]), median(outer[2]), median(outer[3]) }
	end
	if #inner[1] > 0 then
		c.innerColour = { median(inner[1]), median(inner[2]), median(inner[3]) }
	end

	-- bulge: film edges bow. Per scanline I find the strongest same-sign
	-- gradient just inside the line; the 90th percentile of how far in it
	-- lies is added to the crop's margin on that side.
	local ws = {}
	local sk, sp, sw = 0, 0, 0
	for i = 1, #c.inliers do
		local q = c.inliers[i]
		ws[i] = q.w
		sk = sk + q.w * q.k; sp = sp + q.w * q.p; sw = sw + q.w
	end
	if sw > 0 then c.kbar, c.pbar = sk / sw, sp / sw end
	local wmed = median(ws)
	local devs = {}
	local win = max(3, floor(geo.depthMax * opt.bulgeWindow))
	for k = geo.k0, geo.nScan - 1 - geo.k0, 2 do
		local p0 = c.a + c.b * (k - kc)
		local b0 = geo.base(k)
		local bestM, bestP = 0, nil
		for p = max(1, floor(p0 - 2)), min(geo.depthMax - 2, floor(p0 + win)) do
			local ix = b0 + p * geo.stride
			local st = geo.stride
			local dr = R[ix + st] - R[ix - st]
			local dg = G[ix + st] - G[ix - st]
			local db = B[ix + st] - B[ix - st]
			if (dr + dg + db) * c.sgn > 0 then
				local m = abs(dr) + abs(dg) + abs(db)
				if m > bestM then bestM, bestP = m, p end
			end
		end
		if bestP and bestM >= 0.35 * wmed then
			devs[#devs + 1] = max(0, bestP - p0)
		end
	end
	c.bulge = 0
	if #devs >= 10 then
		tsort(devs)
		c.bulge = devs[max(1, floor(#devs * 0.9 + 0.5))]
	end
	c.inliers = nil
	return c
end

-------------------------------------------------------------------------------
-- side quality, frame scoring

local function sideScore(c)
	if c.none then return 0.35 end
	local cov = min(c.coverage, 1)
	local q = (c.quarters >= 3) and 1 or ((c.quarters == 2) and 0.6 or 0.2)
	-- outside a real frame edge, the band is uniform along the edge
	local flat = 1
	if c.outerVar then
		flat = (c.innerVar + 1) / (c.outerVar + c.innerVar + 2) * 2 -- 1 when equal, up to 2
		local spreadPen = 1 / (1 + (c.outerSpread or 0) / 60)
		flat = flat * spreadPen
	end
	local contrast = max(0.1, min(c.step / 50, 1))
	return cov * q * contrast * flat
end

-- side-local line p = a + b (k - kc) in image coordinates:
-- vertical sides x = X0 + SX (y - yc), horizontal sides y = Y0 + SY (x - xc)
local function toImageLine(side, c, w, h)
	if side == "L" then return c.a, c.b
	elseif side == "R" then return (w - 1) - c.a, -c.b
	elseif side == "T" then return c.a, c.b
	else return (h - 1) - c.a, -c.b end
end

local function intersect(vx0, vsx, hy0, hsy, xc, yc)
	local x = (vx0 + vsx * (hy0 - hsy * xc - yc)) / (1 - vsx * hsy)
	local y = hy0 + hsy * (x - xc)
	return x, y
end

local function frameFrom(sel, w, h)
	local xc, yc = (w - 1) / 2, (h - 1) / 2
	local L0, Ls = toImageLine("L", sel.L, w, h)
	local R0, Rs = toImageLine("R", sel.R, w, h)
	local T0, Ts = toImageLine("T", sel.T, w, h)
	local B0, Bs = toImageLine("B", sel.B, w, h)
	local tl = { intersect(L0, Ls, T0, Ts, xc, yc) }
	local tr = { intersect(R0, Rs, T0, Ts, xc, yc) }
	local br = { intersect(R0, Rs, B0, Bs, xc, yc) }
	local bl = { intersect(L0, Ls, B0, Bs, xc, yc) }
	return { tl = tl, tr = tr, br = br, bl = bl, slopes = { L = Ls, R = Rs, T = Ts, B = Bs } }
end

local function frameScore(sel, w, h, opt)
	local f = frameFrom(sel, w, h)
	local width = 0.5 * ((f.tr[1] - f.tl[1]) + (f.br[1] - f.bl[1]))
	local height = 0.5 * ((f.bl[2] - f.tl[2]) + (f.br[2] - f.tr[2]))
	if width < opt.minFrameShare * w or height < opt.minFrameShare * h then return -1e9, f end
	-- the edges of one frame share one angle (loosely: holder edges may not)
	local angs = {}
	local function add(side, s) if not sel[side].none then angs[#angs + 1] = s end end
	add("L", -f.slopes.L); add("R", -f.slopes.R); add("T", f.slopes.T); add("B", f.slopes.B)
	local spread = 0
	if #angs >= 2 then
		local lo, hi = 1e9, -1e9
		for i = 1, #angs do lo = min(lo, angs[i]); hi = max(hi, angs[i]) end
		spread = deg(atan(hi - lo))
	end
	local anglePen = 1 / (1 + (spread / 2.0) ^ 2)
	-- aspect prior, either orientation
	local aspPen = 1
	if opt.aspect and opt.aspect > 0 then
		local r = max(width, height) / min(width, height)
		local d = math.log(r / opt.aspect)
		aspPen = math.exp(-(d / 0.15) ^ 2)
		aspPen = 0.5 + 0.5 * aspPen
		-- a frame bounded by rebate can come out short (bad advance, holder)
		if sel.L.confirmed or sel.R.confirmed or sel.T.confirmed or sel.B.confirmed then
			aspPen = max(aspPen, 0.85)
		end
	end
	local s = 0
	for _, side in ipairs({ "L", "R", "T", "B" }) do s = s + sel[side].score end
	return s * anglePen * aspPen, f
end

-------------------------------------------------------------------------------
-- entry points

local function options(o)
	local opt = {}
	for k, v in pairs(M.defaults) do opt[k] = v end
	for k, v in pairs(o or {}) do opt[k] = v end
	return opt
end

-- analyse: the candidates of each side (the part that reads pixels)
function M.analyse(img, o)
	local opt = options(o)
	local w, h = img.w, img.h
	img.sr = img.sr or smooth3(img.r, w, h)
	img.sg = img.sg or smooth3(img.g, w, h)
	img.sb = img.sb or smooth3(img.b, w, h)

	local perSide = {}
	for _, side in ipairs({ "L", "R", "T", "B" }) do
		local pts, geo = edgePoints(img, side, opt)
		local cands = houghCandidates(pts, geo, opt)
		local list = {}
		for _, c in ipairs(cands) do
			describe(img, geo, c, opt)
			-- a line hugging the scan's edge is the smoothing's border, not an
			-- edge: "none" covers that case
			if c.coverage >= opt.minCoverage and c.quarters >= 2 and c.a >= 2.5 then
				c.score = sideScore(c)
				list[#list + 1] = c
			end
		end
		-- rebate plateau: an outer edge Y whose inside matches the outside of
		-- an inner edge X, within a rebate's width, means the band between
		-- them is rebate or holder. Y is not the picture edge, and X (often
		-- patchy, as a negative's shadows fade into the base) takes Y's credit.
		local rebateMax = opt.maxRebate * geo.depthMax
		for _, x in ipairs(list) do
			for _, y in ipairs(list) do
				if y ~= x and y.a < x.a - 2 and x.a - y.a <= rebateMax and y.coverage >= 0.5
					and y.step >= opt.residualStep and x.step >= 0.5 * opt.residualStep
					and x.outerColour and y.innerColour and x.outerVar and x.outerVar <= opt.uniformVar then
					local d = abs(x.outerColour[1] - y.innerColour[1]) + abs(x.outerColour[2] - y.innerColour[2])
						+ abs(x.outerColour[3] - y.innerColour[3])
					if d <= opt.plateauTolerance then
						y.superseded = true
						-- only a real edge takes the credit, not a faint line in sky
						if x.step >= opt.residualStep and (x.coverage >= 0.5 or x.step >= 2.5 * opt.residualStep) then
							x.confirmed = true
							x.score = max(x.score, 0.8 * y.score, 0.6)
						end
					end
				end
			end
		end
		-- two strong parallel edges within a rebate's width: what lies between
		-- (a light leak, an uneven rebate) is not picture, so the inner one wins
		local function strong(c) return c.coverage >= 0.7 and c.quarters == 4 and c.step >= 2 * opt.residualStep end
		for _, x in ipairs(list) do
			for _, y in ipairs(list) do
				if y ~= x and strong(x) and strong(y) and y.a < x.a - 2 and x.a - y.a <= rebateMax
					and abs(x.b - y.b) <= opt.parallelSlope then
					y.superseded = true
					x.confirmed = true
					x.score = max(x.score, 0.8 * y.score, 0.6)
				end
			end
		end
		for _, c in ipairs(list) do
			if c.superseded then c.score = c.score * 0.25 end
		end
		-- "none" is unlikely on a side showing a long straight border edge
		local noneScore = sideScore({ none = true })
		for _, c in ipairs(list) do
			local uniformOutside = c.outerVar and c.outerVar <= opt.uniformVar
				and (c.outerSpread or 1e9) <= opt.uniformSpread and c.step >= opt.residualStep
			if c.coverage >= 0.8 and c.quarters == 4 and (uniformOutside or c.step >= 2 * opt.residualStep) then
				noneScore = 0.05
			end
		end
		list[#list + 1] = { none = true, a = 0, b = 0, score = noneScore }
		perSide[side] = list
	end
	return { w = w, h = h, perSide = perSide }
end

local function frameSize(f)
	return 0.5 * ((f.tr[1] - f.tl[1]) + (f.br[1] - f.bl[1])),
		0.5 * ((f.bl[2] - f.tl[2]) + (f.br[2] - f.tr[2]))
end

local toAngle = { L = -1, R = 1, T = 1, B = -1 } -- image angle t = sign * side-local b

-- select: the best frame from the candidates. opt.expectSize = { W, H } (export
-- pixels, e.g. the roll's median frame) adds a size prior.
function M.select(an, o)
	local opt = options(o)
	local w, h, perSide = an.w, an.h, an.perSide
	-- the frame's angle comes from its well-supported edges; an edge seen over
	-- only part of its length keeps its position but takes that angle
	local ts = {}
	for side, list in pairs(perSide) do
		for _, c in ipairs(list) do
			if not c.none and not c.superseded and c.coverage >= 0.8 and c.quarters == 4 then
				ts[#ts + 1] = toAngle[side] * c.b
			end
		end
	end
	if #ts >= 2 then
		tsort(ts)
		local t = ts[floor((#ts + 1) / 2)]
		for side, list in pairs(perSide) do
			local kc = ((side == "L" or side == "R") and h or w) / 2 - 0.5
			for _, c in ipairs(list) do
				if not c.none and c.coverage < opt.reslopeCoverage and c.kbar and not c.resloped then
					local nb = toAngle[side] * t
					c.a = c.pbar - nb * (c.kbar - kc)
					c.b = nb
					c.resloped = true
				end
			end
		end
	end
	local best, bestF, bestSel = -1e18, nil, nil
	local S = { "L", "R", "T", "B" }
	local sel = {}
	local function rec(i)
		if i > 4 then
			local sc, f = frameScore(sel, w, h, opt)
			if opt.expectSize and sc > -1e8 then
				local fw, fh = frameSize(f)
				-- a frame running off the scan, or bounded by rebate, may measure
				-- smaller than the roll's frame on that axis, never larger
				local dw, dh = math.log(fw / opt.expectSize[1]), math.log(fh / opt.expectSize[2])
				if sel.L.none or sel.R.none or sel.L.confirmed or sel.R.confirmed then dw = max(0, dw) end
				if sel.T.none or sel.B.none or sel.T.confirmed or sel.B.confirmed then dh = max(0, dh) end
				local pen = dw ^ 2 + dh ^ 2
				sc = sc * (0.3 + 0.7 * math.exp(-pen / (2 * opt.sizeTolerance ^ 2)))
			end
			if sc > best then
				best, bestF = sc, f
				bestSel = { L = sel.L, R = sel.R, T = sel.T, B = sel.B }
			end
			return
		end
		for _, c in ipairs(perSide[S[i]]) do
			sel[S[i]] = c
			rec(i + 1)
		end
	end
	rec(1)

	local f = bestF
	local function norm(pt) return { (pt[1] + 0.5) / w, (pt[2] + 0.5) / h } end
	-- rotation: mean angle of the found edges, degrees, clockwise on screen
	local sum, n = 0, 0
	local function add(side, s) if not bestSel[side].none then sum = sum + atan(s); n = n + 1 end end
	add("L", -f.slopes.L); add("R", -f.slopes.R); add("T", f.slopes.T); add("B", f.slopes.B)
	local angle = (n > 0) and deg(sum / n) or 0

	local edges = {}
	local nFound = 0
	for _, side in ipairs(S) do
		local c = bestSel[side]
		edges[side] = { found = not c.none, coverage = c.coverage, step = c.step, a = c.a, bulge = c.bulge or 0 }
		if not c.none then nFound = nFound + 1 end
	end
	local fw, fh = frameSize(f)
	-- keystone: relative length difference of opposite sides
	local function len(p, q) return sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2) end
	local kv, kh = 0, 0
	if edges.L.found and edges.R.found and edges.T.found and edges.B.found then
		kv = (len(f.tl, f.tr) - len(f.bl, f.br)) / fw
		kh = (len(f.tl, f.bl) - len(f.tr, f.br)) / fh
	end

	return {
		w = w, h = h,
		corners = { tl = norm(f.tl), tr = norm(f.tr), br = norm(f.br), bl = norm(f.bl) },
		cornersPx = { tl = f.tl, tr = f.tr, br = f.br, bl = f.bl },
		frameW = fw, frameH = fh,
		angle = angle,
		keystoneV = kv, keystoneH = kh,
		score = best,
		edges = edges,
		edgesFound = nFound,
		candidates = perSide,
		selected = bestSel,
	}
end

--[[ filmFrame(det, o): the film's own edges around the picture, for the
keep-rebate crop. The band just outside a picture edge is film base when it
is uniform and neither holder-black nor scan-bed white; I then go out to the
last edge that still has base colour inside it. Sides without base keep the
picture edge. A slide's black rebate looks like the holder, so nothing is
kept there.
]]
function M.filmFrame(det, o)
	local opt = options(o)
	local w, h = det.w, det.h
	local sel = det.selected
	local function isFilm(col)
		if not col then return false end
		local m = (col[1] + col[2] + col[3]) / 3
		return m >= opt.baseMin * 255 and m <= opt.baseMax * 255
	end
	local function near(col, ref)
		if not (col and ref) then return false end
		local d = abs(col[1] - ref[1]) + abs(col[2] - ref[2]) + abs(col[3] - ref[3])
		return d <= max(opt.plateauTolerance, opt.baseTolerance * (ref[1] + ref[2] + ref[3]))
	end
	local t = math.tan(math.rad(det.angle))
	local out, rebate = {}, {}
	for _, side in ipairs({ "L", "R", "T", "B" }) do
		local c = sel[side]
		local pick = c
		local ref = c.outerColour
		if not c.none and c.outerVar and c.outerVar <= opt.uniformVar and isFilm(ref) then
			for _, y in ipairs(det.candidates[side]) do
				if not y.none and y.a < c.a - 1 and y.a < pick.a and y.coverage >= 0.3
					and isFilm(y.innerColour) and near(y.innerColour, ref) then
					pick = y
				end
			end
		end
		rebate[side] = (pick ~= c)
		if pick.none or not pick.kbar then
			out[side] = pick
		else
			local kc = ((side == "L" or side == "R") and h or w) / 2 - 0.5
			local nb = toAngle[side] * t
			out[side] = { a = pick.pbar - nb * (pick.kbar - kc), b = nb }
		end
	end
	local f = frameFrom(out, w, h)
	return {
		w = w, h = h, angle = det.angle, rebate = rebate,
		cornersPx = { tl = f.tl, tr = f.tr, br = f.br, bl = f.bl },
	}
end

function M.detect(img, o)
	return M.select(M.analyse(img, o), o)
end

-- residualBorder(img): sides of an already cropped render that still show a
-- border edge near the crop edge, e.g. { "L", "B" }; empty when clean
function M.residualBorder(img, o)
	local opt = options(o)
	opt.searchDepth = opt.residualDepth
	opt.minCoverage = 0.6
	local an = M.analyse(img, opt)
	local found = {}
	for _, side in ipairs({ "L", "R", "T", "B" }) do
		for _, c in ipairs(an.perSide[side]) do
			if not c.none and c.a >= 1.5 and c.coverage >= 0.5 and c.quarters >= 3
				and c.step >= opt.residualStep
				and (c.outerVar == nil or c.outerVar <= opt.uniformVar) then
				found[#found + 1] = side
				break
			end
		end
	end
	return found
end

return M
