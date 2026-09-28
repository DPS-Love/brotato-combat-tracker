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
└── ui/                         浮窗、明细窗口、战斗记录主面板，全部自绘
tools/
├── package.py                  打包，核对版本号
├── pck.py / gdc.py             解包游戏、把编译过的脚本还原成源码（对齐用）
└── testpack/                   隔离测试包与自动测试
docs/                           文档；workshop/ 下是创意工坊的文案和预览图
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
`build/workshop/Brotato Combat Tracker - DPS Meter 伤害统计.zip`（创意工坊上传，内容相同）。
zip 里只有 `mods-unpacked/DPSLove-CombatTracker/` 一个目录，时间戳固定，同样的源码打出来逐字节相同。

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

每个事件 ──► Parser（本局会话）──► 浮窗 / 主面板
         └─► LogWriter ──► logs/bct-*.bctlog.gz
导入：LogReader ──► Parser（新会话）──► 主面板
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

- 三个窗口都是整窗自绘的 `Control`（`ui/window_base.gd`），绘制时顺手登记点击区——和 TBH Combat Tracker 的 IMGUI 写法一一对应。
  不用 `Button` 等内置控件：它们会抢键盘 / 手柄焦点，和游戏的焦点导航打架；焦点一律 `FOCUS_NONE`
- **鼠标不走 Godot 的界面分发**，由 `ui_root` 在 `_input` 里自己分发（窗口的 `mouse_filter` 都是 `IGNORE`）。原因有二：
  Godot 3 找鼠标下的控件时按节点在树里的先后，不看 `CanvasLayer` 的层级，点击会先落到游戏场景铺满全屏的容器上；
  多人时游戏的手柄焦点模拟器（`FocusEmulator`）在 `_input` 里把鼠标事件全部标记为已处理，界面根本收不到。
  界面的 `CanvasLayer` 挂在**根节点下、排在最后**（每次换场景挪回最后），`_input` 按树的逆序调用，所以最先轮到它：
  落在窗口上的点击和滚轮交给窗口并吃掉，鼠标移动照样放给游戏（鼠标瞄准时光标划过浮窗不会卡住准星），
  按住拖窗口期间事件一直交给按下的那个窗口
- 浮窗只在波次进行中、游戏没暂停时显示，免得盖住暂停菜单和收波后的升级选择并吃掉那里的点击
- 字体用游戏自带的思源黑体（Noto Sans SC / TC / JP / KR）现建，描边字用 `DynamicFont.outline_size`
- 配色、版式常量来自 TBH Combat Tracker（按 1080p 放大约 1.3 倍）；主面板里按来源分组时色条和曲线用调色板按名次配色，
  因为同品质的武器颜色一样，曲线会分不开

---

## 自动测试

`tools/testpack/` 用游戏本体跑一整套端到端测试，**完全不碰玩家的存档**：

- `build_testpack.py` 复制一份 `Brotato.pck` 到 `build/testpack/`，只在副本里打补丁：
  用户目录改名 `BrotatoBCTTest`（存档、设置、日志全部隔离）、平台层固定走 LocalPlatform（不初始化 Steam，
  不碰云存档、成就和统计）、Mod Loader 从 `--mods-path` 加载、追加一个测试驱动自动加载
- `run_test.py` 打 Mod 包，用 `Brotato.exe --main-pack <测试包> --mods-path <目录> --audio-driver Dummy` 启动，
  等测试驱动跑完自动退出，汇总结果、截图和日志里的脚本错误
- 测试驱动（`driver.gd`）自动开一局站桩打一波，检查：Mod 加载、开波挂上、有伤害记录、热键、鼠标点击和拖动
  （用 `Input.parse_input_event` 走引擎真实的输入流程）、暂停菜单上方也点得到主面板（多人时同样）、
  暂停时钟不走、手动重置、收波、浮窗在暂停和收波后让开、
  **日志按当前版本重新解析后与实时统计逐段逐来源一致**、CSV 导出、主面板后台导入、队友快照往返，
  并给每个窗口截图

```bash
python tools/testpack/run_test.py                                   # 默认：第 3 波、20 秒、一套覆盖燃烧 / 爆炸 / 建筑 / 反击的配装
python tools/testpack/run_test.py --wave 9 --seconds 30 --loadout "weapon_plank_2,weapon_torch_2,item_riposte"
python tools/testpack/run_test.py --players 2                       # 本地合作
python tools/testpack/run_test.py --with "<Steam 库>/steamapps/workshop/content/1942280/3741034628/six666-BrotatoOnline.zip"
python tools/testpack/run_test.py --wave 18 --enemy-mult 3 --loadout "weapon_minigun_4,weapon_minigun_4,weapon_gatling_laser_4"   # 压力测试
python tools/testpack/run_test.py --lang en --preview preview-en    # 顺便生成预览图
python tools/testpack/summary.py                                    # 再看一遍上次的结果
```

结果在 `%APPDATA%\BrotatoBCTTest\bct_test\`（`results.json` 和截图），游戏日志在 `%APPDATA%\BrotatoBCTTest\logs\`。
测试会弹出一个游戏窗口，跑完自己关，一次半分钟左右。

结果里的 `perf` 是开销：伤害回调每次约 40 µs（压力测试每秒 125 次时合计每秒 5 ms），
浮窗每次重绘约 0.5 ms（每秒 10 次），主面板约 1 ms（每秒 4 次）。

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

用游戏目录里自带的 `GodotWorkshopUtility.exe`（Steam 要开着、登录的是上传者的账号）：

1. `python tools/package.py`，用 `build/workshop/` 下那个 zip。**它的文件名就是创意工坊标题**，
   上传工具每次上传都会用文件名覆盖标题，所以文件名固定、不带版本号
2. 选 zip；第一次上传选预览图 `docs/workshop/preview.png`；标签选 **GUI** 和 **Utilities**
3. Workshop ID：第一次留空（新建条目），之后填这个 ID（更新条目）。新建成功后记下 ID
4. 上传完到创意工坊页面：把 `docs/workshop/description.zh.txt` / `description.en.txt`（Steam 的 BBCode）
   贴进说明，写更新说明，确认没问题后把可见性改成公开

上传工具不设说明，也不设可见性；新条目默认不公开。

---

## 已知的无害报错

`ERROR: Cannot load source code from file 'res://tests/partial_doubles/pd_player.gd'` —
Mod Loader 给 `player.gd` 装扩展后会重载所有以 `Player` 为父类的全局类，其中有一个游戏开发时的测试类，
文件没打进游戏。加载失败什么也不影响；只要有 Mod 扩展 `player.gd` 就会出现（BrotatoOnline 也一样）。
