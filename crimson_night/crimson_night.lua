-- Crimson Night — FC-16 原生移植（由 code.lua 逐函数迁移）
--crimson night 
--By Fictionity / v1.0


t=time
local __fc16_time=time
-- PICO-8 色号 0–15 → FC-16 色号（convert_assets.py 按 assets/palette.dat 最近色
-- 生成，与精灵像素转换同源；PICO 白色 → FC 7 白）。所有绘制期颜色经此表取值。
COL = {[0]=0,12,53,36,18,4,8,7,63,29,30,35,42,5,57,21}
-- 音乐占通道 0/3/5/7（低音/鼓/和声/主奏），1/2/4/6 保留给音效（SPEC §5.1：
-- 无 mask 时音乐占用全部 8 通道，自动路由的 sfx 会被整批丢弃）
MUSIC_CHANNELS_MASK = 169
dash_trails={}
MAX_ENEMIES=50
MAX_PARTICLES=100
MAX_XP_GEMS=30
MAX_VEGETATION=200
dynamite_cooldown=300
dynamite_timer=0
dynamite_unlocked=false
dynamites={}
ghost_gun_unlocked=false
ghost_gun={x=0,y=0,angle=0}
kill_count=0
particles={}
blood_stains={}
player_x=64
player_y=64
player_speed=1.8
camera_shake_timer=0
hit_flash_timer=0
invulnerable_timer=0
player_facing_left=false
dash_timer=0
dash_dx=0
dash_dy=0
dash_speed=4
dash_cooldown=60
dash_cooldown_timer=0
player_direction="down"
player_prev_direction="down"
player_last_movement_direction="down"
direction_transition_timer=0
direction_transition_duration=3
player_target_direction=nil
turn_transition_timer=0
turn_transition_stage=0
map_center_x=512
map_center_y=512
-- unused: map_radius/vegetation state removed
vegetation_sprites={192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,208,218,219,220,221,222,223,250,251,252,253,254,255}
stone_sprites={209,210,211,212,213,214,215,216,217}
map_seed=0
cam_x=0
cam_y=0
enemies={}
enemy_types={{first_sprite=64,hp=10,unlock_time=0},{first_sprite=65,hp=11,unlock_time=38},{first_sprite=66,hp=12,unlock_time=76},{first_sprite=67,hp=13,unlock_time=114},{first_sprite=68,hp=14,unlock_time=152},{first_sprite=69,hp=15,unlock_time=190},{first_sprite=70,hp=16,unlock_time=228},{first_sprite=71,hp=17,unlock_time=266},{first_sprite=72,hp=18,unlock_time=304},{first_sprite=73,hp=19,unlock_time=342}}
enemy_spawn_timer=0
enemy_spawn_delay=30
spawn_increase_timer=0
  spawn_increase_delay=300
  player_health=5
  game_over=false
  game_over_slide=0
  tutorial_screen=1
  intro_t=0
  tutorial_slide=0
  
  game_state="intro"
bullets={}
bullet_speed=5
bullet_timer=0
bullet_delay=45
manual_fire_cooldown=0
revolver_shake_timer=0
revolver_rotation=0
bullet_damage=10
bullet_multi_count=0
bullet_multi_angle=0.08
revolver_bullets=6
revolver_current=6
revolver_reload_timer=0
revolver_reload_delay=60
revolver_reloading=false
mirror_shot_enabled=false
bullet_ricochet_count=0
bullet_bounce_enabled=false
xp_gems={}
player_xp=0
player_level=1
xp_to_next=8

-- Global walk animations table to avoid duplication
walk_animations={
  side={{0,1,16,17},{2,3,18,19},{4,5,20,21},{6,7,22,23}},
  down={{8,9,24,25},{10,11,26,27},{12,13,28,29},{14,15,30,31}},
  up={{40,41,56,57},{42,43,58,59},{44,45,60,61},{46,47,62,63}},
  down_diag={{32,33,48,49},{36,37,52,53},{38,39,54,55},{32,33,48,49}},
  up_diag={{224,225,240,241},{226,227,242,243},{228,229,244,245},{230,231,246,247}},
  right_diag={{232,233,248,249},{234,235,250,251},{236,237,252,253},{238,239,254,255}}
}

level_up_pending=false
selected_card=1
offered_upgrades={}
-- Skills (unlock once, no repeats)
skills_pool={
  {id="dyn",name="炸药",icon=147,apply=function()dynamite_unlocked=true end},
  {id="ghost",name="幽灵手枪",icon=151,apply=function()ghost_gun_unlocked=true end},
  {id="shotgun",name="散彈槍",icon=157,apply=function()bullet_multi_count=1 end},
  {id="mir",name="镜像射击",icon=156,apply=function()mirror_shot_enabled=true end},
  {id="ric",name="跳弹",icon=154,apply=function()bullet_ricochet_count=1 bullet_bounce_enabled=true end},
  {id="fire_dash",name="烈焰冲刺",icon=138,apply=function()fire_dash_unlocked=true end},
  {id="sword",name="幽灵之剑",icon=155,apply=function()ghost_sword_unlocked=true end}
}

-- Stackable upgrades (can be repeated)
upgrade_pool={
  {id="dmg",name="伤害+5",icon=140,apply=function()bullet_damage = bullet_damage + 5 end},
  {id="hp",name="生命+1",icon=148,apply=function()player_health = player_health + 1 end},
  {id="mov",name="移动速度",icon=153,apply=function()player_speed = player_speed + 0.2 end},
  {id="mag",name="磁吸范围",icon=150,apply=function()magnet_range = magnet_range + 10 end},
  {id="dash",name="冲刺距离",icon=149,apply=function()dash_speed = dash_speed + 1 end},
  {id="reload",name="装填速度",icon=174,apply=function()revolver_reload_delay=flr(revolver_reload_delay*0.8)end}
}
magnet_range=15
fire_dash_unlocked=false
ghost_sword_unlocked=false
ghost_sword_x=0
ghost_sword_y=0
ghost_sword_angle=0
-- removed: current_target_enemy (use helper)
bullet_target_enemy=nil

function choose_random_upgrades()
  local pool={}
  
  -- Add stackable upgrades (always available)
  for u in all(upgrade_pool) do
    add(pool,u)
  end
  
  -- Add skills that aren't unlocked yet
  for s in all(skills_pool) do
    if s.id=="dyn" and not dynamite_unlocked then add(pool,s)
    elseif s.id=="ghost" and not ghost_gun_unlocked then add(pool,s)
    elseif s.id=="shotgun" and bullet_multi_count==0 then add(pool,s)
    elseif s.id=="mir" and not mirror_shot_enabled then add(pool,s)
    elseif s.id=="ric" and bullet_ricochet_count==0 then add(pool,s)
    elseif s.id=="fire_dash" and not fire_dash_unlocked then add(pool,s)
    elseif s.id=="sword" and not ghost_sword_unlocked then add(pool,s)
    end
  end
  
  local selected={}
  for i=1,3 do
    if #pool==0 then break end
    local idx=flr(rnd(#pool))+1
    add(selected,pool[idx])
    deli(pool,idx)
  end
  return selected
end

local function reset_run_state()
  -- restore firmware timer after the game-over overlay's temporary clock
  time=__fc16_time
  t=__fc16_time
  dash_trails={}; dynamites={}; enemies={}; bullets={}; particles={}
  blood_stains={}; xp_gems={}; kill_count=0
  player_health=5; player_level=1; player_xp=0; xp_to_next=8
  player_speed=1.8; bullet_damage=10; bullet_multi_count=0
  bullet_ricochet_count=0; bullet_bounce_enabled=false; mirror_shot_enabled=false
  dynamite_unlocked=false; ghost_gun_unlocked=false; fire_dash_unlocked=false
  ghost_sword_unlocked=false; revolver_current=6; revolver_reloading=false
  revolver_reload_timer=0; enemy_spawn_timer=0; enemy_spawn_delay=30
  spawn_increase_timer=0; dynamite_timer=0; dash_timer=0; dash_cooldown_timer=0
  manual_fire_cooldown=0; invulnerable_timer=0; hit_flash_timer=0
  level_up_pending=false; offered_upgrades={}; selected_card=1
  game_over=false; game_over_slide=0; tutorial_screen=1; tutorial_slide=0
end

function _init()
  reset_run_state()
  player_x=map_center_x
  player_y=map_center_y
  gun_angle=0
  map_seed=flr(rnd(1000000))
  cam_x=player_x-64
  cam_y=player_y-64
  game_state="intro"
  -- MUSIC 0–4 前奏，5 的 BEGIN 到 16 的 END 构成循环乐段
  music(0, 0, MUSIC_CHANNELS_MASK)
end




local DT=0.5
local function ease60(k) return 1-sqrt(1-k) end
local function chance30(p) return rnd()<1-sqrt(1-p) end

function _update()
    if game_state=="intro" then
    intro_t=(intro_t or 0)+1
    if btnp(11) then
      sfx(36)
      if tutorial_screen==1 then
        tutorial_screen=2
        tutorial_slide=0
      elseif tutorial_screen==2 then
        tutorial_slide=1
        t=function()return 0 end
      end
    end
    if tutorial_slide>0 then
      tutorial_slide=min(tutorial_slide+0.1*DT,1)
      if tutorial_slide>=1 then
        game_state="playing"
        t=time
      end
    end
    return
  end
  
  
  if ghost_gun_unlocked then
    local follow=ease60(0.1)
    ghost_gun.x = ghost_gun.x + (player_x+12-ghost_gun.x)*follow
    ghost_gun.y = ghost_gun.y + (player_y+4-ghost_gun.y)*follow
    ghost_gun.bullet_timer=(ghost_gun.bullet_timer or 0)+DT
    if ghost_gun.bullet_timer>=30 then
      ghost_gun.bullet_timer=ghost_gun.bullet_timer-30
      local gx,gy=ghost_gun.x+4,ghost_gun.y+4
      local n=nearest_enemy(gx,gy,false)
      local dx,dy=cos(gun_angle),sin(gun_angle)
      if n then dx=n.x+4-gx dy=n.y+4-gy local l=sqrt(dx*dx+dy*dy) if l>0 then dx = dx / l dy = dy / l end end
      add(bullets,{x=gx,y=gy,dx=dx*bullet_speed,dy=dy*bullet_speed,color=11,trail={},source="ghost"})
      ghost_gun.recoil=2
    end
    ghost_gun.recoil=max((ghost_gun.recoil or 0)-0.2*DT,0)
  end

  -- ghost sword orbiting logic
  if ghost_sword_unlocked then
    ghost_sword_angle=(ghost_sword_angle or 0)+0.02*DT
    ghost_sword_x=player_x+8+cos(ghost_sword_angle)*20
    ghost_sword_y=player_y+8+sin(ghost_sword_angle)*20
    
    -- check for enemy collisions
    for e in all(enemies) do
      local dx=ghost_sword_x-(e.x+4)
      local dy=ghost_sword_y-(e.y+4)
      if sqrt(dx*dx+dy*dy)<8 then
        e.hp = e.hp - 20*DT e.hit_timer=10 e.last_damage=20 e.damage_color=11
        if e.hp<=0 then on_enemy_killed(e,ghost_sword_x-(e.x+4),ghost_sword_y-(e.y+4)) end
      end
    end
  end

  if game_over then
    time=function()
      if game_over then return death_time else return t() end
    end
    game_over_slide=min(game_over_slide+0.1*DT,1)
    if btnp(11) then
      sfx(36)
      game_state="playing"
      _init()
    end
    return
  end

  if level_up_pending then
    time=function()
      if level_up_pending then return 0 else return t() end
    end
    if dirp(0) then
      selected_card=max(1,selected_card-1)
      sfx(32, 1)
    end
    if dirp(1) then
      selected_card=min(3,selected_card+1)
      sfx(32, 1)
    end
    if btnp(5) then
      sfx(36)
      level_up_pending=false
      local upgrade=offered_upgrades[selected_card]
      if upgrade then 
        upgrade.apply()
        invulnerable_timer=60
      end
    end
    return
  end

  local px=player_x
  local py=player_y

  local input_x = (dir(1) and 1 or 0) - (dir(0) and 1 or 0)
  local input_y = (dir(3) and 1 or 0) - (dir(2) and 1 or 0)
  local move_x = input_x * player_speed*DT
  local move_y = input_y * player_speed*DT
  
  if input_x < 0 then
    if not player_facing_left and turn_transition_timer==0 then
      turn_transition_timer=8
      turn_transition_stage=0
    end
    player_facing_left=true 
  end
  if input_x > 0 then
    player_facing_left=false 
  end
  
  local input_len = sqrt(input_x*input_x + input_y*input_y)
  if input_len > 1 then
    move_x = move_x / input_len
    move_y = move_y / input_len
  end
  
  px = px + move_x
  py = py + move_y

  player_prev_direction=player_direction
  
  if direction_transition_timer>0 then
  else
    local is_moving=input_x~=0 or input_y~=0
    
    if is_moving then
      player_direction="down"
      if input_y<0 and input_x~=0 then
        player_direction="up_diag"
      elseif input_y>0 and input_x~=0 then
        player_direction="down_diag"
      elseif input_y<0 then
        player_direction="up"
      elseif input_y>0 then
        player_direction="down"
      elseif input_x~=0 then
        player_direction="side"
      end
      
      player_last_movement_direction=player_direction
    else
      player_direction=player_last_movement_direction
    end
    
    if player_direction~=player_prev_direction then
      local cardinal_dirs={"up","down","side"}
      local is_prev_cardinal=false
      local is_current_cardinal=false
      
      for dir in all(cardinal_dirs) do
        if player_prev_direction==dir then is_prev_cardinal=true end
        if player_direction==dir then is_current_cardinal=true end
      end
      
      if is_prev_cardinal and is_current_cardinal then
        direction_transition_timer=direction_transition_duration
        player_target_direction=player_direction
        
        -- existing diagonal transitions
        if (player_prev_direction=="side" and player_direction=="down") or
           (player_prev_direction=="down" and player_direction=="side") then
          player_direction="down_diag"
        elseif (player_prev_direction=="side" and player_direction=="up") or
               (player_prev_direction=="up" and player_direction=="side") then
          player_direction="up_diag"
        -- new opposite direction transitions
        elseif (player_prev_direction=="up" and player_direction=="down") then
          player_direction="down_diag" -- up -> down_diag -> down
        elseif (player_prev_direction=="down" and player_direction=="up") then
          player_direction="up_diag" -- down -> up_diag -> up
        elseif (player_prev_direction=="side" and player_direction=="side") then
          -- left to right or right to left - use diagonal transition
          if player_facing_left then
            player_direction="down_diag" -- left -> down_diag -> right
          else
            player_direction="up_diag" -- right -> up_diag -> left
          end
        end
      end
    end
  end
  
  if direction_transition_timer>0 then
    direction_transition_timer = max(0,direction_transition_timer-DT)
    if direction_transition_timer<=0 and player_target_direction then
      player_direction=player_target_direction
      player_target_direction=nil
    end
  end
  
  if turn_transition_timer>0 then
    turn_transition_timer = max(0,turn_transition_timer-DT)
    if turn_transition_timer<=0 then
      turn_transition_stage=0
    end
  end

  player_x=mid(0,px,1024-16)
  player_y=mid(0,py,1024-16)
  

  -- autotarget logic - always run this regardless of movement
  local target_enemy=nearest_enemy(player_x+8,player_y+8,false)
  if target_enemy then
    local desired_angle=atan2(target_enemy.y+4-(player_y+8),target_enemy.x+4-(player_x+8))
    local diff=(desired_angle-gun_angle+0.5)%1.0-0.5
    gun_angle = gun_angle + diff*ease60(0.2)
  end

  if (input_x~=0 or input_y~=0) and chance30(0.6) then
    local px=player_x+8
    local py=player_y+16
    emit(px,py,input_x*0.3+(rnd(1)-0.5)*0.4,input_y*0.3+(rnd(1)-0.5)*0.4-0.2,15+flr(rnd(10)),5+flr(rnd(3)),1,nil,true)
  end


  if btnp(5) and dash_timer==0 and dash_cooldown_timer==0 then
    dash_timer=5
    sfx(35)
    invulnerable_timer=60
    -- prefer input direction; if none, use character direction
    local dx_input=input_x
    local dy_input=input_y
    dash_dx=dx_input
    dash_dy=dy_input
    local len=sqrt(dash_dx*dash_dx+dash_dy*dash_dy)
    if len==0 then
      local d=player_direction or player_last_movement_direction or "down"
      local sx=player_facing_left and -1 or 1
      dash_dx=(d=="side" or d=="up_diag" or d=="down_diag") and sx or 0
      dash_dy=(d=="up" or d=="up_diag") and -1 or ((d=="down" or d=="down_diag") and 1 or 0)
      len=sqrt(dash_dx*dash_dx+dash_dy*dash_dy)
    end
    if len>0 then
      dash_dx = dash_dx / len
      dash_dy = dash_dy / len
    end
    dash_cooldown_timer=dash_cooldown
  end

  if dash_timer>0 then
    dash_timer = max(0,dash_timer-DT)
    player_x = player_x + dash_dx*dash_speed*DT
    player_y = player_y + dash_dy*dash_speed*DT
    
    -- Fire dash damage and particles
    if fire_dash_unlocked then
      -- Make player invulnerable during fire dash
      invulnerable_timer=max(invulnerable_timer,60)
      
       for e in all(enemies) do
        if abs(e.x-player_x)<12 and abs(e.y-player_y)<12 then
          e.hp = e.hp - 15*DT e.hit_timer=10 e.last_damage=15 e.damage_color=8
          if e.hp<=0 then on_enemy_killed(e,player_x-e.x,player_y-e.y) end
        end
      end
      
      -- Fire particles
       for i=1,3 do
        emit(player_x+8+rnd(8)-4,player_y+8+rnd(8)-4,rnd(2)-1,rnd(2)-1-0.5,8+rnd(4),8+rnd(2),nil,nil)
      end
    end
    
    if #dash_trails>=3 then
      deli(dash_trails,1)
    end
    add(dash_trails,{
      x=player_x,
      y=player_y,
      spr_id=nil,
      life=6
    })
  end

  for t in all(dash_trails) do
    t.life = t.life - DT
    if t.life<=0 then
      del(dash_trails,t)
    end
  end

  cam_x=mid(0,(player_x+8)-64,1024-128)
  cam_y=mid(0,(player_y+8)-64,1024-128)




  enemy_spawn_timer = enemy_spawn_timer + DT
  if enemy_spawn_timer >= enemy_spawn_delay and #enemies < 50 then
    enemy_spawn_timer = 0
    spawn_enemy()
  end

  for e in all(enemies) do
    local dx,dy=player_x-e.x,player_y-e.y
    local d=sqrt(dx*dx+dy*dy)
    if d>1 then 
      local speed_mult = min(0.8, 0.5 + (player_level - 1) * 0.03)
      local s = player_speed * speed_mult
      e.x = e.x + (dx/d) * s*DT
      e.y = e.y + (dy/d) * s*DT
    end
    for o in all(enemies) do if e~=o and abs(e.x-o.x)<16 and abs(e.y-o.y)<16 then local x=e.x-o.x local y=e.y-o.y if x*x+y*y<16 then e.x = e.x + x*0.1*DT e.y = e.y + y*0.1*DT end end end
    if abs(e.x-player_x)<8 and abs(e.y-player_y)<8 and invulnerable_timer==0 then
      player_health = player_health - 1 camera_shake_timer=10 hit_flash_timer=10 invulnerable_timer=60
      -- 受伤反馈：轻震；死亡加重并延长（SPEC §12.5，无手柄时静默忽略）
      if player_health<=0 then
        game_over=true death_time=flr(time()) game_over_slide=0 sfx(38)
        rumble(255, 180, 40)
      else
        rumble(160, 90, 12)
      end
      del(enemies,e)
    end
  end


  last_target_dx=last_target_dx or 1
  last_target_dy=last_target_dy or 0

  -- bullet targeting logic - continuous
    local px=player_x+4
    local py=player_y+4
    bullet_target_enemy=nearest_enemy(px,py,true)

  if btnp(4) and revolver_current>0 and not revolver_reloading and manual_fire_cooldown<=0 then
    sfx(33, 1)
    bullet_timer=0
    revolver_current = revolver_current - 1
    manual_fire_cooldown=7
    revolver_shake_timer=8
    
    if revolver_current<=0 then
      revolver_reloading=true
      revolver_reload_timer=revolver_reload_delay
      revolver_rotation=0
      -- sfx removed
    end

    last_target_dx=last_target_dx or 1
    last_target_dy=last_target_dy or 0

    local dx,dy
    local nearest=bullet_target_enemy
    if nearest then
      dx=nearest.x+4-px dy=nearest.y+4-py
      local len=sqrt(dx*dx+dy*dy)
      if len>0 then dx = dx / len dy = dy / len last_target_dx=dx last_target_dy=dy gun_angle=atan2(dy,dx) end
    else dx=last_target_dx dy=last_target_dy end



    add(bullets,{x=px,y=py,dx=dx*bullet_speed,dy=dy*bullet_speed,trail={}})
    if mirror_shot_enabled then
      local mirror_dx=-dx*bullet_speed
      local mirror_dy=-dy*bullet_speed
      add(bullets,{x=px,y=py,dx=mirror_dx,dy=mirror_dy,trail={}})
    end

    if bullet_multi_count>0 then
        for i=1,bullet_multi_count do
            local angle_offset=bullet_multi_angle*(i%2==0 and 1 or -1)*ceil(i/2)
            local spread_dx=cos(gun_angle+angle_offset)*bullet_speed
            local spread_dy=sin(gun_angle+angle_offset)*bullet_speed
            add(bullets,{
                x=px,
                y=py,
                dx=spread_dx,
                dy=spread_dy,
                trail={}
            })
        end
    end
  end

  -- update bullets
  for b in all(bullets) do
    b.x = b.x + b.dx*DT b.y = b.y + b.dy*DT
    emit(b.x,b.y,0,0,6,10,1)
    if b.x<0 or b.x>1024 or b.y<0 or b.y>1024 then del(bullets,b) end
  end

  -- bullet collision with enemies
  for b in all(bullets) do
    if not b.bounces then b.bounces = 0 end
    
    local hit = false
    for e in all(enemies) do
        if not hit and abs(b.x - e.x) < 6 and abs(b.y - e.y) < 6 then
            -- Apply damage (ghost gun ignores upgrades)
            local dmg = (b.source=="ghost") and 10 or bullet_damage
            e.hp = e.hp - dmg
            e.hit_timer = 10
            e.last_damage = dmg
            if b.source=="ghost" then e.damage_color=11 end
            hit = true
            
            -- Handle ricochet
            if bullet_bounce_enabled and b.bounces < bullet_ricochet_count and b.source~="ghost" then
                -- Find next closest enemy
                local next_target = nil
                local closest_dist = 999
                
                for next_e in all(enemies) do
                    if next_e ~= e then
                        local dx = next_e.x - b.x
                        local dy = next_e.y - b.y
                        local dist = sqrt(dx*dx + dy*dy)
                        if dist < closest_dist then
                            closest_dist = dist
                            next_target = next_e
                        end
                    end
                end
                
                -- If found another target, redirect bullet
                if next_target then
                    local dx = next_target.x - b.x
                    local dy = next_target.y - b.y
                    local dist = sqrt(dx*dx + dy*dy)
                    b.dx = (dx/dist) * bullet_speed
                    b.dy = (dy/dist) * bullet_speed
                    b.bounces = b.bounces + 1
                    
                    -- Add bounce effect
                    for i=1,6 do emit(b.x,b.y,rnd(2)-1,rnd(2)-1,10,8+b.bounces,1) end
                else
                    del(bullets, b)
                end
            else
                del(bullets, b)
            end
            
            if e.hp <= 0 then
                if e.hit_timer and e.hit_timer > 0 then
                    emit(e.x+4,e.y-6,0,-0.5,30,7,nil,nil,nil,"damage_number",e.last_damage)
                end
                on_enemy_killed(e,b.dx,b.dy)
            end
            break
        end
    end
  end

  -- ghost bullet logic removed

  if dynamite_unlocked then
    dynamite_timer = dynamite_timer + DT
    if dynamite_timer >= dynamite_cooldown then
      dynamite_timer = 0
      local nearest=nearest_enemy(player_x+4,player_y+4,false)
      if nearest then
        local bx = player_x + 4
        local by = player_y + 4
        local tx = nearest.x + 4
        local ty = nearest.y + 4
        -- throw directly at target with slight overshoot
        tx = bx + (tx - bx) * 1.2
        ty = by + (ty - by) * 1.2
        local angle = atan2(ty - by, tx - bx)
        local speed = 2.5
        local vx = cos(angle) * speed
        local vy = sin(angle) * speed
        local dynamite = {
          x = bx,
          y = by,
          dx = vx,
          dy = vy,
          height = 0,
          vyz = -3, -- higher arc
          gravity = 0.3,
          exploded = false,
          timer = 0
        }
        add(dynamites, dynamite)
      end
    end
  end

  -- update dynamites with arched motion and explosion
  for d in all(dynamites) do
    d.timer = d.timer + DT
    d.vyz = d.vyz + d.gravity*DT
    d.height = d.height + d.vyz*DT
    d.x = d.x + d.dx*DT
    d.y = d.y + d.dy*DT
    -- dynamite shadow and trail effect
    if d.height < 0 then
      emit(d.x,d.y,rnd(0.2)-0.1,rnd(0.2)-0.1,6,8,1)
    end
    if d.height > 0 then
      d.height = 0
      d.vyz = -d.vyz * 0.6
      if abs(d.vyz) < 0.4 then
        d.vyz = 0
      end
    end
    if not d.exploded and d.timer >= 5 and d.height == 0 then
      d.exploded = true
      local px = d.x
      local py = d.y
      -- explosion flash and shake
      shake_timer = 5
      circfill(((px)*2), ((py)*2), ((12)*2), COL[7])
      for j=1,18 do local a=rnd(1) local s=1+rnd(1) emit(px,py,cos(a)*s,sin(a)*s,10,8+flr(rnd(2)),1) end
      for e in all(enemies) do
        local dx = px - (e.x + 4)
        local dy = py - (e.y + 4)
      if sqrt(dx*dx + dy*dy) < 18 then
          -- Area damage: 50 damage to all enemies in range
          e.hp = e.hp - 50
          e.hit_timer = 10
          e.last_damage = 50
          e.damage_color = 8
          
          -- Visual explosion effect on hit enemies
          for i=1, 6 do
            local a = rnd(1)
            local s = rnd(1)
            emit(e.x+rnd(8)-4,e.y+rnd(8)-4,cos(a)*s,sin(a)*s,8,8+flr(rnd(2)))
          end
          
          -- Kill enemy if HP reaches 0
            if e.hp<=0 then on_enemy_killed(e,dx,dy) end
        end
      end
    end
    if d.exploded and d.timer > 10 then
      del(dynamites, d)
    end
  end

  -- update particles
  for p in all(particles) do
      p.x = p.x + p.dx*DT
      p.y = p.y + p.dy*DT
    
    -- Apply gravity if particle has it
    if p.gravity then
      p.dy = p.dy + p.gravity*DT
    end
    
    p.life = p.life - DT
    if p.life <= 0 then
      del(particles, p)
    else
      -- Handle fading for walking dust particles
      if p.fade then
        local ratio = p.life / (p.max_life or 20)
        if ratio < 0.3 then
          p.color = 1 -- Fade to black
        elseif ratio < 0.6 then
          p.color = 5 -- Dark gray
        end
      elseif p.type~="blood" then
        -- keep blood splashes red; others use original color shift
        local ratio = p.life / (p.max_life or 6)
        p.color = (ratio < 0.5) and 9 or 10
      end
    end
  end

  -- update blood stains life and fade
  for b in all(blood_stains) do
    b.life = b.life - DT
    if b.life<=0 then del(blood_stains,b) end
  end

  -- gradually increase spawn rate
  spawn_increase_timer = spawn_increase_timer + DT
  if spawn_increase_timer >= spawn_increase_delay then
    spawn_increase_timer = 0
    enemy_spawn_delay = max(10, enemy_spawn_delay - 5) -- cap minimum delay
  end

  -- xp gem logic (reset & simplified)
  for g in all(xp_gems) do
    -- If collected, always switch to collect_bounce state and reset bounce
    if not g.collected and abs(g.x - player_x) < 8 and abs(g.y - player_y) < 8 then
        g.collected = true
        g.collect_timer = 0
        g.collect_duration = 15
        g.z = 0
        g.vz = -2.5 - rnd(1.0)
        g.gravity = 0.3
        g.bounce = 0
        g.max_bounces = 1
        g.state = "collect_bounce"
    end

    -- Drop animation (only if not collected)
    if not g.collected and g.state == "bouncing" then
        g.z = g.z + g.vz*DT
        g.vz = g.vz + g.gravity*DT
        -- Bounce when hitting ground
        if g.z >= 0 then
            g.z = 0
            g.vz = -g.vz * 0.5
            g.bounce = g.bounce + 1
            if abs(g.vz) < 0.2 or g.bounce >= g.max_bounces then
                g.state = "idle"
                g.vz = 0
                g.z = 0
            end
        end
    end

    -- Collection animation (overwrites drop)
    if g.collected and g.state == "collect_bounce" then
        g.x = player_x + 4
        g.y = player_y + 4
        g.z = g.z + g.vz*DT
        g.vz = g.vz + g.gravity*DT
        if g.z >= 0 then
            g.z = 0
            g.vz = -g.vz * 0.5
            g.bounce = g.bounce + 1
            if abs(g.vz) < 0.2 or g.bounce >= g.max_bounces then
                g.state = "collected_done"
            end
        end
    end
  end

  -- Add cleanup for off-screen XP gems with delay
  for g in all(xp_gems) do
    if not is_visible(g.x, g.y) and not g.collected then
      if not g.off_screen_timer then
        g.off_screen_timer = 0
      end
      g.off_screen_timer = g.off_screen_timer + DT
      if g.off_screen_timer >= 1800 then -- 原作 30Hz 下 1 分钟
        del(xp_gems, g)
      end
    else
      g.off_screen_timer = 0
    end
  end

  -- Add cleanup for old particles
  for p in all(particles) do
    if p.life <= 0 or not is_visible(p.x, p.y) then
        del(particles, p)
    end
  end

  if player_xp >= xp_to_next then
    player_level = player_level + 1
    sfx(37, 4)
    level_up_pending = true
    player_xp = 0
    -- tiered xp: 30%->35%->40%->45% based on level
    xp_to_next = flr(xp_to_next * (1.3 + (player_level > 5 and 0.05 or 0) + (player_level > 10 and 0.05 or 0) + (player_level > 15 and 0.05 or 0)))
    local upgrades = choose_random_upgrades()
    offered_upgrades = {}
    for u in all(upgrades) do
        add(offered_upgrades, {
            id = u.id,
            name = u.name,
            apply = u.apply,
            icon = u.icon
        })
    end
  end
  if invulnerable_timer > 0 then invulnerable_timer = max(0,invulnerable_timer-DT) end
  if dash_cooldown_timer > 0 then dash_cooldown_timer = max(0,dash_cooldown_timer-DT) end
  if manual_fire_cooldown > 0 then manual_fire_cooldown = max(0,manual_fire_cooldown-DT) end
  if revolver_shake_timer > 0 then revolver_shake_timer = max(0,revolver_shake_timer-DT) end
  
  if revolver_reloading then
    revolver_rotation = revolver_rotation + 0.3*DT
  end
  
  -- Update revolver reload timer
  if revolver_reloading then
    revolver_reload_timer = revolver_reload_timer - DT
    if revolver_reload_timer <= 0 then
      revolver_reloading = false
      revolver_current = revolver_bullets
    end
  end
  -- No area transitions - starting fresh
  

end

function _draw()
  -- pal(0, 1, 1) -- remap color 0 (black) to color 1
    -- map color 3 to hidden color 131 (with hidden color flag)
  cls(COL[1])   -- 原作 cls(1) 深蓝底（地面精灵会覆盖整屏）
  if hit_flash_timer > 0 then
    -- 受击闪红：PICO 白对应的 FC 7 整帧画成红色（原作 pal(7,8)）
    hit_flash_timer = max(0,hit_flash_timer-DT)
    pal() pal(COL[7], COL[8])
  else
    pal()
  end

  if game_state == "intro" then
    cls(COL[0])
    spr(236, ((0)*2), ((0)*2))
    spr(236, ((120)*2), ((0)*2), 1, 1, true)
    spr(236, ((0)*2), ((120)*2), 1, 1, false, true)
    spr(236, ((120)*2), ((120)*2), 1, 1, true, true)
    
    local s = tutorial_slide * 128
    
    if tutorial_screen == 1 then
      local x, y = 56, 20 - s
      spr(78, ((x)*2), ((y)*2))
      spr(79, ((x + 8)*2), ((y)*2))
      spr(94, ((x)*2), ((y + 8)*2))
      spr(95, ((x + 8)*2), ((y + 8)*2))
      spr(110, ((x)*2), ((y + 16)*2))
      spr(111, ((x + 8)*2), ((y + 16)*2))
      spr(126, ((x)*2), ((y + 24)*2))
      spr(127, ((x + 8)*2), ((y + 24)*2))
      
      x, y = 48, 60 - s
      for i = 0, 3 do
        spr(74 + i, ((x + i * 8)*2), ((y)*2))
        spr(90 + i, ((x + i * 8)*2), ((y + 8)*2))
        spr(106 + i, ((x + i * 8)*2), ((y + 16)*2))
      end
      
      if (intro_t or 0) > 90 then
        print(btnicon("menu") .. " 继续", ((256 - tw(btnicon("menu") .. " 继续")) / 2), ((105 - s)*2), COL[7])
      end
    else
      print("收集詛咒寶石獲得經驗", ((5)*2), ((20 - s)*2), COL[7])
      print("尽可能长时间生存", ((10)*2), ((30 - s)*2), COL[7])
      -- 操作表（图标 + 说明，两列）
      print(btnicon("dpad"), ((30)*2), ((55 - s)*2), COL[8])
      print("移动", ((44)*2), ((55 - s)*2), COL[7])
      print(btnicon("b"), ((30)*2), ((65 - s)*2), COL[8])
      print("冲刺", ((44)*2), ((65 - s)*2), COL[7])
      print(btnicon("a"), ((30)*2), ((75 - s)*2), COL[8])
      print("射击", ((44)*2), ((75 - s)*2), COL[7])
      print("弹尽自动装填", ((30)*2), ((85 - s)*2), COL[8])
      print(btnicon("menu") .. " 进入游戏", ((256 - tw(btnicon("menu") .. " 进入游戏")) / 2), ((105 - s)*2), COL[8])
    end
    return
  end

  -- camera shake logic (explosion flash and shake)
  if shake_timer and shake_timer > 0 then
    camera(((rnd(2) - 1 + cam_x)*2), ((rnd(2) - 1 + cam_y)*2))
    shake_timer = max(0,shake_timer-DT)
  else
    local shake_x, shake_y = 0, 0
    if camera_shake_timer > 0 then
      camera_shake_timer = max(0,camera_shake_timer-DT)
      shake_x, shake_y = rnd(3) - 1, rnd(3) - 1
    end
    camera(((cam_x + shake_x)*2), ((cam_y + shake_y)*2))
  end



  -- Draw floor tiles with proper distribution (screen-only for performance)
  for x = flr(cam_x / 10) - 1, flr((cam_x + 128) / 10) + 1 do
    for y = flr(cam_y / 10) - 1, flr((cam_y + 128) / 10) + 1 do
      local fx = x * 10
      local fy = y * 10
      if fx >= cam_x - 8 and fx <= cam_x + 128 and fy >= cam_y - 8 and fy <= cam_y + 128 then
        local spr_id = get_floor_sprite(fx, fy)
        -- Simple alternating pattern for tile flipping
        local hflip = (flr(fx / 10) + flr(fy / 10)) % 2 == 1
        spr(spr_id, ((fx)*2), ((fy)*2), 1, 1, hflip)
      end
    end
  end

  -- draw blood stains on the ground (scattered red 1px, gradual fade)
  for b in all(blood_stains) do
    if is_visible(b.x,b.y) then
      local ratio=b.life/(b.max or 120)
      local col=COL[ratio<0.25 and 1 or (ratio<0.5 and 5 or 8)]
      pset(((b.x)*2), ((b.y)*2), col)
    end
  end



  -- draw dash ghost trails before player
  for t in all(dash_trails) do
    local frame = walk_animations[player_direction][1]
    local px1 = player_facing_left and t.x + 8 or t.x
    local px2 = player_facing_left and t.x or t.x + 8
    pal(COL[7], COL[5 + flr(t.life / 3)])
    -- spr(frame[1], ((px1)*2), ((t.y)*2), 1, 1, player_facing_left)
    -- spr(frame[2], ((px2)*2), ((t.y)*2), 1, 1, player_facing_left)
    -- spr(frame[3], ((px1)*2), ((t.y + 8)*2), 1, 1, player_facing_left)
    -- spr(frame[4], ((px2)*2), ((t.y + 8)*2), 1, 1, player_facing_left)
    -- additional overlay sprites for dash ghost trails (speed lines)
    local spr_top1, spr_top2, spr_bot1, spr_bot2 = 163, 164, 179, 180
    local offset_x = 0
    local vflip = false
    local hflip = false
    if player_direction == "side" then
      offset_x = player_facing_left and 8 or -8
    elseif player_direction == "up_diag" then
      if dir(0) then
        spr_top1, spr_top2, spr_bot1, spr_bot2 = 165, 166, 181, 182
        hflip = true
      else
        spr_top1, spr_top2, spr_bot1, spr_bot2 = 165, 166, 181, 182
      end
    elseif player_direction == "down_diag" then
      spr_top1, spr_top2, spr_bot1, spr_bot2 = 165, 166, 181, 182
      vflip = true
    elseif player_direction == "up" or player_direction == "down" then
      spr_top1, spr_top2, spr_bot1, spr_bot2 = 167, 168, 183, 184
    end
    spr(spr_top1, ((px1 + offset_x)*2), ((t.y)*2), 1, 1, hflip or player_facing_left, vflip)
    spr(spr_top2, ((px2 + offset_x)*2), ((t.y)*2), 1, 1, hflip or player_facing_left, vflip)
    spr(spr_bot1, ((px1 + offset_x)*2), ((t.y + 8)*2), 1, 1, hflip or player_facing_left, vflip)
    spr(spr_bot2, ((px2 + offset_x)*2), ((t.y + 8)*2), 1, 1, hflip or player_facing_left, vflip)
    pal()
  end

  -- draw particles (before player)
  for p in all(particles) do
    if is_visible(p.x, p.y) then
        if p.type == "damage_number" and p.life > 9 then
                print(p.damage_text, ((p.x)*2), ((p.y)*2), COL[7])
        else
            local size = p.size or 1
                rectfill(((p.x)*2), ((p.y)*2), size*2, size*2, COL[flr(p.color or 7) % 16])
        end
    end
  end

  -- Calculate interpolated position for smooth rendering
  local draw_x = player_x
  local draw_y = player_y
  
  -- draw shadow under player (soft black oval)
  -- 原作 ovalfill(draw_x+2, draw_y+15, draw_x+13, draw_y+17)：FC-16 为中心 +
  -- 双半轴（SPEC §2.3），中心 (player_x+7.5, player_y+16)、半轴 5.5/1
  ovalfill(((player_x + 7.5)*2), ((player_y + 16)*2), 11, 2, COL[0])
  -- draw player with flip logic based on last horizontal movement
  local flip = player_facing_left
  local px1 = flip and player_x + 8 or player_x
  local px2 = flip and player_x or player_x + 8
  
  -- handle turn transition
  if turn_transition_timer > 0 then
    local stage = flr((8 - turn_transition_timer) / 2)
    if stage == 0 then
      -- stage 0: 32, 33, 48, 49
      spr(32, ((px1)*2), ((player_y)*2), 1, 1, flip)
      spr(33, ((px2)*2), ((player_y)*2), 1, 1, flip)
      spr(48, ((px1)*2), ((player_y + 8)*2), 1, 1, flip)
      spr(49, ((px2)*2), ((player_y + 8)*2), 1, 1, flip)
    elseif stage == 1 then
      -- stage 1: 08, 09, 24, 25
      spr(8, ((px1)*2), ((player_y)*2), 1, 1, flip)
      spr(9, ((px2)*2), ((player_y)*2), 1, 1, flip)
      spr(24, ((px1)*2), ((player_y + 8)*2), 1, 1, flip)
      spr(25, ((px2)*2), ((player_y + 8)*2), 1, 1, flip)
    elseif stage == 2 then
      -- stage 2: flip 32, 33, 48, 49
      spr(32, ((px1)*2), ((player_y)*2), 1, 1, true)
      spr(33, ((px2)*2), ((player_y)*2), 1, 1, true)
      spr(48, ((px1)*2), ((player_y + 8)*2), 1, 1, true)
      spr(49, ((px2)*2), ((player_y + 8)*2), 1, 1, true)
    elseif stage == 3 then
      -- stage 3: flip 0, 1, 16, 17
      spr(0, ((px1)*2), ((player_y)*2), 1, 1, true)
      spr(1, ((px2)*2), ((player_y)*2), 1, 1, true)
      spr(16, ((px1)*2), ((player_y + 8)*2), 1, 1, true)
      spr(17, ((px2)*2), ((player_y + 8)*2), 1, 1, true)
    end
  else
    -- normal player drawing
    local anim = walk_animations[player_direction]
    local frame_index = flr(time() * 8) % #anim + 1
    local frame = anim[frame_index]
    
    if invulnerable_timer > 0 then
      local flash = (flr(invulnerable_timer / 2) % 2 == 0)
      -- 原作把 PICO 色 4–8（棕/灰/浅灰/白/红）整组闪红或闪白；FC 对应色号为
      -- COL[4..8] 是玩家精灵实际用到的棕 / 灰 / 浅灰 / 白 / 红存储索引。
      local target = flash and COL[8] or COL[7]
      for c = 4, 8 do pal(COL[c], target) end
    end
    if dash_timer > 0 then
      -- 原作冲刺时把 PICO 色 4–7 整组画成白色（玩家单色化）
      for c = 4, 7 do pal(COL[c], COL[7]) end
    end
    
    spr(frame[1], ((px1)*2), ((player_y)*2), 1, 1, flip)
    spr(frame[2], ((px2)*2), ((player_y)*2), 1, 1, flip)
    spr(frame[3], ((px1)*2), ((player_y + 8)*2), 1, 1, flip)
    spr(frame[4], ((px2)*2), ((player_y + 8)*2), 1, 1, flip)
    
    if invulnerable_timer > 0 then
      pal() -- reset palette after flash
    end
    if dash_timer > 0 then
      pal()
    end
  end

  -- draw tracking silver gun barrel

  -- draw ghost gun attached to player, world space with recoil
  if ghost_gun_unlocked then
    local gx, gy = ghost_gun.x, ghost_gun.y
    local angle = ghost_gun.angle or gun_angle or 0
    local recoil_offset = ghost_gun.recoil or 0
    local rx = cos(angle) * recoil_offset
    local ry = sin(angle) * recoil_offset
    -- circfill(((gx + 4)*2), ((gy + 4)*2), ((5)*2), 11) -- greenish glow (removed)
    local flip_gun = angle > 0.5 or angle < -0.5
    spr(151, ((gx + rx)*2), ((gy + ry)*2), 1, 1, flip_gun)
  end

  -- draw ghost sword orbiting around player
  if ghost_sword_unlocked then
    spr(155, ((ghost_sword_x-4)*2), ((ghost_sword_y-4)*2), 1, 1)
  end

  -- draw enemies only if within camera view plus margin
  for e in all(enemies) do
    if e.x > cam_x - 8 and e.x < cam_x + 128 + 8 and
       e.y > cam_y - 8 and e.y < cam_y + 128 + 8 then
      draw_enemy(e)
    end
  end



  -- draw bullets with simple trail
  for b in all(bullets) do
    -- draw bullet head as circle
    local bullet_color = (b.source == "ghost") and COL[11] or COL[9]
    if b.bounces and b.bounces > 0 then
      if b.source~="ghost" then bullet_color = COL[(8 + b.bounces) % 16] end
    end
    circfill(((b.x)*2), ((b.y)*2), ((1)*2), bullet_color)
    
    -- simple trail: 4 small circles behind bullet
    for i=1,1 do
      local trail_x = b.x - b.dx * i * 0.7
      local trail_y = b.y - b.dy * i * 0.7
      circfill(((trail_x)*2), ((trail_y)*2), ((1)*2), bullet_color)
    end
  end

  -- draw dynamites (throwing dynamites) with bounce, shadow, wobble, and explosion indicator
  for d in all(dynamites) do
    -- dynamite bounces up and down as it travels
    local bx = d.x + 4
    local by = d.y + 4 + d.height
    -- shadow particle (simple shadow under dynamite if in air)
    if d.height < 0 then
      circfill(((d.x)*2), ((d.y)*2), ((2)*2), COL[1])
    end
    -- shadow oval (main shadow under dynamite)
    -- 原作 ovalfill(d.x+2, d.y+11, d.x+6, d.y+13)：中心 + 双半轴换算
    ovalfill(((d.x + 4)*2), ((d.y + 12)*2), 4, 2, COL[0])
    -- dynamite body (use sprite 147 for icon), with wobble
    local offset = flr(d.timer) % 2 == 0 and 0 or 1
    spr(147, ((d.x - 4 + offset)*2), ((d.y - 4 + d.height)*2))
    -- explosion indicator: flashing ring before detonation
    if not d.exploded and d.timer >= 3 then
      local col = COL[flr(d.timer) % 2 == 1 and 8 or 9]
      circ(((bx)*2), ((by)*2), ((14)*2), col)
    end
  end

  -- draw xp gems with bounce animation (draw before enemies)
  local xp_frames = {131, 132, 133, 134}
  local xp_frame = xp_frames[flr(time() * 12) % #xp_frames + 1]
  for g in all(xp_gems) do
    local y = g.y + (g.z or 0)
    -- Draw drop shadow: shrink and darken as gem bounces higher
    if is_visible(g.x, g.y) then
        local shadow_scale = max(0.4, 1 - min(1, abs((g.z or 0) / 12)))
        local shadow_w = 6 * shadow_scale
        local shadow_h = 2 * shadow_scale
        local shadow_col = COL[0] -- always black
        -- 原作 ovalfill(g.x+2±w/2, g.y+7±h/2)：中心 (g.x+2, g.y+7)，
        -- 设备像素半轴 = 虚拟全宽/高（×2 后正好抵消）
        ovalfill(((g.x + 2)*2), ((g.y + 7)*2), shadow_w, shadow_h, shadow_col)
        spr(xp_frame, ((g.x)*2), ((y)*2))
    end
  end

  -- (moved: draw particles now appears before player rendering)

  camera() -- reset camera to (0,0) for UI
  
  -- Draw corner sprites (sprite 236 with appropriate flips)
  spr(236, ((0)*2), ((0)*2), 1, 1, false, false)      -- Top-left (default)
  spr(236, ((120)*2), ((0)*2), 1, 1, true, false)     -- Top-right (horizontal flip)
  spr(236, ((0)*2), ((120)*2), 1, 1, false, true)     -- Bottom-left (vertical flip)
  spr(236, ((120)*2), ((120)*2), 1, 1, true, true)    -- Bottom-right (both flips)
  
  -- Draw revolver bullet counter (bottom left)
  draw_revolver_counter()


  -- draw kill counter at top center with sprite
  local kill_text = ""..kill_count
  local kill_x = (128 - (#kill_text * 4 + 10)) / 2  -- Center the icon + text with 2px spacing
  spr(190, ((kill_x)*2), ((3)*2))  -- Kill icon
  print(kill_text, ((kill_x + 10)*2), ((4)*2), COL[7])  -- Kill number

  -- draw timer at top-right with sprite
  local total_seconds = flr(time())
  local minutes = flr(total_seconds / 60)
  local seconds = total_seconds % 60
  local timer_text = minutes..":"..(seconds < 10 and "0"..seconds or seconds)
  local timer_x = 128 - (#timer_text * 4 + 10) - 5  -- Right align with icon with 2px spacing (moved 4 pixels left)
  spr(189, ((timer_x)*2), ((3)*2))  -- Time icon
  print(timer_text, ((timer_x + 10)*2), ((4)*2), COL[7])  -- Time text

  if game_over then
    -- black curtain overlay
    rectfill(0, 0, 256, 256, COL[0])
    
    -- borders using sprite 236
    spr(236, ((0)*2), ((0)*2), 1, 1, false, false)      -- top-left
    spr(236, ((120)*2), ((0)*2), 1, 1, true, false)     -- top-right
    spr(236, ((0)*2), ((120)*2), 1, 1, false, true)     -- bottom-left
    spr(236, ((120)*2), ((120)*2), 1, 1, true, true)    -- bottom-right
    
    -- slide offset calculation
    local slide_offset = (1 - game_over_slide) * 128
    
    -- death sprite art (2x2) - centered horizontally
    local art_x = 55
    local art_y = 15 - slide_offset
    spr(142, ((art_x)*2), ((art_y)*2))
    spr(143, ((art_x + 8)*2), ((art_y)*2))
    spr(158, ((art_x)*2), ((art_y + 8)*2))
    spr(159, ((art_x + 8)*2), ((art_y + 8)*2))
    
    -- game over text - centered
    local game_over_text = "游戏结束"
    print(game_over_text, ((256 - tw(game_over_text)) / 2), ((45 - slide_offset)*2), COL[8])
    
    -- stats section - aligned vertically
    local stats_y = 60 - slide_offset
    local icon_x = 45
    local text_x = 62
    
    -- kills
    spr(190, ((icon_x)*2), ((stats_y)*2))
    print(""..kill_count, ((text_x)*2), ((stats_y + 1)*2), COL[7])

    -- time
    spr(189, ((icon_x)*2), ((stats_y + 12)*2))
    print(timer_text, ((text_x)*2), ((stats_y + 13)*2), COL[7])

    -- gems collected
    local total_xp = player_xp + (player_level - 1) * xp_to_next
    spr(173, ((icon_x)*2), ((stats_y + 24)*2))
    print(""..total_xp, ((text_x)*2), ((stats_y + 25)*2), COL[7])

    -- restart prompt - centered（原作 press ❎ to restart；本移植死亡重启走 Menu）
    local restart_s = btnicon("menu") .. " 重新开始"
    print(restart_s, ((256 - tw(restart_s)) / 2), ((110 - slide_offset)*2), COL[7])
    return
  end

  -- draw top bar: HP icon and number
  spr(188, ((5)*2), ((3)*2))  -- HP icon (moved 4 pixels right)
  print(""..player_health, ((14)*2), ((4)*2), COL[7])  -- HP number only (moved 4 pixels right)

  -- draw xp bar at bottom left of screen (pixel-art style like screenshot)
  local bar_y = 117
  local bar_width = 83
  local bar_height = 3
  local bar_x = 11
  
  -- Draw black background bar with rounded ends (3 pixels tall)
  rectfill(((bar_x + 2)*2), ((bar_y + 2)*2), (bar_width - 4)*2, 6, COL[0])
  -- Rounded left end
  circfill(((bar_x + 2)*2), ((bar_y + 3)*2), ((1)*2), COL[0])
  -- Rounded right end
  circfill(((bar_x + bar_width - 2)*2), ((bar_y + 3)*2), ((1)*2), COL[0])
  
  -- Draw character icon on the left (sprite 173)
  spr(173, ((bar_x - 8)*2), ((bar_y - 1)*2), 1, 1)
  
  -- Calculate fill width based on XP progress
  local fill_width = flr((player_xp / xp_to_next) * (bar_width - 4)) -- Use full bar width minus padding
  if fill_width > 0 then
    -- Draw yellow fill from left to right (1 pixel tall in center, starting from bar beginning)
    rectfill(((bar_x + 2)*2), ((bar_y + 3)*2), (fill_width + 1)*2, 2, COL[9])
  end

  -- Draw level text inside the bar on the left (after XP fill so it shows on top)
  local lvl_text = "等级 "..player_level
  print(lvl_text, ((bar_x + 4)*2), ((bar_y + 1)*2), COL[7])
  

  
  -- draw current area name (removed - no longer showing area names)

  -- draw unlocked skill icons
  local skills = {{149, (dash_cooldown - dash_cooldown_timer) / dash_cooldown}}
  if dynamite_unlocked then add(skills, {147, dynamite_timer / dynamite_cooldown}) end
  if ghost_gun_unlocked then add(skills, {151, (ghost_gun.bullet_timer or 0) / 30}) end
  if bullet_multi_count>0 then add(skills, {157, 0}) end
  if mirror_shot_enabled then add(skills, {156, 0}) end
  if bullet_ricochet_count>0 then add(skills, {154, 0}) end
  if fire_dash_unlocked then add(skills, {138, 0}) end
  if ghost_sword_unlocked then add(skills, {155, 0}) end

  
  local start_x = 2
  for i, skill in ipairs(skills) do
    local x = start_x + (i - 1) * 11
    -- Draw square placeholder with 1 pixel removed from each corner
    rectfill(((x - 1)*2), ((103)*2), 20, 20, COL[0])
    pset(((x - 1)*2), ((103)*2), COL[1]) -- Remove top-left corner
    pset(((x + 8)*2), ((103)*2), COL[1]) -- Remove top-right corner
    pset(((x - 1)*2), ((112)*2), COL[1]) -- Remove bottom-left corner
    pset(((x + 8)*2), ((112)*2), COL[1]) -- Remove bottom-right corner
    -- Draw skill icon
    spr(skill[1], ((x)*2), ((104)*2))
    -- Draw cooldown bar only for skills that have cooldowns
    if skill[2] > 0 then
    local filled = flr(8 * mid(0, skill[2], 1))
    rectfill(((x)*2), ((114)*2), filled*2, 2, skill[2] >= 1 and COL[11] or COL[8])
    end
  end

  -- draw level-up cards
  if level_up_pending then
    for i=1,3 do
      local x = 20 + (i - 1) * 32
      local y = 45  -- Moved down from 32 to 45
      
      card_offsets = card_offsets or {0, 0, 0}
      local target_offset = (i == selected_card) and -4 or 0
      card_offsets[i] = card_offsets[i] + (target_offset - card_offsets[i]) * ease60(0.2)
      local offset_y = card_offsets[i] + ((i == selected_card) and sin(time() * 3) * 2 or 0)

      -- draw black card shadow first（原作 pal(8,0)..pal(1,0)：卡框用到的
      -- PICO 色 2/4/6/7/8/9/10/14 → FC {5,10,11,13,19,27,28,31} 整组压黑）
      if i == selected_card then
        for c in all({5, 10, 11, 13, 19, 27, 28, 31}) do
          pal(c, COL[0])
        end
        for row=0,3 do
          for col=0,2 do
            spr(128 + col + row * 16, ((x + col * 8 + 2)*2), ((y + row * 8 + offset_y + 2)*2))
          end
        end
        pal()
      end

      -- draw card frame
      for row=0,3 do
        for col=0,2 do
          spr(128 + col + row * 16, ((x + col * 8)*2), ((y + row * 8 + offset_y)*2))
        end
      end

      -- draw upgrade icon
      local upgrade = offered_upgrades[i]
      if upgrade then
        spr(upgrade.icon or 147, ((x + 8)*2), ((y + 12 + offset_y)*2))
      end

      -- draw selection indicator
      if i == selected_card then
        print("选择", ((x + 8)*2), ((y + 34 + offset_y)*2), COL[7])
      end
    end

    -- upgrade box with sprite 237 corners（原作红底 rectfill 色 8 + 黑字）
    rectfill(0, 212, 256, 44, COL[8])
    spr(237, ((0)*2), ((106)*2))
    spr(237, ((120)*2), ((106)*2), 1, 1, true)
    spr(237, ((0)*2), ((120)*2), 1, 1, false, true)
    spr(237, ((120)*2), ((120)*2), 1, 1, true, true)
    print("选择一项升级", ((256 - tw("选择一项升级")) / 2), ((110)*2), COL[0])

    local current_upgrade = offered_upgrades[selected_card]
    if current_upgrade then
      -- Fusion 比例步进，用 tw 计宽居中（#str 是字节数，不适用）
      print(current_upgrade.name, ((256 - tw(current_upgrade.name)) / 2), ((115)*2), COL[7])
    end
    -- 升级选择操作提示（一行图标）
    local pick = btnicon("dpad") .. " 选择　" .. btnicon("b") .. " 确认"
    print(pick, ((256 - tw(pick)) / 2), ((122)*2), COL[0])
  end

  -- update collected xp gems positions
  for g in all(xp_gems) do
    if g.collected then
      g.collect_timer = g.collect_timer + DT
      g.x = player_x + 4
      g.y = player_y + 4
      g.z = g.z + g.vz*DT
      g.vz = g.vz + g.gravity*DT
      if g.z >= 0 then
        g.z = 0
        g.vz = -g.vz * 0.5
        g.bounce = g.bounce + 1
        if abs(g.vz) < 0.2 or g.bounce >= g.max_bounces then
          g.state = "collected_done"
        end
      end
      if g.collect_timer / g.collect_duration >= 1 and g.state == "collected_done" then
        del(xp_gems, g)
        player_xp = player_xp + 1
        sfx(34, 2)
      end
    else
      local dx = player_x + 4 - g.x
      local dy = player_y + 4 - g.y
      local dist = sqrt(dx * dx + dy * dy)
      if dist < magnet_range then
        local k=ease60(0.2 + (1 - dist/magnet_range) * 0.4)
        g.x = g.x + dx*k
        g.y = g.y + dy*k
      end
    end
  end

  pal() -- reset palette at end of draw
end

function is_visible(x,y)
    return x>cam_x-16 and x<cam_x+144 and y>cam_y-16 and y<cam_y+144
end

-- helpers to reduce duplicate tokens
function emit(x,y,dx,dy,life,color,shape,gravity,fade,type,damage_text)
  add(particles,{
    x=x,y=y,dx=dx or 0,dy=dy or 0,
    life=life or 6,max_life=life or 6,
    color=color or 10,
    size=shape,shape=shape,
    gravity=gravity,fade=fade,
    type=type,damage_text=damage_text
  })
end

function add_xp_gem_at(x,y)
  if #xp_gems<MAX_XP_GEMS then
    add(xp_gems,{x=x,y=y,vz=-2.5-rnd(1.5),z=0,gravity=0.3,bounce=0,max_bounces=3,state="bouncing"})
  end
end

function on_enemy_killed(e,hx,hy)
  add_xp_gem_at(e.x,e.y)
  -- blood splash particles
  local bx,by=e.x+4,e.y+4
  if hx and hy then
    local base=(atan2(hy,hx)+0.5)%1
    for i=1,20 do local a=base+(rnd(0.3)-0.15) local s=2+rnd(3) emit(bx,by,cos(a)*s,sin(a)*s,8+rnd(8),8,1,0.2,nil,"blood") end
  else
    for i=1,20 do local a=rnd(1) local s=2+rnd(3) emit(bx,by,cos(a)*s,sin(a)*s,8+rnd(8),8,1,0.2,nil,"blood") end
  end
  add_blood(bx,by)
  kill_count = kill_count + 1
  del(enemies,e)
end

function nearest_enemy(ax,ay,onscreen)
  local best=nil
  local bestd=999999
  for e in all(enemies) do
    if not onscreen or (e.x>cam_x-8 and e.x<cam_x+136 and e.y>cam_y-8 and e.y<cam_y+136) then
      local dx=e.x+4-ax
      local dy=e.y+4-ay
      local d=dx*dx+dy*dy
      if d<bestd then bestd=d best=e end
    end
  end
  return best
end

function add_blood(x,y)
  for i=1,28 do
    local l=60+flr(rnd(90))
    add(blood_stains,{x=x+rnd(12)-6,y=y+rnd(8)-4,life=l,max=l})
  end
end

function get_floor_sprite(x,y)
    local rx=x+map_seed*0.1
    local ry=y+map_seed*0.15
    local large_noise=(sin(rx*0.005)+cos(ry*0.005))*0.5+0.5
    local medium_noise=(sin(rx*0.01)+cos(ry*0.01))*0.5+0.5
    local small_noise=(sin(rx*0.02)+cos(ry*0.02))*0.5+0.5
    local organic_value=(large_noise*0.6+medium_noise*0.3+small_noise*0.1)
    local horizontal_stretch=(sin(rx*0.003)+cos(ry*0.008))*0.5+0.5
    local vertical_stretch=(sin(rx*0.008)+cos(ry*0.003))*0.5+0.5
    local stone_influence=(organic_value+horizontal_stretch*0.3+vertical_stretch*0.3)/1.6
    if stone_influence>0.92 then
        local seed=(x*928371+y*472882+map_seed)%#stone_sprites+1
        return stone_sprites[seed]
    else
        local seed=(x*73856093+y*19349663+map_seed*83492791)%#vegetation_sprites+1
        return vegetation_sprites[seed]
    end
end



function spawn_enemy()
    local available_types={}
    local game_time=flr(time())
    for i,etype in ipairs(enemy_types) do
        if game_time>=etype.unlock_time then add(available_types,i) end
    end
    if #available_types==0 then add(available_types,1) end
    local type_idx=available_types[flr(rnd(#available_types))+1]
    local enemy_type=enemy_types[type_idx]
    local margin=20
    local ex,ey
    local side=flr(rnd(4))
    if side==0 then ex=cam_x-margin ey=cam_y+rnd(128)
    elseif side==1 then ex=cam_x+128+margin ey=cam_y+rnd(128)
    elseif side==2 then ex=cam_x+rnd(128) ey=cam_y-margin
    else ex=cam_x+rnd(128) ey=cam_y+128+margin end
    add(enemies,{x=ex,y=ey,type=type_idx,hp=enemy_type.hp,first_sprite=enemy_type.first_sprite})
end

function draw_enemy(e)
    -- 原作 ovalfill(e.x+2, e.y+7, e.x+6, e.y+9)：FC-16 为中心 + 双半轴，
    -- 中心 (e.x+4, e.y+8)、半轴 2/1（脚下扁椭圆）
    ovalfill(((e.x + 4)*2), ((e.y + 8)*2), 4, 2, COL[0])
    local frames={e.first_sprite,e.first_sprite+16,e.first_sprite+32,e.first_sprite+48}
    local frame_index=flr(time()*6)%#frames+1
    local current_frame=frames[frame_index]
    local flip=e.x<player_x
    spr(current_frame, ((e.x)*2), ((e.y)*2), 1, 1, flip)
    
    -- draw targeting indicator (dotted circle) if this enemy is the bullet target - draw on top
    if e==bullet_target_enemy then
        for i=0,8 do
            local angle=i/9
            local x=e.x+4+cos(angle)*10
            local y=e.y+4+sin(angle)*10
            pset(((x)*2), ((y)*2), COL[8])
        end
    end

    local etype=mid(1,e.type or 1,#enemy_types)
    if e.hp<enemy_types[etype].hp then
        local max_hp=enemy_types[etype].hp
        local hp_width=8
        local hp_filled=(hp_width*e.hp)/max_hp
        rectfill(((e.x)*2), ((e.y-2)*2), (hp_width+1)*2, 4, COL[0])
        rectfill(((e.x)*2), ((e.y-2)*2), (hp_filled+1)*2, 4, COL[8])
    end
    if e.hit_timer and e.hit_timer>0 then
        e.hit_timer = max(0,e.hit_timer-DT)
        local damage_color=e.damage_color or 7
        print(e.last_damage, ((e.x+4)*2), ((e.y-6-(10-e.hit_timer))*2), COL[flr(damage_color) % 16])
    end
end









function draw_revolver_counter()
  local center_x=111
  local center_y=111
  local shake_x=0
  local shake_y=0

  if revolver_shake_timer>0 then
    shake_x=rnd(1)-0.5
    shake_y=rnd(1)-0.5
  end

  -- 黑盘、弹巢旋转与中心图标的共用圆心（原作三处圆心互差 1px，FC-16 2× 下
  -- 更明显，统一到 (center_x+1, center_y+1)）
  local hub_x=center_x+1+shake_x
  local hub_y=center_y+1+shake_y
  local spacing=8

  circfill((hub_x*2), (hub_y*2), ((spacing+5)*2), COL[0])
  -- 6 发弹巢：正六边形顶点绕盘心旋转（换弹时整体旋转）。弹壳图案在 16×16
  -- 格内中心位于 +6.5/+6.5（占 0..13 行列），绘制原点相应对齐素材视觉中心
  for i=1,revolver_bullets do
    local a=(i-1)/revolver_bullets-0.25+revolver_rotation
    local pos_x=hub_x+cos(a)*spacing
    local pos_y=hub_y+sin(a)*spacing
    if i<=revolver_current then spr(170, ((pos_x)*2 - 6.5), ((pos_y)*2 - 6.5), 1, 1) else spr(171, ((pos_x)*2 - 6.5), ((pos_y)*2 - 6.5), 1, 1) end
  end
  -- 中心图标图案中心位于格内 +6.5/+8.5（行 4..13、列 2..11）
  spr(172, ((hub_x)*2 - 6.5), ((hub_y)*2 - 8.5), 1, 1)
end
