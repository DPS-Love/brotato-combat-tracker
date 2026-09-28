extends Control

# 三个窗口（浮窗、明细窗口、战斗记录主面板）的公共部分：
# 整窗自绘，绘制时顺手登记点击区；悬停高亮、拖动、缩放、限制在屏幕内、点一下置顶。
#
# 不用 Button 这类内置控件：它们会抢键盘 / 手柄焦点，和游戏自己的焦点导航打架；
# 自绘 + 点击区也和 TBH Combat Tracker 的 IMGUI 写法一一对应，版式好对照。
#
# 鼠标事件不走 Godot 的界面分发（mouse_filter 为 IGNORE）：由 ui_root 在 _input 里先截下来，
# 落在哪个窗口上就交给哪个窗口（pointer_*），并标记为已处理。原因见 ui_root.gd。

const DRAG_THRESHOLD = 5.0

var root = null            # ui_root
var skin = null
var tracker = null
var refresh_interval := 0.1
var drag_anywhere := true  # 浮窗整窗可拖；主面板只在标题栏拖（面板里到处是可点的行）
var drag_band := 28.0      # drag_anywhere 为假时，顶部这么高的一条可拖
var pos_keys := ["", ""]   # 位置写回配置用的键
# 自测用：累计绘制耗时（微秒）与次数、收到的鼠标事件数
var draw_usec := 0
var draw_calls := 0
var gui_events := 0

var _hits := []            # [矩形, 动作, 参数, 按住拖动时是否让给拖窗口]
var _mouse := Vector2(-10000, -10000)
var _hover := -1
var _pressing := false
var _press_hit := -1
var _press_global := Vector2()
var _press_rect_pos := Vector2()
var _can_drag := false
var _dragging := false
var _refresh_in := 0.0
var _dirty := true


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	focus_mode = FOCUS_NONE
	if pos_keys[0] != "" and tracker != null:
		rect_position = Vector2(float(tracker.config.value(pos_keys[0])), float(tracker.config.value(pos_keys[1])))
	apply_scale()


func apply_scale() -> void:
	var s = 1.0
	if tracker != null:
		s = clamp(float(tracker.config.value("UiScale")), 0.5, 2.5)
	rect_scale = Vector2(s, s)


func mark_dirty() -> void:
	_dirty = true


func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_in -= delta
	if _refresh_in <= 0.0 or _dirty:
		_refresh_in = refresh_interval
		_dirty = false
		_layout()
		_clamp()
		update()


func _draw() -> void:
	var t0 = OS.get_ticks_usec()
	_hits.clear()
	_paint()
	draw_usec += OS.get_ticks_usec() - t0
	draw_calls += 1


# ---- 子类实现 ----

func _layout() -> void:
	pass


func _paint() -> void:
	pass


func _on_action(_action: String, _arg) -> void:
	pass


func _on_wheel(_pos: Vector2, _dir: int) -> void:
	pass


# ---- 绘制时登记点击区；返回鼠标是否悬停在上面 ----

func hit(r: Rect2, action: String, arg = null, drag_through := false) -> bool:
	_hits.append([r, action, arg, drag_through])
	return r.has_point(_mouse)


func hovering(r: Rect2) -> bool:
	return r.has_point(_mouse)


func mouse_pos() -> Vector2:
	return _mouse


func _hit_at(pos: Vector2) -> int:
	# 后登记的画在上面，倒着找
	for i in range(_hits.size() - 1, -1, -1):
		if _hits[i][0].has_point(pos):
			return i
	return -1


# ---- 鼠标（由 ui_root 分发） ----

# 画面坐标是否落在窗口上。get_global_rect() 不算 rect_scale，自己乘
func contains_screen_point(p: Vector2) -> bool:
	return visible and Rect2(rect_global_position, rect_size * rect_scale).has_point(p)


func to_local_point(p: Vector2) -> Vector2:
	return get_global_transform().affine_inverse().xform(p)


func is_pressing() -> bool:
	return _pressing


func pointer_motion(screen: Vector2) -> void:
	gui_events += 1
	_mouse = to_local_point(screen)
	if _pressing and _can_drag:
		if not _dragging and (screen - _press_global).length() > DRAG_THRESHOLD:
			_dragging = true
		if _dragging:
			rect_position = _press_rect_pos + (screen - _press_global)
			_clamp()
	var h = _hit_at(_mouse)
	if h != _hover:
		_hover = h
		update()


func pointer_button(screen: Vector2, pressed: bool) -> void:
	gui_events += 1
	var local = to_local_point(screen)
	_mouse = local
	if pressed:
		_raise()
		_pressing = true
		_dragging = false
		_press_global = screen
		_press_rect_pos = rect_position
		_press_hit = _hit_at(local)
		if _press_hit >= 0:
			_can_drag = _hits[_press_hit][3]
		else:
			_can_drag = drag_anywhere or local.y <= drag_band
		return
	if _dragging:
		_save_position()
	elif _press_hit >= 0 and _press_hit < _hits.size() and _hit_at(local) == _press_hit:
		var h = _hits[_press_hit]
		_on_action(h[1], h[2])
		mark_dirty()
	_pressing = false
	_dragging = false
	_press_hit = -1


func pointer_wheel(screen: Vector2, dir: int) -> void:
	gui_events += 1
	_on_wheel(to_local_point(screen), dir)
	update()


func pointer_exit() -> void:
	_mouse = Vector2(-10000, -10000)
	if _hover != -1:
		_hover = -1
		update()


func _raise() -> void:
	var parent = get_parent()
	if parent != null and get_index() != parent.get_child_count() - 1:
		parent.move_child(self, parent.get_child_count() - 1)


# 别拖到够不着的地方去：至少留 60 像素在屏幕里，标题栏不出上沿
func _clamp() -> void:
	var view = get_viewport_rect().size
	var w = rect_size.x * rect_scale.x
	rect_position.x = clamp(rect_position.x, 60.0 - w, max(0.0, view.x - 60.0))
	rect_position.y = clamp(rect_position.y, 0.0, max(0.0, view.y - 30.0))


func _save_position() -> void:
	if pos_keys[0] == "" or tracker == null:
		return
	tracker.config.put(pos_keys[0], stepify(rect_position.x, 1.0))
	tracker.config.put(pos_keys[1], stepify(rect_position.y, 1.0))
