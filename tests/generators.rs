//! 资源管线须直接生成当前 SFX/MUSIC 布局，不能重新写回旧地址或丢失空声部。
use fc16_core::{cart::CartData, config, font::Font, Machine, RunState, Tunables};
use std::{fs, path::Path, process::Command, sync::Arc};

#[test]
fn tower_composer_emits_current_audio_layout_and_silent_tracks() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let temp = tempfile::tempdir().unwrap();
    let lua_path = temp.path().join("generated.lua");
    fs::write(
        &lua_path,
        "-- BEGIN GENERATED MUSIC (compose_music.py)\n-- END GENERATED MUSIC\n",
    )
    .unwrap();
    let script = r#"
import sys
sys.path.insert(0,sys.argv[1])
import compose_music as cm
song=cm.Song(3)
song.put(0,0,[(0,'C3',2,'nlong',10)])
cm.write_all([('P_TEST',song,1)],sys.argv[2])
"#;
    let output = Command::new(if cfg!(windows) { "python" } else { "python3" })
        .args(["-c", script])
        .arg(root.join("magetower"))
        .arg(&lua_path)
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let code = fs::read_to_string(lua_path).unwrap()
        + r#"
function _init()
  init_audio()
  assert(peek2(0x0C0000+14*144)==12, "字段检查1")
  assert(peek(0x0C0000+14*144+2)==32, "字段检查2")
  assert(peek(0x0C0000+14*144+17)==6, "字段检查3")
  assert(peek(0x0C5380)==1, "字段检查4")
  assert(peek(0x0C5380+32)==14, "字段检查5")
  assert(peek(0x0C5380+33)==-1, "字段检查6")
  assert(peek(0x0C5380+48)==1 and peek(0x0C5380+49)==1, "字段检查7")
  assert(peek(0x0C4800+16)==8, "字段检查8")
end
"#;
    let machine = Machine::new(
        CartData {
            code,
            ..Default::default()
        },
        Tunables::default(),
        0,
        0,
        String::new(),
        Arc::new(Font::from_bytes(config::FONT).unwrap()),
        None,
    );
    assert_eq!(machine.state, RunState::Running);
}

#[test]
fn mario_composer_emits_current_drum_and_music_row_layout() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let script = r#"
import sys
sys.path.insert(0,sys.argv[1])
import convert_music as cm
print(cm.emit_lua([(15,[1,2,3],'drum',3)],[('test',[16,0,0,0],3)],{'test':(0,1)}))
"#;
    let output = Command::new(if cfg!(windows) { "python" } else { "python3" })
        .args(["-c", script])
        .arg(root.join("mario"))
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let code = String::from("local function u8(a,v) poke(a,v%256) end\nlocal TIMBRE_SOURCE = {[0]=0,1,2,3,4,14,5,15,8,9,10,11,12,13,6,6}\n")
        + &String::from_utf8(output.stdout).unwrap() + r#"
function _init()
  music_gen()
  assert(peek2(0x0C0000+15*144)==12 and peek(0x0C0000+15*144+2)==3, "字段检查9")
  assert(peek(0x0C0000+15*144+16)==35 and peek(0x0C0000+15*144+17)==13, "字段检查10")
  assert(peek(0x0C5380)==1 and peek(0x0C5380+36)==15 and peek(0x0C5380+37)==-1, "字段检查11")
  assert(peek(0x0C5380+48)==1 and peek(0x0C5380+49)==1, "字段检查12")
end
"#;
    let machine = Machine::new(
        CartData {
            code,
            ..Default::default()
        },
        Tunables::default(),
        0,
        0,
        String::new(),
        Arc::new(Font::from_bytes(config::FONT).unwrap()),
        None,
    );
    assert_eq!(machine.state, RunState::Running);
}
