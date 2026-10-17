-- 14_util.lua —— 标志位、调色淡出、通用工具

local FL = {}

-- bit32 返回无符号 32 位数；Cave Story 的 Q16.16 坐标使用算术右移。
local function sar(x, n)
  local r = bit32.arshift(x, n)
  return r >= 0x80000000 and r - 0x100000000 or r
end

local function lsl(x, n)
  local r = bit32.lshift(x, n)
  return r >= 0x80000000 and r - 0x100000000 or r
end

function flreset()
  for i = 0, 55 do FL[i] = 0 end
end

function flset(n)
  local w = sar(n, 5)
  FL[w] = bit32.bor(FL[w] or 0, bit32.lshift(1, bit32.band(n, 31)))
end

function flclr(n)
  local w = sar(n, 5)
  FL[w] = bit32.band(FL[w] or 0, bit32.bnot(bit32.lshift(1, bit32.band(n, 31))))
end

function flget(n)
  local w = FL[sar(n, 5)] or 0
  return bit32.band(w, bit32.lshift(1, bit32.band(n, 31))) ~= 0
end

-- 存档用标志位字数组（1-based，56 项；SPEC §13 JSON 数组不允许空洞）
function flsave()
  local t = {}
  for i = 0, 55 do t[i + 1] = FL[i] or 0 end
  return t
end

function flload(t)
  if type(t) ~= "table" then t = {} end
  for i = 0, 55 do
    local w = t[i + 1]
    FL[i] = type(w) == "number" and w or 0
  end
end

-- 显示期调色淡出（SPEC §2.3 典型用途）：把全部色号朝 #131313 压暗
local FADE_PAT = { nil, 1, 2, 3 }
local dark_cache = {}

local function darker(c, k)
  local key = c * 4 + k
  if dark_cache[key] then return dark_cache[key] end
  -- FC 调色板表（仅本表使用，与 SPEC §2.2 一致）
  local PAL = CS_PAL
  local rgb = PAL[c + 1]
  local r, g, b = rgb % 256, sar(rgb, 8) % 256, sar(rgb, 16)
  r = math.floor(r * (4 - k) / 4)
  g = math.floor(g * (4 - k) / 4)
  b = math.floor(b * (4 - k) / 4)
  -- 最近色匹配（排除 0 号以保留纯黑专用，但压暗目标本身就是 0 号附近，
  -- 允许直接映射到 0 号之外的最近暗色会破坏黑场，这里允许全 64 色匹配）
  local best, bd = 0, bit32.lshift(1, 30)
  for i = 0, 63 do
    local pc = PAL[i + 1]
    local pr, pg, pb = pc % 256, sar(pc, 8) % 256, sar(pc, 16)
    local d = (r - pr) * (r - pr) + (g - pg) * (g - pg) + (b - pb) * (b - pb)
    if d < bd then best, bd = i, d end
  end
  dark_cache[key] = best
  return best
end

function apply_fade(lvl)
  if lvl <= 0 then
    pal()
  elseif lvl >= 4 then
    -- 全黑由 draw 阶段的 rectfill 兜底
    pal()
  else
    for c = 0, 63 do
      pal(c, darker(c, lvl), 1)
    end
  end
end
