extends "window_base.gd"

# 设置窗口：配置文件里给玩家用的那些项都能在这里改，改完立刻写回 config.cfg。
# 能立刻生效的立刻生效（缩放、斜切、背景、卡片数、图标、商店、溢出、树木、保留段数、联机、热键、颜色）；
# 战斗日志只在启动时打开，那两项标着「重启后生效」。窗口位置之类由窗口自己写，不放进来。

const Strings = preload("../core/strings.gd")
const Config = preload("../core/config.gd")

const W = 600.0
const H = 456.0
const RAIL_X = 10.0
const RAIL_W = 138.0
const TAB_H = 32.0
const CX = 162.0              # RAIL_X + RAIL_W + 14
const CW = 422.0              # W - CX - 16
# 一行：标题（右边放开关 / 滑杆）+ 最多两行的说明，说明占满整行宽度
const ROW_H = 56.0
const SLIDER_W = 130.0
const TOGGLE_W = 34.0

const PRESETS = [
	"#C0392B", "#E74C3C", "#E07B39", "#F0D98C", "#F2C94C", "#5FB04A",
	"#2AA8A0", "#4FA3E3", "#3F6FD8", "#8E5BD0", "#D1548C", "#9E9E9E",
]
const HOTKEYS = ["ToggleOverlay", "ToggleMainPanel", "Reset", "ExportCsv"]

var _page := 0
var _drag := {}          # 正在拖的滑杆 -> 实时值
var _sliders := {}       # 滑杆 -> [轨道 x, 宽, 最小, 最大, 步长]


func _init() -> void:
	pos_keys = ["SettingsX", "SettingsY"]
	drag_anywhere = false
	drag_band = 32.0
	refresh_interval = 0.0
	visible = false


func open() -> void:
	visible = true
	_raise()
	mark_dirty()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible and root != null:
		if root.capturing != "":
			root.capturing = ""
		_set_preview(-1.0)


func _layout() -> void:
	rect_size = Vector2(W, H)


static func _top(index: int) -> float:
	return 32.0 + 12.0 + index * ROW_H


# 一页上的行：[类型, 配置项, 标题, 说明, 重启后生效, 最小, 最大, 步长]
func _rows(page: int) -> Array:
	match page:
		0:
			return [
				["slider", "UiScale", Strings.set_ui_scale(), Strings.set_ui_scale_desc(), false, 0.5, 2.5, 0.05],
				["slider", "SkewDegrees", Strings.set_skew(), Strings.set_skew_desc(), false, -45.0, 45.0, 1.0],
				["slider", "BackgroundOpacity", Strings.set_bg(), Strings.set_bg_desc(), false, 0.0, 100.0, 5.0],
				["slider", "MaxRows", Strings.set_max_rows(), Strings.set_max_rows_desc(), false, 1.0, 12.0, 1.0],
				["toggle", "ShowIcons", Strings.set_icons(), Strings.set_icons_desc(), false],
				["toggle", "ShowInShop", Strings.set_shop(), Strings.set_shop_desc(), false],
			]
		1:
			return [
				["toggle", "CountOverkill", Strings.set_overkill(), Strings.set_overkill_desc(), false],
				["toggle", "IncludeTrees", Strings.set_trees(), Strings.set_trees_desc(), false],
				["slider", "HistorySize", Strings.set_history(), Strings.set_history_desc(), false, 0.0, 500.0, 10.0],
				["toggle", "ShareStats", Strings.set_share(), Strings.set_share_desc(), false],
			]
		2:
			return [
				["toggle", "LogEvents", Strings.set_log_events(), Strings.set_log_events_desc(), true],
				["slider", "LogRetentionDays", Strings.set_retention(), Strings.set_retention_desc(), true, 0.0, 180.0, 5.0],
			]
	return []


# 配置值 → 滑杆上的数（背景不透明度存的是 0–1，滑杆上是百分数）
func _slider_value(key: String) -> float:
	var v = float(tracker.config.value(key))
	return v * 100.0 if key == "BackgroundOpacity" else v


func _format(key: String, v: float) -> String:
	match key:
		"UiScale":
			return "%.2f×" % v
		"SkewDegrees":
			return "%d°" % int(round(v))
		"BackgroundOpacity":
			return "%d%%" % int(round(v))
		"HistorySize":
			return Strings.segments(int(round(v)))
		"LogRetentionDays":
			return Strings.days(int(round(v)))
	return str(int(round(v)))


func _paint() -> void:
	var th = skin.TITLE_H
	skin.window_frame(self, Rect2(Vector2.ZERO, rect_size), skin.WINDOW_BG)
	skin.icon(self, "settings", Vector2(21, th * 0.5), 15.0, skin.ACCENT)
	skin.text(self, Rect2(36, 0, 300, th), Strings.settings_title(), skin.FONT_TITLE, skin.TEXT, 0, true)
	button(Rect2(W - 36.0, 4, 28, 24), "close", "", skin.GHOST, "close", null, Strings.tip_close())
	skin.text(self, Rect2(CX, H - 26.0, CW, 18), Strings.settings_footer(_config_path()), skin.FONT_TINY, skin.TEXT_FAINT)
	skin.box(self, Rect2(RAIL_X + RAIL_W + 6.0, th + 8.0, 1, H - th - 20.0), skin.DIVIDER)

	var tabs = [[Strings.tab_display(), "sliders"], [Strings.tab_tracking(), "chart"], [Strings.tab_logs(), "document"],
		[Strings.tab_hotkeys(), "keyboard"], [Strings.tab_colors(), "color"]]
	for i in range(tabs.size()):
		button(Rect2(RAIL_X, th + 8.0 + i * (TAB_H + 4.0), RAIL_W, TAB_H), tabs[i][1], tabs[i][0], skin.TAB, "page", i, "", i == _page)

	_sliders.clear()
	match _page:
		3:
			_hotkeys()
		4:
			_colors()
		_:
			_setting_rows()

	# 拖着 / 指着「窗口背景」滑杆时，各窗口（浮窗也亮出背景）按滑杆上的值画，松手才写进配置
	if _drag.has("BackgroundOpacity"):
		_set_preview(float(_drag["BackgroundOpacity"]) / 100.0)
	elif hot("slider", "BackgroundOpacity"):
		_set_preview(_slider_value("BackgroundOpacity") / 100.0)
	else:
		_set_preview(-1.0)


func _setting_rows() -> void:
	var cfg = tracker.config
	var rows = _rows(_page)
	for i in range(rows.size()):
		var row = rows[i]
		var y = _top(i)
		var title_w = skin.text(self, Rect2(CX, y, 240, 22), row[2], skin.FONT_BODY, skin.TEXT)
		if row[4]:
			var tag = Strings.restart_tag()
			var tw = ceil(skin.text_width(tag, 9)) + 12.0
			var tr_ = Rect2(CX + min(200.0, ceil(title_w)) + 8.0, y + 4.0, tw, 15)
			skin.box(self, tr_, skin.with_alpha(skin.WARNING, 0.18), 7.0)
			skin.text(self, tr_, tag, 9, Color("ffe8b34b"), 1)
		# 控件都放在标题那一行的右边，说明占满整行，放不下就折成两行
		skin.text_wrap(self, Rect2(CX, y + 22.0, CW, 30), row[3], skin.FONT_TINY, skin.TEXT_DIM, 2, 15.0)
		var key = row[1]
		if row[0] == "toggle":
			var pos = Vector2(CX + CW - TOGGLE_W, y + 2.0)
			var hv = hit(Rect2(pos.x - 4.0, pos.y - 4.0, TOGGLE_W + 8.0, 26), "toggle", key)
			skin.toggle(self, pos, bool(cfg.value(key)), hv)
		else:
			var sx = CX + CW - 196.0
			var lo = float(row[5])
			var hi = float(row[6])
			var v = float(_drag[key]) if _drag.has(key) else _slider_value(key)
			_sliders[key] = [sx, SLIDER_W, lo, hi, float(row[7])]
			var hv = hit(Rect2(sx - 8.0, y + 1.0, SLIDER_W + 16.0, 20), "slider", key, HIT_DRAG)
			skin.slider(self, sx, y + 2.0, SLIDER_W, (v - lo) / (hi - lo), hv or _drag.has(key), _format(key, v))
	if _page == 2:
		var label = Strings.btn_open_log_folder()
		var bw = skin.button_width("folder", label, 12.0)
		button(Rect2(CX, _top(rows.size()) + 8.0, bw, 28), "folder", label, skin.SUBTLE, "folder")


func _hotkeys() -> void:
	var names = [Strings.key_toggle(), Strings.key_main(), Strings.key_reset(), Strings.key_export()]
	for i in range(HOTKEYS.size()):
		var action = HOTKEYS[i]
		var y = _top(i)
		skin.text(self, Rect2(CX, y, CW - 150.0, 34), names[i], skin.FONT_BODY, skin.TEXT)
		var capturing = root.capturing == action
		var current = root.key_label(action)
		var label = Strings.key_press() if capturing else (current if current != "" else Strings.key_none())
		button(Rect2(CX + CW - 140.0, y + 3.0, 140, 28), "keyboard", label, skin.SUBTLE, "key", action, "", capturing)
	skin.text(self, Rect2(CX, _top(HOTKEYS.size()) + 4.0, CW, 18), Strings.key_hint(), skin.FONT_TINY, skin.TEXT_DIM)


func _colors() -> void:
	var th = skin.TITLE_H
	skin.text(self, Rect2(CX, th + 10.0, CW, 18), Strings.colors_hint(), skin.FONT_TINY, skin.TEXT_DIM)
	for p in range(4):
		var y = th + 34.0 + p * 36.0
		skin.text(self, Rect2(CX, y, 96, 26), Strings.player_name(p), skin.FONT_BODY, skin.TEXT)
		skin.box(self, Rect2(CX + 98.0, y + 3.0, 20, 20), tracker.names.player_color(p), 4.0)
		var hex = _normalize(str(tracker.config.value("Player%d" % (p + 1))))
		for k in range(PRESETS.size()):
			var r = Rect2(CX + 128.0 + k * 22.0, y + 3.0, 20, 20)
			var arg = "%d|%s" % [p, PRESETS[k]]
			var hv = hit(r, "color", arg, 0, PRESETS[k])
			skin.swatch(self, r, Config.parse_color(PRESETS[k]), hex == PRESETS[k], hv)
		button(Rect2(CX + CW - 26.0, y + 1.0, 26, 24), "refresh", "", skin.GHOST, "color_reset", p, Strings.tip_reset_color())


static func _normalize(hex: String) -> String:
	var s = hex.strip_edges().to_upper()
	if s == "":
		return ""
	if not s.begins_with("#"):
		s = "#" + s
	if s.length() == 9:
		s = s.substr(0, 7)   # 忽略透明度
	return s


func _config_path() -> String:
	if OS.get_name() == "Windows":
		return "%APPDATA%\\Brotato\\CombatTracker\\config.cfg"
	return tracker.config.path


func _set_preview(v: float) -> void:
	if root == null or abs(root.preview_opacity - v) < 0.0001:
		return
	root.preview_opacity = v
	root.overlay.mark_dirty()
	root.detail.mark_dirty()
	root.main_panel.mark_dirty()


# ---- 滑杆：按下跳到按下的位置，拖动只预览，松手才提交——界面缩放要是边拖边生效，滑杆会从光标底下跑掉 ----

func _value_at(key: String, local_x: float) -> float:
	var s = _sliders.get(key)
	if s == null:
		return _slider_value(key)
	var t = clamp((local_x - s[0]) / s[1], 0.0, 1.0) if s[1] > 0.0 else 0.0
	var v = s[2] + (s[3] - s[2]) * t
	if s[4] > 0.0:
		v = s[2] + round((v - s[2]) / s[4]) * s[4]
	return clamp(v, s[2], s[3])


func _on_press(action: String, arg, local: Vector2) -> void:
	if action == "slider":
		_drag[str(arg)] = _value_at(str(arg), local.x)


func _on_drag(action: String, arg, local: Vector2, _delta: Vector2) -> void:
	if action == "slider":
		_drag[str(arg)] = _value_at(str(arg), local.x)


func _on_release(action: String, arg, _local: Vector2) -> void:
	if action != "slider":
		return
	var key = str(arg)
	if not _drag.has(key):
		return
	var v = float(_drag[key])
	_drag.erase(key)
	match key:
		"BackgroundOpacity":
			_commit(key, v / 100.0)
		"UiScale", "SkewDegrees":
			_commit(key, v)
		_:
			_commit(key, int(round(v)))


func _commit(key: String, v) -> void:
	if key == "UiScale":
		root.set_ui_scale(float(v))
	else:
		tracker.config.put(key, v)
	tracker.config.save()
	tracker.apply_config()
	root.mark_all_dirty()
	mark_dirty()


func _on_action(action: String, arg) -> void:
	match action:
		"close":
			visible = false
		"page":
			_page = int(arg)
			if root.capturing != "":
				root.cancel_capture()
		"toggle":
			_commit(str(arg), not bool(tracker.config.value(str(arg))))
		"folder":
			root.main_panel.open_log_folder()
		"key":
			if root.capturing == str(arg):
				root.cancel_capture()
			else:
				root.begin_capture(str(arg))
		"color":
			var parts = str(arg).split("|")
			if parts.size() == 2:
				_commit("Player%d" % (int(parts[0]) + 1), parts[1])
		"color_reset":
			_commit("Player%d" % (int(arg) + 1), "")
