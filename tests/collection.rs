//! 每款游戏从当前发布产物启动，覆盖标题、进入玩法、方向、暂停和选项。
use fc16_core::{
    cart::CartData, config, font::Font, input::InputState, machine::NoopHost, Machine, RunState,
    Tunables,
};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf()
}

fn projects() -> Vec<PathBuf> {
    let mut paths: Vec<_> = fs::read_dir(root())
        .unwrap()
        .map(Result::unwrap)
        .map(|e| e.path())
        .filter(|p| p.join("fc16.project.json").is_file())
        .collect();
    paths.sort();
    paths
}

#[test]
fn every_cartridge_runs_title_gameplay_and_controls() {
    let font = Arc::new(Font::from_bytes(config::FONT).unwrap());
    let mut failures = Vec::new();
    for path in projects() {
        let name = path.file_name().unwrap().to_str().unwrap();
        let raw = fs::read(path.join(format!("{name}.fc16"))).unwrap();
        let cart = CartData::parse_file(&raw, "cart.fc16").unwrap();
        let png = CartData::parse_file(
            &fs::read(path.join(format!("{name}.fc16.png"))).unwrap(),
            "cart.fc16.png",
        )
        .unwrap();
        assert_eq!(
            cart.to_fc16().unwrap(),
            png.to_fc16().unwrap(),
            "{name} 发布载荷不一致"
        );
        for seed in [0, 7] {
            let mut m = Machine::new(
                cart.clone(),
                Tunables::default(),
                seed,
                0,
                String::new(),
                font.clone(),
                None,
            );
            if m.state != RunState::Running {
                failures.push(format!("{name} 初始化失败: {:?}", m.state));
                continue;
            }
            for frame in 0..400 {
                let buttons = match frame {
                    100 | 120 | 140 | 160 | 180 | 200 | 220 => 1 << 4,
                    240 | 280 => 1 << 11,
                    300 => 1 << 10,
                    320 | 340 => 1 << 5,
                    350 => 1 << 6,
                    370 => 1 << 7,
                    382 => 1 << 8,
                    390 => 1 << 9,
                    181..=199 => 2,
                    221..=239 => 8,
                    251..=269 => 1,
                    281..=299 => 4,
                    _ => 0,
                };
                let mut input = InputState::from_buttons(buttons);
                if (210..230).contains(&frame) {
                    input.lx = 32767;
                    input.ly = 32767;
                }
                if (310..315).contains(&frame) {
                    input.lt = 65535;
                }
                if (330..335).contains(&frame) {
                    input.rt = 65535;
                }
                m.frame(
                    [input, InputState::ZERO, InputState::ZERO, InputState::ZERO],
                    &mut NoopHost,
                );
                if m.state != RunState::Running {
                    failures.push(format!("{name} seed {seed} frame {frame}: {:?}", m.state));
                    break;
                }
            }
            assert!(
                m.screenshot_rgb()
                    .chunks_exact(3)
                    .any(|p| p != [19, 19, 19]),
                "{name} 没有画面"
            );
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), target).unwrap();
        }
    }
}

#[test]
fn every_release_rebuilds_from_current_project_sources() {
    let fc16 = std::env::var_os("FC16_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| root().join("../FC-16"));
    let binary = fc16.join("target/debug").join(if cfg!(windows) {
        "fc16-tools.exe"
    } else {
        "fc16-tools"
    });
    for path in projects() {
        let name = path.file_name().unwrap().to_str().unwrap();
        let temp = tempfile::tempdir().unwrap();
        copy_tree(&path, temp.path());
        if matches!(name, "doudizhu" | "holdem") {
            fs::copy(
                root().join("tools/cards.bin"),
                temp.path().join("cards.bin"),
            )
            .unwrap();
        }
        if name == "cave-story" {
            let output =
                std::process::Command::new(if cfg!(windows) { "python" } else { "python3" })
                    .arg(temp.path().join("tools/cs_luabuild.py"))
                    .output()
                    .unwrap();
            assert!(output.status.success(), "{output:?}");
        }
        let result = std::process::Command::new(&binary)
            .args(["project", "build"])
            .arg(temp.path().join("fc16.project.json"))
            .output()
            .unwrap();
        assert!(result.status.success(), "{name}: {result:?}");
        for extension in ["fc16", "fc16.png"] {
            let filename = format!("{name}.{extension}");
            assert_eq!(
                fs::read(path.join(&filename)).unwrap(),
                fs::read(temp.path().join(&filename)).unwrap(),
                "{name} 源码与 {extension} 产物不一致，请重新构建"
            );
        }
    }
}
