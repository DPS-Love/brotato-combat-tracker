extends Node

# 统计节点：挂到游戏上、推进波次时钟、把看到的伤害 / 承伤 / 治疗变成战斗事件，
# 交给解析器（本局统计）和日志写入器。联机同步是它的子节点；界面由它创建，挂在根节点下。
#
#   Unit.took_damage 信号 ─┐
#   player.gd 扩展（治疗）─┼─► _emit(事件) ─┬─► Parser（本局会话）──► 浮窗 / 主面板
#   波次开始 / 结束       ─┘                └─► LogWriter ──► logs/bct-*.bctlog.gz
#   队友快照（联机）───────────────────────────► Parser
#
# 只读：只连信号、读字段，不改任何游戏数值。游戏的类型一律按字段和方法「鸭子类型」识别，
# 不写死 class_name——某个类以后改名，这里只是认不出，不会让整个 Mod 加载失败。

const VERSION = "0.2.0"
const BUILT_FOR_GAME = "1.1.15.4"
const LOG_NAME = "DPSLove-CombatTracker"
const DATA_DIR = "user://CombatTracker"

const Model = preload("../core/model.gd")
const Parser = preload("../core/parser.gd")
const Config = preload("../core/config.gd")
const LogWriter = preload("../core/log_writer.gd")
const LogReader = preload("../core/log_reader.gd")
const Csv = preload("../core/csv.gd")
const Names = preload("names.gd")
const NetSync = preload("net_sync.gd")
const UiRoot = preload("../ui/ui_root.gd")

const EMPTY_HASH = 5381      # Keys.empty_hash
const SYNC_INTERVAL = 2.0
const EXPLOSION_LINK_SECONDS = 1.0
const MAX_LIVE_EVENTS = 30000

var config = null
var names = null
var net = null
var ui = null
var session = null
var writer = null
var overkill := false
var include_trees := false
# 进行中那一段的伤害 / 承伤 / 治疗事件，战斗记录的「逐条事件」看实时那段时用；
# 结束的段从日志里读。换段时换一个新数组（gen 加一），界面据此知道要重新筛
var live_events := []
var live_events_enc = null
var live_events_gen := 0
var live_events_capped := false
# 自测用：伤害回调累计耗时（微秒）与调用次数
var cost_usec := 0
var cost_calls := 0

var _main = null
var _scene_id := 0
var _clock := 0.0
var _live := false
var _run_seq := 0
var _new_run := true
var _last_wave := 0
var _last_failed := false
var _hooked := {}           # 单位实例 id -> true
var _hp := {}               # 单位实例 id -> [这一击之前的血量, 当前血量]
var _weapon_keys := {}      # 武器实例 id -> 来源键
var _explosive := {}        # 玩家 -> [来源键, 时钟]：最近一次带爆炸效果的近战命中
var _explosive_weapon := {} # 武器实例 id -> 是否带爆炸效果
var _flush_in := 2.0
var _sweep_in := 0.0
var _sync_in := SYNC_INTERVAL
var _sync_dirty := false
var _keys_node = null


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	Engine.set_meta("dpslove_bct", self)

	config = Config.new()
	config.load_or_create(DATA_DIR.plus_file("config.cfg"))

	names = Names.new()
	names.config = config

	session = Model.BctSession.new()
	session.started_unix = OS.get_unix_time()
	apply_config()

	_maintain_logs()
	if config.value("LogEvents"):
		writer = LogWriter.new()
		if not writer.open(log_dir(), _meta()):
			_warn("战斗日志无法写入：" + ProjectSettings.globalize_path(log_dir()))
			writer = null

	net = NetSync.new()
	net.name = "NetSync"
	add_child(net)
	net.connect("snapshot_received", self, "_on_snapshot_received")

	# 界面挂在根节点下、排在最后：鼠标由它在 _input 里自己分发，_input 按树的逆序调用，
	# 排最后才能赶在游戏的界面和手柄焦点模拟器之前拿到点击（详见 ui_root.gd）
	ui = UiRoot.new()
	ui.name = "DPSLoveCombatTrackerUI"
	ui.tracker = self
	get_tree().root.call_deferred("add_child", ui)

	var game = _game_version()
	if game != "" and game != BUILT_FOR_GAME:
		_info("游戏版本 %s，本版按 %s 构建；统计只连信号，通常不受影响" % [game, BUILT_FOR_GAME])


func _exit_tree() -> void:
	if _live:
		_end_wave()
	if writer != null:
		writer.close()
		writer = null
	if ui != null and is_instance_valid(ui):
		ui.queue_free()
	if Engine.has_meta("dpslove_bct") and Engine.get_meta("dpslove_bct") == self:
		Engine.remove_meta("dpslove_bct")


func _physics_process(delta: float) -> void:
	# 波次时钟：只在波次进行中、游戏没暂停时走，和游戏自己的计时一样受暂停影响
	if _live and not get_tree().paused:
		_clock += delta
		Parser.tick(session, _clock)


func _process(delta: float) -> void:
	_poll_scene()
	if _main != null:
		if not is_instance_valid(_main):
			_detach()
		else:
			_sweep_in -= delta
			if _sweep_in <= 0.0:
				_sweep_in = 1.0
				_sweep()
			# 收波、全员阵亡、波次失败都会走 clean_up_room，它把 _cleaning_up 置真
			if _live and _main.get("_cleaning_up") == true:
				_end_wave()
	_flush_in -= delta
	if _flush_in <= 0.0:
		_flush_in = 2.0
		if writer != null:
			writer.flush()
		config.save_if_dirty()
		# 别的 Mod 也可能往根节点下加东西，隔一会儿检查一次
		_keep_ui_last()
	_sync_in -= delta
	if _sync_in <= 0.0:
		_sync_in = SYNC_INTERVAL
		_sync(false)


# ===========================================================================
# 路径与信息
# ===========================================================================

# 设置界面改了配置：统计口径、保留段数立即生效（热键、颜色、界面由界面自己读）
func apply_config() -> void:
	overkill = config.value("CountOverkill")
	include_trees = config.value("IncludeTrees")
	session.history_size = config.value("HistorySize")
	session.trim()


func log_dir() -> String:
	return DATA_DIR.plus_file("logs")


func export_dir() -> String:
	return DATA_DIR.plus_file("exports")


func is_live() -> bool:
	return _live


func clock() -> float:
	return _clock


func _meta() -> Dictionary:
	var dt = OS.get_datetime()
	return {
		"mod": VERSION,
		"game": _game_version(),
		"start": "%04d-%02d-%02dT%02d:%02d:%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second],
		"start_unix": OS.get_unix_time(),
	}


func _game_version() -> String:
	var pd = get_node_or_null("/root/ProgressData")
	if pd == null:
		return ""
	var v = pd.get("VERSION")
	return str(v) if v != null else ""


func _info(msg: String) -> void:
	ModLoaderLog.info(msg, LOG_NAME)


func _warn(msg: String) -> void:
	ModLoaderLog.warning(msg, LOG_NAME)


# 旧日志：超过保留天数的删掉；上次没压缩成的（游戏被强杀）补压
func _maintain_logs() -> void:
	var dir = log_dir()
	var d = Directory.new()
	if d.open(dir) != OK:
		return
	var retention = int(config.value("LogRetentionDays"))
	var now = OS.get_unix_time()
	for info in LogReader.list_logs(dir):
		if retention > 0 and now - int(info.mtime) > retention * 86400:
			d.remove(info.path)
		elif info.name.ends_with(".bctlog"):
			LogWriter.compress_file(info.path)


# ===========================================================================
# 场景：进入战斗场景就开一段，离开就收
# ===========================================================================

func _poll_scene() -> void:
	var scene = get_tree().current_scene
	var id = scene.get_instance_id() if scene != null else 0
	if id == _scene_id:
		return
	_scene_id = id
	_keep_ui_last()
	if _main != null:
		_detach()
	if scene == null:
		return
	if _is_battle_scene(scene):
		_attach(scene)
	elif _is_menu_scene(scene):
		_new_run = true


# 换场景时新场景会追加到根节点末尾，把界面挪回最后，它的 _input 才最先轮到
func _keep_ui_last() -> void:
	if ui == null or not is_instance_valid(ui):
		return
	var root = get_tree().root
	if ui.get_parent() == root and ui.get_index() != root.get_child_count() - 1:
		root.move_child(ui, root.get_child_count() - 1)


func _is_battle_scene(scene) -> bool:
	if str(scene.filename) == "res://main.tscn":
		return true
	return scene.has_signal("end_of_the_wave") and scene.get_node_or_null("EntitySpawner") != null


func _is_menu_scene(scene) -> bool:
	var f = str(scene.filename)
	return f.find("character_selection") >= 0 or f.find("title_screen") >= 0 or f.find("main_menu") >= 0


func _attach(main) -> void:
	_main = main
	_hooked.clear()
	_hp.clear()
	_weapon_keys.clear()
	_explosive.clear()
	_explosive_weapon.clear()

	var wave = int(_run_data_get("current_wave", 0))
	# 换角色 / 回过标题、波次倒退、同一波没失败却又打了一次（从暂停菜单重开）都算新的一局；
	# 同一波失败后重来算同一局的第 2 次
	if _new_run or wave < _last_wave or (wave == _last_wave and not _last_failed):
		_run_seq += 1
	_new_run = false
	_last_wave = wave
	_last_failed = false

	_clock = 0.0
	_live = true
	var tags = 0
	if main.get("_is_elite_wave") == true:
		tags |= Model.TAG_ELITE
	if main.get("_is_horde_wave") == true:
		tags |= Model.TAG_HORDE
	if _run_data_get("is_endless_run", false) == true:
		tags |= Model.TAG_ENDLESS
	_emit(["W", 0.0, "start", wave, tags, _run_seq, OS.get_unix_time()])
	for p in range(_player_count()):
		var ch = _character_id(p)
		if ch != "":
			_emit(["C", 0.0, p, ch])
		var lo = _loadout(p)
		if lo != "":
			_emit(["L", 0.0, p, lo])

	var spawner = main.get_node_or_null("EntitySpawner")
	if spawner != null:
		for sig in ["enemy_spawned", "neutral_spawned"]:
			if spawner.has_signal(sig) and not spawner.is_connected(sig, self, "_on_unit_spawned"):
				spawner.connect(sig, self, "_on_unit_spawned", [false])
		for sig in ["enemy_respawned", "neutral_respawned"]:
			if spawner.has_signal(sig) and not spawner.is_connected(sig, self, "_on_unit_spawned"):
				spawner.connect(sig, self, "_on_unit_spawned", [true])
		if spawner.has_signal("players_spawned") and not spawner.is_connected("players_spawned", self, "_on_players_spawned"):
			spawner.connect("players_spawned", self, "_on_players_spawned")
	_sweep()


func _detach() -> void:
	if _live:
		_end_wave()
	_main = null
	_hooked.clear()
	_hp.clear()
	_weapon_keys.clear()
	_explosive_weapon.clear()


func _end_wave() -> void:
	if not _live:
		return
	if _main != null and is_instance_valid(_main):
		_last_failed = _main.get("_is_wave_failed") == true or _main.get("_is_run_lost") == true
	var enc = session.current
	_sync(true)
	# 队友的最终快照写进日志：导入时也能看到整队
	if enc != null and writer != null:
		for p in enc.remote_snapshots.keys():
			writer.write(["P", _clock, p, enc.remote_snapshots[p], enc.wave])
	_emit(["W", _clock, "end", enc.tags if enc != null else 0])
	_live = false


# 手动重置（F10 / 浮窗上的「重置」）：同一波切出新的一段
func reset_current() -> void:
	if _live:
		_emit(["R", _clock])


# ===========================================================================
# 事件出口
# ===========================================================================

func _emit(ev: Array) -> void:
	Parser.apply(session, ev)
	if writer != null:
		writer.write(ev)
	_sync_dirty = true
	var k = ev[0]
	if k == "D" or k == "T" or k == "H":
		if session.current != live_events_enc:
			live_events = []
			live_events_enc = session.current
			live_events_gen += 1
			live_events_capped = false
		if live_events.size() < MAX_LIVE_EVENTS:
			live_events.append(ev)
		else:
			live_events_capped = true


# ===========================================================================
# 挂单位
# ===========================================================================

func _on_unit_spawned(unit, respawned: bool) -> void:
	_hook(unit, respawned)


func _on_players_spawned(players) -> void:
	if typeof(players) == TYPE_ARRAY:
		for pl in players:
			_hook(pl, false)
			var weapons = pl.get("current_weapons") if pl != null and is_instance_valid(pl) else null
			if typeof(weapons) == TYPE_ARRAY:
				for w in weapons:
					_hook_melee_explosive(w)


# 生成信号是主路径；这里每秒扫一遍兜底：别的 Mod 绕开 EntitySpawner 生成的单位（联机 Mod 的
# 本地副本就可能这样）、以及挂上之前就已经在场的玩家
func _sweep() -> void:
	if _main == null or not is_instance_valid(_main):
		return
	var players = _main.get("_players")
	if typeof(players) == TYPE_ARRAY:
		for pl in players:
			_hook(pl, false)
			if pl != null and is_instance_valid(pl):
				var weapons = pl.get("current_weapons")
				if typeof(weapons) == TYPE_ARRAY:
					for w in weapons:
						_hook_melee_explosive(w)
	var container = _main.get("_entities_container")
	if container != null and is_instance_valid(container):
		for child in container.get_children():
			if child.has_signal("took_damage"):
				_hook(child, false)


func _hook(unit, reset_hp: bool) -> void:
	if unit == null or not is_instance_valid(unit) or not unit.has_signal("took_damage"):
		return
	var id = unit.get_instance_id()
	if reset_hp or not _hp.has(id):
		var h = _health_of(unit)
		_hp[id] = [h, h]
	if _hooked.has(id):
		return
	_hooked[id] = true
	if not unit.is_connected("took_damage", self, "_on_took_damage"):
		unit.connect("took_damage", self, "_on_took_damage")
	if unit.has_signal("health_updated") and not unit.is_connected("health_updated", self, "_on_health_updated"):
		unit.connect("health_updated", self, "_on_health_updated")
	# Boss 的 is_elite 为假；普通敌人没有这个字段
	if _live and unit.get("enemy_id") != null and unit.get("is_elite") == false:
		_emit(["W", _clock, "tags", Model.TAG_BOSS])


func _health_of(unit) -> float:
	var cs = unit.get("current_stats")
	if cs == null:
		return 0.0
	var h = cs.get("health")
	return float(h) if h != null else 0.0


# health_updated 在 took_damage 之前发：记下「这一击之前」的血量，击杀那一击据此扣掉溢出
func _on_health_updated(unit, current, _max_value) -> void:
	if unit == null:
		return
	var id = unit.get_instance_id()
	var e = _hp.get(id)
	if e == null:
		_hp[id] = [float(current), float(current)]
	else:
		e[0] = e[1]
		e[1] = float(current)


func _effective(unit, value: float) -> float:
	if _health_of(unit) > 0.0:
		return value
	var e = _hp.get(unit.get_instance_id())
	if e == null or e[0] <= 0.0:
		return value
	return min(value, e[0])


# ===========================================================================
# 伤害
# ===========================================================================

func _on_took_damage(unit, value, _knockback, is_crit, is_dodge, is_protected, armor_did_something, args, _hit_type, is_one_shot) -> void:
	if not _live or unit == null or not is_instance_valid(unit):
		return
	var t0 = OS.get_ticks_usec()
	if unit.has_method("on_healing_effect"):
		_on_player_took_damage(unit, value, is_dodge, is_protected, armor_did_something, args)
	else:
		_on_enemy_took_damage(unit, value, is_crit, is_one_shot, args)
	cost_usec += OS.get_ticks_usec() - t0
	cost_calls += 1


func _on_enemy_took_damage(unit, value, is_crit, is_one_shot, args) -> void:
	if value == null or float(value) <= 0.0:
		return
	var is_tree = unit.get("enemy_id") == null
	if is_tree and not include_trees:
		return
	var c = _classify(unit, args)
	var p = c[0]
	# 敌人之间的伤害、环境伤害不属于任何玩家
	if p < 0 or p > 3 or not net.owns_player(p):
		return
	var v = float(value)
	var flags = 0
	if is_crit:
		flags |= Model.F_CRIT
	if is_one_shot:
		flags |= Model.F_ONESHOT
	if _health_of(unit) <= 0.0:
		flags |= Model.F_KILL
	_emit(["D", _clock, p, c[1], _unit_key(unit), v, _effective(unit, v), flags, c[2], c[3]])


func _on_player_took_damage(player, value, is_dodge, is_protected, armor_did_something, args) -> void:
	var p = int(player.get("player_index"))
	if p < 0 or p > 3 or not net.owns_player(p):
		return
	var v = float(value) if value != null else 0.0
	var flags = 0
	if is_dodge:
		flags |= Model.F_DODGE
	if is_protected:
		flags |= Model.F_PROTECTED
	if armor_did_something:
		flags |= Model.F_ARMOR
	if _health_of(player) <= 0.0:
		flags |= Model.F_DIED
	var eff = 0.0 if (is_dodge or is_protected) else _effective(player, v)
	_emit(["T", _clock, p, _attacker_key(args), v, eff, flags])


# 目标 / 攻击者的键
func _unit_key(unit) -> String:
	var eid = unit.get("enemy_id")
	if eid == null:
		return "n:tree"
	var elite = unit.get("is_elite")
	if elite == null:
		return "e:" + str(eid)
	return ("l:" if elite else "b:") + str(eid)


func _attacker_key(args) -> String:
	if args == null:
		return "o:unknown"
	var from = args.get("from")
	var hitbox = args.get("hitbox")
	if (from == null or not is_instance_valid(from)) and hitbox != null and is_instance_valid(hitbox):
		from = hitbox.get("from")
	if from != null and is_instance_valid(from):
		if from.get("enemy_id") != null:
			return _unit_key(from)
		if from.has_method("on_healing_effect"):
			return "p:self"
	# 没有命中框也没有来源：物品效果扣的血（比如受伤触发的自伤）
	if hitbox == null:
		return "p:self"
	return "o:unknown"


# 一次对敌伤害归到谁、哪个来源：[玩家, 来源键, 形式, 类别]
func _classify(unit, args) -> Array:
	var p := -1
	var src := ""
	var form = Model.FORM_HIT
	var cls := ""
	if args == null:
		return [p, "o:unknown", Model.FORM_EFFECT, cls]
	var fp = args.get("from_player_index")
	if fp != null:
		p = int(fp)
	var hitbox = args.get("hitbox")

	if hitbox != null and is_instance_valid(hitbox):
		var from = hitbox.get("from")
		cls = _class_of(hitbox.get("scaling_stats"))
		var track = hitbox.get("damage_tracking_key_hash")
		if from != null and is_instance_valid(from):
			if _is_weapon(from):
				src = _weapon_key(from)
				# 只有武器自己的近战命中框放的爆炸才不连回武器；远程武器的爆炸由弹道连好了
				if hitbox == from.get("_hitbox"):
					_note_explosive(from, src, p)
			elif from.get("enemy_id") != null:
				# 被魅惑的敌人替魅惑它的玩家打
				if from.has_method("get_charmed_by_player_index"):
					var charmer = int(from.get_charmed_by_player_index())
					if charmer >= 0:
						p = charmer
				src = "m:" + str(from.get("enemy_id"))
			elif from.has_method("start_explosion"):
				# 爆炸的命中框来源永远是爆炸节点本身；由武器命中触发的会把 hit_something 连回武器
				form = Model.FORM_EXPLOSION
				var exploder = from.get("player_index")
				if (p < 0 or p > 3) and exploder != null:
					p = int(exploder)
				var w = _linked_weapon(from)
				if w != null:
					src = _weapon_key(w)
				elif _tracked(track):
					src = "i:" + _hash_str(track)
				else:
					src = _recent_explosive(p)
		if src == "" and _tracked(track):
			src = "i:" + _hash_str(track)
		if src == "" and from != null and is_instance_valid(from):
			# 炮塔一类的建筑：自己身上带追踪键
			var own = from.get("_damage_tracking_key_hash")
			if _tracked(own):
				src = "i:" + _hash_str(own)
		if src == "":
			src = "o:unknown"
		return [p, src, form, cls]

	# 没有命中框：燃烧跳伤、反击、敌人死亡 / 拾取触发的属性伤害、联机 Mod 的补账……
	# 靠参数对象本身是谁来区分：燃烧跳伤用的是被烧单位自己的参数对象
	if args.get("is_burning") and args == unit.get("_take_damage_args_unit"):
		form = Model.FORM_BURN
		var burning = unit.get("_burning")
		if burning != null:
			cls = _class_of(burning.get("scaling_stats"))
			# 按游戏自己的记账规则归属（unit.gd 的燃烧跳伤）：
			#   全局燃烧（武器本身不带燃烧、是物品给的燃烧几率）算受惊香肠，哪怕是武器点着的
			#   其余算点着它的武器 / 建筑；没有来源又是工程学缩放的算燃烧炮塔（普通炮塔不填来源）
			var bf = burning.get("from")
			if burning.get("is_global_burn") == true:
				src = "i:item_scared_sausage"
			elif bf != null and is_instance_valid(bf):
				if _is_weapon(bf):
					src = _weapon_key(bf)
				else:
					var own = bf.get("_damage_tracking_key_hash")
					if _tracked(own):
						src = "i:" + _hash_str(own)
			if src == "" and cls == "stat_engineering":
				src = "i:item_turret_flame"
		if src == "":
			src = "o:burn"
		return [p, src, form, cls]
	if _is_riposte(args):
		return [p, "i:item_riposte", Model.FORM_EFFECT, cls]
	return [p, "o:effect", Model.FORM_EFFECT, cls]


func _is_weapon(node) -> bool:
	return node.get("weapon_id") != null and node.has_method("on_weapon_hit_something")


func _weapon_key(w) -> String:
	var id = w.get_instance_id()
	var k = _weapon_keys.get(id)
	if k == null:
		var tier = w.get("tier")
		k = "w:" + str(w.get("weapon_id")) + ":" + str(int(tier) if tier != null else 0)
		_weapon_keys[id] = k
	return k


# 近战武器（木板、动力拳…）命中时会放两发爆炸：unit.gd 那发把 hit_something 连回武器，
# weapon.gd 自己那发不连。后者只能按「同一名玩家刚刚用它打中过东西」认领。
# 爆炸触发时那一击本身不造成伤害（没有 took_damage），所以要直接听武器命中框的 hit_something。
func _hook_melee_explosive(w) -> void:
	if w == null or not is_instance_valid(w) or not _is_weapon(w):
		return
	var hitbox = w.get("_hitbox")
	if hitbox == null or not is_instance_valid(hitbox) or not hitbox.has_signal("hit_something"):
		return
	if hitbox.is_connected("hit_something", self, "_on_melee_hit"):
		return
	hitbox.connect("hit_something", self, "_on_melee_hit", [w])


func _on_melee_hit(_thing_hit, _damage_dealt, weapon) -> void:
	if _live and weapon != null and is_instance_valid(weapon):
		var p = weapon.get("player_index")
		_note_explosive(weapon, _weapon_key(weapon), int(p) if p != null else -1)


func _note_explosive(w, key: String, p: int) -> void:
	var id = w.get_instance_id()
	var explosive = _explosive_weapon.get(id)
	if explosive == null:
		explosive = false
		var effects = w.get("effects")
		if typeof(effects) == TYPE_ARRAY:
			for e in effects:
				if e != null and e.get("explosion_scene") != null:
					explosive = true
					break
		_explosive_weapon[id] = explosive
	if explosive:
		_explosive[p] = [key, _clock]


func _recent_explosive(p: int) -> String:
	var e = _explosive.get(p)
	if e != null and _clock - e[1] <= EXPLOSION_LINK_SECONDS:
		return e[0]
	return "o:explosion"


func _linked_weapon(explosion):
	for c in explosion.get_signal_connection_list("hit_something"):
		var t = c.get("target")
		if t != null and is_instance_valid(t) and _is_weapon(t):
			return t
	return null


func _is_riposte(args) -> bool:
	if _main == null or not is_instance_valid(_main):
		return false
	var players = _main.get("_players")
	if typeof(players) != TYPE_ARRAY:
		return false
	for pl in players:
		if pl != null and is_instance_valid(pl) and args == pl.get("_dodge_damage_args"):
			return true
	return false


# 伤害类别取第一个缩放属性，和游戏的 Utils.get_first_scaling_stat 一致
func _class_of(scaling_stats) -> String:
	if typeof(scaling_stats) != TYPE_ARRAY or scaling_stats.empty():
		return ""
	var first = scaling_stats[0]
	if typeof(first) != TYPE_ARRAY or first.empty():
		return ""
	if typeof(first[0]) == TYPE_STRING:
		return first[0]
	return _hash_str(first[0])


func _tracked(h) -> bool:
	return h != null and typeof(h) == TYPE_INT and h != EMPTY_HASH and h != 0


func _hash_str(h) -> String:
	if _keys_node == null or not is_instance_valid(_keys_node):
		_keys_node = get_node_or_null("/root/Keys")
	if _keys_node != null:
		var map = _keys_node.get("hash_to_string")
		if typeof(map) == TYPE_DICTIONARY and map.has(h):
			return str(map[h])
	return str(h)


# ===========================================================================
# 治疗（由 player.gd 扩展调用）
# ===========================================================================

func on_player_healed(player, healed: int, tracking_key: int, ctx: String) -> void:
	if not _live or player == null:
		return
	var p = int(player.get("player_index"))
	if p < 0 or p > 3 or not net.owns_player(p):
		return
	var src := ""
	if ctx != "":
		src = "h:" + ctx
	elif _tracked(tracking_key):
		src = "i:" + _hash_str(tracking_key)
	else:
		# 空追踪键又不在三条路上的，几乎都是吃掉落物（水果）
		src = "h:consumable"
	_emit(["H", _clock, p, src, float(healed)])


# ===========================================================================
# 联机
# ===========================================================================

func _sync(final: bool) -> void:
	if net == null or not config.value("ShareStats") or not net.is_online():
		return
	var enc = session.current
	if enc == null:
		return
	if not final and not _sync_dirty:
		return
	_sync_dirty = false
	var players := {}
	for p in enc.players():
		if net.owns_player(p):
			players[str(p)] = Parser.export_snapshot(enc, p)
	net.broadcast_snapshot(enc.wave, players, final)


func _on_snapshot_received(p: int, snap: Dictionary, wave: int) -> void:
	if not config.value("ShareStats"):
		return
	var text = to_json(snap)
	var before = session.current
	Parser.apply(session, ["P", _clock, p, text, wave])
	# 本地已经收波之后才到的最终版，补写进日志（导入时后到的覆盖先到的）
	if (before == null or before.wave != wave) and writer != null:
		writer.write(["P", _clock, p, text, wave])


# ===========================================================================
# 导出
# ===========================================================================

func export_csv(enc, tag: String) -> String:
	return Csv.write(enc, names, overkill, export_dir(), tag)


# ===========================================================================
# 读游戏的运行数据
# ===========================================================================

func _run_data():
	return get_node_or_null("/root/RunData")


func _run_data_get(field: String, fallback):
	var rd = _run_data()
	if rd == null:
		return fallback
	var v = rd.get(field)
	return v if v != null else fallback


func _player_count() -> int:
	var rd = _run_data()
	if rd != null and rd.has_method("get_player_count"):
		return int(rd.get_player_count())
	return 1


func _character_id(p: int) -> String:
	var rd = _run_data()
	if rd == null or not rd.has_method("get_player_character"):
		return ""
	var ch = rd.get_player_character(p)
	if ch == null:
		return ""
	var id = ch.get("my_id")
	return str(id) if id != null else ""


func _loadout(p: int) -> String:
	var rd = _run_data()
	if rd == null or not rd.has_method("get_player_weapons"):
		return ""
	var keys := PoolStringArray()
	for w in rd.get_player_weapons(p):
		if w == null:
			continue
		var wid = w.get("weapon_id")
		var tier = w.get("tier")
		if wid != null:
			keys.append("w:" + str(wid) + ":" + str(int(tier) if tier != null else 0))
	return keys.join(",")
