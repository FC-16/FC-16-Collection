#!/usr/bin/env python3
"""生成 GitHub Pages 首页 index.html：平铺展示 carts/ 全部卡带封面 + 实时搜索。

数据源：tools/carts_meta.json（卡带名/作者）+ 本文件里的分类与简介表。
重跑即可在封面更新后刷新页面。
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# 分类与一句话简介（dir 名 → (分类, 简介)）
GAMES = {
    '2048':          ('益智', '滑动合成，冲向 2048'),
    'angrybirds':    ('休闲', '弹弓物理破坏，拆塔砸猪'),
    'ballbattle':    ('动作', '大球吞小球，质量即正义'),
    'battlecity':    ('射击', '坦克保卫基地，经典复刻'),
    'beachhead':     ('射击', '纯软件 3D 管线的滩头守卫战'),
    'breakout':      ('休闲', '打砖块 + 道具弹幕'),
    'crimson_night': ('动作', '赤色之夜，弹幕生存'),
    'doudizhu':      ('棋牌', '经典三人纸牌，真牌面精灵'),
    'flappy':        ('动作', '穿过管道间隙的拍翅飞行'),
    'gomoku':        ('棋牌', '五子连珠，人机对弈'),
    'holdem':        ('棋牌', '无限注德州扑克，热座对局'),
    'klotski':       ('益智', '华容道，横刀立马'),
    'lianliankan':   ('益智', '连连看，图案配对消除'),
    'ludo':          ('桌游', '飞行棋，掷 6 起飞'),
    'mario':         ('动作', '超级马里奥兄弟致敬版'),
    'minesweeper':   ('益智', '扫雷，旗定千雷'),
    'mota24':        ('RPG', '24 层魔塔，数值解谜爬塔'),
    'mota50':        ('RPG', '50 层魔塔，更长的爬塔旅途'),
    'pacman':        ('动作', '迷宫追逐，能量豆反杀'),
    'reversi':       ('棋牌', '黑白棋，翻转制胜'),
    'riichi':        ('棋牌', '日本麻将，立直东风战'),
    'snake':         ('动作', '贪吃蛇，越吃越长'),
    'sokoban':       ('益智', '推箱子 16 关，一步都不能错'),
    'sudoku':        ('益智', '数独，三档难度出题'),
    'survivors':     ('动作', '暗夜幸存者，坟场弹幕求生'),
    'tetris':        ('益智', '俄罗斯方块，Korobeiniki 背景音'),
    'thunder':       ('射击', '雷霆战机，纵向弹幕射击'),
    'tictactoe':     ('棋牌', '井字棋，人机对战'),
    'tunnel':        ('动作', '螺旋隧道，纯视觉竞速'),
    'xiangqi':       ('棋牌', '中国象棋，楚河汉界'),
}

# 外部卡带：cover/dl 为远程直链（GitHub blob 页面地址需换 raw 直链才能当图片源）
EXTERNAL = [
    {'dir': 'brotato', 'name': '土豆兄弟', 'author': 'FC-16', 'genre': '动作',
     'desc': '竞技场生存割草（FC-16 官方移植）',
     'cover': 'https://raw.githubusercontent.com/FC-16/FC-16-Brotato/main/brotato.fc16.png'},
]

GENRES = ['全部', '益智', '棋牌', '动作', '射击', '休闲', 'RPG', '桌游']

TPL = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FC-16 卡带收藏</title>
<style>
  :root {
    --bg: #131313; --panel: #1d1d22; --line: #2c2c34; --ink: #e8e6df;
    --dim: #9a97a3; --gold: #f2c14e; --accent: #4ecdc4;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font-family: "PingFang SC", "Microsoft YaHei", "Noto Sans SC", system-ui, sans-serif;
  }
  header { padding: 36px 20px 8px; text-align: center; }
  header h1 { margin: 0 0 6px; font-size: 30px; letter-spacing: 2px; }
  header h1 .fc { color: var(--gold); }
  header p { margin: 0; color: var(--dim); font-size: 13px; }
  .bar {
    position: sticky; top: 0; z-index: 10; background: rgba(19,19,19,.94);
    backdrop-filter: blur(6px); border-bottom: 1px solid var(--line);
    padding: 12px 20px; display: flex; gap: 12px; flex-wrap: wrap;
    align-items: center; justify-content: center;
  }
  #q {
    width: min(340px, 80vw); padding: 9px 14px; border-radius: 999px;
    border: 1px solid var(--line); background: var(--panel); color: var(--ink);
    font-size: 14px; outline: none;
  }
  #q:focus { border-color: var(--accent); }
  .chips { display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; }
  .chip {
    padding: 5px 14px; border-radius: 999px; border: 1px solid var(--line);
    background: var(--panel); color: var(--dim); font-size: 13px; cursor: pointer;
    user-select: none;
  }
  .chip.on { border-color: var(--gold); color: var(--gold); }
  #count { color: var(--dim); font-size: 12px; min-width: 64px; text-align: center; }
  main {
    max-width: 1240px; margin: 0 auto; padding: 26px 16px 60px;
    display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr));
    gap: 22px; justify-items: center;
  }
  .card {
    width: 100%; max-width: 240px; border-radius: 10px; overflow: hidden;
    background: var(--panel); border: 1px solid var(--line); cursor: zoom-in;
    transition: transform .15s ease, border-color .15s ease;
  }
  .card:hover { transform: translateY(-4px); border-color: var(--gold); }
  .card img { display: block; width: 100%; height: auto; }
  .card .meta { padding: 10px 12px 12px; }
  .card .name { font-size: 15px; font-weight: 600; }
  .card .sub { margin-top: 3px; font-size: 12px; color: var(--dim);
               display: flex; justify-content: space-between; gap: 6px; }
  .tag { color: var(--accent); }
  .empty { grid-column: 1/-1; text-align: center; color: var(--dim); padding: 60px 0; }
  dialog {
    border: 1px solid var(--line); border-radius: 12px; background: var(--panel);
    color: var(--ink); padding: 18px; max-width: min(92vw, 420px);
  }
  dialog::backdrop { background: rgba(0,0,0,.7); }
  dialog img { width: 100%; border-radius: 6px; }
  dialog .row { display: flex; justify-content: space-between; align-items: center; margin-top: 12px; }
  dialog a {
    color: var(--gold); text-decoration: none; font-size: 14px;
    border: 1px solid var(--gold); border-radius: 8px; padding: 6px 14px;
  }
  dialog .close { cursor: pointer; color: var(--dim); font-size: 13px; background: none; border: none; }
  footer { text-align: center; color: var(--dim); font-size: 12px; padding: 0 0 40px; }
  footer a { color: var(--dim); }
</style>
</head>
<body>
<header>
  <h1><span class="fc">FC-16</span> 卡带收藏</h1>
  <p>__TOTAL__ 款游戏 · 幻想主机 · 点击卡带查看大图与下载</p>
</header>
<div class="bar">
  <input id="q" type="search" placeholder="搜索游戏名…" autocomplete="off">
  <div class="chips" id="chips"></div>
  <span id="count"></span>
</div>
<main id="grid"></main>
<dialog id="dlg">
  <img id="dlg_img" alt="">
  <div class="row">
    <div><div id="dlg_name" style="font-weight:600"></div>
         <div id="dlg_desc" style="font-size:13px;color:var(--dim);margin-top:4px"></div></div>
    <a id="dlg_dl" download>下载封面 PNG</a>
  </div>
  <div class="row" style="justify-content:flex-end">
    <button class="close" onclick="dlg.close()">关闭 (Esc)</button>
  </div>
</dialog>
<footer>FC-16 · FrostMiKu's Console —
<a href="https://github.com/FrostMiKu/FC-16-Collection" target="_blank">GitHub 仓库</a>
· 卡带需 FC-16 宿主运行</footer>
<script>
const DATA = __DATA__;
const GENRES = __GENRES__;
let genre = '全部';
const grid = document.getElementById('grid');
const chips = document.getElementById('chips');
const q = document.getElementById('q');
const dlg = document.getElementById('dlg');

GENRES.forEach(g => {
  const c = document.createElement('span');
  c.className = 'chip' + (g === '全部' ? ' on' : '');
  c.textContent = g;
  c.onclick = () => {
    genre = g;
    chips.querySelectorAll('.chip').forEach(x => x.classList.remove('on'));
    c.classList.add('on');
    render();
  };
  chips.appendChild(c);
});

function card(d) {
  const el = document.createElement('div');
  el.className = 'card';
  el.innerHTML = `
    <img loading="lazy" src="${d.cover || `carts/${d.dir}.fc16.png`}" alt="${d.name}">
    <div class="meta">
      <div class="name">${d.name}</div>
      <div class="sub"><span class="tag">${d.genre}</span><span>${d.author}</span></div>
    </div>`;
  el.onclick = () => {
    dlg_img.src = d.cover || `carts/${d.dir}.fc16.png`;
    dlg_name.textContent = d.name;
    dlg_desc.textContent = d.desc;
    dlg_dl.href = d.cover || `carts/${d.dir}.fc16.png`;
    dlg.showModal();
  };
  return el;
}

function render() {
  const kw = q.value.trim().toLowerCase();
  grid.innerHTML = '';
  let n = 0;
  for (const d of DATA) {
    if (genre !== '全部' && d.genre !== genre) continue;
    if (kw && !(d.name.toLowerCase().includes(kw) || d.dir.includes(kw) || d.desc.includes(kw))) continue;
    grid.appendChild(card(d));
    n++;
  }
  document.getElementById('count').textContent = n + ' / ' + DATA.length;
  if (n === 0) {
    const e = document.createElement('div');
    e.className = 'empty';
    e.textContent = '没有匹配的卡带';
    grid.appendChild(e);
  }
}
q.addEventListener('input', render);
render();
</script>
</body>
</html>
'''


def main():
    meta = json.loads((ROOT / 'tools' / 'carts_meta.json').read_text())
    data = []
    for d, (genre, desc) in sorted(GAMES.items()):
        cover = ROOT / 'carts' / f'{d}.fc16.png'
        cart = ROOT / d / f'{d}.fc16'
        assert cover.exists(), cover
        assert cart.exists(), cart
        data.append({
            'dir': d, 'name': meta[d]['name'], 'author': meta[d]['author'],
            'genre': genre, 'desc': desc,
        })
    data += EXTERNAL
    html = (TPL.replace('__DATA__', json.dumps(data, ensure_ascii=False))
               .replace('__GENRES__', json.dumps(GENRES, ensure_ascii=False))
               .replace('__TOTAL__', str(len(data))))
    (ROOT / 'index.html').write_text(html)
    print(f'index.html written: {len(data)} cartridges')


if __name__ == '__main__':
    main()
