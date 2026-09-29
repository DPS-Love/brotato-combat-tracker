extends "window_base.gd"

# 战斗记录窗口，形制参考 ACT 的主窗口（与 TBH Combat Tracker 一致）：
# 左边是本局每一段（波次）的列表，右边是选中那段的战斗员表格、每秒数值曲线、拆分表和环形图；
# 右上角可以把下半截换成逐条事件。表格里点一行只看它，再点一次或点空白处取消、回到全队。
#
# 数据源是一个会话：本局的实时会话，或者从日志导入、按当前版本重新解析出来的会话，界面完全一样。
# 导入和读逐条事件都在后台线程里，不卡游戏。

const Model = preload("../core/model.gd")
const Strings = preload("../core/strings.gd")
const Fmt = preload("../core/fmt.gd")
const LogReader = preload("../core/log_reader.gd")
const EventPages = preload("../core/event_pages.gd")
const Scroll = preload("scroll.gd")
const Donut = preload("donut.gd")

# 版式常量：TBH 的界面单位（窗口整体再按 skin.scale 放大）
const W = 840.0
const H = 590.0
const PAD = 10.0
const TOOLBAR_Y = 33.0
const TOOLBAR_H = 28.0
const BODY_Y = 68.0
const LIST_W = 268.0
const ROW_H = 24.0
const FOOT_H = 32.0
const RIGHT_X = 290.0          # PAD + LIST_W + 12
const RIGHT_W = 540.0          # W - RIGHT_X - PAD
const SUMMARY_H = 48.0
const TABLE_ROW_H = 20.0
const MIN_TABLE_ROWS = 3
const MAX_TABLE_ROWS = 7
const BREAK_ROW_H = 17.0
const BREAK_ROWS = 8
const DONUT = 128.0
const BREAK_H = 198.0          # 页签 28 + 表头 + 8 行 + 底行
const MIN_CHART_H = 80.0
const EV_ROW_H = 18.0
const PICK_ROW_H = 28.0
const SMOOTH = 5
const CH_L = 8.0
const CH_R = 8.0
const CH_T = 22.0
const CH_B = 18.0

# 表格列：名字 | 总量 | 占比 | 每秒 | 暴击(闪避) | 次数 | 最高（治疗：名字 | 总量 | 占比 | 每秒 | 次数 | 主要来源）
const COLS = [146.0, 80.0, 58.0, 80.0, 58.0, 62.0, 56.0]
const HEAL_COLS = [146.0, 80.0, 58.0, 80.0, 62.0, 114.0]
# 逐条事件的列：输出 时间 | 来源 | 目标 | 数值 | 暴击 | 形式；承伤 时间 | 来源 | 承受者 | 数值 | 结果；治疗 时间 | 对象 | 来源 | 数值
const EV_OUT_COLS = [54.0, 150.0, 130.0, 74.0, 34.0, 98.0]
const EV_TAKEN_COLS = [54.0, 170.0, 130.0, 74.0, 112.0]
const EV_HEAL_COLS = [54.0, 130.0, 226.0, 90.0]

# ---- 数据源 ----
var _imported = null           # null = 看本局
var _thread = null
var _importing := false
var _importing_name := ""

# ---- 选择 ----
var _sel = null                # 选中的段；本局时 null = 跟着实时的当前段
var _view: int = Model.VIEW_OUT
var _group: int = Model.GROUP_SOURCE
var _has_source := false       # 表格里选中了一行（没选中时拆分看全队）
var _source = null             # 选中那一行在桶里的键
var _dim := ""
var _events_mode := false
var _shown = null              # 这一帧显示的段，导出用
var _shown_live := true

var _status := ""
var _status_until := 0
var _picker_open := false
var _files := []

# ---- 列表 ----
var _items := []               # 列表里的段，最新的在上面
var _list = Scroll.new(ROW_H)
var _brk = Scroll.new(BREAK_ROW_H)
var _evs = Scroll.new(EV_ROW_H)
var _picks = Scroll.new(PICK_ROW_H)
var _list_rect := Rect2()
var _brk_rect := Rect2()
var _ev_rect := Rect2()
var _pick_rect := Rect2()

# ---- 表格 ----
var _row_colors := {}          # 行的键 -> 颜色（曲线用同一种颜色，色条就是图例）

# ---- 拆分 ----
var _donut = Donut.new(BREAK_ROWS)
var _brk_rows := []
var _brk_sum := 0.0
var _brk_cols := []
var _brk_detailed := true
var _brk_dim := ""
var _brk_dims := []
var _brk_highlight := -1
var _brk_key := ""
var _mi := 1

# ---- 曲线 ----
var _chart_rect := Rect2()
var _chart_series := []        # [每秒数值, 颜色, 加粗, 名字]
var _chart_n := 2
var _chart_ymax := 1.0
var _chart_peak := ""
var _chart_dur := ""
var _chart_sig := ""
var _chart_hover := -1         # 光标所在的秒；-1 = 不在曲线上

# ---- 逐条事件 ----
var _ev_shown := []            # 按视图和选中的行筛过的事件
var _ev_scanned := 0
var _ev_enc = null
var _ev_filter_key := ""
var _ev_key := ""
var _ev_kind := "D"
var _ev_t0 := 0.0
var _ev_multi := false
var _ev_page = null            # 读好的一页：{key, events, error, capped}
var _ev_thread = null
var _ev_loading := ""


func _init() -> void:
	pos_keys = ["MainPanelX", "MainPanelY"]
	drag_anywhere = false
	drag_band = 32.0
	refresh_interval = 0.5
	visible = false


func _ready() -> void:
	for id in ["list", "chart", "chart_hover", "break", "events", "picks"]:
		add_pane(id)


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	if _ev_thread != null:
		_ev_thread.wait_to_finish()
		_ev_thread = null


func toggle() -> void:
	visible = not visible
	if visible:
		_raise()
		mark_dirty()


func _layout() -> void:
	rect_size = Vector2(W, H)
	refresh_interval = 0.5 if _imported == null else 0.0


func _set_status(s: String) -> void:
	_status = s
	_status_until = OS.get_ticks_msec() + 8000
	mark_dirty()


func _tick(delta: float) -> bool:
	var moved = false
	for s in [_list, _brk, _evs, _picks]:
		if s.tick(delta):
			moved = true
	return moved


# ===========================================================================
# 绘制
# ===========================================================================

func _paint() -> void:
	var live = _imported == null
	var session = tracker.session if live else _imported
	var op = opacity()
	skin.window_frame(self, Rect2(Vector2.ZERO, rect_size), skin.with_alpha(skin.WINDOW_BG, op), 1.0, op * 1.6)

	_items = _items_of(session)
	var enc = _resolve(session, live)
	_shown = enc
	_shown_live = live
	var is_live_current = live and enc != null and enc == session.current

	# 右侧空白处：点一下取消表格里的选中。最先登记，压在所有控件下面
	if enc != null and not _picker_open:
		hit(Rect2(RIGHT_X, BODY_Y, RIGHT_W, H - BODY_Y - PAD), "deselect")

	_chrome(live, session, enc)
	_list_pane(session)
	_ev_rect = Rect2()
	_pick_rect = Rect2()
	_brk_rect = Rect2()
	_chart_rect = Rect2()
	if _picker_open:
		_picker_pane()
		_donut.hide()
	elif enc != null:
		skin.box(self, Rect2(RIGHT_X - 8.0, BODY_Y - 6.0, RIGHT_W + 8.0 + PAD * 0.5, H - BODY_Y - PAD + 6.0), skin.PANEL, 6.0)
		_encounter_pane(enc, is_live_current, session)
	else:
		_donut.hide()
		skin.text(self, Rect2(RIGHT_X, BODY_Y + 150.0, RIGHT_W, 24.0), Strings.no_encounters(), skin.FONT_BODY, skin.TEXT_DIM, 1)


# 列表里的段，最新的在上面；本局进行中的那段排第一
func _items_of(s) -> Array:
	var list := []
	if s.current != null:
		list.append(s.current)
	for i in range(s.encounters.size() - 1, -1, -1):
		list.append(s.encounters[i])
	return list


func _resolve(s, live: bool):
	if _items.empty():
		return null
	if live:
		if _sel == null:
			return _items[0]
		if _items.has(_sel):
			return _sel
		_sel = null   # 选中的那段被挤出保留上限了，回到实时
		return _items[0]
	if _sel == null or not _items.has(_sel):
		_sel = _items[0]
	return _sel


# ---------------------------------------------------------------- 标题栏和工具栏

func _chrome(live: bool, session, enc) -> void:
	var th = skin.TITLE_H
	skin.icon(self, "history", Vector2(21, th * 0.5), 15.0, skin.ACCENT)
	skin.text(self, Rect2(36, 0, 300, th), Strings.main_title(), skin.FONT_TITLE, skin.TEXT, 0, true)
	button(Rect2(W - 36.0, 4, 28, 24), "close", "", skin.GHOST, "close", null, Strings.tip_close())
	button(Rect2(W - 66.0, 4, 28, 24), "settings", "", skin.GHOST, "settings", null, Strings.tip_settings())

	# 看导入的日志时，左上角标出是哪份文件（点 × 回到本局）；看本局时什么都不放
	var chip_w = 0.0
	if not live:
		var name = _short_name(session.source_path)
		var text_w = min(220.0, ceil(skin.text_width(name, skin.FONT_SMALL)))
		chip_w = 26.0 + text_w + 30.0
		var chip = Rect2(PAD, TOOLBAR_Y + 2.0, chip_w, 24.0)
		hit(chip, "chip", null, HIT_PASSIVE, Strings.tip_imported_chip(name))
		skin.box(self, chip, skin.PANEL, 11.0)
		skin.icon(self, "document", Vector2(chip.position.x + 16.0, chip.position.y + 12.0), 12.0, skin.TEXT_DIM)
		skin.text(self, Rect2(chip.position.x + 26.0, chip.position.y, text_w + 2.0, 24.0), name, skin.FONT_SMALL, skin.TEXT)
		button(Rect2(chip.end.x - 26.0, chip.position.y + 2.0, 22, 20), "close", "", skin.GHOST, "live", null, Strings.tip_back_to_live())

	# 右边的按钮
	var right = W - PAD
	var y = TOOLBAR_Y + 2.0
	var label = Strings.btn_export_csv()
	var bw = skin.button_width("export", label)
	button(Rect2(right - bw, y, bw, 24), "export", label, skin.GHOST, "export", null, Strings.tip_export(), false, enc != null)
	right -= bw + 4.0
	label = Strings.btn_log_folder()
	bw = skin.button_width("folder", label)
	button(Rect2(right - bw, y, bw, 24), "folder", label, skin.GHOST, "folder", null, Strings.tip_log_folder())
	right -= bw + 4.0
	label = Strings.btn_import()
	bw = skin.button_width("import", label)
	button(Rect2(right - bw, y, bw, 24), "import", label, skin.GHOST, "import", null, Strings.tip_import(), _picker_open, not _importing)
	right -= bw + 8.0

	var status = ""
	if _importing:
		status = Strings.parsing(_importing_name)
	elif _status != "" and OS.get_ticks_msec() < _status_until:
		status = _status
	var sx = PAD + 4.0 if live else PAD + chip_w + 10.0
	skin.text(self, Rect2(sx, TOOLBAR_Y, max(0.0, right - sx), TOOLBAR_H), status, skin.FONT_SMALL, skin.TEXT_DIM)


# ---------------------------------------------------------------- 左侧：分段列表

func _list_pane(session) -> void:
	var pane_h = H - BODY_Y - PAD
	skin.box(self, Rect2(PAD, BODY_Y, LIST_W, pane_h), skin.PANEL, 6.0)
	_list_rect = Rect2(PAD + 4.0, BODY_Y + 4.0, LIST_W - 8.0, pane_h - 8.0 - FOOT_H)
	_list.setup(_items.size(), _list_rect.size.y)
	pane("list", _list_rect)
	var first = _list.first()
	for slot in range(_list.visible_rows()):
		var i = first + slot
		if i >= _items.size():
			break
		# 被视口裁掉的那部分不该还能点；右边留给滚动条
		var r = Rect2(_list_rect.position.x, _list_rect.position.y + i * ROW_H - _list.offset, _list_rect.size.x - 9.0, ROW_H).clip(_list_rect)
		if r.size.y > 0.0:
			hit(r, "select", i)
	_thumb_hit(_list, _list_rect, "list")

	var fy = BODY_Y + pane_h - FOOT_H
	skin.box(self, Rect2(PAD + 8.0, fy, LIST_W - 16.0, 1), skin.DIVIDER)
	button(Rect2(PAD + 8.0, fy + 5.0, 28, 22), "chevron_up", "", skin.SUBTLE, "up", null, Strings.tip_page_up())
	button(Rect2(PAD + 40.0, fy + 5.0, 28, 22), "chevron_down", "", skin.SUBTLE, "down", null, Strings.tip_page_down())
	var foot = ""
	if not _items.empty():
		var rng = _list.visible_range()
		foot = "%d–%d / %d" % [rng[0], rng[1], _items.size()]
		if _imported == null and session.dropped > 0 and rng[1] == _items.size():
			foot = Strings.dropped_hint(session.dropped)
	skin.text(self, Rect2(PAD + 72.0, fy, LIST_W - 84.0, FOOT_H), foot, skin.FONT_SMALL, skin.TEXT_DIM, 2)
	if _items.empty():
		skin.text(self, Rect2(PAD, BODY_Y + 20.0, LIST_W, 24.0), Strings.no_encounters(), skin.FONT_SMALL, skin.TEXT_DIM, 1)


func _paint_list(ci: CanvasItem) -> void:
	var vw = ci.rect_size.x
	var live = _imported == null
	var session = tracker.session if live else _imported
	var first = _list.first()
	for slot in range(_list.visible_rows()):
		var i = first + slot
		if i >= _items.size():
			break
		var e = _items[i]
		var y = i * ROW_H - _list.offset
		var selected = e == _shown
		if selected:
			skin.box(ci, Rect2(0, y + 1.0, vw - 6.0, ROW_H - 2.0), skin.ACCENT_SOFT, 4.0)
			skin.box(ci, Rect2(0, y + 5.0, 2, ROW_H - 10.0), skin.ACCENT, 1.0)
		elif hot("select", i):
			skin.box(ci, Rect2(0, y + 1.0, vw - 6.0, ROW_H - 2.0), skin.HOVER, 4.0)
		skin.text(ci, Rect2(8, y, 40, ROW_H), Fmt.clock_of(e.started_unix), skin.FONT_SMALL, skin.TEXT_DIM)
		skin.text(ci, Rect2(50, y, vw - 100.0, ROW_H), tracker.names.encounter_title(e), skin.FONT_BODY, skin.TEXT)
		skin.text(ci, Rect2(vw - 50.0, y, 44, ROW_H), Fmt.dur(e.duration), skin.FONT_SMALL, skin.TEXT_DIM, 2)
	_paint_thumb(ci, _list, "list")


# ---------------------------------------------------------------- 滚动条

func _thumb_hit(s, r: Rect2, which: String) -> void:
	var t = s.thumb()
	if t.size() == 2:
		hit(Rect2(r.end.x - 10.0, r.position.y + t[0], 10.0, t[1]), "thumb", which, HIT_DRAG)


func _paint_thumb(ci: CanvasItem, s, which: String) -> void:
	var t = s.thumb()
	if t.size() != 2:
		return
	var wide = hot("thumb", which) or pressed_on("thumb", which)
	var w = 6.0 if wide else 4.0
	skin.box(ci, Rect2(ci.rect_size.x - w - 1.0, t[0], w, t[1]), Color(1, 1, 1, 0.32 if wide else 0.16), 2.0)


# ---------------------------------------------------------------- 右侧：一段的统计

func _encounter_pane(enc, is_live: bool, session) -> void:
	var y = BODY_Y
	var d = enc.duration
	var ov = tracker.overkill
	var names = tracker.names
	var multi = enc.players().size() > 1
	if not multi:
		if _group != Model.GROUP_SOURCE:
			_group = Model.GROUP_SOURCE
			_has_source = false

	# ---- 摘要：实时的那段在标题右边标一个「实时」----
	var vx = RIGHT_X + RIGHT_W - 3.0 * 58.0 - 4.0
	var title_max = RIGHT_W - 270.0 - (50.0 if is_live else 0.0)
	var title = names.encounter_title(enc)
	var tw = skin.text(self, Rect2(RIGHT_X, y - 1.0, title_max, 26.0), title, 15, skin.TEXT, 0, true)
	var after = RIGHT_X + tw + 8.0
	if is_live:
		var lt = Strings.live_tag()
		var pw = ceil(skin.text_width(lt, skin.FONT_TINY, true)) + 14.0
		var pill = Rect2(after, y + 4.0, pw, 17.0)
		skin.box(self, pill, skin.with_alpha(skin.LIVE, 0.16), 8.0)
		skin.text(self, pill, lt, skin.FONT_TINY, skin.LIVE, 1, true)
		after += pw + 8.0
	# 角色名放在标题后面，一直到右上角的切换按钮前
	skin.text(self, Rect2(after, y - 1.0, max(0.0, vx - 12.0 - 62.0 - 8.0 - after), 26.0), _characters(enc), skin.FONT_SMALL, skin.TEXT_DIM)
	var out_total = enc.total(Model.VIEW_OUT, ov)
	var stats = Strings.summary_stats(Fmt.dur(d), Fmt.short(out_total), Fmt.short(Fmt.per_sec(out_total, d)),
		Fmt.short(enc.total(Model.VIEW_TAKEN, ov)), Fmt.short(enc.total(Model.VIEW_HEAL, ov)))
	var stats_w = RIGHT_W - 260.0
	if multi:
		var gl = [Strings.group_label(Model.GROUP_SOURCE), Strings.group_label(Model.GROUP_PLAYER)]
		var gw = segmented(RIGHT_X + RIGHT_W - 2.0 * 56.0 - 4.0, y + 31.0, 56.0, 17.0, gl, _group, "group")
		stats_w = RIGHT_W - gw - 10.0
	skin.text(self, Rect2(RIGHT_X, y + 25.0, stats_w, 18.0), stats, skin.FONT_SMALL, skin.TEXT_DIM)
	var vl = [Strings.view_label(0), Strings.view_label(1), Strings.view_label(2)]
	segmented(vx, y + 2.0, 58.0, 28.0, vl, _view, "view")
	button(Rect2(vx - 12.0 - 62.0, y + 3.0, 30, 26), "chart", "", skin.TAB, "mode_chart", null, Strings.tip_mode_chart(), not _events_mode)
	button(Rect2(vx - 12.0 - 30.0, y + 3.0, 30, 26), "list", "", skin.TAB, "mode_events", null, Strings.tip_mode_events(), _events_mode)
	y += SUMMARY_H

	# ---- 表格 ----
	var rows = Model.sorted_rows(enc, _view, _group, ov)
	var total = enc.total(_view, ov)
	var bucket = enc.bucket(_view, _group)
	# 没选中任何行（或选中的那行这一段 / 这个视图里没有）：表格不高亮、曲线不加粗，拆分看全队
	var sel = bucket.get(_source) if _has_source else null
	_row_colors.clear()
	for i in range(rows.size()):
		_row_colors[rows[i].key] = _row_color(rows[i], i)

	# 按三个视图里行最多的那个留高度（切视图时布局不跳），曲线填满表格和拆分区之间
	var most = 0
	for v in Model.VIEWS:
		most = int(max(most, enc.bucket(v, _group).size()))
	var table_rows = int(clamp(most, MIN_TABLE_ROWS, MAX_TABLE_ROWS))
	_table(y, enc, rows, total, sel, table_rows)
	y += TABLE_ROW_H * (table_rows + 1) + 8.0

	if _events_mode:
		_donut.hide()
		_events_pane(y, enc, is_live, session, sel)
		return

	# ---- 曲线 ----
	var break_top = H - PAD - BREAK_H
	var chart_h = max(MIN_CHART_H, break_top - 10.0 - y)
	_chart(Rect2(RIGHT_X, y, RIGHT_W, chart_h), enc, rows, sel)
	y += chart_h + 10.0

	# ---- 拆分 ----
	_breakdown(y, enc, sel, session)


# 表格色条和曲线用同一种颜色，色条就是曲线的图例。按玩家分组用玩家色；
# 按来源分组时同品质的武器颜色一样、曲线分不开，改用和环形图一样的调色板按名次配色
func _row_color(s, index: int) -> Color:
	if _group == Model.GROUP_PLAYER:
		return tracker.names.player_color(s.player)
	return skin.palette(index)


func _characters(enc) -> String:
	var parts := PoolStringArray()
	var keys = enc.characters.keys()
	keys.sort()
	if keys.size() == 1:
		# 单人时不带 P1，只写角色名
		return tracker.names.character_label(str(enc.characters[keys[0]]))
	for p in keys:
		parts.append(tracker.names.player_label(p, enc))
	return parts.join("  ")


func _key_of(s):
	return s.player if _group == Model.GROUP_PLAYER else s.key


func _table(y: float, enc, rows: Array, total: float, sel, max_rows: int) -> void:
	var heal = _view == Model.VIEW_HEAL
	var taken = _view == Model.VIEW_TAKEN
	var cols = HEAL_COLS if heal else COLS
	var heads = [Strings.col_name(), Strings.col_total(), Strings.col_share(), Strings.col_per_sec()]
	if heal:
		heads += [Strings.col_hits(), Strings.col_top_source()]
	else:
		heads += [Strings.col_dodge() if taken else Strings.col_crit(), Strings.col_hits(), Strings.col_max()]

	var x = RIGHT_X
	for c in range(heads.size()):
		# 治疗的最后一列（主要来源）是文字，左对齐
		var text_col = c == 0 or (heal and c == heads.size() - 1)
		var pad = 12.0 if c == 0 else 0.0
		var extra = 14.0 if heal and c == heads.size() - 1 else 0.0
		skin.text(self, Rect2(x + pad + extra, y, cols[c] - pad - 6.0, TABLE_ROW_H), heads[c], skin.FONT_TINY, skin.TEXT_FAINT, 0 if text_col else 2)
		x += cols[c]

	if rows.empty():
		skin.text(self, Rect2(RIGHT_X + 12.0, y + TABLE_ROW_H, RIGHT_W - 12.0, TABLE_ROW_H), Strings.empty_hint(_view), skin.FONT_SMALL, skin.TEXT_DIM)
		return

	var ov = tracker.overkill
	var names = tracker.names
	for i in range(min(max_rows, rows.size())):
		var s = rows[i]
		var ry = y + (i + 1) * TABLE_ROW_H
		var row = Rect2(RIGHT_X, ry, RIGHT_W, TABLE_ROW_H)
		var key = _key_of(s)
		var hover = hit(row, "row", key)
		if s == sel:
			skin.box(self, row, skin.ACCENT_SOFT, 4.0)
		elif hover:
			skin.box(self, row, skin.HOVER, 4.0)
		var color = _row_colors.get(s.key, skin.TEXT_DIM)
		var value = s.metric(ov)
		var share = value / total if total > 0.0 else 0.0
		skin.box(self, Rect2(RIGHT_X + 3.0, ry + 4.0, 3, TABLE_ROW_H - 8.0), color)
		skin.box(self, Rect2(RIGHT_X + 12.0, ry + TABLE_ROW_H - 3.0, (RIGHT_W - 16.0) * clamp(share, 0.0, 1.0), 2), skin.with_alpha(color, 0.75))

		var cells = [names.row_label(enc, _view, _group, s), Fmt.short(value), Fmt.pct(share), Fmt.short(Fmt.per_sec(value, enc.duration))]
		if heal:
			var top = Model.sorted_dim(s, Model.DIM_SOURCE, ov)
			var lead = "—"
			if top.size() > 0:
				lead = names.source_label(_view, top[0][0])
			elif s.src != "":
				lead = names.source_label(_view, s.src)
			cells += [Fmt.count(s.hits), lead]
		else:
			cells += [Fmt.pct(float(s.crits) / s.hits) if s.hits > 0 else "—", Fmt.count(s.hits), Fmt.short(s.max_hit)]
		var cx = RIGHT_X
		for c in range(cells.size()):
			var text_col = c == 0 or (heal and c == cells.size() - 1)
			var pad = 12.0 if c == 0 else 0.0
			var extra = 14.0 if heal and c == cells.size() - 1 else 0.0
			var col = skin.TEXT if c <= 1 else skin.TEXT_DIM
			skin.text(self, Rect2(cx + pad + extra, ry, cols[c] - pad - 6.0, TABLE_ROW_H), str(cells[c]), skin.FONT_BODY, col, 0 if text_col else 2)
			cx += cols[c]

	if rows.size() > max_rows:
		skin.text(self, Rect2(RIGHT_X + 12.0, y + (max_rows + 1) * TABLE_ROW_H - 3.0, RIGHT_W - 12.0, 14.0),
			Strings.more_items(rows.size() - max_rows), skin.FONT_TINY, skin.TEXT_FAINT)


# ---------------------------------------------------------------- 曲线

func _chart(r: Rect2, enc, rows: Array, sel) -> void:
	_chart_rect = r
	hit(r, "chart", null, HIT_PASSIVE)
	var ov = tracker.overkill
	var shown = rows.slice(0, int(min(6, rows.size())) - 1) if rows.size() > 0 else []
	if sel != null and not shown.has(sel):
		shown.append(sel)
	var n = 2
	for s in shown:
		n = int(max(n, s.metric_series(ov).size()))
	# 数据没变就不重画曲线（实时的那段每秒才多一个点）
	var sig = "%s|%d|%d|%d|%s|%s|%s" % [str(enc), n, _view, _group, str(_key_of(sel)) if sel != null else "-", str(r.size), str(ov)]
	for s in shown:
		sig += "|" + s.key + ":" + str(s.metric(ov))
	if sig != _chart_sig:
		_chart_sig = sig
		_chart_series = []
		var peak := 0.0
		for s in shown:
			var sm = _smooth(s.metric_series(ov), n, SMOOTH)
			for v in sm:
				if v > peak:
					peak = v
			_chart_series.append([sm, _row_colors.get(s.key, skin.TEXT_DIM), s == sel, tracker.names.row_label(enc, _view, _group, s)])
		_chart_n = n
		_chart_ymax = peak * 1.12 if peak > 0.0 else 1.0
		_chart_peak = Strings.peak(Fmt.short(peak))
		_chart_dur = Fmt.dur(enc.duration)
		pane("chart", r, true)
		pane("chart_hover", r, true)
	else:
		pane("chart", r, false)
		pane("chart_hover", r, false)


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


func _plot_size(size: Vector2) -> Vector2:
	return Vector2(max(8.0, size.x - CH_L - CH_R), max(8.0, size.y - CH_T - CH_B))


# 曲线：每个来源一条「每秒数值」曲线，选中的那条加粗。不铺面积色——半透明的面积会盖住别的线
func _paint_chart(ci: CanvasItem) -> void:
	var size = ci.rect_size
	var plot = _plot_size(size)
	skin.box(ci, Rect2(Vector2.ZERO, size), skin.INSET, skin.RADIUS_CONTROL)
	# 网格：25% / 50% / 75%，外加一条零线
	for k in range(1, 4):
		ci.draw_rect(Rect2(CH_L, CH_T + plot.y * k / 4.0, plot.x, 1), skin.DIVIDER)
	ci.draw_rect(Rect2(CH_L, CH_T + plot.y, plot.x, 1), Color(1, 1, 1, 0.10))
	var has_sel = false
	for s in _chart_series:
		if s[2]:
			has_sel = true
	# 先画普通的，选中的最后画、压在最上面
	for pass_ in range(2):
		for s in _chart_series:
			if s[2] != (pass_ == 1):
				continue
			var pts = _sample(s[0], plot)
			if pts.size() < 2:
				continue
			var c = s[1] if s[2] else skin.with_alpha(s[1], 0.55 if has_sel else 0.85)
			ci.draw_polyline(pts, c, 2.25 if s[2] else 1.25, true)
	skin.text(ci, Rect2(CH_L, 3, size.x * 0.5, 16), _chart_peak, skin.FONT_TINY, skin.TEXT_DIM)
	skin.text(ci, Rect2(CH_L, size.y - CH_B + 1.0, 80, 16), "0:00", skin.FONT_TINY, skin.TEXT_FAINT)
	skin.text(ci, Rect2(size.x - CH_R - 80.0, size.y - CH_B + 1.0, 80, 16), _chart_dur, skin.FONT_TINY, skin.TEXT_FAINT, 2)


# 数据点换成图上的坐标；点比像素多就按宽度重采样（每两个单位一个点）
func _sample(v: Array, plot: Vector2) -> PoolVector2Array:
	var pts := PoolVector2Array()
	var n = v.size()
	if n == 0:
		return pts
	var m = int(clamp(n, 2, max(2, int(plot.x / 2.0))))
	for j in range(m):
		var pos = 0.0 if n == 1 else j * (n - 1) / float(m - 1)
		var i0 = int(min(int(pos), n - 1))
		var i1 = int(min(i0 + 1, n - 1))
		var val = float(v[i0]) + (float(v[i1]) - float(v[i0])) * (pos - i0)
		pts.append(Vector2(CH_L + plot.x * j / float(m - 1), CH_T + plot.y * (1.0 - clamp(val / _chart_ymax, 0.0, 1.0))))
	return pts


# 光标在曲线上：一条竖线和读数。有选中的看选中那条，没有就看这一秒最高的那条
func _paint_chart_hover(ci: CanvasItem) -> void:
	if _chart_hover < 0 or _chart_series.empty():
		return
	var size = ci.rect_size
	var plot = _plot_size(size)
	var n = _chart_n
	var idx = int(clamp(_chart_hover, 0, n - 1))
	var pick = -1
	for i in range(_chart_series.size()):
		if _chart_series[i][2]:
			pick = i
	if pick < 0:
		var best = -1.0
		for i in range(_chart_series.size()):
			var vals = _chart_series[i][0]
			if idx < vals.size() and vals[idx] > best:
				best = vals[idx]
				pick = i
	if pick < 0:
		return
	var s = _chart_series[pick]
	var val = s[0][idx] if idx < s[0].size() else 0.0
	var x = CH_L + plot.x * (idx / float(n - 1) if n > 1 else 0.0)
	var y = CH_T + plot.y * (1.0 - clamp(val / _chart_ymax, 0.0, 1.0))
	ci.draw_rect(Rect2(round(x), CH_T, 1, plot.y), Color(1, 1, 1, 0.28))
	skin.box(ci, Rect2(x - 4.0, y - 4.0, 8, 8), s[1], 4.0)
	# 每秒一个点：下标就是距本段开始的秒数
	skin.text(ci, Rect2(size.x * 0.3, 3, size.x * 0.7 - CH_R, 16), "%s  %s  %s/s" % [Fmt.dur(idx), s[3], Fmt.short(val)],
		skin.FONT_TINY, skin.TEXT, 2)


# ---------------------------------------------------------------- 拆分

func _breakdown(y: float, enc, sel, session) -> void:
	var ov = tracker.overkill
	var names = tracker.names
	# 没选中任何行时看全队：各玩家的汇总加起来，按玩家那一套维度拆
	var src = sel
	var dims = Model.dims_for(_view, _group)
	if sel == null:
		src = Model.everyone(enc, _view)
		dims = Model.dims_for(_view, Model.GROUP_PLAYER)
	if not dims.has(_dim):
		_dim = dims[0] if dims.size() > 0 else ""
	_brk_dim = _dim
	_brk_dims = dims
	var tabs_w = 0.0
	if dims.size() > 0:
		var labels := []
		for dname in dims:
			labels.append(Strings.tab_label(dname))
		tabs_w = segmented(RIGHT_X, y, 60.0, 26.0, labels, dims.find(_dim), "dim")
	if src != null:
		var who = names.row_label(enc, _view, _group, sel) if sel != null else Strings.all_sources()
		skin.text(self, Rect2(RIGHT_X + tabs_w + 10.0, y, RIGHT_W - DONUT - 16.0 - tabs_w - 10.0, 26.0),
			who + " — " + Strings.view_label(_view), skin.FONT_SMALL, skin.TEXT_DIM, 2)
	y += 30.0

	var tw = RIGHT_W - DONUT - 16.0
	_brk_detailed = _dim == Model.DIM_SOURCE or _dim == Model.DIM_TARGET or _dim == Model.DIM_FORM or _dim == Model.DIM_CLASS
	_brk_cols = [138.0, 66.0, 52.0, 48.0, 46.0, tw - 350.0] if _brk_detailed else [tw - 150.0, 90.0, 60.0]
	var heads = [Strings.col_item(), Strings.col_total(), Strings.col_share()]
	if _brk_detailed:
		heads += [Strings.col_hits(), Strings.col_dodge() if _view == Model.VIEW_TAKEN else Strings.col_crit(), Strings.col_max()]
	if src != null:
		var x = RIGHT_X
		for c in range(heads.size()):
			var pad = 14.0 if c == 0 else 0.0
			skin.text(self, Rect2(x + pad, y, _brk_cols[c] - pad - 4.0, BREAK_ROW_H), heads[c], skin.FONT_TINY, skin.TEXT_FAINT, 0 if c == 0 else 2)
			x += _brk_cols[c]

	_mi = Model.ROW_TOTAL if ov else Model.ROW_EFF
	_brk_rows = Model.sorted_dim(src, _dim, ov) if src != null and _dim != "" else []
	var values := []
	_brk_sum = 0.0
	for r in _brk_rows:
		var v = float(r[1][_mi])
		values.append(v)
		_brk_sum += v

	if src == null:
		_donut.hide()
		_brk_highlight = -1
		skin.text(self, Rect2(RIGHT_X, y, RIGHT_W, BREAK_ROW_H), Strings.no_breakdown(), skin.FONT_SMALL, skin.TEXT_DIM)
	else:
		# 拆分行和环上的一段互相高亮：指着哪边都行。先定环：哪些行单独成段、哪些并进「其他」，表里的色点跟着它
		var hover_row = int(_hover_key[1]) if _hover_key != null and _hover_key[0] == "brk" else -1
		_brk_highlight = hover_row if hover_row >= 0 and hover_row < _brk_rows.size() else _donut.hovered
		var donut_rect = Rect2(RIGHT_X + RIGHT_W - DONUT, y - 4.0, DONUT, DONUT)
		hit(donut_rect, "donut", null, HIT_PASSIVE)
		var value = src.metric(ov)
		_donut.paint(self, skin, donut_rect, values, Fmt.short(value), Fmt.short(Fmt.per_sec(value, enc.duration)) + "/s", _brk_highlight)
		if _brk_rows.empty():
			skin.text(self, Rect2(RIGHT_X + 14.0, y + BREAK_ROW_H, tw, BREAK_ROW_H), Strings.no_breakdown(), skin.FONT_SMALL, skin.TEXT_DIM)

	# 一屏 BREAK_ROWS 行，多的用滚轮翻；换了段 / 视图 / 维度 / 选中的行就回到顶上。
	# 视口只和行一样高：行下面的空白照样是「点空白处取消选中」
	var key = "%s|%d|%d|%d|%s|%s" % [session.source_path, enc.index, _view, _group, _dim, str(_source) if sel != null else "-"]
	_brk_rect = Rect2(RIGHT_X - 2.0, y + BREAK_ROW_H, tw + 14.0, min(_brk_rows.size(), BREAK_ROWS) * BREAK_ROW_H)
	_brk.setup(_brk_rows.size(), _brk_rect.size.y)
	if key != _brk_key:
		_brk_key = key
		_brk.to_top()
	pane("break", _brk_rect)
	var first = _brk.first()
	for slot in range(_brk.visible_rows()):
		var i = first + slot
		if i >= _brk_rows.size():
			break
		var r = Rect2(_brk_rect.position.x + 2.0, _brk_rect.position.y + i * BREAK_ROW_H - _brk.offset, tw, BREAK_ROW_H).clip(_brk_rect)
		if r.size.y > 0.0:
			hit(r, "brk", i, HIT_PASSIVE)
	_thumb_hit(_brk, _brk_rect, "break")
	if _brk_rows.size() > BREAK_ROWS:
		var rng = _brk.visible_range()
		skin.text(self, Rect2(RIGHT_X + 14.0, y + (BREAK_ROWS + 1) * BREAK_ROW_H, tw - 14.0, BREAK_ROW_H),
			"%d–%d / %d" % [rng[0], rng[1], _brk_rows.size()], skin.FONT_TINY, skin.TEXT_FAINT)


func _paint_break(ci: CanvasItem) -> void:
	var names = tracker.names
	var other_hot = _brk_highlight == Donut.OTHER
	var tw = RIGHT_W - DONUT - 16.0
	var first = _brk.first()
	for slot in range(_brk.visible_rows()):
		var i = first + slot
		if i >= _brk_rows.size():
			break
		var row = _brk_rows[i]
		var b = row[1]
		var y = i * BREAK_ROW_H - _brk.offset
		if i == _brk_highlight or (other_hot and i >= _donut.folded):
			skin.box(ci, Rect2(0, y, tw + 4.0, BREAK_ROW_H), skin.HOVER, 4.0)
		var dot = skin.palette(i) if i < _donut.folded else skin.OTHER_SLICE
		skin.box(ci, Rect2(4, y + BREAK_ROW_H * 0.5 - 3.5, 7, 7), dot, 3.0)
		var v = float(b[_mi])
		var cells = [names.dim_label(_view, _brk_dim, row[0]), Fmt.short(v), Fmt.pct(v / _brk_sum if _brk_sum > 0.0 else 0.0)]
		if _brk_detailed:
			var hits = int(b[Model.ROW_HITS])
			var rate = Fmt.pct(float(b[Model.ROW_CRITS]) / hits) if hits > 0 and _view != Model.VIEW_HEAL else "—"
			cells += [Fmt.count(hits), rate, Fmt.short(float(b[Model.ROW_MAX]))]
		var cx = 2.0
		for c in range(cells.size()):
			var pad = 14.0 if c == 0 else 0.0
			var col = skin.TEXT if c <= 1 else skin.TEXT_DIM
			skin.text(ci, Rect2(cx + pad, y, _brk_cols[c] - pad - 4.0, BREAK_ROW_H), str(cells[c]), skin.FONT_SMALL, col, 0 if c == 0 else 2)
			cx += _brk_cols[c]
	_paint_thumb(ci, _brk, "break")


# ---------------------------------------------------------------- 逐条事件

# 这一段的原始事件按时间排，跟着当前视图（输出看伤害、承伤看挨打、治疗看恢复）和表格里选中的行筛选。
# 实时那段从内存里拿、跟着最新的往下滚；别的段从日志里读
func _events_pane(y: float, enc, is_live: bool, session, sel) -> void:
	var x = RIGHT_X
	var bottom = H - PAD
	var wait = ""
	var capped = 0
	var source = null
	var source_id = ""
	var names = tracker.names

	if is_live:
		if tracker.live_events_enc == enc:
			source = tracker.live_events
			source_id = "live:%d" % tracker.live_events_gen
		else:
			source = []
			source_id = "none"
		if tracker.live_events_capped:
			capped = EventPages.MAX_EVENTS
	else:
		var path = session.source_path if _imported != null else (tracker.writer.path if tracker.writer != null else "")
		if path == "":
			wait = Strings.events_no_log()
		else:
			var key = "%s|%d|%d" % [path, enc.index, enc.wave]
			if _ev_page != null and _ev_page.key == key:
				if _ev_page.error == "notFound":
					wait = Strings.events_not_found()
				elif _ev_page.error != "":
					wait = Strings.load_failed(_ev_page.error)
				else:
					source = _ev_page.events
					source_id = "page:" + key
					if _ev_page.capped:
						capped = EventPages.MAX_EVENTS
			else:
				_request_page(path, enc.index, enc.wave, key)
				wait = Strings.events_loading()

	# 按视图和选中的行筛；实时那段只往后接着筛新来的
	_ev_kind = "T" if _view == Model.VIEW_TAKEN else ("H" if _view == Model.VIEW_HEAL else "D")
	_ev_t0 = enc.t0
	_ev_enc = enc
	_ev_multi = enc.players().size() > 1
	var fkey = "%s|%d|%s|%s" % [str(enc), _view, str(_group), str(_key_of(sel)) if sel != null else "-"]
	if source == null:
		_ev_shown = []
		_ev_scanned = 0
		_ev_filter_key = ""
	else:
		if fkey + source_id != _ev_filter_key or source.size() < _ev_scanned:
			_ev_filter_key = fkey + source_id
			_ev_shown = []
			_ev_scanned = 0
		var sp = sel.player if sel != null else -1
		var ss = sel.src if sel != null and _group == Model.GROUP_SOURCE else ""
		for i in range(_ev_scanned, source.size()):
			var e = source[i]
			if e[0] != _ev_kind:
				continue
			if sp >= 0 and (int(e[2]) != sp or (ss != "" and str(e[3]) != ss)):
				continue
			_ev_shown.append(e)
		_ev_scanned = source.size()

	# 标题行：谁 · 视图 · 条数
	var who = names.row_label(enc, _view, _group, sel) if sel != null else Strings.all_sources()
	skin.text(self, Rect2(x + 2.0, y, RIGHT_W * 0.6, 22.0), Strings.events_header(who, Strings.view_label(_view), _ev_shown.size()), skin.FONT_SMALL, skin.TEXT)
	if capped > 0:
		skin.text(self, Rect2(x + RIGHT_W * 0.5, y, RIGHT_W * 0.5 - 4.0, 22.0), Strings.events_capped(capped), skin.FONT_TINY, skin.TEXT_FAINT, 2)
	y += 24.0

	# 列头
	var cols = _ev_cols()
	var heads = []
	if _ev_kind == "D":
		heads = [Strings.col_time(), Strings.col_source(), Strings.col_target(), Strings.col_amount(), Strings.col_crit_short(), Strings.col_form()]
	elif _ev_kind == "T":
		heads = [Strings.col_time(), Strings.col_source(), Strings.col_victim(), Strings.col_amount(), Strings.col_result()]
	else:
		heads = [Strings.col_time(), Strings.col_recipient(), Strings.col_source(), Strings.col_amount()]
	var cx = x
	for c in range(heads.size()):
		skin.text(self, Rect2(cx + 6.0, y, cols[c] - 10.0, 18.0), heads[c], skin.FONT_TINY, skin.TEXT_FAINT, _ev_align(c))
		cx += cols[c]
	y += 20.0

	# 列表：换了段 / 视图 / 选中的行就重新定位——实时的看最新，结束的从头看
	var key = fkey + "|" + str(is_live)
	var follow = _evs.at_end()
	_ev_rect = Rect2(x, y, RIGHT_W, max(0.0, bottom - y))
	_evs.setup(_ev_shown.size(), _ev_rect.size.y)
	if key != _ev_key:
		_ev_key = key
		if is_live:
			_evs.to_end()
		else:
			_evs.to_top()
	elif is_live and follow:
		_evs.to_end()
	pane("events", _ev_rect)
	_thumb_hit(_evs, _ev_rect, "events")

	if wait != "" or _ev_shown.empty():
		skin.text(self, Rect2(x, y + 30.0, RIGHT_W, 24.0), wait if wait != "" else Strings.events_empty(), skin.FONT_SMALL, skin.TEXT_DIM, 1)


func _ev_cols() -> Array:
	if _ev_kind == "T":
		return EV_TAKEN_COLS
	if _ev_kind == "H":
		return EV_HEAL_COLS
	return EV_OUT_COLS


# 数值右对齐，暴击标记居中，其余左对齐
func _ev_align(c: int) -> int:
	if _ev_kind == "D":
		return 2 if c == 3 else (1 if c == 4 else 0)
	return 2 if c == 3 else 0


func _paint_events(ci: CanvasItem) -> void:
	var vw = ci.rect_size.x
	var cols = _ev_cols()
	var names = tracker.names
	var ov = tracker.overkill
	var first = _evs.first()
	for slot in range(_evs.visible_rows()):
		var i = first + slot
		if i >= _ev_shown.size():
			break
		var e = _ev_shown[i]
		var y = i * EV_ROW_H - _evs.offset
		if i % 2 == 1:
			ci.draw_rect(Rect2(0, y, vw - 8.0, EV_ROW_H), Color(1, 1, 1, 0.03))
		var cells = []
		var colors = []
		var t = _ev_time(float(e[1]))
		var who = names.player_label(int(e[2]), _ev_enc)
		if _ev_kind == "D":
			var src = names.source_label(0, str(e[3]))
			if _ev_multi:
				src = who + " " + src
			var form = names.dim_label(0, Model.DIM_FORM, str(e[8]) if e.size() > 8 and str(e[8]) != "" else Model.FORM_HIT)
			if e.size() > 9 and str(e[9]) != "":
				form += " · " + names.dim_label(0, Model.DIM_CLASS, str(e[9]))
			var amount = float(e[5]) if ov else float(e[6])
			var crit = (int(e[7]) & Model.F_CRIT) != 0
			cells = [t, src, names.source_label(0, str(e[4])), Fmt.count(int(round(amount))), Strings.crit_mark() if crit else "", form]
			colors = [skin.TEXT_DIM, skin.TEXT, skin.TEXT, skin.TEXT, skin.WARNING, skin.TEXT_DIM]
		elif _ev_kind == "T":
			var flags = int(e[6])
			var outcome = Model.OUTCOME_HIT
			if (flags & Model.F_DODGE) != 0:
				outcome = Model.OUTCOME_DODGE
			elif (flags & Model.F_PROTECTED) != 0:
				outcome = Model.OUTCOME_PROTECTED
			cells = [t, names.source_label(1, str(e[3])), who, Fmt.count(int(round(float(e[4])))), names.dim_label(1, Model.DIM_OUTCOME, outcome)]
			colors = [skin.TEXT_DIM, skin.TEXT, skin.TEXT, skin.TEXT, skin.TEXT_DIM]
		else:
			cells = [t, who, names.source_label(2, str(e[3])), Fmt.count(int(round(float(e[4]))))]
			colors = [skin.TEXT_DIM, skin.TEXT, skin.TEXT, skin.TEXT]
		var cx = 0.0
		for c in range(cells.size()):
			skin.text(ci, Rect2(cx + 6.0, y, cols[c] - 10.0, EV_ROW_H), str(cells[c]), skin.FONT_SMALL, colors[c], _ev_align(c))
			cx += cols[c]
	_paint_thumb(ci, _evs, "events")


func _ev_time(t: float) -> String:
	var s = max(0.0, t - _ev_t0)
	return "%d:%04.1f" % [int(s / 60.0), fmod(s, 60.0)]


func _request_page(path: String, index: int, wave: int, key: String) -> void:
	if _ev_thread != null or _ev_loading == key:
		return
	if tracker.writer != null and path == tracker.writer.path:
		tracker.writer.flush()   # 本局的日志：先把还没落盘的写下去
	_ev_loading = key
	_ev_thread = Thread.new()
	if _ev_thread.start(self, "_page_worker", [path, index, wave, key]) != OK:
		_ev_thread = null
		_ev_loading = ""
		_ev_page = {"key": key, "events": [], "error": "thread", "capped": false}


# 后台线程：从头解析到那一段结束，挑出它的事件。解析器是纯 GDScript，不碰场景树
func _page_worker(args):
	var r = EventPages.read(args[0], args[1], args[2])
	r["key"] = args[3]
	call_deferred("_page_finished", r)


func _page_finished(r) -> void:
	if _ev_thread != null:
		_ev_thread.wait_to_finish()
		_ev_thread = null
	_ev_loading = ""
	_ev_page = r
	if r.error != "":
		ModLoaderLog.warning("从日志读第 %s 段的事件失败：%s" % [str(r.key), str(r.error)], "DPSLove-CombatTracker")
	mark_dirty()


# ---------------------------------------------------------------- 导入

func _picker_pane() -> void:
	var x = RIGHT_X
	var y = BODY_Y
	var h = H - BODY_Y - PAD
	skin.box(self, Rect2(x, y, RIGHT_W, h), skin.PANEL, 6.0)
	skin.text(self, Rect2(x + 12.0, y + 6.0, RIGHT_W - 110.0, 24.0), Strings.pick_log(), skin.FONT_BODY, skin.TEXT, 0, true)
	var cancel = Strings.btn_cancel()
	var bw = max(64.0, skin.button_width("", cancel, 12.0))
	button(Rect2(x + RIGHT_W - bw - 8.0, y + 6.0, bw, 24), "", cancel, skin.SUBTLE, "cancel")

	_pick_rect = Rect2(x + 4.0, y + 38.0, RIGHT_W - 8.0, h - 42.0)
	_picks.setup(_files.size(), _pick_rect.size.y)
	pane("picks", _pick_rect)
	var first = _picks.first()
	for slot in range(_picks.visible_rows()):
		var i = first + slot
		if i >= _files.size():
			break
		var r = Rect2(_pick_rect.position.x, _pick_rect.position.y + i * PICK_ROW_H - _picks.offset, _pick_rect.size.x - 9.0, PICK_ROW_H).clip(_pick_rect)
		if r.size.y > 0.0:
			hit(r, "file", i)
	_thumb_hit(_picks, _pick_rect, "picks")
	if _files.empty():
		skin.text(self, Rect2(x, y + 60.0, RIGHT_W, 24.0), Strings.no_logs(), skin.FONT_SMALL, skin.TEXT_DIM, 1)


func _paint_picks(ci: CanvasItem) -> void:
	var vw = ci.rect_size.x
	var current = tracker.writer.path if tracker.writer != null else ""
	var first = _picks.first()
	for slot in range(_picks.visible_rows()):
		var i = first + slot
		if i >= _files.size():
			break
		var f = _files[i]
		var y = i * PICK_ROW_H - _picks.offset
		if hot("file", i):
			skin.box(ci, Rect2(0, y + 1.0, vw - 6.0, PICK_ROW_H - 2.0), skin.HOVER, 4.0)
		var name = f.name + (Strings.current_file_tag() if f.path == current else "")
		skin.text(ci, Rect2(10, y, vw - 220.0, PICK_ROW_H), name, skin.FONT_BODY, skin.TEXT)
		skin.text(ci, Rect2(vw - 206.0, y, 70, PICK_ROW_H), _size_text(int(f.size)), skin.FONT_SMALL, skin.TEXT_DIM, 2)
		skin.text(ci, Rect2(vw - 126.0, y, 112, PICK_ROW_H), _mtime_text(int(f.mtime)), skin.FONT_SMALL, skin.TEXT_DIM, 2)
	_paint_thumb(ci, _picks, "picks")


func _refresh_files() -> void:
	_picks.to_top()
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
	_sel = null
	_list.to_top()
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


# ---------------------------------------------------------------- 子画布

func _paint_pane(id: String, ci: CanvasItem) -> void:
	match id:
		"list":
			_paint_list(ci)
		"chart":
			_paint_chart(ci)
		"chart_hover":
			_paint_chart_hover(ci)
		"break":
			_paint_break(ci)
		"events":
			_paint_events(ci)
		"picks":
			_paint_picks(ci)


# ---------------------------------------------------------------- 鼠标

func _pointer_moved(local: Vector2) -> void:
	if _donut.update_hover(local):
		update()
	var idx = -1
	if _chart_rect.size.x > 0.0 and _chart_rect.has_point(local) and not _chart_series.empty():
		var plot = _plot_size(_chart_rect.size)
		var t = clamp((local.x - _chart_rect.position.x - CH_L) / plot.x, 0.0, 1.0)
		idx = int(round(t * (_chart_n - 1)))
	if idx != _chart_hover:
		_chart_hover = idx
		_panes["chart_hover"].update()


func _on_wheel(local: Vector2, dir: int) -> bool:
	if _picker_open and _pick_rect.has_point(local):
		_picks.scroll_by(dir * 3.0 * PICK_ROW_H)
	elif _list_rect.has_point(local):
		_list.scroll_by(dir * 3.0 * ROW_H)
	elif _brk_rect.has_point(local):
		_brk.scroll_by(dir * 3.0 * BREAK_ROW_H)
	elif _ev_rect.has_point(local):
		_evs.scroll_by(dir * 3.0 * EV_ROW_H)
	else:
		return false
	return true


func _on_drag(action: String, arg, _local: Vector2, delta: Vector2) -> void:
	if action != "thumb":
		return
	match str(arg):
		"list":
			_list.drag_thumb(delta.y)
		"break":
			_brk.drag_thumb(delta.y)
		"events":
			_evs.drag_thumb(delta.y)
		"picks":
			_picks.drag_thumb(delta.y)


func _on_action(action: String, arg) -> void:
	match action:
		"close":
			visible = false
		"settings":
			root.open_settings()
		"export":
			var path = tracker.export_csv(_shown, "live" if _shown_live else "import")
			_set_status(Strings.exported(path.get_file()) if path != "" else Strings.export_failed())
		"folder":
			open_log_folder()
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
			_sel = null
			_list.to_top()
		"select":
			var i = int(arg)
			if i >= 0 and i < _items.size():
				var e = _items[i]
				_sel = null if _imported == null and e == tracker.session.current else e
				_picker_open = false
		"up":
			_list.page(-1)
		"down":
			_list.page(1)
		"view":
			_view = int(arg)
		"group":
			if int(arg) != _group:
				_group = int(arg)
				_has_source = false
				_source = null
		"row":
			if _has_source and _same(_source, arg):
				_has_source = false
			else:
				_source = arg
				_has_source = true
		"deselect":
			_has_source = false
		"dim":
			if int(arg) >= 0 and int(arg) < _brk_dims.size():
				_dim = _brk_dims[int(arg)]
		"mode_chart":
			_events_mode = false
		"mode_events":
			_events_mode = true
			_ev_key = ""   # 回来时重新定位滚动


func open_log_folder() -> void:
	var dir = tracker.log_dir()
	var d = Directory.new()
	if not d.dir_exists(dir):
		d.make_dir_recursive(dir)
	OS.shell_open(ProjectSettings.globalize_path(dir))


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
