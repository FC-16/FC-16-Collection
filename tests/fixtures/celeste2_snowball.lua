-- FC16-AC-163：在平地上逐帧观察雪球落地后的反弹次数。
level = levels[4]
level.height = 128
level_index = 4

local function run_ball(ball)
    ball.check_solid = function(self, ox, oy)
        return self.y + (oy or 0) >= 400
    end
    local bounces = 0
    for _ = 1, 180 do
        local before = ball.speed_y
        ball:update()
        if before >= 0 and ball.speed_y < 0 then
            bounces += 1
        end
    end
    return bounces, ball.y, ball.speed_x
end

function measure_snowball(kind)
    objects = {}
    local ball
    if kind == "stomp" then
        ball = create(snowball, 392, 399)
        ball.speed_x = 2
        local p = create(player, 392, 384)
        p.speed_y = 2
        p.check_solid = function() return false end
        p.hazard_check = function() return false end
        input_x = 0
        input_jump = false
        input_jump_pressed = 0
        input_grapple = false
        input_grapple_pressed = 0
        p:update()
        assert(p.speed_y == -4 and ball.speed_y == -1)
        assert(ball.bounce_ready == false)
    else
        ball = create(snowball, 392, 370)
        ball.speed_x = 2
        ball.speed_y = kind == "spawned" and 4 or -1
        if kind == "thrown" or kind == "rethrow" then ball:on_release(true) end
        if kind == "dropped" then ball:on_release(false) end
    end
    local count, y, speed_x = run_ball(ball)
    if kind == "rethrow" then
        ball.y = 370
        ball.speed_y = -1
        ball:on_release(true)
        local second_count = run_ball(ball)
        return count, second_count, y, speed_x
    end
    return count, y, speed_x
end
