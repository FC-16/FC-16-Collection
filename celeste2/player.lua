-- ════════════════════════════════════════════════════════════════════
-- player.lua — 玩家（原作 player.lua）
-- 坐标、尺寸、试探距离 ×2；速度与瞬时冲量保持原值，逐帧加速度 ÷2。
-- 跳跃保持窗口计入触发阶段，自由跳跃位移补半步重力；见 README「跳跃验收」。
-- ════════════════════════════════════════════════════════════════════

player = new_type(2)
player.t_jump_grace = 0
player.t_var_jump = 0
player.var_jump_speed = 0
player.auto_var_jump = false
player.grapple_x = 0
player.grapple_y = 0
player.grapple_dir = 0
player.grapple_hit = nil
player.grapple_wave = 0
player.grapple_boost = false
player.t_grapple_cooldown = 0
player.grapple_retract = false
player.holding = nil
player.wipe_timer = 0
player.finished = false
player.t_grapple_jump_grace = 0
player.t_grapple_pickup = 0

player.state = 0

-- 钩索判定模式（对象 grapple_mode）：
--   0 无 / 1 实心 / 2 实心居中 / 3 可抓取

function player.start_grapple(self)
	self.state = 10

	self.speed_x = 0
	self.speed_y = 0
	self.remainder_x = 0
	self.remainder_y = 0
	self.grapple_x = self.x
	self.grapple_y = self.y - 6
	self.grapple_wave = 0
	self.grapple_retract = false
	self.t_grapple_cooldown = 12
	self.t_var_jump = 0

	if input_x ~= 0 then
		self.grapple_dir = input_x
	else
		self.grapple_dir = self.facing
	end
	self.facing = self.grapple_dir

	psfx(8, 0, 5)
end

-- 0 = 未命中，1 = 命中，2 = 失败（冰面）
function player.grapple_check(self, x, y)
	local tile = tile_at(math.floor(x / 16), tile_y(y))
	if fget(tile, 1) then
		self.grapple_hit = nil
		return fget(tile, 2) and 2 or 1
	end

	for o in all(objects) do
		if o.grapple_mode ~= 0 and o:contains(x, y) then
			self.grapple_hit = o
			return 1
		end
	end

	return 0
end

function player.jump(self)
	consume_jump_press()
	self.state = 0
	self.speed_y = -4
	self.var_jump_speed = -4
	self.speed_x += input_x * 0.2
	-- 起跳当帧也移动：原作(1+4)更新对应10个60Hz更新，此处还剩9次保持。
	self.t_var_jump = 9
	self.t_jump_grace = 0
	self.auto_var_jump = false
	self:move_y(self.jump_grace_y - self.y)
	psfx(7, 0, 4)
end

function player.bounce(self, x, y)
	self.state = 0
	self.speed_y = -4
	self.var_jump_speed = -4
	self.t_var_jump = 8
	self.t_jump_grace = 0
	self.auto_var_jump = true
	-- 雪球中心属于右半侧，居中弹跳同样获得水平冲量。
	self.speed_x += (self.x < x and -1 or 1) * 0.5
	self:move_y(y - self.y)
end

function player.spring(self, y)
	consume_jump_press()
	if input_jump then
		psfx(17, 2, 3)
	else
		psfx(17, 0, 2)
	end
	self.state = 0
	self.speed_y = -5
	self.var_jump_speed = -5
	self.t_var_jump = 13
	self.t_jump_grace = 0
	self.remainder_y = 0
	self.auto_var_jump = false
	self.springboard.player = nil

	for o in all(objects) do
		if o.base == crumble and not o.destroyed and self.springboard:overlaps(o, 0, 8) then
			o.breaking = true
			psfx(8, 20, 4)
		end
	end
end

function player.wall_jump(self, dir)
	consume_jump_press()
	self.state = 0
	self.speed_y = -3
	self.var_jump_speed = -3
	self.speed_x = 3 * dir
	self.t_var_jump = 9
	self.auto_var_jump = false
	self.facing = dir
	self:move_x(-dir * 6)
	psfx(7, 4, 4)
end

function player.grapple_jump(self)
	consume_jump_press()
	psfx(17, 2, 3)
	self.state = 0
	self.t_grapple_jump_grace = 0
	self.state = 0
	self.speed_y = -3
	self.var_jump_speed = -3
	self.t_var_jump = 9
	self.auto_var_jump = false
	self.grapple_retract = true
	if math.abs(self.speed_x) > 4 then
		self.speed_x = sgn(self.speed_x) * 4
	end
	self:move_y(self.grapple_jump_grace_y - self.y)
end

function player.bounce_check(self, obj)
	return self.speed_y >= 0 and self.y - self.speed_y < obj.y + obj.speed_y + 8
end

function player.die(self)
	self.state = 99
	freeze_time = 4
	shake = 10
	death_count += 1
	psfx(14, 16, 16, 240)
end

-- 危险类型：0 无害 / 1 通用 / 2 上刺 / 3 下刺 / 4 右刺 / 5 左刺
player.hazard_table = {
	[1] = function(self) return true end,
	[2] = function(self) return self.speed_y >= 0 end,
	[3] = function(self) return self.speed_y <= 0 end,
	[4] = function(self) return self.speed_x <= 0 end,
	[5] = function(self) return self.speed_x >= 0 end
}

function player.hazard_check(self, ox, oy)
	ox = ox or 0
	oy = oy or 0

	for o in all(objects) do
		if o.hazard ~= 0 and self:overlaps(o, ox, oy) and self.hazard_table[o.hazard](self) then
			return true
		end
	end

	return false
end

function player.correction_func(self, ox, oy)
	return not self:hazard_check(ox, oy)
end

-- 抓取对象移动时的碰撞回调
pull_collide_x = function(self, moved, target)
	if self:corner_correct(sgn(target), 0, 4, 2, 0) then
		return false
	end
	return true
end

function player.release_holding(self, obj, x, y, thrown)
	obj.held = false
	obj.speed_x = x
	obj.speed_y = y
	obj:on_release(thrown)
	psfx(7, 24, 6)
	self.holding = nil
end

function player.init(self)
	self.x += 8
	self.y += 16
	self.hit_x = -6
	self.hit_y = -12
	self.hit_w = 12
	self.hit_h = 12

	self.scarf = {}
	for i = 0, 4 do
		add(self.scarf, { x = self.x, y = self.y })
	end

	-- 摄像机
	camera_modes[level.camera_mode](self.x, self.y)
	camera_x = camera_target_x
	camera_y = camera_target_y
	camera(camera_x, camera_y)
end

function player.update(self)
	local gravity_move = 0
	local on_ground = self:check_solid(0, 2)
	if on_ground then
		self.t_jump_grace = 8
		self.jump_grace_y = self.y
	else
		self.t_jump_grace = math.max(0, self.t_jump_grace - 1)
	end

	self.t_grapple_jump_grace = math.max(0, self.t_grapple_jump_grace - 1)

	if self.t_grapple_cooldown > 0 and self.state < 1 then
		self.t_grapple_cooldown -= 1
	end

	-- 钩索回收
	if self.grapple_retract then
		self.grapple_x = approach(self.grapple_x, self.x, 12)
		self.grapple_y = approach(self.grapple_y, self.y - 6, 6)

		if self.grapple_x == self.x and self.grapple_y == self.y - 6 then
			self.grapple_retract = false
		end
	end

	-- 玩家状态：
	--   0 常态 / 1 举起 / 2 弹簧板弹起 / 10 抛出钩索 / 11 钩索附着
	--   12 拉近抓取物 / 50 取得钩索 / 99 死亡 / 100 通关

	if self.state == 0 then
		-- 朝向
		if input_x ~= 0 then
			self.facing = input_x
		end

		-- 奔跑
		-- 60Hz：加速度按 dt² 减半（原作 0.2/0.1/0.8/0.4 @30Hz）
		local target, accel = 0, 0.1
		if math.abs(self.speed_x) > 2 and input_x == sgn(self.speed_x) then
			target, accel = 2, 0.05
		elseif on_ground then
			target, accel = 2, 0.4
		elseif input_x ~= 0 then
			target, accel = 2, 0.2
		end
		self.speed_x = approach(self.speed_x, input_x * target, accel)

		-- 重力
		if not on_ground then
			local fall_max = dir("down") and 5.2 or 4.4
			local gravity = math.abs(self.speed_y) < 0.2 and input_jump and 0.2 or 0.4
			self.speed_y = math.min(self.speed_y + gravity, fall_max)
			-- 原作先加重力再移动；拆成两次60Hz步进后每步补半个加速度的位移，
			-- 两步总位移才与原作一次更新的2倍坐标相等。速度本身不重复加重力。
			gravity_move = math.min(self.speed_y + gravity * 0.5, fall_max) - self.speed_y
		end

		-- 可变跳跃高度
		if self.t_var_jump > 0 then
			if input_jump or self.auto_var_jump then
				self.speed_y = self.var_jump_speed
				gravity_move = 0
				self.t_var_jump -= 1
			else
				self.t_var_jump = 0
			end
		end

		-- 跳跃
		if input_jump_pressed > 0 then
			if self.t_jump_grace > 0 then
				self:jump()
				gravity_move = 0
			elseif self:check_solid(4) then
				self:wall_jump(-1)
				gravity_move = 0
			elseif self:check_solid(-4) then
				self:wall_jump(1)
				gravity_move = 0
			elseif self.t_grapple_jump_grace > 0 then
				self:grapple_jump()
				gravity_move = 0
			end
		end

		-- 抛出抓取物
		if self.holding and not input_grapple and not self.holding:check_solid(0, -4) then
			self.holding.y -= 4
			if dir("down") then
				self:release_holding(self.holding, 2 * self.facing, 0, false)
			else
				self:release_holding(self.holding, 4 * self.facing, -1, true)
			end
		end

		-- 抛钩索
		if have_grapple and not self.holding and self.t_grapple_cooldown <= 0 and consume_grapple_press() then
			self:start_grapple()
			gravity_move = 0
		end

	elseif self.state == 1 then
		-- 举起状态
		local hold = self.grapple_hit
		hold.x = approach(hold.x, self.x - 8, 4)
		hold.y = approach(hold.y, self.y - 28, 4)

		if hold.x == self.x - 8 and hold.y == self.y - 28 then
			self.state = 0
			self.holding = hold
		end

	elseif self.state == 2 then
		-- 弹簧板弹起状态
		local at_x = approach(self.x, self.springboard.x + 8, 0.5)
		self:move_x(at_x - self.x)

		local at_y = approach(self.y, self.springboard.y + 8, 0.2)
		self:move_y(at_y - self.y)

		if self.springboard.spr == 11 and self.y >= self.springboard.y + 4 then
			self.springboard.spr = 12
		elseif self.y == self.springboard.y + 8 then
			self:spring(self.springboard.y + 8)
			self.springboard.spr = 11
		end

	elseif self.state == 10 then
		-- 抛出钩索状态：每帧最多前进 3 步（原作 6 步 @30Hz），每步 4px
		local amount = math.min(128 - math.abs(self.grapple_x - self.x), 3)
		local grabbed = false
		for i = 1, amount do
			local hit = self:grapple_check(self.grapple_x + self.grapple_dir * 2, self.grapple_y)
			if hit == 0 then
				hit = self:grapple_check(self.grapple_x + self.grapple_dir * 2, self.grapple_y - 2)
			end
			if hit == 0 then
				hit = self:grapple_check(self.grapple_x + self.grapple_dir * 2, self.grapple_y + 2)
			end

			local mode = self.grapple_hit and self.grapple_hit.grapple_mode or 0

			if hit == 0 then
				self.grapple_x += self.grapple_dir * 4
			elseif hit == 1 then
				if mode == 2 then
					self.grapple_x = self.grapple_hit.x + 8
					self.grapple_y = self.grapple_hit.y + 8
				elseif mode == 3 then
					self.grapple_hit.held = true
					grabbed = true
				end

				self.state = mode == 3 and 12 or 11
				self.grapple_wave = 2
				self.grapple_boost = false
				self.freeze = 4
				psfx(14, 0, 5)
				break
			end

			if hit == 2 or (hit == 0 and math.abs(self.grapple_x - self.x) >= 128) then
				psfx(hit == 2 and 7 or 14, 8, 3)
				self.grapple_retract = true
				self.freeze = 4
				self.state = 0
				break
			end
		end

		-- 钩索摆动幅度
		self.grapple_wave = approach(self.grapple_wave, 1, 0.1)
		self.spr = 3

		-- 松开
		if not grabbed and (not input_grapple or math.abs(self.y - self.grapple_y) > 16) then
			self.state = 0
			self.grapple_retract = true
			if sfx_timer <= 0 then voice_release(3) end
		end

	elseif self.state == 11 then
		-- 钩索附着状态

		-- 起步加速
		if not self.grapple_boost then
			self.grapple_boost = true
			self.speed_x = self.grapple_dir * 8
		end

		-- 加速度
		self.speed_x = approach(self.speed_x, self.grapple_dir * 5, 0.125)
		self.speed_y = approach(self.speed_y, 0, 0.2)

		-- 纵向对齐
		if self.speed_y == 0 then
			if self.y - 6 > self.grapple_y then
				self:move_y(-0.5)
			elseif self.y - 6 < self.grapple_y then
				self:move_y(0.5)
			end
		end

		-- 贴墙姿势
		if self.spr ~= 4 and self:check_solid(self.grapple_dir * 2) then
			self.spr = 4
			psfx(14, 8, 3)
		end

		-- 跳跃
		if consume_jump_press() then
			if self:check_solid(self.grapple_dir * 4) then
				self:wall_jump(-self.grapple_dir)
			else
				self.grapple_jump_grace_y = self.y
				self:grapple_jump()
			end
		end

		-- 钩索摆动幅度
		self.grapple_wave = approach(self.grapple_wave, 0, 0.3)

		-- 松开
		if not input_grapple or (self.grapple_hit and self.grapple_hit.destroyed) then
			self.state = 0
			self.t_grapple_jump_grace = 8
			self.grapple_jump_grace_y = self.y
			self.grapple_retract = true
			self.facing *= -1
			if math.abs(self.speed_x) > 5 then
				self.speed_x = sgn(self.speed_x) * 5
			elseif math.abs(self.speed_x) <= 0.5 then
				self.speed_x = 0
			end
		end

		-- 越过钩索点则松开
		local anchor_side = self.x < self.grapple_x and -1 or 1
		if anchor_side == self.grapple_dir then
			self.state = 0
			if self.grapple_hit ~= nil and self.grapple_hit.grapple_mode == 2 then
				self.t_grapple_jump_grace = 8
				self.grapple_jump_grace_y = self.y
			end
			if math.abs(self.speed_x) > 5 then
				self.speed_x = sgn(self.speed_x) * 5
			end
		end

	elseif self.state == 12 then
		-- 拉近抓取物状态
		local obj = self.grapple_hit

		-- 拉动
		if obj:move_x(-self.grapple_dir * 6, pull_collide_x) then
			self.state = 0
			self.grapple_retract = true
			obj:on_release(-self.grapple_dir)
			obj.held = false
			return
		else
			self.grapple_x = approach(self.grapple_x, self.x, 6)
		end

		-- 纵向对齐
		if obj.y ~= self.y - 14 then
			obj:move_y(sgn(self.y - obj.y - 14) * 0.5)
		end

		-- 钩索摆动幅度
		self.grapple_wave = approach(self.grapple_wave, 0, 0.3)

		-- 抓住
		if self:overlaps(obj) then
			self.state = 1
			psfx(7, 16, 6)
		end

		-- 松开
		local holding_side = obj.x + 8 < self.x and -1 or 1
		if not input_grapple or math.abs(obj.y - self.y + 14) > 16 or holding_side == -self.grapple_dir then
			self.state = 0
			self.grapple_retract = true
			self:release_holding(obj, -self.grapple_dir * 5, 0, true)
		end

	elseif self.state == 50 then
		-- 取得钩索状态
		self.speed_y = math.min(self.speed_y + 0.4, 4.5)
		self.speed_x = approach(self.speed_x, 0, 0.1)
		if on_ground then
			if self.t_grapple_pickup == 0 then music(39, 0, 15) end
			if self.t_grapple_pickup == 122 then music_stop() end
			if self.t_grapple_pickup == 140 then music(22, 0, 15) end
			if self.t_grapple_pickup > 160 then self.state = 0 end
			self.t_grapple_pickup += 1
		end

	elseif self.state == 99 or self.state == 100 then
		-- 死亡 / 通关状态
		if self.state == 100 then
			self.x += 1
			if self.wipe_timer == 10 and level_index > 1 then psfx(17, 24, 9) end
		end

		self.wipe_timer += 1
		if self.wipe_timer > 40 then
			if self.state == 99 then restart_level() else next_level() end
		end
		return
	end

	-- 应用速度
	self:move_x(self.speed_x, self.on_collide_x)
	self:move_y(self.speed_y + gravity_move, self.on_collide_y)

	-- 抓取物跟随
	if self.holding then
		self.holding.x = self.x - 8
		self.holding.y = self.y - 28
	end

	-- 精灵
	if self.state == 50 and self.t_grapple_pickup > 0 then
		self.spr = 5
	elseif self.state ~= 11 then
		if not on_ground then
			self.spr = 3
		elseif input_x ~= 0 then
			self.spr += 0.125
			self.spr = 2 + self.spr % 2
		else
			self.spr = 2
		end
	end

	-- 对象交互
	for o in all(objects) do
		if o.base == grapple_pickup and self:overlaps(o) then
			-- 钩索拾取
			o.destroyed = true
			have_grapple = true
			psfx(7, 12, 4)
			self.state = 50
		elseif o.base == bridge and not o.falling and self:overlaps(o) then
			-- 断桥
			o.falling = true
			self.freeze = 2
			shake = 4
			psfx(8, 16, 4)
		elseif o.base == snowball and not o.held then
			-- 雪球
			if self:bounce_check(o) and o:bounce_overlaps(self) then
				self:bounce(o.x + 8, o.y)
				psfx(17, 0, 2)
				o.freeze = 2
				o.speed_y = -1
				o.bounce_ready = false
				o:hurt()
			elseif o.speed_x ~= 0 and o.thrown_timer <= 0 and self:overlaps(o) then
				self:die()
				return
			end
		elseif o.base == springboard and self.state ~= 2 and not o.held and self:overlaps(o) and self:bounce_check(o) then
			-- 弹簧板
			self.state = 2
			self.speed_x = 0
			self.speed_y = 0
			self.t_jump_grace = 0
			self.springboard = o
			self.remainder_y = 0
			o.player = self
			self:move_y(o.y + 8 - self.y)
		elseif o.base == berry and self:overlaps(o) then
			-- 草莓
			o:collect(self)
		elseif o.base == crumble and not o.breaking then
			-- 碎裂砖
			if self.state == 0 and self:overlaps(o, 0, 2) then
				o.breaking = true
				psfx(8, 20, 4)
			elseif self.state == 11 then
				if self:overlaps(o, self.grapple_dir * 2) or self:overlaps(o, self.grapple_dir * 2, 6) or self:overlaps(o, self.grapple_dir * 2, -4) then
					o.breaking = true
					psfx(8, 20, 4)
				end
			end
		elseif o.base == checkpoint and level_checkpoint ~= o.id and self:overlaps(o) then
			level_checkpoint = o.id
			psfx(8, 24, 6, 40)
			save_progress()
		end
	end

	-- 死亡
	if self.state < 99 and (self.y > level.height * 16 + 32 or self:hazard_check()) then
		if level_index == 1 and self.x > level.width * 16 - 128 then
			self.state = 100
			self.wipe_timer = -30
		else
			self:die()
		end
		return
	end

	-- 边界
	if self.y < -32 then
		self.y = -32
		self.speed_y = 0
	end
	if self.x < 6 then
		self.x = 6
		self.speed_x = 0
	elseif self.x > level.width * 16 - 6 then
		if level.right_edge then
			self.x = level.width * 16 - 6
			self.speed_x = 0
		else
			self.state = 100
		end
	end

	-- 开场断桥处换曲
	if current_music == levels[1].music and self.x > 61 * 16 then
		current_music = 37
		music(37, 0, 15)
		psfx(17, 24, 9)
	end

	-- 结局
	if level_index == 8 then
		if current_music ~= 40 and self.y > 80 then
			current_music = 40
			music(40, 0, 15)
		end
		if self.y > 752 then show_score += 1 end
		if show_score == 240 then music(38, 0, 15) end
	end

	-- 摄像机
	camera_modes[level.camera_mode](self.x, self.y, on_ground)
	camera_x = approach(camera_x, camera_target_x, 5)
	camera_y = approach(camera_y, camera_target_y, 5)
	camera(camera_x, camera_y)
end

function player.on_collide_x(self, moved, target)
	if self.state == 0 then
		if sgn(target) == input_x and self:corner_correct(input_x, 0, 2, 2, -1, self.correction_func) then
			return false
		end
	elseif self.state == 11 then
		if self:corner_correct(self.grapple_dir, 0, 4, 2, 0, self.correction_func) then
			return false
		end
	end

	return object.on_collide_x(self, moved, target)
end

function player.on_collide_y(self, moved, target)
	if target < 0 and self:corner_correct(0, -1, 2, 1, input_x, self.correction_func) then
		return false
	end

	self.t_var_jump = 0
	return object.on_collide_y(self, moved, target)
end

function player.draw(self)
	-- 死亡特效
	if self.state == 99 then
		local e = self.wipe_timer / 20
		local dx = mid(camera_x, self.x, camera_x + 256)
		local dy = mid(camera_y, self.y - 8, camera_y + 256)
		if e <= 1 then
			for i = 0, 7 do
				circfill(dx + cos(i / 8) * 64 * e, dy + sin(i / 8) * 64 * e, (1 - e) * 16, CLR[10])
			end
		end
		return
	end

	-- 围巾
	local last = { x = self.x - self.facing * 2, y = self.y - 6 }
	for i = 1, #self.scarf do
		local s = self.scarf[i]

		-- 追向上一段（60Hz 等效平滑系数）
		s.x += (last.x - self.facing * 2 - s.x) * 0.422650
		s.y += (last.y + sin(i * 0.25 + time()) * i * 0.5 - s.y) * 0.292893

		-- 限制拉扯距离
		local dx = s.x - last.x
		local dy = s.y - last.y
		local dist = math.sqrt(dx * dx + dy * dy)
		if dist > 3 then
			local nx = (s.x - last.x) / dist
			local ny = (s.y - last.y) / dist
			s.x = last.x + nx * 3
			s.y = last.y + ny * 3
		end

		-- 绘制
		rectfill(s.x, s.y, 2, 2, CLR[10])
		rectfill((s.x + last.x) / 2, (s.y + last.y) / 2, 2, 2, CLR[10])
		last = s
	end

	-- 钩索
	if self.state >= 10 and self.state <= 12 then
		draw_sine_h(self.x, self.grapple_x, self.y - 6, CLR[7], 4 * self.grapple_wave, 6, 0.04, 12)
	end

	-- 回收中的钩索
	if self.grapple_retract then
		line(self.x, self.y - 4, self.grapple_x, self.grapple_y + 2, CLR[1])
		line(self.x, self.y - 6, self.grapple_x, self.grapple_y, CLR[7])
	end

	-- 精灵
	spr(math.floor(self.spr), self.x - 8, self.y - 16, 1, 1, self.facing ~= 1)

	if self.state == 50 and self.t_grapple_pickup > 0 then
		spr(20, self.x - 8, self.y - 36)
		for i = 0, 16 do
			local s = sin(time() * 4 + i / 16)
			local c = cos(time() * 4 + i / 16)
			local ty = self.y - 28
			line(self.x + s * 32, ty + c * 32, self.x + s * 80, ty + c * 80, CLR[7])
		end
	end
end
