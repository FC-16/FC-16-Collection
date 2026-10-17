-- 常量：调色板语义色、音频通道、瓦片带布局
-- ------------------------------------------------------------ 常量
FLR, CEIL, ABS = math.floor, math.ceil, math.abs
MIN, MAX, MID = math.min, math.max, mid

-- RUN.seed 保留完整 u32 显示值；srand 的脚本入口只接受 signed32。
function SRAND_U32(seed)
  seed = seed % 4294967296
  srand(seed >= 2147483648 and seed - 4294967296 or seed)
end

CL = {
  bg = 0, panel = 1, hole = 2, ink = 3, d3 = 4, g1 = 5, g2 = 6, white = 7,
  frost = 8, steel = 9, slate = 10, dusk = 11, night = 12,
  cream = 22, amber = 23, gold = 30, yellow = 31,
  lime = 33, green = 35, teal = 36, navy = 39,
  blue = 41, sky = 42, cyan = 43, ice = 44,
  rose = 56, pink = 57, red = 59, crimson = 60, dred = 61, maroon = 62,
  violet = 48, purple = 49, plum = 53, orchid = 54,
}
CL.cur = 31       -- 光标黄
CL.fd = 41        -- 出牌钮
CH_UI = 5

-- 瓦片号（gen_assets.py 带式布局：32×32 精灵占 2 行瓦片带，带内 8 张）
T_BACK, T_JOKER, T_BLIND = 224, 256, 480
function band_tile(base, idx) return base + math.floor(idx / 8) * 32 + (idx % 8) * 2 end
