extends RefCounted
## Deliberately static presentation fixtures. Replace at the presenter boundary later.
const ITEMS := [
	{"name":"逐风之剑","kind":"sword","type":"单手剑","color":Color("c8d4c6"),"count":"","note":"轻巧的旅伴。\n剑刃映着原野的晨光。","stat":"攻击  24   ·   轻型"},
	{"name":"旅人短弓","kind":"bow","type":"弓","color":Color("d7bc82"),"count":"","note":"弦声很轻。\n适合在树林间穿行。","stat":"攻击  18   ·   远程"},
	{"name":"红苹果","kind":"apple","type":"食物","color":Color("df8c75"),"count":"12","note":"刚刚采下的果实，\n还带着青草与阳光的气息。","stat":"恢复  20   ·   可食用"},
	{"name":"露水药剂","kind":"potion","type":"补给","color":Color("99cdb3"),"count":"3","note":"盛着清晨露水的小瓶。\n给疲惫的旅人一点力量。","stat":"恢复  50   ·   消耗品"},
	{"name":"风铃草","kind":"leaf","type":"素材","color":Color("b7c8df"),"count":"6","note":"在微风中轻轻摇摆，\n传来几乎听不见的铃声。","stat":"采集物   ·   原野"},
	{"name":"琥珀碎片","kind":"crystal","type":"素材","color":Color("e3bd78"),"count":"2","note":"温润的金色碎片。\n里面藏着很久以前的光。","stat":"矿物   ·   稀有"},
	{"name":"甜梨","kind":"pear","type":"食物","color":Color("d9cc7a"),"count":"5","note":"从水边果树摘下的甜梨。\n清甜多汁。","stat":"恢复  15   ·   可食用"},
	{"name":"白雏菊","kind":"flower","type":"素材","color":Color("ead9ab"),"count":"8","note":"不张扬的小花，\n总在旅人歇脚的地方盛开。","stat":"花卉   ·   原野"},
	{"name":"橡木枝","kind":"wood","type":"素材","color":Color("b59a75"),"count":"14","note":"晒干的橡木枝。\n适合添一小堆温暖的篝火。","stat":"木材   ·   森林"},
	{"name":"河边卵石","kind":"stone","type":"素材","color":Color("a8b0a0"),"count":"9","note":"被溪水磨圆的石头，\n握在手里有一点凉。","stat":"石材   ·   水岸"},
	{"name":"林间小菇","kind":"mushroom","type":"素材","color":Color("bb8765"),"count":"4","note":"藏在落叶下面的小蘑菇。\n可以请村里的花匠辨认。","stat":"采集物   ·   森林"},
	{"name":"旧日来信","kind":"scroll","type":"任务物品","color":Color("e6d5ae"),"count":"1","note":"纸角写着风铃村的名字。\n也许还有人在等它。","stat":"信件   ·   不可丢弃"},
	{"name":"晴空羽毛","kind":"feather","type":"素材","color":Color("9eb6bc"),"count":"3","note":"轻得像一小片晴空。\n风把它送到了你的脚边。","stat":"羽毛   ·   常见"},
	{"name":"蓝晶石","kind":"crystal","type":"素材","color":Color("79afc7"),"count":"5","note":"透着溪水一样的蓝，\n切面映出细碎的日光。","stat":"矿物   ·   稀有"},
	{"name":"浅滩贝壳","kind":"shell","type":"素材","color":Color("dfbaa3"),"count":"4","note":"沿着浅滩拾到的贝壳。\n细细的纹路像水面涟漪。","stat":"采集物   ·   水岸"}
]
const EQUIPMENT := [
	{"name":"逐风之剑","kind":"sword","slot":"武器 A","note":"","stat":"攻击力 +24"},
	{"name":"旅人短弓","kind":"bow","slot":"武器 B","note":"","stat":"攻击力 +18"},
	{"name":"空置","kind":"","slot":"头部","note":"","stat":""},
	{"name":"旅人外衣","kind":"coat","slot":"上衣","note":"","stat":"护甲 +12"},
	{"name":"空置","kind":"","slot":"腿部","note":"","stat":""},
	{"name":"旅人短靴","kind":"boot","slot":"鞋履","note":"","stat":"敏捷 +4"},
	{"name":"空置","kind":"","slot":"腰带","note":"","stat":""},
	{"name":"空置","kind":"","slot":"项链","note":"","stat":""},
	{"name":"绿石指环","kind":"ring","slot":"戒指一","note":"","stat":"感知 +2"},
	{"name":"空置","kind":"","slot":"戒指二","note":"","stat":""}
]
const SKILLS := [
	{"name":"回风斩","kind":"wind","type":"剑技 · 近身","note":"顺着风势挥剑，扫过身边的敌人。\n轻盈的起手，适合近身时使用。","cost":"20 气力","cooldown":"8 秒","passive":false,"parent":-1,"pos":Vector2(260,188)},
	{"name":"疾风步","kind":"dash","type":"身法 · 位移","note":"踏着气流，向前掠出一段距离。\n在进攻与退让之间，留一点余裕。","cost":"15 气力","cooldown":"6 秒","passive":false,"parent":-1,"pos":Vector2(345,333)},
	{"name":"原野祝福","kind":"leaf","type":"祝福 · 恢复","note":"在叶影中休息，重新积蓄力量。\n让原野的生机，伴你继续前行。","cost":"30 气力","cooldown":"18 秒","passive":false,"parent":-1,"pos":Vector2(175,333)},
	{"name":"逐风连斩","kind":"sword","type":"剑技 · 连击","note":"让前一剑的余势，带出下一剑。\n在轻快的节奏中连续进攻。","cost":"25 气力","cooldown":"10 秒","passive":false,"parent":0,"pos":Vector2(158,109)},
	{"name":"剑意","kind":"sword","type":"被动 · 专注","note":"握剑的手愈发沉稳。\n每一次练习，都刻进身体的记忆。","cost":"被动印记","cooldown":"常驻","passive":true,"parent":0,"pos":Vector2(260,94)},
	{"name":"回旋剑舞","kind":"wind","type":"剑技 · 范围","note":"以脚步为轴，画出一圈剑光。\n为近在身旁的危险留出距离。","cost":"35 气力","cooldown":"14 秒","passive":false,"parent":0,"pos":Vector2(362,109)},
	{"name":"踏影","kind":"dash","type":"身法 · 追击","note":"循着风的方向，迅速逼近目标。\n落脚时，剑锋已到身前。","cost":"20 气力","cooldown":"9 秒","passive":false,"parent":1,"pos":Vector2(452,274)},
	{"name":"轻身","kind":"feather","type":"被动 · 身法","note":"卸下步伐中多余的力气。\n即便走得很远，也能保持轻盈。","cost":"被动印记","cooldown":"常驻","passive":true,"parent":1,"pos":Vector2(425,380)},
	{"name":"迎风","kind":"wind","type":"被动 · 耐力","note":"学会在风中调整呼吸。\n让体力随每一次吐息慢慢归来。","cost":"被动印记","cooldown":"常驻","passive":true,"parent":1,"pos":Vector2(355,449)},
	{"name":"叶之息","kind":"leaf","type":"祝福 · 治愈","note":"将草木间的生机拢在掌心。\n为漫长的战斗留下一线余力。","cost":"40 气力","cooldown":"20 秒","passive":false,"parent":2,"pos":Vector2(165,449)},
	{"name":"蓄势","kind":"sun","type":"被动 · 守候","note":"不必每时每刻都在挥剑。\n等待合适的瞬间，也是一种力量。","cost":"被动印记","cooldown":"常驻","passive":true,"parent":2,"pos":Vector2(95,380)},
	{"name":"森语","kind":"flower","type":"被动 · 自然","note":"听见花与叶之间细小的声音。\n原野会回应愿意停下来的人。","cost":"被动印记","cooldown":"常驻","passive":true,"parent":2,"pos":Vector2(68,274)}
]
const QUESTS := [
	{"title":"风从遗迹吹来","tag":"主线 · 原野的回声","body":"沿着水岸，寻找古老的石碑。\n听说，那里还留着旧时代的故事。","steps":["在水边遗迹醒来","寻找刻着风纹的石碑","前往北方的风铃村"]},
	{"title":"一束花的约定","tag":"支线 · 风铃村","body":"为村里的花匠带回一束风铃草。\n她说，森林边缘的花开得最好。","steps":["到村庄拜访花匠","采集三株风铃草","把花送回村庄"]}
]
