-- 输入包装：按键边沿、方向重复、扳机轴
-- ------------------------------------------------------------ 输入包装
-- GBA 宏 → FC-16 按钮：A=a B=b LB=lb RB=rb；LT/RT 是模拟轴 lt/rt（没有独立按钮位）
function kA() return btnp("a") end
function kB() return btnp("b") end
function kL() return btnp("lb") end
function kR() return btnp("rb") end

-- 方向派发：首次边沿立即响应，保持 12 帧后每 4 帧重复一次，各方向独立计时。
-- 每帧每方向至多派发一次：同一帧内多个消费者不会重复消费边沿或重复推进计时。
-- 同一轴两个方向同时按住视为取消（不动、不双向各走一步），并重置按下延迟。
local REP_HOLD, REP_RATE = 12, 4
-- d 为方向名 left/right/up/down（与 dir/dirp 同名）
local REP = { left = 0, right = 0, up = 0, down = 0 }
local DIRD = { left = false, right = false, up = false, down = false }
local CXL = { left = false, right = false, up = false, down = false }
function dpr(d)
  if DIRD[d] then return false end
  if CXL[d] then REP[d] = REP_HOLD return false end
  if dirp(d) then DIRD[d], REP[d] = true, REP_HOLD return true end
  if REP[d] == 0 or not dir(d) then REP[d] = 0 return false end
  REP[d] = REP[d] - 1
  if REP[d] > 0 then return false end
  REP[d], DIRD[d] = REP_RATE, true
  return true
end

-- 扳机 LT/RT：行程过半视为按下；只取按下边沿
local TRG_AXIS = { "lt", "rt" }
local TRG, TRGE = { false, false }, { false, false }
function kLTp() return TRGE[1] end
function kRTp() return TRGE[2] end

-- 每逻辑帧开头轮询：同轴取消标记与扳机边沿，各屏幕共享同一份解析结果
function poll_input()
  local hx, vt = dir("left") and dir("right"), dir("up") and dir("down")
  CXL.left, CXL.right, CXL.up, CXL.down = hx, hx, vt, vt
  DIRD.left, DIRD.right, DIRD.up, DIRD.down = false, false, false, false
  for k = 1, 2 do
    local down = axis(TRG_AXIS[k]) >= 0.5
    TRGE[k], TRG[k] = down and not TRG[k], down
  end
end
function buzz() sfx(20, CH_UI) end
function ri(n) return math.floor(rnd(n)) + 1 end
