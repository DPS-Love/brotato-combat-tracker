extends CanvasLayer

# 界面根节点：一个压在游戏界面之上的 CanvasLayer，下面挂浮窗、明细窗口、战斗记录主面板；
# 处理热键；游戏暂停时照常响应（暂停时正好翻记录）。
#
# 浮窗只在波次进行中出现（配置打开时商店里也显示刚打完的那一波），菜单里不挡路。
# F9 是玩家自己的开关，两者同时满足才显示。

const UiSkin = preload("skin.gd")
const Overlay = preload("overlay.gd")
const DetailWindow = preload("detail_window.gd")
const MainPanel = preload("main_panel.gd")

const LAYER = 110

var tracker = null
var skin = null
var overlay = null
var detail = null
var main_panel = null

var overlay_wanted := true
var force_overlay := false   # 自测截图用：不看场合，一直显示
var _keys := {}
var _cursor_forced := false


func _ready() -> void:
	layer = LAYER
	pause_mode = PAUSE_MODE_PROCESS
	skin = UiSkin.new()
	overlay_wanted = bool(tracker.config.value("ShowOverlay"))

	overlay = _window(Overlay.new(), "Overlay")
	detail = _window(DetailWindow.new(), "Detail")
	main_panel = _window(MainPanel.new(), "MainPanel")

	for action in ["ToggleOverlay", "ToggleMainPanel", "Reset", "ExportCsv"]:
		var code = OS.find_scancode_from_string(str(tracker.config.value(action)))
		if code == 0:
			code = OS.find_scancode_from_string(_default_key(action))
		_keys[action] = code


func _window(w, name: String):
	w.name = name
	w.root = self
	w.skin = skin
	w.tracker = tracker
	add_child(w)
	return w


static func _default_key(action: String) -> String:
	match action:
		"ToggleOverlay":
			return "F9"
		"ToggleMainPanel":
			return "F8"
		"Reset":
			return "F10"
		_:
			return "F11"


func _process(_delta: float) -> void:
	var want = overlay_wanted and (force_overlay or _overlay_context())
	if overlay.visible != want:
		overlay.visible = want
		overlay.mark_dirty()
	if not want and detail.visible:
		detail.close()
	_update_cursor()


# 波次进行中、游戏没暂停时显示；配置打开时商店里也显示（有刚打完的那一波可看）。
# 暂停菜单、收波后的升级选择都铺在同一片地方，浮窗会盖住并吃掉那里的点击，这时让开；
# 要看记录按 F8，主面板哪里都能开
func _overlay_context() -> bool:
	if tracker.is_live():
		return not get_tree().paused
	var scene = get_tree().current_scene
	if scene == null:
		return false
	var f = str(scene.filename)
	return f.find("shop") >= 0 and bool(tracker.config.value("ShowInShop")) and tracker.session.encounters.size() > 0


# 游戏在战斗里会把鼠标藏起来（手柄 / 键盘操作、多人时一直藏）。主面板开着时把鼠标放出来，
# 关掉后交还给游戏——游戏每帧都会按自己的规则重新设置，不用我们恢复
func _update_cursor() -> void:
	if main_panel.visible:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_HIDDEN:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			_cursor_forced = true
	elif _cursor_forced:
		_cursor_forced = false


# 鼠标：自己分发，不走 Godot 的界面分发。
#   - 界面分发按节点在树里的先后找控件，不看 CanvasLayer 层级，会先落到游戏场景铺满全屏的容器上
#   - 多人时游戏的手柄焦点模拟器（FocusEmulator）在 _input 里把鼠标事件全部标记为已处理，界面根本收不到
# 这个节点排在根节点最后，_input 最先轮到它：落在我们窗口上的点击、滚轮在这里交给窗口并吃掉，
# 其余原样放行，游戏什么也感觉不到。按住拖动期间事件一直交给按下的那个窗口。
var _captured = null
var _hovered = null


func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_route_mouse(event)
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var code = event.scancode
	if code == _keys.get("ToggleOverlay"):
		overlay_wanted = not overlay_wanted
	elif code == _keys.get("ToggleMainPanel"):
		main_panel.toggle()
	elif code == _keys.get("Reset"):
		tracker.reset_current()
	elif code == _keys.get("ExportCsv"):
		var enc = overlay.current_encounter()
		var path = tracker.export_csv(enc, "live")
		if path != "":
			ModLoaderLog.info("已导出 " + ProjectSettings.globalize_path(path), "DPSLove-CombatTracker")
		overlay.flash(path.get_file() if path != "" else "")
	else:
		return
	get_tree().set_input_as_handled()


func _window_at(p: Vector2):
	# 后面的子节点画在上面，倒着找
	for i in range(get_child_count() - 1, -1, -1):
		var w = get_child(i)
		if w.has_method("contains_screen_point") and w.contains_screen_point(p):
			return w
	return null


func _route_mouse(event: InputEventMouse) -> void:
	var p = event.position
	var target = _captured
	if target == null or not is_instance_valid(target) or not target.visible:
		_captured = null
		target = _window_at(p)
	if _hovered != null and _hovered != target and is_instance_valid(_hovered):
		_hovered.pointer_exit()
	_hovered = target
	if target == null:
		return
	if event is InputEventMouseMotion:
		target.pointer_motion(p)
		# 移动照样给游戏（鼠标瞄准时光标划过浮窗不能卡住准星），只有按住拖窗口时才吃掉
		if _captured != null:
			get_tree().set_input_as_handled()
		return
	elif event is InputEventMouseButton:
		if event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN:
			if event.pressed:
				target.pointer_wheel(p, -1 if event.button_index == BUTTON_WHEEL_UP else 1)
		elif event.button_index == BUTTON_LEFT:
			target.pointer_button(p, event.pressed)
			_captured = target if event.pressed else null
	get_tree().set_input_as_handled()
