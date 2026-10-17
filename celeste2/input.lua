-- ════════════════════════════════════════════════════════════════════
-- input.lua — 输入缓冲（原作 input.lua）
-- 方向读取改用 FC-16 的合并方向 dir()（D-pad 或左摇杆，SPEC §6.1）；
-- 跳跃 = A（"a"）、钩索 = B（"b"）。按下缓冲窗口为 60Hz 下的 8 帧（原作 4 帧 @30Hz）。
-- ════════════════════════════════════════════════════════════════════

input_x = 0
input_jump = false
input_jump_pressed = 0
input_grapple = false
input_grapple_pressed = 0
axis_x_value = 0
axis_x_turned = false

function update_input()
	-- 左右（同时按下时转身）
	local prev_x = axis_x_value
	if dir("left") then
		if dir("right") then
			if axis_x_turned then
				axis_x_value = prev_x
				input_x = prev_x
			else
				axis_x_turned = true
				axis_x_value = -prev_x
				input_x = -prev_x
			end
		else
			axis_x_turned = false
			axis_x_value = -1
			input_x = -1
		end
	elseif dir("right") then
		axis_x_turned = false
		axis_x_value = 1
		input_x = 1
	else
		axis_x_turned = false
		axis_x_value = 0
		input_x = 0
	end

	-- 跳跃
	local jump = btn("a")
	if jump and not input_jump then
		input_jump_pressed = 8
	else
		input_jump_pressed = jump and math.max(0, input_jump_pressed - 1) or 0
	end
	input_jump = jump

	-- 钩索
	local grapple = btn("b")
	if grapple and not input_grapple then
		input_grapple_pressed = 8
	else
		input_grapple_pressed = grapple and math.max(0, input_grapple_pressed - 1) or 0
	end
	input_grapple = grapple
end

function consume_jump_press()
	local val = input_jump_pressed > 0
	input_jump_pressed = 0
	return val
end

function consume_grapple_press()
	local val = input_grapple_pressed > 0
	input_grapple_pressed = 0
	return val
end
