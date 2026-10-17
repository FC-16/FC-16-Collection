-- ════════════════════════════════════════════════════════════════════
-- main.lua — 入口与帧循环（原作 main.lua）
-- 模块经构建期静态 require 组合（fc16.project.json → fc16-tools project build）；
-- 跨文件状态经全局表共享，require 仅声明组装顺序与依赖。
-- FC-16 固定 60Hz：原作 _update/_draw 为 30Hz 且屏幕/瓦片是 2 倍，
-- 位置与尺寸 ×2、速度原值（2 倍尺度 ÷ 2 倍帧率相消）、加速度 ÷2、
-- 帧计数计时器 ×2、指数平滑取 60Hz 等效系数。见 README「时间语义」。
-- ════════════════════════════════════════════════════════════════════

local __modules = {
	require("data"),
	require("object"),
	require("objects"),
	require("player"),
	require("input"),
	require("game"),
}

function _init()
	game_start()
end

function _update()
	-- 标题画面
	if level_index == 0 then
		if titlescreen_flash then
			titlescreen_flash -= 1
			if titlescreen_flash < -60 then goto_level(1) end
		elseif btn("a") or btn("b") then
			titlescreen_flash = 100
			sfx(22, 3)
		end

	-- 关卡标题卡
	elseif level_intro > 0 then
		level_intro -= 1
		if level_intro == 0 then psfx(17, 24, 9) end

	-- 正常关卡
	else
		-- 计时器
		sfx_timer = math.max(0, sfx_timer - 1)
		shake = math.max(0, shake - 1)
		infade = math.min(infade + 1, 120)
		if level_index ~= 8 then frames += 1 end
		if frames == 60 then seconds += 1 frames = 0 end
		if seconds == 60 then minutes += 1 seconds = 0 end

		update_input()

		-- 冻结
		if freeze_time > 0 then
			freeze_time -= 1
		else
			-- 实体
			for o in all(objects) do
				if o.freeze > 0 then
					o.freeze -= 1
				else
					o:update()
				end

				if o.destroyed then
					del(objects, o)
				end
			end
		end
	end
end

function _draw()
	pal()

	if level_index == 0 then
		cls(CLR[0])

		if titlescreen_flash then
			local c = 10
			if titlescreen_flash > 20 then
				if titlescreen_flash % 20 < 10 then c = 7 end
			elseif titlescreen_flash > 10 then
				c = 2
			elseif titlescreen_flash > 0 then
				c = 1
			else
				c = 0
			end
			if c < 10 then
				for i = 0, 15 do pal(CLR[i], CLR[c]) end
			end
		end

		sspr(128, 64, 128, 64, 72, 64)
		rect(0, 0, 256, 256, CLR[7])
		print_center("lANI'S tREK", 128, 136, CLR[14])
		print_center("a game by", 128, 160, CLR[1])
		print_center("maddy thorson", 128, 174, CLR[5])
		print_center("noel berry", 128, 188, CLR[5])
		print_center("lena raine", 128, 202, CLR[5])
		draw_snow()
		return
	end

	if level_intro > 0 then
		cls(CLR[0])
		camera(0, 0)
		draw_time(8, 8)
		if level_index ~= 8 then
			print_center("level " .. (level_index - 2), 128, 112, CLR[7])
		end
		print_center(level.title, 128, 128, CLR[7])
		return
	end

	-- 震屏
	if shake > 0 then
		camera(camera_x - 4 + rnd(9), camera_y - 4 + rnd(9))
	end

	-- 清屏
	cls(level and level.bg and CLR[level.bg] or CLR[0])

	-- 云
	draw_clouds(1, 0, 0, 1, 1, level.clouds and CLR[level.clouds] or CLR[13], #clouds)

	-- 背景冰柱（原作图案的透明位反转为 FC-16 的位 0 透明）
	if level.columns then
		fillp(0xf7fd)
		local x = 0
		while x < level.width do
			local tx = x * 16 + camera_x * 0.1
			rectfill(tx, 0, (x % 2) * 16 + 18, level.height * 16, CLR[level.columns])
			x += 1 + x % 7
		end
		fillp()
	end

	-- 瓦片
	for x = mid(0, math.floor(camera_x / 16), level.width), mid(0, math.floor((camera_x + 256) / 16), level.width) do
		for y = mid(0, math.floor(camera_y / 16), level.height), mid(0, math.floor((camera_y + 256) / 16), level.height) do
			local tile = tile_at(x, y)
			if level.pal and fget(tile, 7) then level.pal() end
			if tile ~= 0 and fget(tile, 0) then spr(tile, x * 16, y * 16) end
			pal() palt()
		end
	end

	-- 结算面板
	if show_score > 210 then
		rectfill(68, 784, 130, 86, CLR[1])
		rectfill(64, 780, 130, 86, CLR[0])
		rect(64, 780, 130, 86, CLR[7])
		spr(21, 88, 792)
		print("X " .. berry_count, 112, 796, CLR[7])
		spr(87, 88, 816)
		draw_time(112, 816)
		spr(71, 88, 840)
		print("X " .. death_count, 112, 842, CLR[7])
	end

	-- 实体（玩家最后画）
	local p = nil
	for o in all(objects) do
		if o.base == player then p = o else o:draw() end
	end
	if p then p:draw() end

	-- 雪
	draw_snow()

	-- 前景雾
	if level.fogmode then
		if level.fogmode == 1 then fillp(0xa5a5) end
		draw_clouds(1.25, 0, level.height * 16 + 2, 1, 0, CLR[7], #clouds - 10)
		fillp()
	end

	-- 转场擦除
	if p ~= nil and p.wipe_timer > 10 then
		local e = (p.wipe_timer - 10) / 24
		for i = 0, 127 do
			local s = 382 * e - 64 + sin(i * 0.2) * 32 + (127 - i) * 0.5
			rectfill(camera_x, camera_y + i * 2, math.max(0, s + 2), 2, CLR[0])
		end
	end

	if infade < 30 then
		local e = infade / 24
		for i = 0, 127 do
			local s = 382 * e - 64 + sin(i * 0.2) * 32 + (127 - i) * 0.5
			rectfill(camera_x + s, camera_y + i * 2, math.max(0, 258 - s), 2, CLR[0])
		end
	end

	-- 计时器
	if infade < 90 then
		draw_time(camera_x + 8, camera_y + 8)
	end

	camera(camera_x, camera_y)
end
