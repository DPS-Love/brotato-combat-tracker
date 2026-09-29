extends Reference

# 配置文件：user://CombatTracker/config.cfg
# （Windows 上是 %APPDATA%\Brotato\CombatTracker\config.cfg）
#
# 第一次启动时生成，每项都带中英说明。游戏里的设置界面改动立即生效并写回这里；
# 直接改文件要重启游戏。窗口位置由窗口自己写回。
# 缺项自动补上默认值，认不出来的值按默认值处理，不会因为改坏了一项就整个失效。

const ENTRIES = [
	# [节, 键, 默认值, 中文说明, English]
	["Hotkeys", "ToggleOverlay", "F9", "显示 / 隐藏浮窗；留空为不用热键", "Show / hide the overlay; empty for no hotkey"],
	["Hotkeys", "ToggleMainPanel", "F8", "打开 / 关闭战斗记录", "Open / close the combat log window"],
	["Hotkeys", "Reset", "F10", "重置当前统计（旧的一段收进战斗记录）", "Reset the current encounter (the old one moves to the combat log)"],
	["Hotkeys", "ExportCsv", "F11", "把当前这一段导出成 CSV", "Export the current encounter as a CSV"],

	["Display", "ShowOverlay", true, "启动时显示浮窗", "Show the overlay at startup"],
	["Display", "ShowInShop", false,
		"商店里也显示浮窗（显示刚打完的那一波）；默认不显示，免得挡住物品说明",
		"Also show the overlay in the shop (it shows the wave just finished); off by default so it doesn't cover item descriptions"],
	["Display", "UiScale", 1.0, "界面缩放（0.5 – 2.5）", "UI scale (0.5 – 2.5)"],
	["Display", "SkewDegrees", -30.0, "卡片斜切角度，0 为普通矩形", "Skew angle of the cards; 0 for plain rectangles"],
	["Display", "BackgroundOpacity", 0.9,
		"浮窗、拆分窗口和战斗记录背景的不透明度（0 – 1）；浮窗只在鼠标移上去时显示背景和按钮",
		"Background opacity of the overlay, breakdown and combat log windows (0 – 1); the overlay shows its background and buttons only while the cursor is on it"],
	["Display", "MaxCards", 5, "浮窗最多显示几张卡片（1 – 12），其余计入标题栏的「+n」", "Max cards on the overlay (1 – 12); the rest are counted as +n in the title bar"],
	["Display", "ShowIcons", true, "卡片上显示武器 / 物品图标", "Show weapon / item icons on the cards"],
	["Display", "OverlayX", 12.0, "浮窗位置（拖动后自动保存）", "Overlay position (saved when dragged)"],
	["Display", "OverlayY", 200.0, "", ""],
	["Display", "MainPanelX", 440.0, "战斗记录窗口位置", "Combat log window position"],
	["Display", "MainPanelY", 150.0, "", ""],
	["Display", "DetailX", 12.0, "拆分窗口位置", "Breakdown window position"],
	["Display", "DetailY", 470.0, "", ""],
	["Display", "SettingsX", 560.0, "设置窗口位置", "Settings window position"],
	["Display", "SettingsY", 240.0, "", ""],

	["Stats", "CountOverkill", false,
		"伤害计入溢出（打死怪时超出剩余血量的部分）。默认不计，与游戏里武器伤害统计的口径一致",
		"Count overkill (damage beyond the target's remaining HP). Off by default, matching the game's own weapon damage counters"],
	["Stats", "IncludeTrees", false, "统计对树木的伤害", "Count damage dealt to trees"],
	["Stats", "HistorySize", 200, "战斗记录里本局保留多少段，更早的仍在日志里；0 为不限", "How many encounters the combat log window keeps (older ones stay in the log file); 0 for no limit"],

	["Log", "LogEvents", true, "写战斗日志；关掉的话战斗记录只有本局的数据，结束的段也看不了逐条事件", "Write combat logs; when off, the combat log window only has this session and ended encounters have no event list"],
	["Log", "LogRetentionDays", 30, "战斗日志保留天数，0 为永久保留", "Days to keep combat logs; 0 keeps them forever"],

	["Online", "ShareStats", true,
		"联机（BrotatoOnline）时与装了本 Mod 的队友互传各自的统计；关掉则只看得到自己",
		"In BrotatoOnline co-op, exchange stats with teammates who also run this mod; when off you only see yourself"],

	["Colors", "Player1", "", "玩家颜色（#RGB / #RRGGBB），留空用游戏里的玩家颜色", "Player colours (#RGB / #RRGGBB); empty uses the game's player colours"],
	["Colors", "Player2", "", "", ""],
	["Colors", "Player3", "", "", ""],
	["Colors", "Player4", "", "", ""],
]

var path := ""
var _cf := ConfigFile.new()
var _index := {}     # 键 -> 条目
var _dirty := false


func _init() -> void:
	for e in ENTRIES:
		_index[e[1]] = e


func load_or_create(p: String) -> void:
	path = p
	var err = _cf.load(p)
	var missing: bool = err != OK
	for e in ENTRIES:
		if not _cf.has_section_key(e[0], e[1]):
			_cf.set_value(e[0], e[1], e[2])
			missing = true
	if missing:
		save()


func value(key: String):
	var e = _index.get(key)
	if e == null:
		return null
	var def = e[2]
	var v = _cf.get_value(e[0], key, def)
	match typeof(def):
		TYPE_BOOL:
			if typeof(v) == TYPE_BOOL:
				return v
			if typeof(v) == TYPE_STRING:
				return v.to_lower() in ["true", "1", "yes", "on"]
			if typeof(v) == TYPE_INT or typeof(v) == TYPE_REAL:
				return v != 0
			return def
		TYPE_INT:
			if typeof(v) == TYPE_INT or typeof(v) == TYPE_REAL:
				return int(v)
			if typeof(v) == TYPE_STRING and v.is_valid_integer():
				return int(v)
			return def
		TYPE_REAL:
			if typeof(v) == TYPE_INT or typeof(v) == TYPE_REAL:
				return float(v)
			if typeof(v) == TYPE_STRING and v.is_valid_float():
				return float(v)
			return def
		_:
			return str(v)


func put(key: String, v) -> void:
	var e = _index.get(key)
	if e == null:
		return
	_cf.set_value(e[0], key, v)
	_dirty = true


# 拖动面板时会连续改位置，攒一下再写
func save_if_dirty() -> void:
	if _dirty:
		save()


func save() -> void:
	_dirty = false
	if path == "":
		return
	var d = Directory.new()
	var dir = path.get_base_dir()
	if not d.dir_exists(dir):
		d.make_dir_recursive(dir)
	var lines := PoolStringArray()
	lines.append("; Brotato Combat Tracker")
	lines.append("; 游戏里的设置界面改动立即生效；直接改这个文件要重启游戏")
	lines.append("; Changes made in the in-game settings apply at once; restart the game after editing this file")
	var section := ""
	for e in ENTRIES:
		if e[0] != section:
			section = e[0]
			lines.append("")
			lines.append("[" + section + "]")
		if e[3] != "":
			lines.append("")
			lines.append("; " + e[3])
			lines.append("; " + e[4])
		lines.append(e[1] + "=" + var2str(_cf.get_value(e[0], e[1], e[2])))
	var f = File.new()
	if f.open(path, File.WRITE) == OK:
		f.store_string(lines.join("\n") + "\n")
		f.close()


# 解析 #RGB / #RRGGBB / #RRGGBBAA；不合法返回 null。
# 自己解析而不用 Color("#…")：Godot 3 把 8 位的当成 #AARRGGBB，和这里的写法相反。
static func parse_color(hex: String):
	var s = hex.strip_edges()
	if s.begins_with("#"):
		s = s.substr(1)
	if s.length() == 3:
		s = s[0] + s[0] + s[1] + s[1] + s[2] + s[2]
	if s.length() != 6 and s.length() != 8:
		return null
	var bytes := []
	for i in range(0, s.length(), 2):
		var hi = _hex_digit(s[i])
		var lo = _hex_digit(s[i + 1])
		if hi < 0 or lo < 0:
			return null
		bytes.append(hi * 16 + lo)
	var a = bytes[3] if bytes.size() == 4 else 255
	return Color(bytes[0] / 255.0, bytes[1] / 255.0, bytes[2] / 255.0, a / 255.0)


static func _hex_digit(c: String) -> int:
	var i = "0123456789abcdef".find(c.to_lower())
	return i
