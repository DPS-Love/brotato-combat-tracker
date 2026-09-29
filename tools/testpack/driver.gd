extends Node

# 测试驱动：只存在于隔离测试包里，永远不进发布包。
#
# 自动开一局（指定角色、武器、物品），打一波，途中给浮窗 / 明细窗口 / 主面板截图；
# 收波后把本局日志按当前版本重新解析，逐段、逐来源和实时统计比对；导出 CSV；
# 再把玩家 1 的快照当成联机队友（玩家 2）喂回去，截一张多人视图；最后退出。
#
# 结果写在测试用户目录的 bct_test/ 下：results.json 和若干 png。
# 环境变量：
#   BCT_TEST_WAVE        开局波次（默认 3）
#   BCT_TEST_SECONDS     波次时长（默认 40：界面检查要在波次里做完）
#   BCT_TEST_LANG        界面语言（zh / en，由测试平台层读取）
#   BCT_TEST_LOADOUT     逗号分隔的 my_id（武器与物品），默认一套覆盖燃烧 / 爆炸 / 建筑 / 反击的配装
#   BCT_TEST_ENEMY_MULT  敌人数量倍率（压力测试用，默认 1）
#   BCT_TEST_PLAYERS     本地合作的玩家数（默认 1）

const OUT = "user://bct_test"
const MOD = "res://mods-unpacked/DPSLove-CombatTracker"
const DEFAULT_LOADOUT = "weapon_smg_3,weapon_smg_3,weapon_torch_2,weapon_plank_2,weapon_rocket_launcher_2,weapon_flamethrower_2,item_turret,item_landmines,item_riposte,item_turret_flame"

var results := {"checks": {}, "notes": []}
var tracker = null


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	DebugService.disable_saving = true
	DebugService.no_fullscreen_on_launch = true
	DebugService.custom_wave_duration = int(_env("BCT_TEST_SECONDS", "40"))
	DebugService.nb_enemies_mult = float(_env("BCT_TEST_ENEMY_MULT", "1"))
	var d = Directory.new()
	d.make_dir_recursive(OUT)
	call_deferred("_run")


func _env(key: String, fallback: String) -> String:
	var v = OS.get_environment(key)
	return v if v != "" else fallback


func _check(name: String, ok: bool, detail = null) -> void:
	results.checks[name] = {"ok": ok, "detail": detail}


func _note(s: String) -> void:
	results.notes.append(s)


func _run() -> void:
	yield(get_tree().create_timer(0.5), "timeout")
	var screen = OS.get_screen_size()
	var size = Vector2(1920, 1080)
	if screen.x < 2000 or screen.y < 1150:
		size = Vector2(1600, 900)
	OS.window_fullscreen = false
	OS.window_size = size
	OS.window_position = Vector2(20, 20)
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	# 测试用户目录里存过语言设置后，平台层给的语言就不再生效，这里直接切
	var lang = _env("BCT_TEST_LANG", "")
	if lang != "":
		ProgressData.settings.language = lang
		TranslationServer.set_locale(lang)
	yield(get_tree().create_timer(3.0), "timeout")

	tracker = Engine.get_meta("dpslove_bct") if Engine.has_meta("dpslove_bct") else null
	_check("mod_loaded", tracker != null)
	if tracker == null:
		_finish()
		return
	results["locale"] = TranslationServer.get_locale()
	results["mods"] = ModLoaderStore.mod_data.keys()

	_start_run()
	yield(get_tree().create_timer(2.0), "timeout")
	_check("battle_attached", tracker.is_live())

	yield(get_tree().create_timer(10.0), "timeout")
	yield(_shot("1-overlay-live"), "completed")
	if _env("BCT_TEST_PREVIEW", "") != "":
		yield(_make_preview(_env("BCT_TEST_PREVIEW", "")), "completed")

	var Model = load(MOD + "/core/model.gd")
	var enc = tracker.session.current
	var rows = Model.sorted_rows(enc, 0, 0, false) if enc != null else []
	_check("damage_recorded", rows.size() > 0, rows.size())
	var src_keys := []
	for s in rows:
		src_keys.append(s.src)
	results["sources_live"] = src_keys
	if rows.size() > 0:
		tracker.ui.detail.open(0, 0, rows[0].key, tracker.names.row_label(enc, 0, 0, rows[0]))
		yield(get_tree().create_timer(0.4), "timeout")
		yield(_shot("2-detail"), "completed")
		tracker.ui.detail.close()

	var panel = tracker.ui.main_panel
	panel.toggle()
	yield(get_tree().create_timer(0.6), "timeout")
	yield(_shot("3-main-damage"), "completed")
	# 没选中任何行时拆分看全队
	_check("breakdown_everyone", not panel._has_source and panel._brk_rows.size() > 0, panel._brk_rows.size())
	panel._view = 1
	panel.mark_dirty()
	yield(get_tree().create_timer(0.4), "timeout")
	yield(_shot("4-main-taken"), "completed")
	panel._view = 2
	panel.mark_dirty()
	yield(get_tree().create_timer(0.4), "timeout")
	yield(_shot("5-main-healing"), "completed")
	# 逐条事件：实时那段从内存里拿
	panel._view = 0
	panel._events_mode = true
	panel.mark_dirty()
	yield(get_tree().create_timer(0.6), "timeout")
	_check("events_live", panel._ev_shown.size() > 0, panel._ev_shown.size())
	yield(_shot("5b-main-events-live"), "completed")
	panel._events_mode = false
	panel._group = 0
	panel.toggle()

	yield(_verify_input(), "completed")
	yield(_verify_windows(), "completed")

	# 等收波
	var waited = 0.0
	while tracker.is_live() and waited < 60.0:
		yield(get_tree().create_timer(0.5), "timeout")
		waited += 0.5
	_check("wave_ended", not tracker.is_live(), waited)
	_perf()
	yield(get_tree().create_timer(1.0), "timeout")
	_check("overlay_hidden_after_wave", not tracker.ui.overlay.visible)
	# 收波后浮窗本该让开；下面几张图要看它，强制显示
	tracker.ui.force_overlay = true
	yield(get_tree().create_timer(0.3), "timeout")
	yield(_shot("6-overlay-ended"), "completed")

	_verify_log_roundtrip()
	_verify_csv()
	yield(_verify_event_page(), "completed")
	yield(_verify_ui_import(), "completed")
	yield(_simulate_teammate(), "completed")
	_finish()


# 热键、鼠标点击（走 Godot 真实的输入分发，验证点击落在我们的窗口上而不是游戏里）、暂停时钟
func _verify_input():
	var overlay = tracker.ui.overlay
	var panel = tracker.ui.main_panel
	var detail = tracker.ui.detail

	_key(KEY_F9)
	yield(get_tree().create_timer(0.2), "timeout")
	var hidden_ok = not overlay.visible
	_key(KEY_F9)
	yield(get_tree().create_timer(0.2), "timeout")
	_check("hotkey_overlay", hidden_ok and overlay.visible)

	_key(KEY_F8)
	yield(get_tree().create_timer(0.2), "timeout")
	var opened = panel.visible
	_key(KEY_F8)
	yield(get_tree().create_timer(0.2), "timeout")
	_check("hotkey_main_panel", opened and not panel.visible)

	# 视图按钮：点三下回到「输出」，中途应是「承伤」。浮窗宽度跟着卡片数变，按钮位置每次重取
	var seen := []
	for i in range(3):
		var view_rect = _hit_rect(overlay, "view")
		if view_rect == null:
			break
		_click(overlay, view_rect)
		yield(get_tree().create_timer(0.3), "timeout")
		seen.append(overlay.view)
	_check("click_view_button", seen == [1, 2, 0], seen)

	# 点第一张卡片打开明细，再点一次关掉。卡片按伤害排序、随时可能换位置，每次点之前按键重新找
	var card_key = null
	for h in overlay._hits:
		if h[1] == "card":
			card_key = h[2]
			break
	var card_ok = false
	var card_rect = _hit_rect_arg(overlay, "card", card_key) if card_key != null else null
	if card_rect != null:
		_click(overlay, card_rect)
		yield(get_tree().create_timer(0.25), "timeout")
		card_ok = detail.visible and typeof(detail._key) == typeof(card_key) and detail._key == card_key
		yield(_shot("2b-detail-clicked"), "completed")
		card_rect = _hit_rect_arg(overlay, "card", card_key)
		if card_rect != null:
			_click(overlay, card_rect)
		yield(get_tree().create_timer(0.25), "timeout")
		card_ok = card_ok and not detail.visible
	_check("click_card_detail", card_ok, str(card_key))

	# 拖动浮窗：按住标题栏挪 (80, 60)，位置写回配置；再拖回去
	var start = overlay.rect_position
	var grab = overlay.rect_global_position + Vector2(overlay.rect_size.x * 0.5 * overlay.rect_scale.x, 8)
	_drag(grab, grab + Vector2(80, 60))
	yield(get_tree().create_timer(0.3), "timeout")
	var moved = overlay.rect_position - start
	var saved = Vector2(float(tracker.config.value("OverlayX")), float(tracker.config.value("OverlayY")))
	_check("drag_overlay", moved.distance_to(Vector2(80, 60)) < 1.5 and saved.distance_to(overlay.rect_position) < 1.5, [moved, saved])
	_drag(grab + Vector2(80, 60), grab)
	yield(get_tree().create_timer(0.3), "timeout")

	# 游戏自己的暂停菜单铺满全屏：打开它，再在主面板上点「承伤」页签，点击要落到主面板上
	_key(KEY_ESCAPE)
	yield(get_tree().create_timer(0.6), "timeout")
	var game_paused = get_tree().paused
	_check("overlay_hidden_when_paused", game_paused and not overlay.visible)
	_key(KEY_F8)
	yield(get_tree().create_timer(0.4), "timeout")
	var tab = null
	for h in panel._hits:
		if h[1] == "view" and int(h[2]) == 1:
			tab = h[0]
	if tab != null:
		_click(panel, tab)
		yield(get_tree().create_timer(0.4), "timeout")
	_check("click_over_pause_menu", game_paused and panel._view == 1, [game_paused, panel._view])
	yield(_shot("11-pause-menu"), "completed")
	panel._view = 0
	_key(KEY_F8)
	yield(get_tree().create_timer(0.2), "timeout")
	_key(KEY_ESCAPE)
	yield(get_tree().create_timer(0.6), "timeout")

	# 暂停时波次时钟不走
	var enc = tracker.session.current
	var d0 = enc.duration if enc != null else 0.0
	get_tree().paused = true
	yield(get_tree().create_timer(1.0), "timeout")
	var d1 = enc.duration if enc != null else 0.0
	get_tree().paused = false
	_check("clock_pauses", enc != null and abs(d1 - d0) < 0.05, [d0, d1])

	# F10 手动重置：同一波切出新的一段
	var before = tracker.session.encounters.size()
	_key(KEY_F10)
	yield(get_tree().create_timer(0.3), "timeout")
	var after = tracker.session.encounters.size()
	var cur = tracker.session.current
	_check("hotkey_reset", after == before + 1 and cur != null and cur.part == 2, [before, after])


# 设置窗口、滑杆、热键录制、悬停提示、浮窗背景淡入淡出。都走 Godot 真实的输入分发
func _verify_windows():
	var overlay = tracker.ui.overlay
	var settings = tracker.ui.settings

	# 光标移到浮窗上：背景和按钮淡入；移开后淡出
	_move(overlay.get_global_transform().xform(overlay.rect_size * 0.5))
	yield(get_tree().create_timer(0.4), "timeout")
	var faded_in = overlay._fade
	yield(_shot("12-overlay-hover"), "completed")
	_move(Vector2(4, 4))
	yield(get_tree().create_timer(0.4), "timeout")
	_check("overlay_fade", faded_in > 0.99 and overlay._fade < 0.01, [faded_in, overlay._fade])

	# 悬停提示：停在战斗记录标题栏的齿轮上（浮窗的按钮随卡片数左右移，拿来测会时准时不准）
	var panel = tracker.ui.main_panel
	panel.toggle()
	yield(get_tree().create_timer(0.4), "timeout")
	var tip_ok = false
	var gear_rect = _hit_rect(panel, "settings")
	if gear_rect != null:
		_move(panel.get_global_transform().xform(gear_rect.position + gear_rect.size * 0.5))
		yield(get_tree().create_timer(0.8), "timeout")
		tip_ok = tracker.ui.tooltip.visible and tracker.ui.tooltip._text != ""
		yield(_shot("13-tooltip"), "completed")
	_check("tooltip", tip_ok, [str(panel._hover_key), tracker.ui.tooltip._text])
	_move(Vector2(4, 4))
	panel.toggle()
	yield(get_tree().create_timer(0.2), "timeout")

	# 浮窗上的齿轮打开设置
	var gear = _hit_rect(overlay, "settings")
	if gear != null:
		_click(overlay, gear)
	yield(get_tree().create_timer(0.4), "timeout")
	var opened = settings.visible
	yield(_shot("14-settings-display"), "completed")

	# 滑杆：把卡片斜切从 -30 拖到正中（0°），配置跟着变；再改回去
	var skew_before = float(tracker.config.value("SkewDegrees"))
	var skew_after = skew_before
	var track = settings._sliders.get("SkewDegrees")
	var hr = _hit_rect_arg(settings, "slider", "SkewDegrees")
	if track != null and hr != null:
		var y = hr.position.y + hr.size.y * 0.5
		var from = Vector2(track[0] + track[1] * (skew_before - track[2]) / (track[3] - track[2]), y)
		var to = Vector2(track[0] + track[1] * 0.5, y)
		var xf = settings.get_global_transform()
		_drag(xf.xform(from), xf.xform(to))
		yield(get_tree().create_timer(0.3), "timeout")
		skew_after = float(tracker.config.value("SkewDegrees"))
	_check("settings_slider", abs(skew_after) < 0.6, [skew_before, skew_after])
	tracker.config.put("SkewDegrees", skew_before)
	tracker.config.save()
	tracker.ui.mark_all_dirty()

	# 热键页：点「显示 / 隐藏浮窗」的按钮录新热键，按 F7；F7 就能开关浮窗了。最后改回 F9
	settings._page = 3
	settings.mark_dirty()
	yield(get_tree().create_timer(0.3), "timeout")
	var key_rect = _hit_rect_arg(settings, "key", "ToggleOverlay")
	if key_rect != null:
		_click(settings, key_rect)
	yield(get_tree().create_timer(0.2), "timeout")
	var capturing = tracker.ui.capturing == "ToggleOverlay"
	yield(_shot("15-settings-hotkeys"), "completed")
	_key(KEY_F7)
	yield(get_tree().create_timer(0.3), "timeout")
	var rebound = str(tracker.config.value("ToggleOverlay")) == "F7"
	var wanted = tracker.ui.overlay_wanted
	_key(KEY_F7)
	yield(get_tree().create_timer(0.2), "timeout")
	var toggled = tracker.ui.overlay_wanted != wanted
	_key(KEY_F7)
	yield(get_tree().create_timer(0.2), "timeout")
	tracker.config.put("ToggleOverlay", "F9")
	tracker.config.save()
	tracker.ui.reload_keys()
	_check("hotkey_capture", capturing and rebound and toggled, [capturing, rebound, toggled])
	settings._page = 0

	# 标题栏的 × 关掉
	var close_rect = _hit_rect(settings, "close")
	if close_rect != null:
		_click(settings, close_rect)
	yield(get_tree().create_timer(0.3), "timeout")
	_check("click_settings", opened and not settings.visible, [opened, settings.visible])


# 逐条事件：已经结束的段从本局日志里读，条数和这一段的命中次数一致
func _verify_event_page():
	var panel = tracker.ui.main_panel
	var s = tracker.session
	var enc = s.encounters[0] if s.encounters.size() > 0 else null
	if enc == null:
		_check("events_page", false, "no encounter")
		yield(get_tree(), "idle_frame")
		return
	if not panel.visible:
		panel.toggle()
	panel._sel = enc
	panel._view = 0
	panel._has_source = false
	panel._events_mode = true
	panel.mark_dirty()
	var waited = 0.0
	while waited < 10.0:
		yield(get_tree().create_timer(0.3), "timeout")
		waited += 0.3
		if panel._ev_page != null and panel._ev_thread == null and panel._ev_shown.size() > 0:
			break
	var hits = 0
	for st in enc.by_player[0].values():
		hits += st.hits
	_check("events_page", hits > 0 and panel._ev_shown.size() == hits, [panel._ev_shown.size(), hits, waited])
	yield(get_tree().create_timer(0.3), "timeout")
	yield(_shot("16-main-events-page"), "completed")
	# 表格里选中一行：逐条事件只剩它的，条数等于它的命中次数
	var Model = load(MOD + "/core/model.gd")
	var rows = Model.sorted_rows(enc, 0, 0, false)
	if rows.size() > 0:
		panel._has_source = true
		panel._source = rows[0].key
		panel.mark_dirty()
		yield(get_tree().create_timer(0.4), "timeout")
		_check("events_filter", panel._ev_shown.size() == rows[0].hits, [panel._ev_shown.size(), rows[0].hits, rows[0].src])
		yield(_shot("17-main-events-filtered"), "completed")
		# 曲线上的悬停读数
		panel._events_mode = false
		panel.mark_dirty()
		yield(get_tree().create_timer(0.4), "timeout")
		var cr = panel._chart_rect
		_move(panel.get_global_transform().xform(cr.position + cr.size * Vector2(0.6, 0.5)))
		yield(get_tree().create_timer(0.3), "timeout")
		_check("chart_hover", panel._chart_hover >= 0, panel._chart_hover)
		yield(_shot("18-main-chart-hover"), "completed")
		_move(Vector2(4, 4))
		panel._has_source = false
	panel._events_mode = false
	panel._sel = null
	panel.toggle()


func _move(pos: Vector2) -> void:
	var ev = InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	Input.parse_input_event(ev)


func _hit_rect_arg(window, action: String, arg):
	for h in window._hits:
		if h[1] == action and typeof(h[2]) == typeof(arg) and h[2] == arg:
			return h[0]
	return null


func _key(code: int) -> void:
	for pressed in [true, false]:
		var ev = InputEventKey.new()
		ev.scancode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)


func _drag(from: Vector2, to: Vector2) -> void:
	_mouse_button(from, true)
	for i in range(1, 5):
		var ev = InputEventMouseMotion.new()
		ev.position = from.linear_interpolate(to, i / 4.0)
		ev.global_position = ev.position
		ev.button_mask = BUTTON_MASK_LEFT
		Input.parse_input_event(ev)
	_mouse_button(to, false)


func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev = InputEventMouseButton.new()
	ev.button_index = BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	Input.parse_input_event(ev)


func _hit_rect(window, action: String):
	for h in window._hits:
		if h[1] == action:
			return h[0]
	return null


func _click(window, local_rect: Rect2) -> void:
	var local = local_rect.position + local_rect.size * 0.5
	var pos = window.get_global_transform().xform(local)
	for pressed in [true, false]:
		var ev = InputEventMouseButton.new()
		ev.button_index = BUTTON_LEFT
		ev.pressed = pressed
		ev.position = pos
		ev.global_position = pos
		Input.parse_input_event(ev)


# 走主面板的「导入」：后台线程解析本局日志，结果和实时统计同样多的段
func _verify_ui_import():
	var panel = tracker.ui.main_panel
	if not panel.visible:
		panel.toggle()
	panel._picker_open = true
	panel._refresh_files()
	panel.mark_dirty()
	yield(get_tree().create_timer(0.4), "timeout")
	yield(_shot("10a-main-picker"), "completed")
	var idx = -1
	for i in range(panel._files.size()):
		if panel._files[i].path == tracker.writer.path:
			idx = i
	panel._start_import(idx)
	var waited = 0.0
	while panel._importing and waited < 20.0:
		yield(get_tree().create_timer(0.2), "timeout")
		waited += 0.2
	var s = panel._imported
	_check("ui_import", s != null and s.encounters.size() == tracker.session.encounters.size(),
		[s.encounters.size() if s != null else null, tracker.session.encounters.size(), waited])
	yield(get_tree().create_timer(0.4), "timeout")
	yield(_shot("10-main-imported"), "completed")
	panel._on_action("live", null)
	panel.toggle()


func _start_run() -> void:
	var players = int(_env("BCT_TEST_PLAYERS", "1"))
	RunData.reset(false)
	if players > 1:
		# 本地合作：给每名玩家登记一个（不存在的）手柄，站桩不动
		CoopService.connected_players.clear()
		for i in range(players):
			CoopService._add_player(i, CoopService.PlayerType.GAMEPAD_XBOX)
		RunData.set_coop_run(true)
		RunData.play_mode = RunData.PlayMode.COOP
		RunData.set_player_count(players, true)
	var characters = ["character_well_rounded", "character_ranger", "character_brawler", "character_mage"]
	for p in range(players):
		RunData.add_character(_find(ItemService.characters, characters[p % characters.size()]), p)
		var first_weapon := true
		for id in _env("BCT_TEST_LOADOUT", DEFAULT_LOADOUT).split(",", false):
			if id.begins_with("weapon_"):
				var w = _find(ItemService.weapons, id)
				if w != null:
					RunData.add_weapon(w, p, first_weapon)
					first_weapon = false
				else:
					_note("找不到武器 " + id)
			else:
				var it = _find(ItemService.items, id)
				if it != null:
					RunData.add_item(it, p)
				else:
					_note("找不到物品 " + id)
	RunData.add_starting_items_and_weapons()
	results["players"] = players
	RunData.current_difficulty = 0
	RunData.reset_elites_spawn()
	RunData.init_elites_spawn()
	RunData.init_events_nightmare()
	RunData.init_bosses_spawn()
	RunData.current_run_accessibility_settings = ProgressData.settings.enemy_scaling.duplicate()
	# 站桩打一整波：血量加厚，能挨打（测承伤）但不会死
	for p in range(players):
		RunData.add_stat(Keys.stat_max_hp_hash, 400, p)
		RunData.add_stat(Keys.stat_hp_regeneration_hash, 8, p)
		RunData.add_stat(Keys.stat_lifesteal_hash, 10, p)
		RunData.add_stat(Keys.stat_dodge_hash, 20, p)
	RunData.current_wave = int(_env("BCT_TEST_WAVE", "3"))
	var err = get_tree().change_scene("res://main.tscn")
	_check("run_started", err == OK, err)


# 创意工坊预览图：真实的游戏画面压暗，上面摆浮窗和主面板、加标题，裁成正方形
func _make_preview(name: String):
	var overlay = tracker.ui.overlay
	var panel = tracker.ui.main_panel
	var old_cards = tracker.config.value("MaxCards")
	var old_scale = float(tracker.config.value("UiScale"))
	var old_overlay_pos = overlay.rect_position
	var old_panel_pos = panel.rect_position
	# 正方形里要放下浮窗和整个战斗记录窗口：界面缩小一点；浮窗亮出背景和按钮，表格里选中第一名
	tracker.config.put("MaxCards", 5)
	tracker.ui.set_ui_scale(0.9)
	overlay.force_frame = true
	overlay.mark_dirty()
	if not panel.visible:
		panel.toggle()
	var Model = load(MOD + "/core/model.gd")
	var top_rows = Model.sorted_rows(tracker.session.current, 0, 0, false)
	if top_rows.size() > 0:
		panel._has_source = true
		panel._source = top_rows[0].key
	yield(get_tree().create_timer(0.3), "timeout")
	var ow = overlay.rect_size.x * overlay.rect_scale.x
	var oh = overlay.rect_size.y * overlay.rect_scale.y
	var pw = panel.rect_size.x * panel.rect_scale.x
	overlay.rect_position = Vector2(round(960 - ow * 0.5), 176)
	panel.rect_position = Vector2(round(960 - pw * 0.5), round(176 + oh + 22))
	overlay.mark_dirty()
	panel.mark_dirty()

	var hud = get_tree().current_scene.get_node_or_null("UI/HUD")
	if hud != null:
		hud.visible = false
	var layer = CanvasLayer.new()
	layer.layer = 105
	var dim = ColorRect.new()
	dim.color = Color(0.03, 0.03, 0.05, 0.55)
	dim.rect_size = Vector2(1920, 1080)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(dim)
	var skin_script = load(MOD + "/ui/skin.gd")
	var skin = skin_script.new()
	var title = Label.new()
	title.text = "Brotato Combat Tracker"
	title.add_font_override("font", skin.make_font(64, 3))
	title.add_color_override("font_color", Color(1, 1, 1))
	title.align = Label.ALIGN_CENTER
	title.rect_position = Vector2(420, 34)
	title.rect_size = Vector2(1080, 80)
	layer.add_child(title)
	var sub = Label.new()
	sub.text = _env("BCT_TEST_PREVIEW_SUB", "伤害统计 · DPS Meter · 联机兼容")
	sub.add_font_override("font", skin.make_font(34, 2))
	sub.add_color_override("font_color", Color(0.85, 0.87, 0.92))
	sub.align = Label.ALIGN_CENTER
	sub.rect_position = Vector2(420, 112)
	sub.rect_size = Vector2(1080, 50)
	layer.add_child(sub)
	add_child(layer)

	yield(get_tree().create_timer(0.6), "timeout")
	yield(VisualServer, "frame_post_draw")
	var img = get_viewport().get_texture().get_data()
	img.flip_y()
	var sx = img.get_width() / 1920.0
	var square = img.get_rect(Rect2(420 * sx, 0, 1080 * sx, 1080 * sx))
	square.resize(900, 900, Image.INTERPOLATE_LANCZOS)
	square.save_png(OUT.plus_file(name + ".png"))

	layer.queue_free()
	if hud != null:
		hud.visible = true
	tracker.config.put("MaxCards", old_cards)
	tracker.ui.set_ui_scale(old_scale)
	overlay.force_frame = false
	overlay.rect_position = old_overlay_pos
	panel.rect_position = old_panel_pos
	panel._has_source = false
	panel.toggle()


func _find(list: Array, id: String):
	for r in list:
		if r != null and r.get("my_id") == id:
			return r
	return null


func _shot(name: String):
	yield(VisualServer, "frame_post_draw")
	var img = get_viewport().get_texture().get_data()
	img.flip_y()
	img.save_png(OUT.plus_file(name + ".png"))


# 日志按当前版本重新解析，逐段、逐视图、逐来源和实时统计比对
func _verify_log_roundtrip() -> void:
	if tracker.writer == null:
		_check("log_roundtrip", false, "no writer")
		return
	tracker.writer.flush()
	var Reader = load(MOD + "/core/log_reader.gd")
	var s = Reader.read(tracker.writer.path, 0)
	var live = tracker.session.encounters
	var mismatches := []
	if s.encounters.size() != live.size():
		mismatches.append("encounters %d vs %d" % [s.encounters.size(), live.size()])
	for i in range(min(s.encounters.size(), live.size())):
		var a = live[i]
		var b = s.encounters[i]
		for v in range(3):
			for group in range(2):
				var ba = a.bucket(v, group)
				var bb = b.bucket(v, group)
				if ba.size() != bb.size():
					mismatches.append("enc %d view %d group %d rows %d vs %d" % [i, v, group, ba.size(), bb.size()])
				for key in ba.keys():
					var x = ba[key]
					var y = bb.get(key)
					if y == null:
						mismatches.append("enc %d view %d missing %s" % [i, v, str(key)])
						continue
					if abs(x.total - y.total) > 0.01 or abs(x.eff - y.eff) > 0.01 or x.hits != y.hits or x.crits != y.crits or abs(x.max_hit - y.max_hit) > 0.01:
						mismatches.append("enc %d view %d %s: %s/%s/%d vs %s/%s/%d" % [i, v, str(key), x.total, x.eff, x.hits, y.total, y.eff, y.hits])
		if abs(a.duration - b.duration) > 0.05:
			mismatches.append("enc %d duration %.3f vs %.3f" % [i, a.duration, b.duration])
	_check("log_roundtrip", mismatches.empty(), mismatches.slice(0, 20) if mismatches.size() > 0 else s.event_count)
	var enc = live.back() if live.size() > 0 else null
	if enc != null:
		var totals = {}
		for v in range(3):
			totals[str(v)] = [enc.total(v, false), enc.total(v, true)]
		results["last_wave_totals"] = totals
		results["last_wave_duration"] = enc.duration
		var per_src = {}
		for st in enc.by_source[0].values():
			per_src[st.src] = [st.eff, st.total, st.hits, st.crits, st.dims.keys()]
		results["last_wave_sources"] = per_src
		var heal = {}
		for st in enc.by_source[2].values():
			heal[st.src] = st.eff
		results["last_wave_heal"] = heal
		var taken = {}
		for st in enc.by_source[1].values():
			taken[st.src] = [st.eff, st.hits, st.crits]
		results["last_wave_taken"] = taken


# 开销：伤害回调每次多少微秒、每秒多少次；各窗口每次重绘多少微秒
func _perf() -> void:
	var enc = tracker.session.encounters.back() if tracker.session.encounters.size() > 0 else null
	var dur = enc.duration if enc != null else 1.0
	var calls = tracker.cost_calls
	var perf = {
		"hook_calls": calls,
		"hook_calls_per_s": calls / max(dur, 0.01),
		"hook_usec_avg": float(tracker.cost_usec) / max(calls, 1),
		"hook_ms_per_s": tracker.cost_usec / 1000.0 / max(dur, 0.01),
	}
	for w in [tracker.ui.overlay, tracker.ui.detail, tracker.ui.main_panel, tracker.ui.settings]:
		perf[w.name + "_draw_usec_avg"] = float(w.draw_usec) / max(w.draw_calls, 1)
		perf[w.name + "_draws"] = w.draw_calls
	perf["fps_now"] = Engine.get_frames_per_second()
	results["perf"] = perf


func _verify_csv() -> void:
	var enc = tracker.session.encounters.back() if tracker.session.encounters.size() > 0 else null
	var path = tracker.export_csv(enc, "test")
	var ok = path != "" and File.new().file_exists(path)
	_check("csv_export", ok, ProjectSettings.globalize_path(path) if ok else path)


# 把玩家 1 的快照当成联机队友的数据喂回去：验证快照往返和多人界面
func _simulate_teammate():
	var Parser = load(MOD + "/core/parser.gd")
	var enc = tracker.session.encounters.back() if tracker.session.encounters.size() > 0 else null
	if enc == null:
		_check("teammate_snapshot", false, "no encounter")
		yield(get_tree(), "idle_frame")
		return
	# 本地合作时真人玩家占了前几个位子，假队友排在后面
	var mate = int(results.get("players", 1))
	var snap = Parser.export_snapshot(enc, 0)
	var wire = JSON.parse(to_json(snap)).result
	tracker._on_snapshot_received(mate, wire, enc.wave)
	var a = enc.by_player[0].get(0)
	var b = enc.by_player[0].get(mate)
	var ok = a != null and b != null and abs(a.eff - b.eff) < 0.01 and a.hits == b.hits
	_check("teammate_snapshot", ok, [a.eff if a != null else null, b.eff if b != null else null])
	results["snapshot_bytes"] = to_json(snap).length()
	tracker.ui.overlay.group = 1
	tracker.ui.overlay.mark_dirty()
	yield(get_tree().create_timer(0.4), "timeout")
	yield(_shot("7-overlay-coop-players"), "completed")
	tracker.ui.overlay.group = 0
	tracker.ui.overlay.mark_dirty()
	yield(get_tree().create_timer(0.4), "timeout")
	yield(_shot("8-overlay-coop-sources"), "completed")
	tracker.ui.main_panel.toggle()
	tracker.ui.main_panel._group = 1
	tracker.ui.main_panel.mark_dirty()
	yield(get_tree().create_timer(0.6), "timeout")
	yield(_shot("9-main-coop"), "completed")


func _finish() -> void:
	results["finished_unix"] = OS.get_unix_time()
	var f = File.new()
	if f.open(OUT.plus_file("results.json"), File.WRITE) == OK:
		f.store_string(JSON.print(results, "  "))
		f.close()
	yield(get_tree().create_timer(0.5), "timeout")
	get_tree().quit()
