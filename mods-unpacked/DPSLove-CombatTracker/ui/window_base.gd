extends Control

# 四个窗口（浮窗、拆分窗口、战斗记录、设置）的公共部分：
# 整窗自绘，绘制时顺手登记点击区；悬停高亮、悬停提示、拖动、滑杆 / 滚动条拖动、滚轮、
# 限制在屏幕内、点一下置顶。窗口整体按 skin.scale 缩放，里面的坐标一律是 TBH 的界面单位。
#
# 不用 Button 这类内置控件：它们会抢键盘 / 手柄焦点，和游戏自己的焦点导航打架。
# 鼠标事件也不走 Godot 的界面分发（mouse_filter 为 IGNORE）：由 ui_root 在 _input 里先截下来，
# 落在哪个窗口上就交给哪个窗口（pointer_*）。原因见 ui_root.gd。

const ClipPane = preload("clip_pane.gd")

# 点击区的标志位
const HIT_DRAG_WINDOW = 1   # 按住拖动时拖整个窗口（浮窗的卡片、底板）
const HIT_DRAG = 2          # 自己处理拖动（滑杆、滚动条）：_on_press / _on_drag / _on_release
const HIT_PASSIVE = 4       # 只响应悬停，不响应点击（拆分表的行、禁用的按钮）

const DRAG_THRESHOLD = 4.0
const TIP_DELAY_MS = 450

var root = null            # ui_root
var skin = null
var tracker = null
var refresh_interval := 0.25
var drag_anywhere := false  # 整窗可拖（浮窗）；否则只有顶部 drag_band 这么高的标题栏可拖
var drag_band := 32.0
var pos_keys := ["", ""]    # 位置写回配置用的键
# 自测用：累计绘制耗时（微秒）与次数、收到的鼠标事件数
var draw_usec := 0
var draw_calls := 0
var gui_events := 0

var _hits := []             # [矩形, 动作, 参数, 标志, 提示]
var _mouse := Vector2(-100000, -100000)
var _hover_key = null       # 光标下最上面那块点击区：[动作, 参数, 提示]
var _hover_since := 0
var _pressing := false
var _press_key = null
var _press_flags := 0
var _press_global := Vector2()
var _press_rect_pos := Vector2()
var _last_local := Vector2()
var _drag_mode := 0         # 0 未拖动，1 拖窗口，2 交给窗口自己
var _refresh_in := 0.0
var _dirty := true
var _panes := {}
var _pane_used := {}


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	focus_mode = FOCUS_NONE
	if pos_keys[0] != "" and tracker != null:
		rect_position = Vector2(float(tracker.config.value(pos_keys[0])), float(tracker.config.value(pos_keys[1])))
	apply_scale()


func apply_scale() -> void:
	var s = skin.scale if skin != null else 1.0
	rect_scale = Vector2(s, s)
	_clamp()
	mark_dirty()


func mark_dirty() -> void:
	_dirty = true


func _process(delta: float) -> void:
	if not visible:
		return
	var redraw = _tick(delta)
	_refresh_in -= delta
	if _dirty or (refresh_interval > 0.0 and _refresh_in <= 0.0):
		_refresh_in = refresh_interval
		_dirty = false
		_layout()
		_clamp()
		redraw = true
	if redraw:
		update()


func _draw() -> void:
	var t0 = OS.get_ticks_usec()
	_hits.clear()
	for id in _panes.keys():
		_pane_used[id] = false
	_paint()
	for id in _panes.keys():
		if not _pane_used[id] and _panes[id].visible:
			_panes[id].visible = false
	_rehover()
	draw_usec += OS.get_ticks_usec() - t0
	draw_calls += 1


# ---- 子类实现 ----

# 每帧：动画（淡入淡出、滚动）。要重画时返回真
func _tick(_delta: float) -> bool:
	return false


func _layout() -> void:
	pass


func _paint() -> void:
	pass


func _paint_pane(_id: String, _ci: CanvasItem) -> void:
	pass


func _on_action(_action: String, _arg) -> void:
	pass


func _on_press(_action: String, _arg, _local: Vector2) -> void:
	pass


func _on_drag(_action: String, _arg, _local: Vector2, _delta: Vector2) -> void:
	pass


func _on_release(_action: String, _arg, _local: Vector2) -> void:
	pass


# 滚轮：处理了返回真
func _on_wheel(_local: Vector2, _dir: int) -> bool:
	return false


# 光标在窗口上移动（环形图、曲线的悬停）
func _pointer_moved(_local: Vector2) -> void:
	pass


# ---- 子画布（会滚动的列表、曲线）----

func add_pane(id: String, clip: bool = true) -> void:
	var p = ClipPane.new()
	p.host = self
	p.pane_id = id
	p.name = "Pane_" + id
	p.rect_clip_content = clip
	p.visible = false
	add_child(p)
	_panes[id] = p
	_pane_used[id] = false


# 这一帧用到这块子画布：摆好位置；redraw 为假时内容不变就不重画
func pane(id: String, r: Rect2, redraw: bool = true):
	var p = _panes[id]
	_pane_used[id] = true
	if p.rect_position != r.position:
		p.rect_position = r.position
	if p.rect_size != r.size:
		p.rect_size = r.size
		redraw = true
	if not p.visible:
		p.visible = true
		redraw = true
	if redraw:
		p.update()
	return p


# ---- 绘制时登记点击区；返回光标是否正停在它上面（且它在最上面）----

func hit(r: Rect2, action: String, arg = null, flags: int = 0, tip: String = "") -> bool:
	_hits.append([r, action, arg, flags, tip])
	return hot(action, arg)


func hot(action: String, arg = null) -> bool:
	return _hover_key != null and _hover_key[0] == action and _same(_hover_key[1], arg)


func pressed_on(action: String, arg = null) -> bool:
	return _pressing and _press_key != null and _press_key[0] == action and _same(_press_key[1], arg)


static func _same(a, b) -> bool:
	return typeof(a) == typeof(b) and a == b


func mouse_pos() -> Vector2:
	return _mouse


func _hit_at(pos: Vector2) -> int:
	# 后登记的画在上面，倒着找
	for i in range(_hits.size() - 1, -1, -1):
		if _hits[i][0].has_point(pos):
			return i
	return -1


func _key_at(pos: Vector2):
	var i = _hit_at(pos)
	if i < 0:
		return null
	var h = _hits[i]
	return [h[1], h[2], h[4]]


func _set_hover(k) -> bool:
	var same = (k == null and _hover_key == null) or (k != null and _hover_key != null and k[0] == _hover_key[0] and _same(k[1], _hover_key[1]))
	if same:
		if k != null:
			_hover_key[2] = k[2]
		return false
	_hover_key = k
	_hover_since = OS.get_ticks_msec()
	return true


# 画完之后按新的点击区重新定悬停项：布局变了（列表滚了、行换了），悬停的也跟着换
func _rehover() -> void:
	if _set_hover(_key_at(_mouse)):
		call_deferred("update")


# 光标在同一块上停够一会儿，它的提示
func tip_now() -> String:
	if _pressing or _hover_key == null or str(_hover_key[2]) == "":
		return ""
	if OS.get_ticks_msec() - _hover_since < TIP_DELAY_MS:
		return ""
	return str(_hover_key[2])


# ---- 常用控件：画出来、登记点击区 ----

func button(r: Rect2, icon_name: String, label: String, style: int, action: String, arg = null,
		tip: String = "", on: bool = false, enabled: bool = true, alpha: float = 1.0) -> void:
	var hv = hit(r, action, arg, 0 if enabled else HIT_PASSIVE, tip)
	skin.button(self, r, icon_name, label, style, hv and enabled, pressed_on(action, arg) and enabled, on, enabled, alpha)


# 分段选择：每段等宽，返回总宽度；点击的参数是段的序号
func segmented(x: float, y: float, seg_w: float, h: float, labels: Array, selected: int, action: String) -> float:
	var n = labels.size()
	var total = seg_w * n + 4.0
	skin.box(self, Rect2(x, y, total, h), Color(1, 1, 1, 0.05), skin.RADIUS_CONTROL)
	for i in range(n):
		var r = Rect2(x + 2.0 + i * seg_w, y + 2.0, seg_w, h - 4.0)
		var hv = hit(r, action, i)
		skin.button(self, r, "", str(labels[i]), skin.TAB, hv, pressed_on(action, i), i == selected)
	return total


# ---- 鼠标（由 ui_root 分发）----

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
	if _pressing:
		if _drag_mode == 0 and (_press_flags & HIT_DRAG_WINDOW) != 0 and (screen - _press_global).length() > DRAG_THRESHOLD:
			_drag_mode = 1
		if _drag_mode == 1:
			rect_position = (_press_rect_pos + (screen - _press_global)).round()
			_clamp()
			_mouse = to_local_point(screen)
		elif _drag_mode == 2 and _press_key != null:
			_on_drag(_press_key[0], _press_key[1], _mouse, _mouse - _last_local)
			update()
	_last_local = _mouse
	if _set_hover(_key_at(_mouse)):
		update()
	_pointer_moved(_mouse)


func pointer_button(screen: Vector2, pressed: bool) -> void:
	gui_events += 1
	var local = to_local_point(screen)
	_mouse = local
	_last_local = local
	if pressed:
		_raise()
		_pressing = true
		_drag_mode = 0
		_press_global = screen
		_press_rect_pos = rect_position
		var i = _hit_at(local)
		if i >= 0:
			var h = _hits[i]
			_press_key = [h[1], h[2]]
			_press_flags = h[3]
			if (h[3] & HIT_DRAG) != 0:
				_drag_mode = 2
				_on_press(h[1], h[2], local)
		else:
			_press_key = null
			_press_flags = HIT_DRAG_WINDOW if (drag_anywhere or local.y <= drag_band) else 0
		update()
		return
	var key = _press_key
	var flags = _press_flags
	var mode = _drag_mode
	_pressing = false
	_drag_mode = 0
	_press_key = null
	if mode == 1:
		_save_position()
	elif mode == 2 and key != null:
		_on_release(key[0], key[1], local)
	elif key != null and (flags & HIT_PASSIVE) == 0:
		var now = _key_at(local)
		if now != null and now[0] == key[0] and _same(now[1], key[1]):
			_on_action(key[0], key[1])
	mark_dirty()


func pointer_wheel(screen: Vector2, dir: int) -> void:
	gui_events += 1
	if _on_wheel(to_local_point(screen), dir):
		update()


func pointer_exit() -> void:
	_mouse = Vector2(-100000, -100000)
	if _set_hover(null):
		update()
	_pointer_moved(_mouse)


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


# 窗口背景的不透明度（设置里的「窗口背景」，拖滑杆时是预览值）
func opacity() -> float:
	return root.opacity() if root != null else 0.9
