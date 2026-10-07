--[[ TiffReader.lua
Reads the uncompressed 8-bit RGB TIFF the plugin exports for analysis.
Returns { w, h, r, g, b }: channel arrays, 1-based (index = y * w + x + 1),
values 0..255. I control the export, so any other kind of file is refused
with a message.
]]

local M = {}

local byte, floor = string.byte, math.floor

local function reader(data, little)
	local function u16(off)
		local a, b = byte(data, off + 1, off + 2)
		if little then return a + b * 256 end
		return a * 256 + b
	end
	local function u32(off)
		local a, b, c, d = byte(data, off + 1, off + 4)
		if little then return a + b * 256 + c * 65536 + d * 16777216 end
		return ((a * 256 + b) * 256 + c) * 256 + d
	end
	return u16, u32
end

-- TIFF field types: 3 = SHORT, 4 = LONG
local function tagValues(data, u16, u32, entry)
	local typ, count = u16(entry + 2), u32(entry + 4)
	local size = (typ == 3) and 2 or 4
	local get = (typ == 3) and u16 or u32
	local base = entry + 8
	if size * count > 4 then base = u32(entry + 8) end
	local out = {}
	for i = 0, count - 1 do out[i + 1] = get(base + i * size) end
	return out
end

function M.parse(data)
	local order = data:sub(1, 2)
	local little
	if order == "II" then little = true
	elseif order == "MM" then little = false
	else return nil, "not a TIFF file" end
	local u16, u32 = reader(data, little)
	if u16(2) ~= 42 then return nil, "not a classic TIFF (BigTIFF unsupported)" end

	local ifd = u32(4)
	local n = u16(ifd)
	local tags = {}
	for i = 0, n - 1 do
		local entry = ifd + 2 + i * 12
		tags[u16(entry)] = tagValues(data, u16, u32, entry)
	end

	local w, h = tags[256] and tags[256][1], tags[257] and tags[257][1]
	local bps = tags[258] and tags[258][1] or 1
	local comp = tags[259] and tags[259][1] or 1
	local spp = tags[277] and tags[277][1] or 1
	local planar = tags[284] and tags[284][1] or 1
	local offsets, counts = tags[273], tags[279]
	if not (w and h and offsets) then return nil, "TIFF lacks size or strips" end
	if comp ~= 1 then return nil, "TIFF is compressed (" .. comp .. ")" end
	if planar ~= 1 then return nil, "TIFF is planar" end
	if spp < 3 then return nil, "TIFF is not RGB" end
	if bps ~= 8 then return nil, "TIFF bit depth " .. bps end

	local rowBytes = w * spp
	local r, g, b = {}, {}, {}
	local idx = 0
	local rows = 0
	for s = 1, #offsets do
		local off = offsets[s]
		local stripRows = floor(((counts and counts[s]) or (rowBytes * h)) / rowBytes)
		for _ = 1, stripRows do
			if rows >= h then break end
			-- string.byte in chunks: Lua 5.1 limits how many values one call returns
			local p = off
			local chunk = 1024
			local x = 0
			while x < w do
				local nx = (w - x < chunk) and (w - x) or chunk
				local vals = { byte(data, p + 1, p + nx * spp) }
				for j = 0, nx - 1 do
					local k = j * spp
					idx = idx + 1
					r[idx], g[idx], b[idx] = vals[k + 1], vals[k + 2], vals[k + 3]
				end
				x = x + nx
				p = p + nx * spp
			end
			off = off + rowBytes
			rows = rows + 1
		end
	end
	if rows < h then return nil, "TIFF strips hold " .. rows .. " of " .. h .. " rows" end
	return { w = w, h = h, r = r, g = g, b = b }
end

return M
