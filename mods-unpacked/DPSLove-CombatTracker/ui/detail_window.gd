extends "window_base.gd"

# 点浮窗卡片弹出的拆分窗口：一个来源（或一名玩家）在当前段里的构成，环形图 + 图例。
#
# 维度随浮窗当前的视图和分组变化：
#   输出 · 来源  → 形式（直接 / 燃烧 / 爆炸 / 效果）、目标、暴击
#   输出 · 玩家  → 来源、类别（近战 / 远程 / 元素 / 工程…）、目标
#   承伤 · 来源  → 结果（命中 / 闪避 / 抵挡）
#   承伤 · 玩家  → 来源、结果
#   治疗 · 玩家  → 来源
# 跟着浮窗显示的那一段走：刚切段、这个来源还没出手时显示空状态，不自动关——几秒后数据就回来了。
# 图例一屏 7 行，多的用滚轮翻；图例行和环上的一段互相高亮。

const Model = preload("../core/model.gd")
const Strings = preload("../core/strings.gd")
const Fmt = preload("../core/fmt.gd")
const Scroll = preload("scroll.gd")
const Donut = preload("donut.gd")

const W = 372.0
const H = 214.0
const PAD = 12.0
const DONUT = 118.0
const LEGEND_ROW = 16.0
const LEGEND_ROWS = 7
const TAB_W = 56.0

var _view := 0
var _group := 0
var _key = null
var _name := ""
var _dim := ""

var _scroll = Scroll.new(LEGEND_ROW)
var _donut = Donut.new(LEGEND_ROWS)
var _rows := []           # [[项, 行], …]
var _sum := 0.0
var _mi := 1
var _legend_w := 0.0
var _legend_rect := Rect2()
var _highlight := -1
var _list_key := ""


func _init() -> void:
	pos_keys = ["DetailX", "DetailY"]
	drag_anywhere = false
	drag_band = 32.0
	refresh_interval = 0.25
	visible = false


func _ready() -> void:
	add_pane("legend")


# 打开某个来源；再点一次同一张卡片就关掉，符合直觉
func toggle(view: int, group: int, key, name: String) -> void:
	if visible and _view == view and _group == group and _same(_key, key):
		close()
		return
	open(view, group, key, name)


func open(view: int, group: int, key, name: String) -> void:
	_view = view
	_group = group
	_key = key
	_name = name
	var dims = Model.dims_for(view, group)
	_dim = dims[0] if dims.size() > 0 else ""
	visible = true
	_raise()
	mark_dirty()
	root.overlay.mark_dirty()   # 浮窗上被选中的名字变色


func close() -> void:
	visible = false
	root.overlay.mark_dirty()


# 浮窗在这个视图、分组下哪张卡片的拆分开着（没有就是 null）
func open_key(view: int, group: int):
	if visible and _view == view and _group == group:
		return _key
	return null


func _tick(delta: float) -> bool:
	return _scroll.tick(delta)


func _layout() -> void:
	rect_size = Vector2(W, H)


func _paint() -> void:
	var enc = root.overlay.current_encounter()
	var names = tracker.names
	var stats = enc.bucket(_view, _group).get(_key) if enc != null else null
	if stats != null:
		_name = names.row_label(enc, _view, _group, stats)

	var op = opacity()
	skin.window_frame(self, Rect2(Vector2.ZERO, rect_size), skin.with_alpha(skin.WINDOW_BG, op), 1.0, op * 1.6)
	# 内容区垫一层半透明的黑：窗口背景调得很透明时，环形图和图例还有衬底
	skin.box(self, Rect2(6, skin.TITLE_H, W - 12.0, H - skin.TITLE_H - 6.0), skin.PANEL, 6.0)

	# ---- 标题栏：颜色点 + 名字 · 视图 + 关闭 ----
	var th = skin.TITLE_H
	var color = names.row_color(_view, _group, stats) if stats != null else skin.TEXT_FAINT
	skin.box(self, Rect2(PAD, th * 0.5 - 4.0, 8, 8), color, 4.0)
	skin.text(self, Rect2(PAD + 14.0, 0, W - PAD - 14.0 - 40.0, th), Strings.detail_title(_name, Strings.view_label(_view)),
		skin.FONT_BODY, skin.TEXT, 0, true)
	button(Rect2(W - 34.0, 4, 26, 24), "close", "", skin.GHOST, "close", null, Strings.tip_close())

	# ---- 第二行：当前段 + 维度 ----
	var y = th + 2.0
	var dims = Model.dims_for(_view, _group)
	if not dims.has(_dim):
		_dim = dims[0] if dims.size() > 0 else ""
	var tabs_w = 0.0
	if dims.size() > 0:
		var labels := []
		for d in dims:
			labels.append(Strings.tab_label(d))
		tabs_w = segmented(W - PAD - dims.size() * TAB_W - 4.0, y, TAB_W, 24.0, labels, dims.find(_dim), "dim")
	skin.text(self, Rect2(PAD, y, W - PAD * 2.0 - tabs_w - 6.0, 24.0), names.encounter_title(enc), skin.FONT_SMALL, skin.TEXT_DIM)

	var top = y + 32.0
	var lx = PAD + DONUT + 14.0
	# 图例右边留 8 给滚动条（在内容底板里面）
	var lw = W - lx - PAD - 8.0
	_legend_w = lw
	if stats == null:
		skin.text(self, Rect2(PAD, top, W - PAD * 2.0, 20.0), Strings.no_data_in_segment(), skin.FONT_SMALL, skin.TEXT_DIM)
		_rows = []
		_donut.hide()
		return

	var ov = tracker.overkill
	_mi = Model.ROW_TOTAL if ov else Model.ROW_EFF
	_rows = Model.sorted_dim(stats, _dim, ov) if _dim != "" else []
	var values := []
	_sum = 0.0
	for r in _rows:
		var v = float(r[1][_mi])
		values.append(v)
		_sum += v

	# 图例行和环上的一段互相高亮：指着哪边都行。先定环，图例的色点跟着它分单独成段 / 「其他」
	var hover_row = _hovered_row()
	_highlight = hover_row if hover_row >= 0 and hover_row < _rows.size() else _donut.hovered
	var value = stats.metric(ov)
	var donut_rect = Rect2(PAD, top, DONUT, DONUT)
	hit(donut_rect, "donut", null, HIT_PASSIVE)
	_donut.paint(self, skin, donut_rect, values, Fmt.short(value), Fmt.short(Fmt.per_sec(value, enc.duration)) + "/s", _highlight)
	if _rows.empty():
		skin.text(self, Rect2(lx, top, lw, 20.0), Strings.no_breakdown(), skin.FONT_SMALL, skin.TEXT_DIM)

	# 一屏 LEGEND_ROWS 行，多的用滚轮翻；换了段 / 来源 / 视图 / 维度就回到顶上
	var key = "%d|%s|%d|%d|%s" % [enc.index, str(_key), _view, _group, _dim]
	var view_h = min(_rows.size(), LEGEND_ROWS) * LEGEND_ROW
	_scroll.setup(_rows.size(), view_h)
	if key != _list_key:
		_list_key = key
		_scroll.to_top()
	_legend_rect = Rect2(lx - 4.0, top + 2.0, lw + 14.0, view_h)
	pane("legend", _legend_rect)
	var first = _scroll.first()
	for slot in range(_scroll.visible_rows()):
		var i = first + slot
		if i >= _rows.size():
			break
		var r = Rect2(_legend_rect.position.x, _legend_rect.position.y + i * LEGEND_ROW - _scroll.offset, lw + 4.0, LEGEND_ROW).clip(_legend_rect)
		if r.size.y > 0.0:
			hit(r, "legend", i, HIT_PASSIVE)
	var thumb = _scroll.thumb()
	if thumb.size() == 2:
		hit(Rect2(_legend_rect.end.x - 10.0, _legend_rect.position.y + thumb[0], 10.0, thumb[1]), "thumb", null, HIT_DRAG)
	if _rows.size() > LEGEND_ROWS:
		var rng = _scroll.visible_range()
		skin.text(self, Rect2(lx + 12.0, top + 2.0 + LEGEND_ROWS * LEGEND_ROW, lw - 12.0, LEGEND_ROW),
			"%d–%d / %d" % [rng[0], rng[1], _rows.size()], skin.FONT_TINY, skin.TEXT_FAINT)


# 光标指着的图例行（-1 = 没有）
func _hovered_row() -> int:
	if _hover_key != null and _hover_key[0] == "legend":
		return int(_hover_key[1])
	return -1


func _paint_pane(id: String, ci: CanvasItem) -> void:
	if id != "legend":
		return
	var lw = _legend_w
	var names = tracker.names
	var other_hot = _highlight == Donut.OTHER
	var first = _scroll.first()
	for slot in range(_scroll.visible_rows()):
		var i = first + slot
		if i >= _rows.size():
			break
		var y = i * LEGEND_ROW - _scroll.offset
		var row = _rows[i]
		if i == _highlight or (other_hot and i >= _donut.folded):
			skin.box(ci, Rect2(0, y, lw + 6.0, LEGEND_ROW), skin.HOVER, 4.0)
		var dot = skin.palette(i) if i < _donut.folded else skin.OTHER_SLICE
		skin.box(ci, Rect2(4, y + LEGEND_ROW * 0.5 - 3.5, 7, 7), dot, 3.5)
		var v = float(row[1][_mi])
		skin.text(ci, Rect2(16, y, lw - 12.0 - 96.0, LEGEND_ROW), names.dim_label(_view, _dim, row[0]), skin.FONT_SMALL, skin.TEXT)
		skin.text(ci, Rect2(4.0 + lw - 96.0, y, 50, LEGEND_ROW), Fmt.short(v), skin.FONT_SMALL, skin.TEXT, 2)
		skin.text(ci, Rect2(4.0 + lw - 44.0, y, 44, LEGEND_ROW), Fmt.pct(v / _sum if _sum > 0.0 else 0.0), skin.FONT_TINY, skin.TEXT_DIM, 2)
	var thumb = _scroll.thumb()
	if thumb.size() == 2:
		var wide = hot("thumb") or pressed_on("thumb")
		var tw = 6.0 if wide else 4.0
		skin.box(ci, Rect2(ci.rect_size.x - tw - 1.0, thumb[0], tw, thumb[1]), Color(1, 1, 1, 0.32 if wide else 0.16), 2.0)


func _pointer_moved(local: Vector2) -> void:
	if _donut.update_hover(local):
		update()


func _on_wheel(local: Vector2, dir: int) -> bool:
	if _legend_rect.has_point(local):
		_scroll.scroll_by(dir * 3.0 * LEGEND_ROW)
		return true
	return false


func _on_drag(action: String, _arg, _local: Vector2, delta: Vector2) -> void:
	if action == "thumb":
		_scroll.drag_thumb(delta.y)


func _on_action(action: String, arg) -> void:
	match action:
		"dim":
			var dims = Model.dims_for(_view, _group)
			if int(arg) >= 0 and int(arg) < dims.size():
				_dim = dims[int(arg)]
		"close":
			close()
