-- FC16-AC-163：隔离障碍和输入采样，测量卡带自身五种起跳动作的高度。
-- 普通/蹬墙/钩索/弹簧在更新的移动前触发；雪球弹跳在移动后的碰撞阶段触发。
function measure_jump(kind, held_ticks)
    level=levels[4] level.height=128 level_index=4
    objects={}
    local p=create(player,400,384)
    p.x=400 p.y=400 p.speed_x=0 p.speed_y=0 p.remainder_x=0 p.remainder_y=0
    p.jump_grace_y=400 p.grapple_jump_grace_y=400 p.springboard={player=p}
    p.check_solid=function() return false end
    p.hazard_check=function() return false end
    input_x=1 input_jump=true input_jump_pressed=0 input_grapple=false input_grapple_pressed=0
    btn=function(name) return name=="a" and input_jump end
    p[kind](p,1,400)
    local impulse=p.speed_x
    local min_y=400
    if kind~='bounce' then p:move_y(p.speed_y) min_y=p.y end
    for i=(kind=='bounce' and 1 or 2),80 do
        input_jump=i<=held_ticks
        p:update()
        min_y=math.min(min_y,p.y)
    end
    return 400-min_y,impulse
end
