//! 演示卡带端到端验证：crimson_night 原生60Hz步进与balatro对局输入。
//! crimson_night读取单文件源码；balatro加载静态require打包产物。

use fc16_core::cart::CartData;
use fc16_core::font::Font;
use fc16_core::machine::{Machine, NoopHost, RunState};
use fc16_core::Tunables;
use std::sync::Arc;

fn crimson_machine() -> Machine {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let root = manifest.as_path();
    let code = std::fs::read_to_string(root.join("crimson_night/crimson_night.lua"))
        .expect("crimson_night.lua");
    let font = Arc::new(Font::from_bytes(fc16_core::config::FONT).unwrap());
    Machine::new(
        CartData {
            name: "crimson".into(),
            code,
            ..Default::default()
        },
        Tunables::default(),
        7,
        0,
        String::new(),
        font,
        None,
    )
}

fn balatro_machine() -> Machine {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let root = manifest.as_path();
    // 源码按构建期静态 require 拆分为多模块（balatro/*.lua），测试直接加载
    // 打包产物，与发行内容同源（产物一致性另见 FC16-AC-104）。
    let cart = CartData::parse_file(
        &std::fs::read(root.join("balatro/balatro.fc16")).expect("balatro.fc16"),
        "balatro.fc16",
    )
    .expect("balatro.fc16");
    let font = Arc::new(Font::from_bytes(fc16_core::config::FONT).unwrap());
    Machine::new(cart, Tunables::default(), 1, 0, String::new(), font, None)
}

/// 跳过菜单与存档，直接把小丑牌推进到"可以出牌"的阶段。
fn to_play_phase(m: &mut Machine, host: &mut NoopHost) {
    m.lua
        .load("RUN.deck = 0 new_run(1) G.blind = 1 st, tt = 'round', 0 start_round()")
        .exec()
        .unwrap();
    for _ in 0..60 {
        m.frame([fc16_core::input::InputState::ZERO; 4], host);
    }
    assert_eq!(
        m.lua.load("return PS.ph").eval::<String>().unwrap(),
        "input",
        "发牌动画后应进入出牌阶段"
    );
}

fn key(m: &mut Machine, frames: u32, buttons: u16, lt: u16, rt: u16) {
    let input = fc16_core::input::InputState {
        buttons,
        lt,
        rt,
        ..fc16_core::input::InputState::ZERO
    };
    let mut host = NoopHost;
    for _ in 0..frames {
        m.frame(
            [
                input,
                fc16_core::input::InputState::ZERO,
                fc16_core::input::InputState::ZERO,
                fc16_core::input::InputState::ZERO,
            ],
            &mut host,
        );
    }
}

fn cursor(m: &Machine) -> i64 {
    m.lua.load("return PS.cur").eval().unwrap()
}

fn hand(m: &Machine) -> Vec<(i64, i64)> {
    let s: String = m
        .lua
        .load("local o='' for _,c in ipairs(DH) do o=o..c.s..','..c.r..' ' end return o")
        .eval()
        .unwrap();
    s.split_whitespace()
        .map(|pair| {
            let (suit, rank) = pair.split_once(',').unwrap();
            (suit.parse().unwrap(), rank.parse().unwrap())
        })
        .collect()
}

use std::path::PathBuf;

#[test]
fn crimson_night_native_60hz_keeps_original_one_second_distance() {
    let mut m = crimson_machine();
    let mut host = NoopHost;
    let mut start = [0u16; 4];
    start[0] = 1 << 11;
    m.frame(
        [
            fc16_core::input::InputState::from_buttons(start[0]),
            fc16_core::input::InputState::ZERO,
            fc16_core::input::InputState::ZERO,
            fc16_core::input::InputState::ZERO,
        ],
        &mut host,
    );
    m.frame([fc16_core::input::InputState::ZERO; 4], &mut host);
    m.frame(
        [
            fc16_core::input::InputState::from_buttons(start[0]),
            fc16_core::input::InputState::ZERO,
            fc16_core::input::InputState::ZERO,
            fc16_core::input::InputState::ZERO,
        ],
        &mut host,
    );
    m.frame([fc16_core::input::InputState::ZERO; 4], &mut host);
    for _ in 0..24 {
        m.frame([fc16_core::input::InputState::ZERO; 4], &mut host);
    }
    let x0: f64 = m.lua.globals().get("player_x").unwrap();
    let right = fc16_core::input::InputState {
        lx: 32767,
        ..fc16_core::input::InputState::ZERO
    };
    m.frame(
        [
            right,
            fc16_core::input::InputState::ZERO,
            fc16_core::input::InputState::ZERO,
            fc16_core::input::InputState::ZERO,
        ],
        &mut host,
    );
    let x_first: f64 = m.lua.globals().get("player_x").unwrap();
    assert!(
        (x_first - x0 - 0.9).abs() < 0.001,
        "每个 60Hz 帧都应推进半个原作步长"
    );
    for _ in 1..60 {
        m.frame(
            [
                right,
                fc16_core::input::InputState::ZERO,
                fc16_core::input::InputState::ZERO,
                fc16_core::input::InputState::ZERO,
            ],
            &mut host,
        );
    }
    let x1: f64 = m.lua.globals().get("player_x").unwrap();
    assert!(
        ((x1 - x0) - 54.0).abs() < 0.01,
        "原作一秒移动 30×1.8=54，原生 60Hz 实际 {}",
        x1 - x0
    );
}

/// 小丑牌对局的方向按住重复：换向/同轴双按都不再打断自动重复。
/// 回归点——旧实现只记一个"当前重复方向"，先按住 ← 再追加 → 后两个方向都不再重复；
/// 且同一轴双按时会各走一步。
#[test]
fn balatro_round_direction_repeat_survives_direction_change() {
    let mut m = balatro_machine();
    let mut host = NoopHost;
    to_play_phase(&mut m, &mut host);

    const LEFT: u16 = 1 << 0;
    const RIGHT: u16 = 1 << 1;
    let trace = |m: &mut Machine, frames: u32, buttons: u16| {
        let mut steps = Vec::new();
        let mut last = cursor(m);
        for _ in 0..frames {
            key(m, 1, buttons, 0, 0);
            let now = cursor(m);
            if now != last {
                steps.push(now - last);
            }
            last = now;
        }
        steps
    };

    // 按住 ← 20 帧：边沿立即响应，之后按固定节奏重复
    m.lua.load("PS.row, PS.cur = 1, 4").exec().unwrap();
    let steps = trace(&mut m, 20, LEFT);
    assert!(
        (3..=5).contains(&steps.len()) && steps.iter().all(|d| *d == -1),
        "按住 ← 应逐格左移（1 次边沿 + 每 4 帧 1 格）：{steps:?}"
    );

    // 同轴双按：取消，不动
    let steps = trace(&mut m, 10, LEFT | RIGHT);
    assert!(steps.is_empty(), "←/→ 同按应视为取消：{steps:?}");

    // 松开 ←、只留 →：应恢复自动重复（不是死等到重新按一次）
    let steps = trace(&mut m, 20, RIGHT);
    assert!(
        steps.len() >= 3,
        "换向后应继续按节奏移动，实际只移动 {} 次：{steps:?}",
        steps.len()
    );
    assert!(steps.iter().all(|d| *d == 1), "重复步长应为 1：{steps:?}");

    // 松开方向后立刻停止
    let stop = cursor(&m);
    key(&mut m, 12, 0, 0, 0);
    assert_eq!(cursor(&m), stop, "松开方向后不应继续移动");
}

/// 小丑牌对局的排序切换：LT(轴 4)=点数、RT(轴 5)=花色，行程过半才生效。
#[test]
fn balatro_round_triggers_switch_hand_sort() {
    let mut m = balatro_machine();
    let mut host = NoopHost;
    to_play_phase(&mut m, &mut host);

    let monotone = |hand: &[(i64, i64)], by_suit: bool| {
        hand.windows(2).all(|w| {
            if by_suit {
                w[0].0 > w[1].0 || (w[0].0 == w[1].0 && w[0].1 >= w[1].1)
            } else {
                w[0].1 > w[1].1 || (w[0].1 == w[1].1 && w[0].0 >= w[1].0)
            }
        })
    };
    assert_eq!(m.lua.load("return G.sortm").eval::<i64>().unwrap(), 0);
    assert!(monotone(&hand(&m), false), "开局手牌应已按点数整理");

    // 半行程以下不触发
    key(&mut m, 4, 0, 30000, 0);
    assert_eq!(m.lua.load("return G.sortm").eval::<i64>().unwrap(), 0);

    // RT 满行程：花色排序；按住不重复触发无副作用
    key(&mut m, 12, 0, 0, 65535);
    assert_eq!(m.lua.load("return G.sortm").eval::<i64>().unwrap(), 1);
    assert!(monotone(&hand(&m), true), "RT 后手牌应按花色整理");

    // LT 满行程：回到点数排序
    key(&mut m, 2, 0, 0, 0);
    key(&mut m, 4, 0, 65535, 0);
    assert_eq!(m.lua.load("return G.sortm").eval::<i64>().unwrap(), 0);
    assert!(monotone(&hand(&m), false), "LT 后手牌应按点数整理");
}

#[test]
fn crimson_uses_native_objects_for_queries_separation_and_cleanup() {
    // FC16-AC-186/188/189：敌人为带push的actor，位置读取自物理对象，无Lua成对分离。
    let mut m = crimson_machine();
    m.lua.globals().set_safeenv(false);
    m.lua
        .load(
            r#"
      game_state='playing';invulnerable_timer=600
      for i=1,50 do
        spawn_enemy();local o=enemies[i].phys
        o.x=(player_x+40+((i-1)%10-5)*0.5)*2 o.y=(player_y+(math.floor((i-1)/10)-2)*0.5)*2
      end
      local e=enemies[1]
      assert(type(e.phys)=='userdata' and e.phys.data==e and e.phys.kind=='actor')
      assert(rawget(e,'x')==nil and e.x==e.phys.x/2)
      assert(enemy_first(e.x+4,e.y+4,6)~=nil)
      function crowd_overlap()
        local s=0
        for i=1,#enemies do for j=i+1,#enemies do
          local a,b=enemies[i].phys,enemies[j].phys
          local ox=math.min(a.x+12,b.x+12)-math.max(a.x+4,b.x+4)
          local oy=math.min(a.y+12,b.y+12)-math.max(a.y+4,b.y+4)
          if ox>0 and oy>0 then s+=ox*oy end
        end end
        return s
      end
      before=crowd_overlap()
    "#,
        )
        .exec()
        .unwrap();
    for _ in 0..12 {
        m.frame([fc16_core::input::InputState::ZERO; 4], &mut NoopHost);
        assert_eq!(m.state, RunState::Running);
    }
    m.lua
        .load(
            r#"
      assert(#enemies==50)
      local after=crowd_overlap() assert(after*2<before,before..' '..after)
      local old=enemies[1].phys local e=enemies[1]
      local x=e.x
      enemy_release(e);table.remove(enemies,1)
      assert(e.x==x and rawget(e,'phys')==nil)
      assert(not pcall(function()return old.x end))
      _init()
      assert(#enemies==0)
    "#,
        )
        .exec()
        .unwrap();
    assert!(m.core.borrow().phys.is_empty());
}

#[test]
fn crimson_sfx_pitches_follow_pico8_frequency_mapping() {
    // FC16-AC-054：PICO-8 音高按频率映射为 FC-16 音高（PICO Cn → FC Cn+2，即 +24 半音）；
    // crimson_night 的 SFX000 鼓身原始 E0 生成为 FC E2。
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let pico = std::fs::read(
        std::env::var_os("FC16_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| root.join("../FC-16"))
            .join("third_party/crimson_night/sfx.bin"),
    )
    .unwrap();
    let fc = std::fs::read(root.join("crimson_night/sfx_fc16.bin")).unwrap();
    let mut checked = 0;
    for sfx in 0..64 {
        for step in 0..32 {
            let at = sfx * 68 + step * 2;
            let note = u16::from_le_bytes([pico[at], pico[at + 1]]);
            let (pitch, volume, custom) = (note & 63, (note >> 9) & 7, note >> 15);
            if volume == 0 || custom != 0 {
                continue;
            }
            let fc_pitch = fc[sfx * 144 + 16 + step * 4];
            assert_eq!(u16::from(fc_pitch), pitch + 24, "SFX{sfx} step{step}");
            checked += 1;
        }
    }
    assert!(checked > 100, "应覆盖原作全部可听系统波形音符");
    let drum = u16::from_le_bytes([pico[2], pico[3]]);
    assert_eq!(drum & 63, 4, "原作 SFX000 step1 为 E0");
    assert_eq!(fc[16 + 4], 2 * 12 + 4, "生成为 FC E2");
}
