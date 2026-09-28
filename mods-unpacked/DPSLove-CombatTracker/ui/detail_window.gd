extends "window_base.gd"

# 点击浮窗卡片后弹出的明细窗口：一张环形图 + 图例，按维度切换。
#
# 维度随浮窗当前的视图和分组变化：
#   输出 · 来源  → 形式（直接 / 燃烧 / 爆炸 / 效果）、目标、暴击
#   输出 · 玩家  → 来源、类别（近战 / 远程 / 元素 / 工程…）、目标
#   承伤 · 来源  → 结果（命中 / 闪避 / 抵挡）
#   承伤 · 玩家  → 来源、结果
#   治疗 · 玩家  → 来源
# 跟着浮窗显示的那一段走；这一段里还没有它的数据时显示空状态，不自动关窗。

const Model = preload("../core/model.gd")
const Strings = preload("../core/strings.gd")
const Fmt = preload("../core/fmt.gd")

const W = 450.0
const PAD = 12.0
const TITLE_H = 24.0
const TAB_H = 22.0
const TAB_W = 76.0
const PIE = 152.0
const ROW_H = 19.0
const LEGEND_ROWS = 7

var _view := 0
var _group := 0
var _key = null
var _name := ""
var _dim := ""


func _init() -> void:
	pos_keys = ["DetailX", "DetailY"]
	drag_anywhere = true
	visible = false


func open(view: int, group: int, key, name: String) -> void:
	# 再点一次同一张卡片就关掉，符合直觉
	if visible and _view == view and _group == group and _key == key:
		close()
		return
	_view = view
	_group = group
	_key = key
	_name = name
	var dims = Model.dims_for(view, group)
	_dim = dims[0] if dims.size() > 0 else ""
	visible = true
	_raise()
	mark_dirty()


func close() -> void:
	visible = false


func _layout() -> void:
	rect_size = Vector2(W, TITLE_H + TAB_H + 8.0 + PIE + PAD)


func _paint() -> void:
	var enc = root.overlay.current_encounter()
	var stats = null
	if enc != null:
		stats = enc.bucket(_view, _group).get(_key)
	var names = tracker.names

	skin.fill(self, Rect2(Vector2.ZERO, rect_size), skin.WINDOW_BG)
	skin.frame(self, Rect2(Vector2.ZERO, rect_size), skin.WINDOW_BORDER)
	var title = Strings.detail_title(_name, Strings.view_label(_view), names.encounter_title(enc))
	skin.text(self, skin.o_title, Rect2(PAD, 2, W - PAD * 2.0 - 26.0, TITLE_H - 2.0), title, skin.TITLE, 1)

	var top = TITLE_H
	# ---- 维度切换 ----
	var dims = Model.dims_for(_view, _group)
	for i in range(dims.size()):
		var r = Rect2(PAD + i * (TAB_W + 4.0), top, TAB_W, TAB_H)
		skin.tab(self, skin.o_small, r, Strings.tab_label(dims[i]), dims[i] == _dim, hit(r, "dim", dims[i]))
	var r_close = Rect2(W - PAD - 24.0, top, 24.0, TAB_H)
	skin.button(self, skin.o_small, r_close, "×", hit(r_close, "close"))
	top += TAB_H + 8.0

	if stats == null:
		skin.text(self, skin.o_sub, Rect2(PAD, top, W - PAD * 2.0, ROW_H), Strings.no_data_in_segment(), skin.TEXT)
		return

	var rows = Model.sorted_dim(stats, _dim, tracker.overkill) if _dim != "" else []
	var metric_index = Model.ROW_TOTAL if tracker.overkill else Model.ROW_EFF
	var sum := 0.0
	for row in rows:
		sum += float(row[1][metric_index])

	# ---- 环形图：前 8 项各一色，其余并成一块灰 ----
	var slices := []
	var rest := 0.0
	for i in range(rows.size()):
		var v = float(rows[i][1][metric_index])
		if i < 8:
			slices.append([v, skin.palette(i)])
		else:
			rest += v
	if rest > 0.0:
		slices.append([rest, skin.palette(8)])
	var center = Vector2(PAD + PIE * 0.5, top + PIE * 0.5)
	skin.donut(self, center, PIE * 0.5 - 1.0, PIE * 0.5 * 0.42, slices)

	# 环心放总计和每秒
	var value = stats.metric(tracker.overkill)
	skin.text(self, skin.o_center, Rect2(PAD, center.y - 20.0, PIE, 22.0), Fmt.short(value), skin.TEXT, 1)
	skin.text(self, skin.o_sub, Rect2(PAD, center.y + 1.0, PIE, 18.0),
		Fmt.short(Fmt.per_sec(value, enc.duration)) + "/s", skin.TEXT, 1)

	# ---- 图例 ----
	var lx = PAD + PIE + 12.0
	var lw = W - lx - PAD
	var ly = top
	if rows.empty():
		skin.text(self, skin.o_sub, Rect2(lx, ly, lw, ROW_H), Strings.no_breakdown(), skin.TEXT)
		return
	var shown = int(min(rows.size(), LEGEND_ROWS))
	for i in range(shown):
		var item = rows[i][0]
		var v = float(rows[i][1][metric_index])
		var share = v / sum if sum > 0.0 else 0.0
		skin.fill(self, Rect2(lx, ly + 5.0, 9.0, 9.0), skin.palette(i))
		var right = Fmt.short(v) + "  " + Fmt.pct(share)
		var rw = skin.text_width(skin.o_small, right) + 4.0
		skin.text(self, skin.o_sub, Rect2(lx + 14.0, ly, lw - 14.0 - rw, ROW_H),
			tracker.names.dim_label(_view, _dim, item), skin.TEXT)
		skin.text(self, skin.o_small, Rect2(lx, ly, lw, ROW_H), right, skin.TEXT, 2)
		ly += ROW_H
	if rows.size() > shown:
		skin.text(self, skin.o_small, Rect2(lx + 14.0, ly, lw - 14.0, ROW_H), Strings.more_items(rows.size() - shown), skin.DIM)


func _on_action(action: String, arg) -> void:
	match action:
		"dim":
			_dim = str(arg)
		"close":
			close()
