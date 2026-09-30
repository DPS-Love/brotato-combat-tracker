# 开发文档

面向想改代码、或在游戏更新后重新对齐的人。玩家看仓库根目录的 README 即可。

当前对齐：游戏 **1.1.15.4** / Mod Loader **6.3.0** / 引擎 Godot 3.x（脚本字节码版本 13）。

---

## 目录结构

```
mods-unpacked/DPSLove-CombatTracker/   Mod 本体，发布包里就是这个目录
├── manifest.json
├── mod_main.gd                 入口：登记 player.gd 扩展、挂统计节点
├── extensions/…/player.gd      治疗归因（唯一的脚本扩展）
├── core/                       纯 GDScript：模型、解析器、日志读写、配置、文案、CSV、数字格式
├── game/                       和游戏打交道：tracker（挂钩、归因、分段）、names（名字 / 颜色 / 图标）、net_sync（联机）
└── ui/                         浮窗、拆分窗口、战斗记录、设置，全部自绘；skin 是配色 / 字体 / 画法
tools/
├── package.py                  打包，核对版本号
├── workshop_upload.py          上传创意工坊：文件、预览图、标签、各语言的标题和说明、改动说明
├── gamedir.py                  找游戏目录（Steam 的各个库）
├── pck.py / gdc.py             解包游戏、把编译过的脚本还原成源码（对齐用）
└── testpack/                   隔离测试包与自动测试
docs/                           文档；workshop/ 下是创意工坊的上传配置、文案、预览图和各版本的改动说明
```

`core/` 不引用游戏和 Mod Loader 的任何全局类：导入日志时解析器在后台线程里跑，而且游戏哪天改了类名，
这部分也不受影响。和游戏有关的全部集中在 `game/`，界面只通过 `game/names.gd` 认识游戏里的东西。

## 开发环境

- Python 3.8+（打包和测试工具）
- Brotato（Steam 版即可）。自动测试直接用游戏本体的 `Brotato.exe` 跑，**不需要 Godot 编辑器**

## 构建

```bash
python tools/package.py
```

产出 `build/DPSLove-CombatTracker-vX.Y.Z.zip`（Release / 手动安装）和
`build/workshop/Brotato Combat Tracker - DPS Meter.zip`（创意工坊上传，内容相同）。
zip 里只有 `mods-unpacked/DPSLove-CombatTracker/` 一个目录。时间戳固定、不压缩，同样的源码在任何机器上打出来都逐字节相同，
本机打的包和 CI 发布的包可以直接比对哈希。

版本号有两处：`manifest.json` 的 `version_number` 和 `game/tracker.gd` 的 `VERSION`，`package.py` 会核对两者一致；
给了 `--tag vX.Y.Z` 还要和标签一致。

---

## 工作原理

```
current_scene 变成 main.tscn ─────────────► W start（波次、标签、局序）
EntitySpawner 生成信号 / 每秒扫一遍实体 ──► 给每个单位连 took_damage、health_updated
Unit.took_damage(unit, value, …, args, …) ─► 归因 ──► D（对敌）/ T（承伤）
player.gd 扩展 on_healing_effect ─────────► H（治疗）
main._cleaning_up 置真 / 离开战斗场景 ─────► W end

每个事件 ──► Parser（本局会话）──► 浮窗 / 战斗记录
         └─► LogWriter ──► logs/bct-*.bctlog.gz
导入：LogReader ──► Parser（新会话）──► 战斗记录
```

伤害走游戏的信号，而不是给 `unit.gd` / `enemy.gd` 装脚本扩展：信号是游戏自己的稳定接口，
不改任何方法，也不会和别的 Mod 的扩展互相干扰。`unit.gd` 是几十个敌人脚本的父类，扩展它还会触发
Mod Loader 重载全部子类。唯一的扩展是 `player.gd`（治疗归因，见下），只覆写四个方法，参数和返回值原样透传。

游戏对象一律按字段和方法识别（有 `enemy_id` 的是敌人，有 `on_healing_effect` 的是玩家，
有 `weapon_id` 和 `on_weapon_hit_something` 的是武器……），不写死 `class_name`：某个类以后改名，
这里只是认不出，不会让整个 Mod 编译失败。

### 归因

`took_damage` 的 `args`（`TakeDamageArgs`）里有 `from_player_index`、`hitbox`、`from`、`is_burning`。
有命中框时看 `hitbox.from`：

| `hitbox.from` | 来源 |
|---|---|
| 武器（有 `weapon_id`） | 这把武器；同名同品质合并成一个键 |
| 爆炸（有 `start_explosion`） | 爆炸节点的 `hit_something` 连回了哪把武器就算哪把；没连的看追踪键；都没有的，算这名玩家 1 秒内用带爆炸效果的**近战**武器打中过东西的那一把 |
| 敌人（被魅惑） | 魅惑它的玩家，来源 `m:<敌人>` |
| 其它（炮塔、宠物…） | `hitbox.damage_tracking_key_hash`，没有再看节点自己的 `_damage_tracking_key_hash` |

近战武器触发爆炸时会放两发：`unit.gd` 那发把 `hit_something` 连回武器，`weapon.gd` 自己那发不连；
而且触发爆炸的那一击本身不造成伤害（没有 `took_damage`）。所以「最近一次近战命中」是直接听武器命中框的
`hit_something` 记下的，打树也算。

没有命中框的伤害靠**参数对象本身是谁**区分——游戏给每条路各留了一个复用的参数对象：

| `args` 是 | 情形 | 来源 |
|---|---|---|
| 被打单位自己的 `_take_damage_args_unit`，且 `is_burning` | 燃烧跳伤 | 看单位的 `_burning`：`is_global_burn` → 受惊香肠；`from` 是武器 → 那把武器；建筑 → 它的追踪键；无来源的工程学燃烧 → 燃烧炮塔 |
| 某名玩家的 `_dodge_damage_args` | 闪避后的反击 | `i:item_riposte` |
| 其它 | 敌人死亡 / 拾取 / 治疗触发的属性伤害等 | `o:effect` |

燃烧、香肠、燃烧炮塔的规则照搬游戏在 `unit.gd` 燃烧跳伤里给物品记账的逻辑。

伤害类别取命中框（燃烧取燃烧数据）的第一个缩放属性，和游戏的 `Utils.get_first_scaling_stat` 一致。

### 溢出

`took_damage` 的数值是结算后的伤害，打死怪那一击会超过它剩余的血。`Unit.take_damage` 在发
`took_damage` 之前先发 `health_updated`，所以给每个单位记「上一次的血量、这一次的血量」，击杀那一击的有效值
取两者之差。池化复用的敌人重生时（`enemy_respawned`）清零重记。

### 治疗

所有生命恢复都汇进 `Player.on_healing_effect(value, tracking_key, from_torture)`，
但生命再生、生命窃取、持续恢复进来时 `tracking_key` 都是空的。扩展覆写这三条路的入口
（`on_health_regen` / `on_lifesteal_effect` / `on_heal_over_time_timer_timeout`）记下上下文，
`on_healing_effect` 拿到实际回复量后连同追踪键、上下文一起交给统计节点。
空追踪键又不在三条路上的，几乎都是吃掉落物（`ConsumableHealingEffect` 发的就是空键）。

### 分段

- 当前场景变成 `res://main.tscn` 开一段，`main._cleaning_up` 置真就收——正常收波、全员阵亡、波次失败都会走 `clean_up_room`
- 波次时钟只在波次进行中、游戏没暂停时走（`_physics_process` 累加 delta），事件时间都用它
- 标签：开波时读 `main._is_elite_wave` / `_is_horde_wave`；Boss（`is_elite == false` 的 Boss 类敌人）出场时补一条 `tags`
- 局序：回过标题 / 选角色、波次倒退、没失败又打同一波都算新的一局；失败后重打同一波（重试波次）算同一局第 2 次

### 联机

创意工坊的 BrotatoOnline 里，每台机器只模拟自己那名玩家的命中（打的是本地的敌人副本），
房主只收客机的击杀、不收伤害；房主那边的客机玩家是代理，受伤后血量会被还原。**没有哪台机器有全队的伤害。**

所以统计是「谁的玩家谁说了算」：

1. 本地事件只记本机拥有的玩家（`owns_player`）；别的玩家在本机上的伤害、承伤、治疗一律忽略
2. 每 2 秒把本机玩家这一段的统计（`parser.export_snapshot`）广播给队友，收波时再可靠地发一次最终版
3. 收到队友的快照，按波次找到同一段，整名玩家替换进去（`parser.apply_snapshot`），界面上和本地玩家一样显示
4. 收波时把队友的最终快照写进日志（`P` 行），导入时也能看到整队

走的是 BrotatoOnline 公开的 Mod 消息接口：节点组 `brotato_online_api`、API v1 的
`is_online` / `owns_player` / `broadcast(mod_id, route, payload, options)` 和 `mod_message_received` 信号，
不依赖它的任何内部实现。消息体是 JSON（数字到对方那边都变成浮点数，解析时一律转回来）；
中途的快照走不可靠通道、`battle` 作用域，最终版走可靠通道、`menu` 作用域（对方可能已经进了商店）。
一名玩家一波的快照通常 2–5 KB。

没装 BrotatoOnline、单机、本地合作时所有玩家都算本机拥有，同步什么也不做。
要适配别的联机 Mod，在 `game/net_sync.gd` 里加一个分支，提供同样的几个方法即可。

### 界面

配色、版式、交互照搬 TBH Combat Tracker v0.4 的界面：深色圆角窗口、图标按钮和悬停提示，浮窗平时只有描边的字和色条，
鼠标移上去才淡入背景和按钮；拆分表和环形图互相高亮，环上一屏之外的小项并成「其他」。

浮窗和 TBH 不同：TBH 是横向并排的卡片（一个英雄一张），这里是竖向的多级列表（`ui/overlay.gd`）——
Brotato 一名玩家就有好几件武器和物品，多人时按玩家分组才看得清。多人是玩家 → 分类 → 来源，单人省掉玩家这一级；
分类见 `names.category_of`（输出：武器 / 物品 / 其他；承伤：敌人 / 精英 / Boss / 其他；治疗：属性回复 / 物品 / 消耗品 / 其他）。
每一行一条斜切色条，整棵树用同一把尺子（多人时最大的那名玩家、单人时最大的那一类是满格）；
折叠状态只在本次游戏里记着，按视图分开。

- 四个窗口（浮窗、拆分、战斗记录、设置）都是整窗自绘的 `Control`（`ui/window_base.gd`），绘制时顺手登记点击区。
  版式常量直接用 TBH 的界面单位（和它的源码一一对应），窗口整体按 `skin.scale` 缩放：
  1.3 × `UiScale`，1.3 是 Brotato 的 1080p 画面相对 TBH（桌面分辨率、10–13 号字）的放大倍数。
  不用 `Button` 等内置控件：它们会抢键盘 / 手柄焦点，和游戏的焦点导航打架；焦点一律 `FOCUS_NONE`
- 画法：圆角块、窗口底板和阴影用 `StyleBoxFlat`（引擎自带抗锯齿）；斜切色条、环形图、图标的线条在 GDScript 里拼成
  三角形网格（`ui/aa_mesh.gd`：每条边外侧铺一圈一像素宽的羽化带，和 TBH 的 MeshBuilder 同一做法）；曲线用引擎的抗锯齿折线。
  图标照着 Segoe Fluent Icons 的字形用线条画（`ui/icons.gd`），各平台一样，网格按大小和颜色缓存
- 字：游戏自带的思源黑体（Noto Sans SC / TC / JP / KR，按游戏语言挑主字体）按缩放后的字号现建，
  画字时用 `draw_set_transform` 把窗口的缩放抵消掉、起点对齐整像素，放大缩小都不糊。
  游戏只带了 Medium 一种字重，粗体是同一行错开 0.6 像素再画一遍；浮窗的描边字用 `DynamicFont.outline_size`
- 会滚动的列表（分段、拆分表、图例、逐条事件、导入列表）和曲线各是一块子画布（`ui/clip_pane.gd`）：
  列表裁掉视口外的半行、平滑滚动（`ui/scroll.gd`），曲线数据没变就不重画
- **鼠标不走 Godot 的界面分发**，由 `ui_root` 在 `_input` 里自己分发（窗口的 `mouse_filter` 都是 `IGNORE`）。原因有二：
  Godot 3 找鼠标下的控件时按节点在树里的先后，不看 `CanvasLayer` 的层级，点击会先落到游戏场景铺满全屏的容器上；
  多人时游戏的手柄焦点模拟器（`FocusEmulator`）在 `_input` 里把鼠标事件全部标记为已处理，界面根本收不到。
  界面的 `CanvasLayer` 挂在**根节点下、排在最后**（每次换场景挪回最后），`_input` 按树的逆序调用，所以最先轮到它：
  落在窗口上的点击和滚轮交给窗口并吃掉，鼠标移动照样放给游戏（鼠标瞄准时光标划过浮窗不会卡住准星），
  按住拖窗口、拖滑杆期间事件一直交给按下的那个窗口。热键录制也在这里截键盘
- 浮窗只在波次进行中、游戏没暂停时显示，免得盖住暂停菜单和收波后的升级选择并吃掉那里的点击
- 窗口背景的不透明度默认 0.9（TBH 是 0.7）：战斗记录多半是在暂停菜单、升级选择、商店上面打开的，那些画面满屏是字，
  0.7 会透出来
- 战斗记录里按来源分组时色条和曲线用调色板按名次配色，因为同品质的武器颜色一样，曲线会分不开。
  表格里没选中任何行时，拆分看全部玩家加起来的那一条（`model.everyone`），维度和按玩家看时一样
- 逐条事件：进行中那段的伤害 / 承伤 / 治疗事件由统计节点在内存里留着（最多 3 万条）；
  结束的段在后台线程里把本局日志重新解析到那一段为止（`core/event_pages.gd`），用段的序号和波次核对是不是同一段。
  联机时队友只传汇总的快照，逐条事件里只有本机玩家的
- 设置窗口改的是同一份 `config.cfg`，改完立即写回；统计口径（溢出、树木、保留段数）由 `tracker.apply_config()` 当场生效，
  战斗日志的开关和保留天数只在启动时读，标着「重启后生效」

---

## 自动测试

`tools/testpack/` 用游戏本体跑一整套端到端测试，**完全不碰玩家的存档**：

- `build_testpack.py` 复制一份 `Brotato.pck` 到 `build/testpack/`，只在副本里打补丁：
  用户目录改名 `BrotatoBCTTest`（存档、设置、日志全部隔离）、平台层固定走 LocalPlatform（不初始化 Steam，
  不碰云存档、成就和统计）、Mod Loader 从 `--mods-path` 加载、追加一个测试驱动自动加载
- `run_test.py` 打 Mod 包，用 `Brotato.exe --main-pack <测试包> --mods-path <目录> --audio-driver Dummy` 启动，
  等测试驱动跑完自动退出，汇总结果、截图和日志里的脚本错误
- 测试驱动（`driver.gd`）自动开一局站桩打一波，检查：Mod 加载、开波挂上、有伤害记录、热键、鼠标点击和拖动
  （用 `Input.parse_input_event` 走引擎真实的输入流程）、暂停菜单上方也点得到战斗记录（多人时同样）、
  暂停时钟不走、手动重置、浮窗树形的折叠 / 展开和多人时按玩家分组、浮窗背景随鼠标淡入淡出、悬停提示、设置窗口（开关、拖滑杆改配置、录热键）、
  没选中时拆分看全部、逐条事件（实时那段、从日志读结束的段、按选中的行筛选，条数和命中次数一致）、曲线悬停读数、
  收波、浮窗在暂停和收波后让开、**日志按当前版本重新解析后与实时统计逐段逐来源一致**、CSV 导出、战斗记录后台导入、
  队友快照往返，并给每个窗口截图。每次开跑前删掉测试用户目录里 Mod 的配置，测的是默认值

```bash
python tools/testpack/run_test.py                                   # 默认：第 3 波、40 秒、一套覆盖燃烧 / 爆炸 / 建筑 / 反击的配装
python tools/testpack/run_test.py --wave 9 --seconds 30 --loadout "weapon_plank_2,weapon_torch_2,item_riposte"
python tools/testpack/run_test.py --players 2                       # 本地合作
python tools/testpack/run_test.py --with "<Steam 库>/steamapps/workshop/content/1942280/3741034628/six666-BrotatoOnline.zip"
python tools/testpack/run_test.py --wave 18 --enemy-mult 3 --loadout "weapon_minigun_4,weapon_minigun_4,weapon_gatling_laser_4"   # 压力测试
python tools/testpack/summary.py                                    # 再看一遍上次的结果
```

游戏目录默认从 Steam 的各个库里找（`tools/gamedir.py`），也可以设环境变量 `BROTATO_GAME_DIR`，或用 `--game` 指定。

预览图（README 和创意工坊用）也由测试顺便生成，双人、用一套打得热闹的配装：

```bash
python tools/testpack/run_test.py --lang zh --players 2 --wave 9 --seconds 45 --preview preview-zh --loadout "weapon_plank_2,weapon_plank_2,weapon_torch_2,weapon_knife_1,weapon_flamethrower_2,weapon_shredder_1,item_riposte,item_turret_flame,item_scared_sausage,item_landmines"
python tools/testpack/run_test.py --lang en --players 2 --wave 9 --seconds 45 --preview preview-en --preview-sub "Damage meter · Co-op ready" --loadout "（同上）"
```

生成在结果目录里，复制到 `docs/images/`；`docs/workshop/preview.png` 用中文那张。

结果在 `%APPDATA%\BrotatoBCTTest\bct_test\`（`results.json` 和截图），游戏日志在 `%APPDATA%\BrotatoBCTTest\logs\`。
测试会弹出一个游戏窗口，跑完自己关，一次一分钟左右。

结果里的 `perf` 是开销：伤害回调每次约 40 µs（压力测试每秒 125 次时合计每秒 5 ms），
浮窗每次重绘约 0.5–1.2 ms（每秒 5 次，行越多越久），战斗记录约 1.4 ms（实时时每秒 2 次，操作时当帧重画），设置窗口约 1.9 ms（只在操作时画）。

---

## 游戏更新后

本 Mod 只连信号、读字段，多数更新不受影响。确认的办法：

1. 解包、还原脚本到 `reference/`（已在 `.gitignore` 里，游戏代码不入库）：

   ```bash
   python tools/pck.py extract "<游戏目录>/Brotato.pck" reference/game "*.gd*"
   python tools/gdc.py reference/game reference/src
   ```

2. 核对这些还在、含义没变：
   - `Unit.took_damage` 信号的参数；`Unit.take_damage` 先发 `health_updated` 再发 `took_damage`
   - `TakeDamageArgs` 的 `from_player_index` / `hitbox` / `from` / `is_burning`；
     单位的 `_take_damage_args_unit`、`_burning`（`from` / `is_global_burn` / `scaling_stats`）；玩家的 `_dodge_damage_args`
   - `Hitbox` 的 `from` / `damage_tracking_key_hash` / `scaling_stats` / `hit_something`；`PlayerExplosion` 的 `start_explosion` / `player_index`
   - `Weapon` 的 `weapon_id` / `tier` / `_hitbox` / `effects` / `on_weapon_hit_something`；`Player` 的 `player_index` / `current_weapons`
   - `Player.on_healing_effect` 与三条恢复路的方法签名（扩展必须和原方法签名一字不差）
   - `main` 的 `_cleaning_up` / `_is_elite_wave` / `_is_horde_wave` / `_is_wave_failed` / `_is_run_lost` / `_players` / `_entities_container`，
     `EntitySpawner` 的几个生成信号
   - `RunData.current_wave` / `get_player_count` / `get_player_character` / `get_player_weapons`，`Keys.hash_to_string`，
     `ItemService` 的物品列表与 `get_color_from_tier`，`CoopService.get_player_color`，`Text.text("WAVE", …)`
3. 跑自动测试，上面几个场景全绿
4. 更新 `manifest.json` 的 `compatible_game_version` 和 `game/tracker.gd` 的 `BUILT_FOR_GAME`
   （Mod Loader 不按它拦截加载，只是记录；版本不一致时本 Mod 在日志里提一句）

---

## 发布

### GitHub Release

1. 改 `manifest.json` 和 `game/tracker.gd` 里的版本号，提交
2. 打带注释的标签，注释就是发布说明：`git tag -a vX.Y.Z -m "…"`，推送标签
3. CI（`.github/workflows/release.yml`）核对版本号、打包，建 Release 并附上 zip；标题就是标签名

### 创意工坊

用 `tools/workshop_upload.py`（64 位 Python；Steam 要开着、登录的是条目作者的账号）。
它直接调游戏目录里 `steam_api64.dll` 的创意工坊接口，一次设好文件、预览图、标签、各语言的标题和说明，以及英文改动说明；
借 Steam 客户端的登录，不需要账号密码，也不需要 `steam_appid.txt`。连着 Steam 的那一会儿，Steam 会显示在玩 Brotato。

要传的东西都在 `docs/workshop/`：

- `workshop.json`：条目号 [`3809733696`](https://steamcommunity.com/sharedfiles/filedetails/?id=3809733696)、标签、预览图，
  各语言的标题、说明文件和改动说明文件。语言用 Steam 的 API 语言代码（`english`、`schinese`、`tchinese`…）；
  没有单独标题和说明的语言显示英文那一份，所以 `english` 必须有
- `description.*.txt`：说明，Steam 的 BBCode，UTF-8 下要少于 8000 字节（脚本会检查）
- `preview.png`：预览图，要小于 1 MB
- `changenotes/vX.Y.Z.en.txt`、`vX.Y.Z.zh.txt`：这一版的改动说明（BBCode），英文必须有

1. 改好版本号，写好这一版各语言的改动说明；标题、说明、预览图有变化就一起改
2. `python tools/workshop_upload.py`：打包，列出要传的文件、标题、说明和改动说明，不连 Steam
3. `python tools/workshop_upload.py --check`：连上 Steam，核对条目作者是登录的账号，逐个语言对比条目上现在的标题和说明，
   不改任何东西
4. `python tools/workshop_upload.py --upload`：上传。英文以外的语言各自提交一次标题和说明（和条目上一样的跳过），
   最后一次提交文件、预览图、标签、英文的标题和说明，带上英文改动说明；打印 `传好了`
5. 其他语言的改动说明接口提交不了（见下），脚本最后会列出来：到条目的改动说明页面编辑最新一条，按语言填上

改动说明和标题、说明一样按语言存，但接口只能写一种语言。2026-10-01 用一个临时条目实测（试完已删）：

- 文件有变化的提交会新建一条改动说明，说明记在这次提交的语言下；其他语言没有译文时都显示这一份
  （用简体中文提交的那条，英文和繁体中文页面也显示中文）
- 不传文件、或者文件没变的提交，带上的改动说明被丢掉，也不新建一条（简体中文和英文都试过），
  所以给已有的一条补别的语言只能在网页上编辑
- 只改标题和说明、不带改动说明的提交不新建一条，标题和说明按语言生效

`--note 文件` 换一份英文改动说明，`--no-preview` 不换预览图，`--visibility public|friends|private|unlisted` 顺便改可见性，
`--game 目录` 指定游戏目录（默认从 Steam 的各个库里找，也可以设环境变量 `BROTATO_GAME_DIR`）。
账号没接受过创意工坊法律协议的话脚本最后会提示，接受之前条目对别人不可见。

备用：游戏目录里自带的 `GodotWorkshopUtility.exe`。它不经 Steam 启动，游戏目录里要有 `steam_appid.txt`，内容是 `1942280`，
否则日志第一行是 `Steam could not initialize: … No appID found …`，点 Upload 只会停在 `creating new workshop item…`。
选 `build/workshop/` 下的 zip，Workshop ID 填 `3809733696`（留空会另建一个新条目）。
它只设文件、预览图、标签和英文标题：标题取 zip 的文件名，所以 `package.py` 用 `workshop.json` 里的英文标题给 zip 命名。
提交的改动说明是空的；其他语言的标题、各语言的说明和改动说明要到条目页面上改。

---

## 已知的无害报错

`ERROR: Cannot load source code from file 'res://tests/partial_doubles/pd_player.gd'` —
Mod Loader 给 `player.gd` 装扩展后会重载所有以 `Player` 为父类的全局类，其中有一个游戏开发时的测试类，
文件没打进游戏。加载失败什么也不影响；只要有 Mod 扩展 `player.gd` 就会出现（BrotatoOnline 也一样）。
