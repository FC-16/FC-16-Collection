-- 20_tsc.lua —— 迷你 TSC 解释器
-- 支持指令：#dddd 事件、<MSG <NOD <CLR <CLO <KEY <PRI <END <WAI <TRA
--           <FL+ <FL- <FLJ <IT+ <ITJ <AM+ <AMJ <SOU <CNP <DNP <EVE <TUR <SKJ
-- 其余原版指令（<CMU <MYD <ANP 等）解析为无操作，便于复用原脚本片段。

local function msg_total(m)
  local n = 0
  for i = 1, #m.lines do n = n + #m.lines[i] end
  return n
end

scr = {
  active = false,   -- 是否有事件在跑
  lock = false,     -- 是否锁玩家输入（<PRI 或对话中）
  toks = {},        -- 令牌序列 {op=..., a=...}
  pc = 0,
  wait = 0,         -- 帧等待
  wait_key = false,
  msg = nil,        -- {pages={{line...}}, page=, chars=, blink=}
  pend = nil,       -- 未排版的剩余文本
  fade_cb = nil,    -- <TRA 等待淡出完成的回调
  trans = nil,      -- 待执行的转场 {stage,ev,tx,ty}
}

local function tokenize(s)
  local t = {}
  local i = 1
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "<" then
      local j = s:find("<", i + 1, true)
      local seg = s:sub(i + 1, (j or n + 1) - 1)
      t[#t + 1] = { cmd = seg }
      i = j or n + 1
    else
      local j = s:find("<", i, true)
      t[#t + 1] = { text = s:sub(i, (j or n + 1) - 1) }
      i = j or n + 1
    end
  end
  return t
end

function scr_run(ev)
  local st = SCRIPTS[G.stage]
  local text = st and st[ev]
  if not text then
    scr.active = false
    scr.lock = false
    return
  end
  scr.active = true
  scr.lock = true
  scr.toks = tokenize(text)
  scr.pc = 1
  scr.wait = 0
  scr.wait_key = false
  scr.msg = nil
  scr.pend = nil
end

function scr_stop()
  scr.active = false
  scr.lock = false
  scr.msg = nil
  scr.pend = nil
  scr.fade_cb = nil
end

-- 排版：把文本按 \n 分行、按每页 3 行分页
local function msg_push(str)
  local m = scr.msg
  for line in str:gmatch("([^\n]*)\n?") do
    if #m.lines < 3 then
      m.lines[#m.lines + 1] = line
    else
      m.overflow = (m.overflow or "") .. line .. "\n"
    end
  end
end

local function msg_open()
  scr.msg = { lines = {}, chars = 0, blink = 0 }
end

-- 令牌参数解析：原版 TSC 为十进制定宽数字，冒号分隔
local function args(s)
  local r = {}
  for v in s:gmatch("[^:]+") do
    r[#r + 1] = tonumber(v) or 0
  end
  return r
end

local function exec(tok)
  local c = tok.cmd
  local op = c:sub(1, 3)
  local rest = c:sub(4)
  if tok.text then
    if scr.msg then msg_push(tok.text:gsub("\r", "")) end
    return true
  end
  if op == "MSG" then
    msg_open()
    local tail = rest
    if tail ~= "" then msg_push(tail) end
  elseif op == "NOD" then
    if scr.msg and (scr.msg.overflow or "") ~= "" then
      scr.msg.lines = {}
      local ov = scr.msg.overflow
      scr.msg.overflow = nil
      msg_push(ov)
    end
    if scr.msg then scr.msg.chars = msg_total(scr.msg) end
    scr.wait_key = true
    sfx(SFX.blip)
    return false
  elseif op == "CLR" then
    if scr.msg then scr.msg.lines = {} end
  elseif op == "CLO" then
    scr.msg = nil
  elseif op == "KEY" then
    -- 无操作：不阻塞（文本框由 NOD/END 控制）
  elseif op == "PRI" then
    scr.lock = true
  elseif op == "END" then
    scr_stop()
    return false
  elseif op == "EVE" then
    local a = args(rest)
    scr_stop()
    scr_run(a[1])
    return false
  elseif op == "WAI" then
    scr.wait = tonumber(rest) or 0
    return false
  elseif op == "TRA" then
    local a = args(rest)
    scr.trans = { stage = a[1], ev = a[2], tx = a[3], ty = a[4] }
    return false
  elseif op == "FL+" then
    flset(tonumber(rest) or 0)
  elseif op == "FL-" then
    flclr(tonumber(rest) or 0)
  elseif op == "FLJ" then
    local a = args(rest)
    if flget(a[1]) then
      scr_stop()
      scr_run(a[2])
      return false
    end
  elseif op == "IT+" then
    local a = args(rest)
    G.items[a[1]] = true
  elseif op == "ITJ" then
    local a = args(rest)
    if G.items[a[1]] then
      scr_stop()
      scr_run(a[2])
      return false
    end
  elseif op == "AM+" then
    local a = args(rest)
    give_weapon(a[1], (a[2] or 0) + 1)
  elseif op == "AMJ" then
    local a = args(rest)
    if G.weapon and G.weapon.id == a[1] then
      scr_stop()
      scr_run(a[2])
      return false
    end
  elseif op == "SOU" then
    sfx(tonumber(rest) or 0)
  elseif op == "CNP" then
    local a = args(rest)
    npc_change_event(a[1], a[2])
  elseif op == "DNP" then
    local a = args(rest)
    npc_delete_event(a[1])
  elseif op == "TUR" then
    -- 玩家面向最近的 interactable：简化为不动
  elseif op == "SKJ" then
    local a = args(rest)
    if flget(a[1]) then
      scr_stop()
      scr_run(a[2])
      return false
    end
  else
    -- <CMU <MYD <RMU <ANP <HMC <SMC <GIT <FAI <FAO <WAI 以外的原版指令一律忽略
  end
  return true
end

function scr_update()
  if scr.msg and not scr.wait_key then
    -- 打字机：每帧 2 字符
    scr.msg.chars = math.min(scr.msg.chars + 2, msg_total(scr.msg))
  end
  if scr.trans then
    -- 等淡出完成（由 game 层驱动 fade，之后执行转场）
    G.fade_tgt = 4
    if G.fade >= 4 then
      local t = scr.trans
      scr.trans = nil
      stage_switch(t.stage, t.ev, t.tx, t.ty)
    end
    return
  end
  if not scr.active then return end
  if scr.wait > 0 then
    scr.wait = scr.wait - 1
    return
  end
  if scr.wait_key then
    if btnp("a") or btnp("b") or btnp("x") or btnp("y") then
      scr.wait_key = false
    end
    return
  end
  while scr.pc <= #scr.toks do
    local tok = scr.toks[scr.pc]
    scr.pc = scr.pc + 1
    if not exec(tok) then
      return
    end
    if scr.wait > 0 or scr.wait_key then
      return
    end
  end
  -- 令牌耗尽：结束
  scr_stop()
end

-- 事件是否需要玩家硬锁定（对话、门、演出）
function scr_locks_player()
  return scr.active or scr.trans ~= nil
end
