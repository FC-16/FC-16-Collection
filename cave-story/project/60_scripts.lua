-- 60_scripts.lua —— 截面事件脚本（TSC 语法，十进制参数）
-- 文本改编自原版汉化脚本；<CMU/<FAI/<FAO 等由解释器作无操作处理

SCRIPTS = {

  -- ─── 出生洞窟（stage 13）──────────────────────────────
  [13] = {
    [1000] = "<PRI<MSG从坠落的冲击中醒来。\n这里是……陌生的洞窟。<NOD<CLO<MSG看来得想办法离开这里。<NOD<CLO<END",
    [100] = "<PRI<SOU010<TRA012:091:037:011",
    [91] = "<CMU0000<FAI0000<END",
  },

  -- ─── 初始洞窟（stage 12）──────────────────────────────
  [12] = {
    [91] = "<CMU0000<FAI0000<END",
    [92] = "<CMU0000<FAI0000<END",
    [93] = "<CMU0000<FAI0000<END",
    [94] = "<CMU0000<FAI0000<END",
    [101] = "<PRI<SOU010<TRA013:0093:010:0003",
    [102] = "<PRI<MSG打开了眼之门。<NOD<CLO<SOU010<TRA011:0094:008:0006",
    [110] = "<PRI<SOU010<TRA090:0092:007:0009",
  },

  -- ─── 咪咪村庄（stage 11）──────────────────────────────
  [11] = {
    [94] = "<CMU0000<FAI0000<END",
    [90] = "<CMU0000<FAI0000<END",
    [110] = "<PRI<SOU010<TRA012:0090:055:0009",
    [100] = "<PRI<MSG门被锁起来了。<NOD<END",
    [105] = "<PRI<MSG打不开……\n里面好像塞满了东西。<NOD<END",
    [107] = "<PRI<MSG门关着。\n里面好像没有人。<NOD<END",
    [108] = "<PRI<MSG门关着。<NOD<END",
    [109] = "<PRI<MSG门关着。<NOD<END",
    [300] = "<KEY<MSG<TUR……你是谁？！<NOD<CLR哼，反正是从外面来的吧。<NOD<CLR最好别给我惹麻烦。<NOD<END",
    [301] = "<KEY<MSG<TUR什么啊，不是敌人啊。<NOD<CLR我还以为他们又来了……<NOD<CLR我的名字是金。\n是这个村庄的No.1。<NOD<CLR虽然说是No.1，\n可也不是什么了不起的事。<NOD<CLR村里的同伴只剩下几个了……<NOD<CLR不，加上数的话再多一人。<NOD<CLR但那家伙才来这里不久，\n总觉得是个可疑份子。<NOD<END",
    [307] = "<KEY<MSG<TUR呀啊……！？<NOD<CLR喵、喵喵……<NOD<END",
    [311] = "<KEY<MSG<TUR哦，新面孔啊。<NOD<CLR欢迎来到咪咪村庄。<NOD<CLR这几天村子气氛不太好，\n你出门可要当心。<NOD<END",
    [600] = "<KEY<MSG<TUR……<NOD<CLR（她似乎警惕地盯着你。）<NOD<END",
    [610] = "<KEY<MSG<TUR（笼子里空空的。）<NOD<END",
    [200] = "<KEY<FLJ322:0201<FL+322<SOU011<CNP0200:0021<MSG打开了宝箱。<NOD<IT+0002<CLR<MSG获得了 =地图系统= 。<NOD<CLR上面写着些什么……<NOD<CLR「只要没有忘记冒险的心，\n总有一天必定能够出去。」<NOD<CLO<END",
    [201] = "<PRI<MSG里面是空的。<NOD<END",
    [500] = "<KEY<MSG<TUR　　　　↑ 山下农场\n蓄水池 ← ■ → 墓地\n　　　　↓ 亚瑟的家<NOD<END",
    [501] = "<KEY<MSG<TUR「山下农场」<NOD<END",
    [502] = "<KEY<MSG<TUR「蓄水池」<NOD<END",
    [503] = "<KEY<MSG<TUR「咪咪卡的墓场」\n现在因危险所以禁止进入。<NOD<END",
    [504] = "<KEY<MSG<TUR「亚瑟的家」<NOD<END",
    [505] = "<KEY<MSG<TUR「集会场」<NOD<END",
  },

  -- ─── 亚瑟的之家（stage 90）────────────────────────────
  [90] = {
    [92] = "<CMU0000<FAI0000<END",
    [100] = "<PRI<SOU010<TRA012:0092:053:0036",
    [200] = "<KEY<FLJ1640:0201<FL+1640<SOU011<CNP0200:0021<MSG打开了宝箱。<NOD<CLR<MSG获得了 =北极星= ！<NOD<CLO<AM+0002:0000<END",
    [201] = "<PRI<MSG里面是空的。<NOD<END",
    [300] = "<KEY<MSG<TUR……<NOD<CLR（他闭着眼，像是在打盹。）<NOD<END",
    [301] = "<KEY<MSG<TUR哦……你是拿走了\n亚瑟的枪的人啊。<NOD<CLR那是把还没完成的枪。<NOD<CLR不过只要你变得够强，\n它也能成为可靠的伙伴。<NOD<CLR好好使用它吧，年轻人。<NOD<END",
    [310] = "<KEY<MSG<TUR\n（全家人安息于此。）<NOD<END",
  },
}
