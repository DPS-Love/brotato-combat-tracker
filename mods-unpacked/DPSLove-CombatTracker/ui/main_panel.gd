extends "window_base.gd"

# 战斗记录主面板，形制参考 ACT 的主窗口（与 TBH Combat Tracker 一致）：
# 左边是分段（波次）列表，右边是选中那段的战斗员表格、每秒数值曲线、选中那一行的拆分表和饼图。
#
# 数据源是一个会话：本局的实时会话，或者从日志导入、按当前版本重新解析出来的会话。
# 两者走同一个解析器，界面完全一样。导入在后台线程里解析，不卡游戏。

const Model = preload("../core/model.gd")
const Strings = preload("../core/strings.gd")
const Fmt = preload("../core/fmt.gd")
const LogReader = preload("../core/log_reader.gd")

const W = 1040.0
const H = 660.0
const PAD = 12.0
const TITLE_H = 24.0
const TOOLBAR_Y = 28.0
const TOOLBAR_H = 24.0
const BODY_Y = 60.0
const LIST_W = 300.0
const ROW_H = 22.0
const RIGHT_X = 324.0          # PAD + LIST_W + 12
const RIGHT_W = 704.0          # W - RIGHT_X - PAD
const TABLE_ROW_H = 20.0
const MIN_TABLE_ROWS = 3
const MAX_TABLE_ROWS = 7
const MIN_CHART_H = 80.0
const BREAK_ROW_H = 19.0
const BREAK_ROWS = 8
const PIE = 152.0
const BREAKDOWN_H = 218.0      # 页签 28 + 表头 + 8 行 + 「另有 n 项」
const SMOOTH = 5

# ---- 数据源 ----
var _imported = null           # null = 看本局
var _thread = null
var _importing := false
var _importing_name := ""

# ---- 选择状态 ----
var _selected = null           # 本局时 null = 跟着实时的当前段
var _view: int = Model.VIEW_OUT
var _group: int = Model.GROUP_SOURCE
var _source = null             # 选中的行（桶里的键）；这一段里没有它就自动看第一名
var _dim := ""
var _list_top := 0
var _list_area := Rect2()
var _list_visible := 1
var _shown = null              # 这一帧显示的段，导出用
var _shown_live := true

# ---- 导入列表 ----
var _picker_open := false
var _files := []
var _file_top := 0
var _file_area := Rect2()
var _file_visible := 1

var _status := ""
var _status_until := 0


func _init() -> void:
	pos_keys = ["MainPanelX", "MainPanelY"]
	drag_anywhere = false
	drag_band = TITLE_H + 2.0
	refresh_interval = 0.25
	visible = false


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


func toggle() -> void:
	visible = not visible
	if visible:
		_raise()
		mark_dirty()


func _layout() -> void:
	rect_size = Vector2(W, H)


func _set_status(s: String) -> void:
	_status = s
	_status_until = OS.get_ticks_msec() + 8000


# ===========================================================================
# 绘制
# ===========================================================================

func _paint() -> void:
	var live = _imported == null
	var session = tracker.session if live else _imported

	# 面板盖在游戏画面上，要一块够暗的底才看得清
	skin.fill(self, Rect2(Vector2.ZERO, rect_size), skin.PANEL_BG)
	skin.frame(self, Rect2(Vector2.ZERO, rect_size), skin.WINDOW_BORDER)
	skin.text(self, skin.p_bold, Rect2(0, 0, W, TITLE_H), Strings.main_title(), skin.TITLE, 1)

	var rows = _rows(session)
	var enc = _resolve(session, live, rows)
	_shown = enc
	_shown_live = live

	_toolbar(live)
	_list(Rect2(PAD, BODY_Y, LIST_W, H - BODY_Y - PAD), session, live, rows, enc)

	var right = Rect2(RIGHT_X, BODY_Y, RIGHT_W, H - BODY_Y - PAD)
	if _picker_open:
		_picker(right)
	elif enc == null:
		skin.text(self, skin.p_small, Rect2(right.position.x, right.position.y + 24.0, right.size.x, 20.0), Strings.no_encounters(), skin.DIM)
	else:
		_encounter(right, session, live, enc)


# 列表里的段，最新的在上面；本局进行中的那段排第一
func _rows(s) -> Array:
	var list := []
	if s.current != null:
		list.append(s.current)
	for i in range(s.encounters.size() - 1, -1, -1):
		list.append(s.encounters[i])
	return list


func _resolve(s, live: bool, rows: Array):
	if rows.empty():
		return null
	if live:
		if _selected == null:
			return rows[0]
		if s.encounters.has(_selected) or _selected == s.current:
			return _selected
		_selected = null   # 选中的那段被挤出保留上限了，回到实时
		return rows[0]
	if _selected == null or not rows.has(_selected):
		_selected = rows[0]
	return _selected


# ---------------------------------------------------------------- 工具栏

func _toolbar(live: bool) -> void:
	var x = W - PAD
	x = _tool(x, 28.0, "×", "close")
	x = _tool(x, 96.0, Strings.btn_export_csv(), "export")
	x = _tool(x, 92.0, Strings.btn_log_folder(), "folder")
	if not _importing:
		x = _tool(x, 72.0, Strings.btn_import(), "import")
	if not live:
		x = _tool(x, 104.0, Strings.btn_back_to_live(), "live")
	# 左边剩下的地方给状态：正在解析、导入结果、导出到了哪
	var status = ""
	if _importing:
		status = Strings.parsing(_importing_name)
	elif _status != "" and OS.get_ticks_msec() < _status_until:
		status = _status
	if status != "":
		skin.text(self, skin.p_small, Rect2(PAD, TOOLBAR_Y, x - PAD - 6.0, TOOLBAR_H), status, skin.DIM)


func _tool(right: float, width: float, label: String, action: String) -> float:
	var r = Rect2(right - width, TOOLBAR_Y, width, TOOLBAR_H)
	skin.button(self, skin.p_small, r, label, hit(r, action))
	return right - width - 6.0


# ---------------------------------------------------------------- 左侧：分段列表

func _list(r: Rect2, session, live: bool, rows: Array, selected) -> void:
	skin.fill(self, r, skin.LIST_BG)
	var count = session.encounters.size()
	if session.current != null and not session.current.is_empty():
		count += 1
	var head = Strings.live_session(count) if live else Strings.imported_session(_short_name(session.source_path), count)
	skin.text(self, skin.p_head, Rect2(r.position.x + 8.0, r.position.y, r.size.x - 16.0, 22.0), head, skin.HEAD)

	var area = Rect2(r.position.x, r.position.y + 24.0, r.size.x, r.size.y - 24.0 - 26.0)
	var visible_rows = int(max(1, floor(area.size.y / ROW_H)))
	_list_area = area
	_list_visible = visible_rows
	_list_top = int(clamp(_list_top, 0, max(0, rows.size() - visible_rows)))

	if rows.empty():
		skin.text(self, skin.p_small, Rect2(area.position.x + 8.0, area.position.y + 4.0, area.size.x - 16.0, ROW_H), Strings.no_encounters(), skin.DIM)

	for i in range(visible_rows):
		var idx = _list_top + i
		if idx >= rows.size():
			break
		var e = rows[idx]
		var row = Rect2(area.position.x, area.position.y + i * ROW_H, area.size.x, ROW_H)
		var is_live_row = live and e == session.current
		var hover = hit(row, "select", e)
		if e == selected:
			skin.fill(self, row, skin.SELECTED)
		elif hover:
			skin.fill(self, row, skin.HOVER)
		skin.text(self, skin.p_small, Rect2(row.position.x + 8.0, row.position.y, 50.0, ROW_H), Fmt.clock_of(e.started_unix), skin.DIM)
		skin.text(self, skin.p_text, Rect2(row.position.x + 60.0, row.position.y, row.size.x - 60.0 - 62.0, ROW_H), tracker.names.encounter_title(e), skin.TEXT)
		if is_live_row and tracker.is_live():
			skin.text(self, skin.p_small, Rect2(row.end.x - 60.0, row.position.y, 52.0, ROW_H), Strings.live_tag(), skin.LIVE, 2)
		else:
			skin.text(self, skin.p_small, Rect2(row.end.x - 60.0, row.position.y, 52.0, ROW_H), Fmt.dur(e.duration), skin.DIM, 2)

	# 底部：翻页 + 位置
	var foot_y = r.end.y - 22.0
	var up = Rect2(r.position.x + 4.0, foot_y, 30.0, 20.0)
	var down = Rect2(r.position.x + 38.0, foot_y, 30.0, 20.0)
	skin.button(self, skin.p_small, up, "▲", hit(up, "up"))
	skin.button(self, skin.p_small, down, "▼", hit(down, "down"))
	var shown_to = int(min(rows.size(), _list_top + visible_rows))
	var foot = "" if rows.empty() else "%d–%d / %d" % [_list_top + 1, shown_to, rows.size()]
	if live and session.dropped > 0 and shown_to == rows.size():
		foot = Strings.dropped_hint(session.dropped)
	skin.text(self, skin.p_small, Rect2(r.position.x + 74.0, foot_y, r.size.x - 82.0, 20.0), foot, skin.DIM, 2)


# ---------------------------------------------------------------- 右侧：一段的统计

func _encounter(r: Rect2, session, live: bool, enc) -> void:
	var y = r.position.y
	var names = tracker.names
	var ov = tracker.overkill
	var is_live_current = live and enc == session.current and tracker.is_live()

	# ---- 摘要 ----
	var d = enc.duration
	var out_total = enc.total(Model.VIEW_OUT, ov)
	var summary = "%s   %s   %s" % [names.encounter_title(enc), Fmt.dur(d),
		Strings.summary(Fmt.short(out_total), Fmt.short(Fmt.per_sec(out_total, d)),
			Fmt.short(enc.total(Model.VIEW_TAKEN, ov)), Fmt.short(enc.total(Model.VIEW_HEAL, ov)))]
	skin.text(self, skin.p_bold, Rect2(r.position.x, y, r.size.x, 22.0), summary, skin.TEXT)
	y += 26.0

	# ---- 视图与分组 ----
	for v in Model.VIEWS:
		var tr_ = Rect2(r.position.x + v * 80.0, y, 76.0, 22.0)
		skin.tab(self, skin.p_small, tr_, Strings.view_label(v), _view == v, hit(tr_, "view", v))
	for g in [Model.GROUP_SOURCE, Model.GROUP_PLAYER]:
		var gr = Rect2(r.position.x + 256.0 + g * 80.0, y, 76.0, 22.0)
		skin.tab(self, skin.p_small, gr, Strings.group_label(g), _group == g, hit(gr, "group", g))
	var chars = _characters(enc)
	var hint = Strings.live_hint() if is_live_current else ""
	if chars != "":
		hint = chars if hint == "" else chars + "   " + hint
	skin.text(self, skin.p_small, Rect2(r.position.x + 420.0, y, r.size.x - 420.0, 22.0), hint, skin.LIVE if is_live_current else skin.DIM, 2)
	y += 28.0

	# ---- 战斗员表格 ----
	var rows = Model.sorted_rows(enc, _view, _group, ov)
	var total = enc.total(_view, ov)
	var bucket = enc.bucket(_view, _group)
	var sel = bucket.get(_source) if _source != null else null
	if sel == null and rows.size() > 0:
		sel = rows[0]

	# 表格按这一段三个视图里行最多的那个留高度（切视图时布局不跳），曲线填满表格和拆分区之间
	var most = 0
	for v in Model.VIEWS:
		most = int(max(most, enc.bucket(v, _group).size()))
	var table_rows = int(clamp(most, MIN_TABLE_ROWS, MAX_TABLE_ROWS))
	var table_h = TABLE_ROW_H * (table_rows + 1)
	if most > MAX_TABLE_ROWS:
		table_h += 14.0   # 「…另有 n 项」那一行
	_table(Rect2(r.position.x, y, r.size.x, table_h), enc, rows, total, sel, table_rows)
	y += table_h + 6.0

	# ---- 曲线 ----
	var breakdown_top = r.end.y - BREAKDOWN_H
	var chart_h = max(MIN_CHART_H, breakdown_top - 8.0 - y)
	_chart(Rect2(r.position.x, y, r.size.x, chart_h), enc, rows, sel)
	y += chart_h + 8.0

	# ---- 选中那一行的拆分 ----
	_breakdown(Rect2(r.position.x, y, r.size.x, r.end.y - y), enc, sel)


# 表格色条和曲线用同一种颜色，色条就是曲线的图例。按玩家分组用玩家色；
# 按来源分组时同品质的武器颜色一样、曲线分不开，改用和饼图一样的调色板按名次配色
func _row_color(s, index: int) -> Color:
	if _group == Model.GROUP_PLAYER:
		return tracker.names.player_color(s.player)
	return skin.palette(index)


func _characters(enc) -> String:
	var parts := PoolStringArray()
	for p in enc.characters.keys():
		parts.append(tracker.names.player_label(p, enc))
	if parts.size() == 1:
		# 单人时不带 P1，只写角色名
		var only = tracker.names.character_label(str(enc.characters.values()[0]))
		return only
	return parts.join("  ")


func _table(r: Rect2, enc, rows: Array, total: float, sel, max_rows: int) -> void:
	var heal = _view == Model.VIEW_HEAL
	var taken = _view == Model.VIEW_TAKEN
	var x = r.position.x
	var hy = r.position.y
	var names = tracker.names

	# 列：名字 | 总量 | 占比 | 每秒 | 暴击(闪避) | 次数 | 最高（治疗：名字 | 总量 | 占比 | 每秒 | 次数 | 主要来源）
	skin.text(self, skin.p_head, Rect2(x + 11.0, hy, 160.0, TABLE_ROW_H), Strings.col_name(), skin.HEAD)
	skin.text(self, skin.p_head, Rect2(x + 171.0, hy, 97.0, TABLE_ROW_H), Strings.col_total(), skin.HEAD, 2)
	skin.text(self, skin.p_head, Rect2(x + 268.0, hy, 73.0, TABLE_ROW_H), Strings.col_share(), skin.HEAD, 2)
	skin.text(self, skin.p_head, Rect2(x + 341.0, hy, 97.0, TABLE_ROW_H), Strings.col_per_sec(), skin.HEAD, 2)
	if heal:
		skin.text(self, skin.p_head, Rect2(x + 438.0, hy, 76.0, TABLE_ROW_H), Strings.col_hits(), skin.HEAD, 2)
		skin.text(self, skin.p_head, Rect2(x + 534.0, hy, 170.0, TABLE_ROW_H), Strings.col_top_source(), skin.HEAD)
	else:
		skin.text(self, skin.p_head, Rect2(x + 438.0, hy, 76.0, TABLE_ROW_H), Strings.col_dodge() if taken else Strings.col_crit(), skin.HEAD, 2)
		skin.text(self, skin.p_head, Rect2(x + 514.0, hy, 87.0, TABLE_ROW_H), Strings.col_hits(), skin.HEAD, 2)
		skin.text(self, skin.p_head, Rect2(x + 601.0, hy, 103.0, TABLE_ROW_H), Strings.col_max(), skin.HEAD, 2)

	if rows.empty():
		skin.text(self, skin.p_small, Rect2(x + 11.0, hy + TABLE_ROW_H + 2.0, r.size.x - 22.0, TABLE_ROW_H), Strings.empty_hint(_view), skin.DIM)
		return

	var ov = tracker.overkill
	for i in range(min(max_rows, rows.size())):
		var s = rows[i]
		var row = Rect2(x, hy + (i + 1) * TABLE_ROW_H, r.size.x, TABLE_ROW_H)
		var hover = hit(row, "row", s.key if _group == Model.GROUP_SOURCE else s.player)
		if s == sel:
			skin.fill(self, row, skin.SELECTED_ROW)
		elif hover:
			skin.fill(self, row, skin.HOVER)
		var color = _row_color(s, i)
		var value = s.metric(ov)
		var share = value / total if total > 0.0 else 0.0
		# 来源色条 + 占比条
		skin.fill(self, Rect2(row.position.x, row.position.y + 3.0, 4.0, row.size.y - 6.0), color)
		skin.fill(self, Rect2(row.position.x + 6.0, row.end.y - 2.0, (row.size.x - 6.0) * clamp(share, 0.0, 1.0), 2.0), skin.with_alpha(color, 0.8))

		var ry = row.position.y
		skin.text(self, skin.p_text, Rect2(x + 11.0, ry, 160.0, TABLE_ROW_H), names.row_label(enc, _view, _group, s), skin.TEXT)
		skin.text(self, skin.p_text, Rect2(x + 171.0, ry, 97.0, TABLE_ROW_H), Fmt.short(value), skin.TEXT, 2)
		skin.text(self, skin.p_text, Rect2(x + 268.0, ry, 73.0, TABLE_ROW_H), Fmt.pct(share), skin.TEXT, 2)
		skin.text(self, skin.p_text, Rect2(x + 341.0, ry, 97.0, TABLE_ROW_H), Fmt.short(Fmt.per_sec(value, enc.duration)), skin.TEXT, 2)
		if heal:
			skin.text(self, skin.p_text, Rect2(x + 438.0, ry, 76.0, TABLE_ROW_H), Fmt.count(s.hits), skin.TEXT, 2)
			var top = Model.sorted_dim(s, Model.DIM_SOURCE, ov)
			var lead = names.source_label(_view, top[0][0]) if top.size() > 0 else (names.source_label(_view, s.src) if s.src != "" else "—")
			skin.text(self, skin.p_text, Rect2(x + 534.0, ry, 170.0, TABLE_ROW_H), lead, skin.TEXT)
		else:
			var rate = Fmt.pct(float(s.crits) / s.hits) if s.hits > 0 else "—"
			skin.text(self, skin.p_text, Rect2(x + 438.0, ry, 76.0, TABLE_ROW_H), rate, skin.TEXT, 2)
			skin.text(self, skin.p_text, Rect2(x + 514.0, ry, 87.0, TABLE_ROW_H), Fmt.count(s.hits), skin.TEXT, 2)
			skin.text(self, skin.p_text, Rect2(x + 601.0, ry, 103.0, TABLE_ROW_H), Fmt.short(s.max_hit), skin.TEXT, 2)

	if rows.size() > max_rows:
		skin.text(self, skin.p_small, Rect2(x + 11.0, hy + (max_rows + 1) * TABLE_ROW_H, r.size.x - 22.0, 14.0),
			Strings.more_items(rows.size() - max_rows), skin.DIM)


func _chart(r: Rect2, enc, rows: Array, sel) -> void:
	skin.fill(self, r, skin.CHART_BG)
	# 参考线：25% / 50% / 75%
	for k in range(1, 4):
		var gy = round(r.end.y - 2.0 - (r.size.y - 4.0) * k / 4.0) + 0.5
		draw_line(Vector2(r.position.x, gy), Vector2(r.end.x, gy), Color(1, 1, 1, 0.10), 1.0)
	if rows.empty():
		return

	var ov = tracker.overkill
	var shown = rows.slice(0, int(min(6, rows.size())) - 1)
	if sel != null and not shown.has(sel):
		shown.append(sel)

	var n = 2
	for s in shown:
		n = int(max(n, s.metric_series(ov).size()))
	var series := []
	var peak := 0.0
	for s in shown:
		var sm = _smooth(s.metric_series(ov), n, SMOOTH)
		for v in sm:
			if v > peak:
				peak = v
		series.append([sm, _row_color(s, rows.find(s)), s == sel])
	var ymax = peak * 1.12 if peak > 0.0 else 1.0

	# 先画普通的，选中的最后画，压在最上面
	for pass_ in range(2):
		for entry in series:
			if entry[2] != (pass_ == 1):
				continue
			var values = entry[0]
			var pts := PoolVector2Array()
			for i in range(values.size()):
				var px = r.position.x + 1.0 + (r.size.x - 2.0) * i / float(n - 1)
				var py = r.end.y - 2.0 - (r.size.y - 4.0) * clamp(values[i] / ymax, 0.0, 1.0)
				pts.append(Vector2(px, py))
			if pts.size() >= 2:
				var c = entry[1] if entry[2] else skin.with_alpha(entry[1], 0.78)
				draw_polyline(pts, c, 2.4 if entry[2] else 1.4, true)

	skin.text(self, skin.p_small, Rect2(r.position.x + 8.0, r.position.y + 2.0, 260.0, 16.0), Strings.peak(Fmt.short(peak)), skin.DIM)
	skin.text(self, skin.p_small, Rect2(r.end.x - 268.0, r.position.y + 2.0, 260.0, 16.0), Strings.chart_hint(), skin.DIM, 2)
	skin.text(self, skin.p_small, Rect2(r.position.x + 8.0, r.end.y - 18.0, 80.0, 16.0), "0:00", skin.DIM)
	skin.text(self, skin.p_small, Rect2(r.end.x - 88.0, r.end.y - 18.0, 80.0, 16.0), Fmt.dur(enc.duration), skin.DIM, 2)


# 每秒一桶 → 5 秒滑动平均，曲线才不会被单次大伤害扎成刺
static func _smooth(per_second: Array, n: int, window: int) -> Array:
	var out := []
	out.resize(n)
	var acc := 0.0
	for i in range(n):
		acc += float(per_second[i]) if i < per_second.size() else 0.0
		var drop = i - window
		if drop >= 0 and drop < per_second.size():
			acc -= float(per_second[drop])
		out[i] = acc / min(i + 1, window)
	return out


func _breakdown(r: Rect2, enc, sel) -> void:
	var y = r.position.y
	var names = tracker.names
	var dims = Model.dims_for(_view, _group)
	if not dims.has(_dim):
		_dim = dims[0] if dims.size() > 0 else ""
	for i in range(dims.size()):
		var t = Rect2(r.position.x + i * 80.0, y, 76.0, 22.0)
		skin.tab(self, skin.p_small, t, Strings.tab_label(dims[i]), dims[i] == _dim, hit(t, "dim", dims[i]))
	if sel != null:
		var who = names.row_label(enc, _view, _group, sel) + " — " + Strings.view_label(_view)
		skin.text(self, skin.p_text, Rect2(r.position.x + 250.0, y, r.size.x - 250.0, 22.0), who, skin.TEXT, 2)
	y += 28.0

	if sel == null:
		skin.text(self, skin.p_small, Rect2(r.position.x, y, r.size.x, BREAK_ROW_H), Strings.select_hint(), skin.DIM)
		return

	var ov = tracker.overkill
	var mi = Model.ROW_TOTAL if ov else Model.ROW_EFF
	var rows = Model.sorted_dim(sel, _dim, ov) if _dim != "" else []
	var tw = r.size.x - PIE - 16.0
	var x = r.position.x
	# 列：项目 | 总量 | 占比 | 次数 | 暴击(闪避) | 最高
	var c_name = tw - 336.0
	skin.text(self, skin.p_head, Rect2(x + 14.0, y, c_name - 14.0, BREAK_ROW_H), Strings.col_item(), skin.HEAD)
	skin.text(self, skin.p_head, Rect2(x + c_name, y, 90.0, BREAK_ROW_H), Strings.col_total(), skin.HEAD, 2)
	skin.text(self, skin.p_head, Rect2(x + c_name + 90.0, y, 70.0, BREAK_ROW_H), Strings.col_share(), skin.HEAD, 2)
	skin.text(self, skin.p_head, Rect2(x + c_name + 160.0, y, 60.0, BREAK_ROW_H), Strings.col_hits(), skin.HEAD, 2)
	if _view != Model.VIEW_HEAL:
		var crit_head = Strings.col_dodge() if _view == Model.VIEW_TAKEN else Strings.col_crit()
		skin.text(self, skin.p_head, Rect2(x + c_name + 220.0, y, 56.0, BREAK_ROW_H), crit_head, skin.HEAD, 2)
		skin.text(self, skin.p_head, Rect2(x + c_name + 276.0, y, 60.0, BREAK_ROW_H), Strings.col_max(), skin.HEAD, 2)

	var sum := 0.0
	for row in rows:
		sum += float(row[1][mi])
	if rows.empty():
		skin.text(self, skin.p_small, Rect2(x + 14.0, y + BREAK_ROW_H, tw - 14.0, BREAK_ROW_H), Strings.no_breakdown(), skin.DIM)

	for i in range(min(BREAK_ROWS, rows.size())):
		var item = rows[i][0]
		var b = rows[i][1]
		var ry = y + (i + 1) * BREAK_ROW_H
		skin.fill(self, Rect2(x + 1.0, ry + 5.0, 8.0, 8.0), skin.palette(i))
		skin.text(self, skin.p_text, Rect2(x + 14.0, ry, c_name - 14.0, BREAK_ROW_H), names.dim_label(_view, _dim, item), skin.TEXT)
		skin.text(self, skin.p_text, Rect2(x + c_name, ry, 90.0, BREAK_ROW_H), Fmt.short(float(b[mi])), skin.TEXT, 2)
		skin.text(self, skin.p_text, Rect2(x + c_name + 90.0, ry, 70.0, BREAK_ROW_H), Fmt.pct(float(b[mi]) / sum if sum > 0.0 else 0.0), skin.TEXT, 2)
		skin.text(self, skin.p_text, Rect2(x + c_name + 160.0, ry, 60.0, BREAK_ROW_H), Fmt.count(int(b[Model.ROW_HITS])), skin.TEXT, 2)
		if _view != Model.VIEW_HEAL:
			var hits = int(b[Model.ROW_HITS])
			var rate = Fmt.pct(float(b[Model.ROW_CRITS]) / hits) if hits > 0 else "—"
			skin.text(self, skin.p_text, Rect2(x + c_name + 220.0, ry, 56.0, BREAK_ROW_H), rate, skin.TEXT, 2)
			skin.text(self, skin.p_text, Rect2(x + c_name + 276.0, ry, 60.0, BREAK_ROW_H), Fmt.short(float(b[Model.ROW_MAX])), skin.TEXT, 2)
	if rows.size() > BREAK_ROWS:
		skin.text(self, skin.p_small, Rect2(x + 14.0, y + (BREAK_ROWS + 1) * BREAK_ROW_H, tw - 14.0, BREAK_ROW_H),
			Strings.more_items(rows.size() - BREAK_ROWS), skin.DIM)

	# ---- 饼图 ----
	var slices := []
	var rest := 0.0
	for i in range(rows.size()):
		var v = float(rows[i][1][mi])
		if i < 8:
			slices.append([v, skin.palette(i)])
		else:
			rest += v
	if rest > 0.0:
		slices.append([rest, skin.palette(8)])
	var center = Vector2(r.end.x - PIE * 0.5, y - 4.0 + PIE * 0.5)
	skin.donut(self, center, PIE * 0.5 - 1.0, PIE * 0.5 * 0.42, slices)
	var value = sel.metric(ov)
	skin.text(self, skin.p_center, Rect2(center.x - PIE * 0.5, center.y - 19.0, PIE, 20.0), Fmt.short(value), skin.TEXT, 1)
	skin.text(self, skin.p_small, Rect2(center.x - PIE * 0.5, center.y + 1.0, PIE, 16.0), Fmt.short(Fmt.per_sec(value, enc.duration)) + "/s", skin.DIM, 1)


# ---------------------------------------------------------------- 导入

func _picker(r: Rect2) -> void:
	skin.fill(self, r, skin.PICKER_BG)
	skin.text(self, skin.p_bold, Rect2(r.position.x + 10.0, r.position.y + 2.0, r.size.x - 110.0, 22.0), Strings.pick_log(), skin.TEXT)
	var cancel = Rect2(r.end.x - 86.0, r.position.y + 2.0, 80.0, 22.0)
	skin.button(self, skin.p_small, cancel, Strings.btn_cancel(), hit(cancel, "cancel"))

	var area = Rect2(r.position.x, r.position.y + 30.0, r.size.x, r.size.y - 30.0)
	_file_area = area
	if _files.empty():
		skin.text(self, skin.p_small, Rect2(area.position.x + 10.0, area.position.y + 4.0, area.size.x - 20.0, ROW_H), Strings.no_logs(), skin.DIM)
		return
	var visible_rows = int(max(1, floor(area.size.y / ROW_H)))
	_file_visible = visible_rows
	_file_top = int(clamp(_file_top, 0, max(0, _files.size() - visible_rows)))
	var current = tracker.writer.path if tracker.writer != null else ""
	for i in range(visible_rows):
		var idx = _file_top + i
		if idx >= _files.size():
			break
		var f = _files[idx]
		var row = Rect2(area.position.x, area.position.y + i * ROW_H, area.size.x, ROW_H)
		if hit(row, "file", idx):
			skin.fill(self, row, Color(1, 1, 1, 0.08))
		var name = f.name + (Strings.current_file_tag() if f.path == current else "")
		skin.text(self, skin.p_text, Rect2(row.position.x + 10.0, row.position.y, row.size.x - 250.0, ROW_H), name, skin.TEXT)
		skin.text(self, skin.p_small, Rect2(row.end.x - 236.0, row.position.y, 80.0, ROW_H), _size_text(int(f.size)), skin.DIM, 2)
		skin.text(self, skin.p_small, Rect2(row.end.x - 146.0, row.position.y, 136.0, ROW_H), _mtime_text(int(f.mtime)), skin.DIM, 2)


func _refresh_files() -> void:
	_file_top = 0
	_files = LogReader.list_logs(tracker.log_dir())


func _start_import(idx: int) -> void:
	if _importing or idx < 0 or idx >= _files.size():
		return
	var f = _files[idx]
	_picker_open = false
	if tracker.writer != null and f.path == tracker.writer.path:
		tracker.writer.flush()   # 本局的日志：先把还没落盘的写下去
	_importing = true
	_importing_name = f.name
	_thread = Thread.new()
	var err = _thread.start(self, "_import_worker", [f.path, int(tracker.config.value("HistorySize"))])
	if err != OK:
		_thread = null
		_importing = false
		_set_status(Strings.import_failed("thread"))


# 后台线程：读文件、按当前版本重新解析。解析器是纯 GDScript，不碰场景树
func _import_worker(args):
	var s = LogReader.read(args[0], args[1])
	call_deferred("_import_finished", s)


func _import_finished(s) -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_importing = false
	if s.meta.has("error"):
		_set_status(Strings.import_failed(str(s.meta["error"])))
		return
	_imported = s
	_selected = null
	_list_top = 0
	var current = tracker.writer != null and s.source_path == tracker.writer.path
	var extra = ""
	if current:
		extra = Strings.import_current_file()
	elif s.truncated:
		extra = Strings.import_truncated()
	_set_status(Strings.import_done(s.encounters.size(), s.event_count) + extra)
	ModLoaderLog.info("已导入战斗日志 %s：%d 段，%d 条事件（不认识 %d，坏行 %d%s）" % [
		s.source_path, s.encounters.size(), s.event_count, s.unknown_lines, s.bad_lines,
		"，末尾不完整" if s.truncated else ""], "DPSLove-CombatTracker")
	mark_dirty()


# ---------------------------------------------------------------- 动作

func _on_action(action: String, arg) -> void:
	match action:
		"close":
			visible = false
		"export":
			var path = tracker.export_csv(_shown, "live" if _shown_live else "import")
			_set_status(Strings.exported(path.get_file()) if path != "" else Strings.export_failed())
		"folder":
			var dir = tracker.log_dir()
			var d = Directory.new()
			if not d.dir_exists(dir):
				d.make_dir_recursive(dir)
			OS.shell_open(ProjectSettings.globalize_path(dir))
		"import":
			_picker_open = not _picker_open
			if _picker_open:
				_refresh_files()
		"cancel":
			_picker_open = false
		"file":
			_start_import(int(arg))
		"live":
			_imported = null
			_selected = null
			_list_top = 0
		"select":
			var live = _imported == null
			if live and arg == tracker.session.current:
				_selected = null
			else:
				_selected = arg
		"up":
			_list_top = int(max(0, _list_top - _list_visible))
		"down":
			_list_top += _list_visible
		"view":
			_view = int(arg)
		"group":
			_group = int(arg)
			_source = null
		"row":
			_source = arg
		"dim":
			_dim = str(arg)


func _on_wheel(pos: Vector2, dir: int) -> void:
	if _picker_open and _file_area.has_point(pos):
		_file_top = int(max(0, _file_top + dir * 3))
	elif _list_area.has_point(pos):
		_list_top = int(max(0, _list_top + dir * 3))


# ---------------------------------------------------------------- 小工具

# bct-20260928-193012.bctlog.gz → bct-20260928-193012
static func _short_name(path: String) -> String:
	var name = path.get_file()
	var dot = name.find(".bctlog")
	return name.substr(0, dot) if dot > 0 else name


static func _size_text(bytes: int) -> String:
	var kb = bytes / 1024.0
	if kb >= 1024.0:
		return "%.1f MB" % (kb / 1024.0)
	return "%d KB" % int(ceil(kb))


static func _mtime_text(unix: int) -> String:
	if unix <= 0:
		return ""
	var bias = int(OS.get_time_zone_info().get("bias", 0))
	var dt = OS.get_datetime_from_unix_time(unix + bias * 60)
	return "%02d-%02d %02d:%02d" % [dt.month, dt.day, dt.hour, dt.minute]
