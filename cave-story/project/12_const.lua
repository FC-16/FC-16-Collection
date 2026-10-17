-- 12_const.lua —— 引擎常数（单位：位置/速度均为 1/512 像素的整数子像素）
-- 数值来源：doukutsu-rs engine_constants 与原版引擎行为，冻结为 Lua integer

SUB = 512          -- 0x200：1 像素
TILE = 8192        -- 0x2000：16 像素

P = {              -- 玩家物理（原版 air_physics）
  max_dash = 0x32c,
  max_move = 0x5ff,
  gravity_air = 0x20,
  gravity_ground = 0x50,
  dash_air = 0x20,
  dash_ground = 0x55,
  resist = 0x33,
  jump = 0x500,
}
PLR_HIT = { l = 5, t = 8, r = 5, b = 8 }   -- 玩家碰撞盒（像素，半宽/半高）
WALK_CYCLE = { 1, 0, 2, 0 }                -- 行走帧序列

WEAPON = {                                 -- 北极星（武器 2，弹种 4/5/6）
  level_table = { 10, 20, 10 },            -- L1→L2 / L2→L3 / L3 上限
  bullets = {
    { dmg = 1, life = 1, life_t = 8 },
    { dmg = 2, life = 1, life_t = 12 },
    { dmg = 4, life = 1, life_t = 16 },
  },
  speed = 0x1000,
  max_on_screen = 2,
}

SFX = { blip = 0, xp = 1, shoot = 2, shoot3 = 3, hit = 4, die = 5,
        hurt = 6, jump = 7, critter = 8, thud = 9, door = 10,
        chest = 11, bounce = 12, save = 13, levelup = 14 }

MAPD = { [13] = { 0, 0 }, [12] = { 0, 16 }, [11] = { 64, 0 }, [90] = { 24, 0 } }
