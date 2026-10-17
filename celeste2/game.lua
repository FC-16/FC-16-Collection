-- ════════════════════════════════════════════════════════════════════
-- game.lua — 全局状态、关卡切换与绘制辅助（原作 gamestate.lua + main.lua 工具函数）
-- ════════════════════════════════════════════════════════════════════

level_index = 0
level_intro = 0

-- 存档只在进入关卡或触碰记录点时提交；草莓、计时和死亡数随该位置一同快照。
-- 结构（SPEC §13）：{level=, checkpoint={x,y}?, deaths=, minutes=, seconds=, frames=, berries={id...}}
function save_progress()
	local berries = {}
	for berry_id in pairs(collected) do add(berries, berry_id) end
	table.sort(berries)

	local checkpoint = nil
	if level_checkpoint then
		local tile = level_checkpoint - level_index * 8192
		checkpoint = { tile % 128, math.floor(tile / 128) }
	end
	save({
		level = level_index,
		checkpoint = checkpoint,
		deaths = death_count,
		minutes = minutes,
		seconds = seconds,
		frames = frames,
		berries = berries,
	})
end

-- 缺失或非数字字段按 0 处理
local function save_int(v)
	return type(v) == "number" and math.floor(v) or 0
end

local function restore_progress()
	local d = load()
	if type(d) ~= "table" then return nil end
	local berries = type(d.berries) == "table" and d.berries or {}
	local saved_level = save_int(d.level)
	local count = #berries
	if saved_level < 1 or saved_level > #levels or count > 32 then return nil end

	for i = 1, count do
		local berry_id = save_int(berries[i])
		local n = math.floor(berry_id / 8192)
		local tile = berry_id % 8192
		if n >= 1 and n <= #levels then
			local x, y = tile % 128, math.floor(tile / 128)
			if x < levels[n].width and y < levels[n].height then
				collected[n * 8192 + tile] = true
				berry_count += 1
			end
		end
	end
	death_count = math.max(0, save_int(d.deaths))
	minutes = math.max(0, save_int(d.minutes))
	seconds = mid(0, save_int(d.seconds), 59)
	frames = mid(0, save_int(d.frames), 59)
	local checkpoint = d.checkpoint
	if type(checkpoint) == "table" then
		return saved_level, save_int(checkpoint[1]), save_int(checkpoint[2])
	end
	return saved_level
end

function game_start()
	-- 重置状态
	snow = {}
	clouds = {}
	freeze_time = 0
	frames = 0
	seconds = 0
	minutes = 0
	shake = 0
	sfx_timer = 0
	berry_count = 0
	death_count = 0
	collected = {}
	camera_x = 0
	camera_y = 0
	show_score = 0
	titlescreen_flash = nil

	for i = 0, 25 do
		snow[i] = { x = rnd(264), y = rnd(264) }
		clouds[i] = { x = rnd(264), y = rnd(264), s = 32 + rnd(64) }
	end

	-- 无存档显示标题画面；有存档从最近关卡入口或记录点继续。
	local saved_level, checkpoint_x, checkpoint_y = restore_progress()
	if not saved_level then
		current_music = 38
		music(current_music, 0, 15)
	else
		goto_level(saved_level, checkpoint_x, checkpoint_y)
	end
end

function goto_level(index, checkpoint_x, checkpoint_y)
	-- 设置关卡
	level = levels[index]
	level_index = index
	level_checkpoint = nil

	if level.title then
		level_intro = 120
	end

	if level_index == 2 then
		psfx(17, 8, 16)
	end

	-- 地图格搬入地图平面 0
	load_level_tiles()
	if checkpoint_x and checkpoint_y and tile_at(checkpoint_x, checkpoint_y) == 13 then
		level_checkpoint = id(checkpoint_x, checkpoint_y)
	end

	-- 开始音乐
	if current_music ~= level.music and level.music then
		current_music = level.music
		music(level.music, 0, 15)
	end

	-- 装载关卡内容
	restart_level()
end

function next_level()
	goto_level(level_index + 1)
	save_progress()
end

function restart_level()
	camera_x = 0
	camera_y = 0
	camera_target_x = 0
	camera_target_y = 0
	objects = {}
	infade = 0
	have_grapple = level_index > 2
	sfx_timer = 0

	for i = 0, level.width - 1 do
		for j = 0, level.height - 1 do
			local t = types[tile_at(i, j)]
			if t and not collected[id(i, j)] and (not level_checkpoint or t ~= player) then
				create(t, i * 16, j * 16)
			end
		end
	end
end

-- ---------------------------------------------------------------- 工具

function approach(x, target, max_delta)
	return x < target and math.min(x + max_delta, target) or math.max(x - max_delta, target)
end

-- 音效走通道 3（与原作一致，音乐占 0–2 轨）
function psfx(sfx_id, off, len, lock)
	if sfx_timer <= 0 or lock then
		sfx(sfx_id, 3, off, len)
		if lock then sfx_timer = lock end
	end
end

function print_center(text, x, y, c)
	x -= textw(text) / 2
	print(text, x, y, c)
end

function draw_time(x, y)
	local m = minutes % 60
	local h = math.floor(minutes / 60)

	rectfill(x, y, 66, 14, CLR[0])
	print((h < 10 and "0" .. h or h) .. ":" .. (m < 10 and "0" .. m or m) .. ":" .. (seconds < 10 and "0" .. seconds or seconds), x + 2, y + 2, CLR[7])
end

function draw_clouds(scale, ox, oy, sx, sy, color, count)
	for i = 0, count do
		local c = clouds[i]
		local s = c.s * scale
		local x = ox + (camera_x + (c.x - camera_x * 0.9) % (256 + s) - s / 2) * sx
		local y = oy + (camera_y + (c.y - camera_y * 0.9) % (256 + s / 2)) * sy
		clip(x - s / 2 - camera_x, y - s / 2 - camera_y, s, s / 2)
		circfill(x, y, s / 3, color)
		if i % 2 == 0 then
			circfill(x - s / 3, y, s / 5, color)
		end
		if i % 2 == 0 then
			circfill(x + s / 3, y, s / 6, color)
		end
		c.x += (4 - i % 4) * 0.25
	end
	clip(0, 0, 256, 256)
end

function draw_snow()
	for i = 1, #snow do
		local s = snow[i]
		circfill(camera_x + (s.x - camera_x * 0.5) % 264 - 4, camera_y + (s.y - camera_y * 0.5) % 264, (i % 2) * 2, CLR[7])
		s.x += (4 - i % 4)
		s.y += sin(time() * 0.25 + i * 0.1)
	end
end

-- 沿水平线画正弦绳索：原作逐像素 pset 一条 2px 高（本色 + 描边）的线，
-- 这里逐 FC 像素画 2×2 色块，等价于原作画面放大 2 倍的外观。
function draw_sine_h(x0, x1, y, col, amplitude, time_freq, x_freq, fade_x_dist)
	rectfill(x0, y, 2, 2, col)
	rectfill(x1, y, 2, 2, col)

	local x_sign = sgn(x1 - x0)
	local x_max = math.abs(x1 - x0) - 1
	local last_y = y
	local this_y = 0
	local ax = 0
	local ay = 0
	local fade = 1

	for i = 1, x_max do
		if i <= fade_x_dist then
			fade = i / (fade_x_dist + 1)
		elseif i > x_max - fade_x_dist + 1 then
			fade = (x_max + 1 - i) / (fade_x_dist + 1)
		else
			fade = 1
		end

		ax = x0 + i * x_sign
		ay = y + sin(time() * time_freq + i * x_freq) * amplitude * fade
		rectfill(ax, ay, 2, 2, col)
		rectfill(ax, ay + 2, 2, 2, CLR[1])

		this_y = ay
		while math.abs(ay - last_y) > 2 do
			ay -= sgn(this_y - last_y) * 2
			rectfill(ax - x_sign * 2, ay, 2, 2, col)
			rectfill(ax - x_sign * 2, ay + 2, 2, 2, CLR[1])
		end
		last_y = this_y
	end
end
