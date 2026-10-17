-- ════════════════════════════════════════════════════════════════════
-- data.lua — 调色板定标 / 关卡表 / 摄像机行为 / 关卡数据装载
-- 原作：gamestate.lua（levels、camera_modes、tile_at）
-- ════════════════════════════════════════════════════════════════════

-- PICO-8 16 色 → FC-16 固定 64 色（索引 0–15，与 PICO-8 色号同序）。
-- tools/cs2_convert.py 按 assets/palette.dat 计算 CIEDE2000 最近色；白（7）
-- 与棕（4）按色族人工定标，理由见 README「调色板定标」。
CLR = {
	[0] = 0, 12, 53, 35, 18, 4, 6, 7, 63, 29, 31, 34, 41, 10, 57, 21,
}

-- 关卡地图格：Data ROM 自定义数据段（SPEC §4.2，0x0C63A0 起 236640B），
-- 每关为 width×2 字节的行，行内 2B 小端地图格（SPEC §4.1 布局）。
LEVEL_DATA = 0x0c63a0
-- 地图平面 0（SPEC §4.2：0x080000，256 格/行 × 2B）
MAP0 = 0x080000
MAP_STRIDE = 512

levels = {
	{
		offset = 0,
		width = 96,
		height = 16,
		camera_mode = 1,
		music = 38,
	},
	{
		offset = 3072,
		width = 32,
		height = 32,
		camera_mode = 2,
		music = 36,
		fogmode = 1,
		clouds = 0,
		columns = 1,
	},
	{
		offset = 5120,
		width = 128,
		height = 22,
		camera_mode = 3,
		camera_barriers_x = { 38 },
		camera_barrier_y = 6,
		music = 2,
		title = "trailhead",
	},
	{
		offset = 10752,
		width = 128,
		height = 32,
		camera_mode = 4,
		music = 2,
		title = "glacial caves",
		pal = function() pal(CLR[2], CLR[12]) pal(CLR[5], CLR[2]) end,
		columns = 1,
	},
	{
		offset = 18944,
		width = 128,
		height = 16,
		camera_mode = 5,
		music = 2,
		title = "golden valley",
		pal = function() pal(CLR[2], CLR[14]) pal(CLR[5], CLR[2]) end,
		bg = 13,
		clouds = 15,
		fogmode = 2,
	},
	{
		offset = 23040,
		width = 128,
		height = 16,
		camera_mode = 6,
		camera_barriers_x = { 105 },
		music = 2,
		pal = function() pal(CLR[2], CLR[14]) pal(CLR[5], CLR[2]) end,
		bg = 13,
		clouds = 15,
		fogmode = 2,
	},
	{
		offset = 27136,
		width = 128,
		height = 16,
		camera_mode = 7,
		music = 2,
		pal = function() pal(CLR[2], CLR[12]) pal(CLR[5], CLR[2]) end,
		bg = 13,
		clouds = 7,
		fogmode = 2,
	},
	{
		offset = 31232,
		width = 16,
		height = 62,
		title = "destination",
		camera_mode = 8,
		music = 2,
		pal = function() pal(CLR[2], CLR[1]) pal(CLR[7], CLR[11]) end,
		bg = 15,
		clouds = 7,
		fogmode = 2,
		right_edge = true,
	},
}

camera_x_barrier = function(tile_x, px, py)
	local bx = tile_x * 16
	if px < bx - 16 then
		camera_target_x = math.min(camera_target_x, bx - 256)
	elseif px > bx + 16 then
		camera_target_x = math.max(camera_target_x, bx)
	end
end

c_offset = 0
c_flag = false
camera_modes = {
	-- 1：开场
	function(px, py)
		if px < 84 then
			camera_target_x = 0
		else
			camera_target_x = math.max(80, math.min(level.width * 16 - 256, px - 96))
		end
	end,

	-- 2：开场 2
	function(px, py)
		if px < 240 then
			camera_target_x = 0
		elseif px > 272 then
			camera_target_x = 256
		else
			camera_target_x = px - 128
		end
		camera_target_y = math.max(0, math.min(level.height * 16 - 256, py - 128))
	end,

	-- 3：第一关
	function(px, py)
		camera_target_x = math.max(0, math.min(level.width * 16 - 256, px - 112))
		for i, b in ipairs(level.camera_barriers_x) do
			camera_x_barrier(b, px, py)
		end

		if py < level.camera_barrier_y * 16 + 6 then
			camera_target_y = 0
		else
			camera_target_y = level.camera_barrier_y * 16
		end
	end,

	-- 4：第二关
	function(px, py)
		if px % 256 > 16 and px % 256 < 240 then
			px = math.floor(px / 256) * 256 + 128
		end
		if py % 256 > 8 and py % 256 < 248 then
			py = math.floor(py / 256) * 256 + 128
		end
		camera_target_x = math.max(0, math.min(level.width * 16 - 256, px - 128))
		camera_target_y = math.max(0, math.min(level.height * 16 - 256, py - 128))
	end,

	-- 5：第三关 3-1
	function(px, py)
		camera_target_x = math.max(0, math.min(level.width * 16 - 256, px - 64))
	end,

	-- 6：第三关 3-2
	function(px, py)
		if px > 1696 then
			c_offset = 96
		elseif px < 1408 then
			c_flag = false
			c_offset = 64
		elseif px > 1616 then
			c_flag = true
			c_offset = 192
		end

		camera_target_x = math.max(0, math.min(level.width * 16 - 256, px - c_offset))

		for i, b in ipairs(level.camera_barriers_x) do
			camera_x_barrier(b, px, py)
		end

		if c_flag then
			camera_target_x = math.max(camera_target_x, 1344)
		end
	end,

	-- 7：第三关 3-3
	function(px, py)
		if px > 840 then
			if px < 872 then
				c_offset = 64 + px - 840
			elseif px > 1616 then
				c_offset = 96 - math.min(32, px - 1616)
			else
				c_offset = 96
			end
		else
			c_offset = 64
		end
		camera_target_x = math.max(0, math.min(level.width * 16 - 256, px - c_offset))
	end,

	-- 8：终点
	function(px, py)
		camera_target_y = math.max(0, math.min(level.height * 16 - 256, py - 64))
	end,
}

-- 关卡行号（16px 瓦片）钳制
tile_y = function(py)
	return math.max(0, math.min(math.floor(py / 16), level.height - 1))
end

-- 地图格读数：越界返回 0（空格）
function tile_at(x, y)
	if x < 0 or y < 0 or x >= level.width or y >= level.height then
		return 0
	end
	local t = mget(x, y)
	return t
end

-- 把关卡地图格从 Data ROM 自定义数据段搬进地图平面 0（mget/mset 后端）
function load_level_tiles()
	local src = LEVEL_DATA + level.offset
	local dst = MAP0
	for i = 1, level.height do
		memcpy(dst, src, level.width * 2)
		src += level.width * 2
		dst += MAP_STRIDE
	end
end
