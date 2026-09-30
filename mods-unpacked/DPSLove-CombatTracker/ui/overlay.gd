extends "window_base.gd"

# 实时浮窗：竖向的多级列表。
#   多人：玩家 → 分类 → 各个来源
#   单人：分类 → 各个来源（只有一名玩家，省掉玩家这一级）
# 分类在输出里是武器 / 物品 / 其他，承伤里是敌人 / 精英 / Boss / 其他，治疗里是属性回复 / 物品 / 消耗品 / 其他
# （见 names.category_of）。
#
# 每一行是一条斜切的色条，长度按数值，整棵树用同一把尺子（多人时最大的那名玩家、单人时最大的那一类是满格）；
# 行上写名字、每秒、总量、占比（占这一段全部的）。点玩家或分类那一行折叠 / 展开，点来源那一行打开它的拆分窗口。
#
# 标题栏、配色、字体和交互沿用 TBH Combat Tracker 的浮窗：平时只有描边的文字和色条浮在游戏上，
# 鼠标移上来，半透明的背景和标题栏按钮才淡入。整个窗口按住就能拖。
# 只看当前这一波；波次之间（商店里）显示刚结束的那一波。已经结束的段在战斗记录里看。

const Model = preload("../core/model.gd")
const Strings = preload("../core/strings.gd")
const Fmt = preload("../core/fmt.gd")
const AaMesh = preload("aa_mesh.gd")

# 版式常量：TBH 的界面单位（窗口整体再按 skin.scale 放大）
const W = 350.0
const PAD = 10.0
const HEADER_H = 30.0
const ROW_H = [22.0, 18.0, 16.0]   # 按缩进深度
const MORE_H = 15.0
const INDENT = 14.0
const GAP = 2.0
const GROUP_GAP = 5.0              # 两名玩家之间多空一点
const COL_PCT = 40.0
const COL_TOTAL = 48.0
const COL_DPS = 52.0
const ICON = 13.0
# 背景和按钮淡入 / 淡出用多久
const FADE_SECONDS = 0.15

var view: int = Model.VIEW_OUT
var force_frame := false     # 自测截图、预览图：背景和按钮一直显示

# 这一帧的行：{kind: player / cat / src / more, depth, label, value, per_sec, share, frac, color, key, open, src}
var _rows := []
# 折叠起来的节点："视图|玩家"、"视图|玩家|分类"
var _collapsed := {}
var _title := ""
var _stats := ""
var _header_enc = null
var _header_view := -1
var _header_w := 0.0
var _flash := ""
var _flash_until := 0
var _fade := 0.0
var _mesh = AaMesh.new()


func _init() -> void:
	pos_keys = ["OverlayX", "OverlayY"]
	drag_anywhere = true
	refresh_interval = 0.2


# 标题栏上短暂显示一条消息（F11 导出的结果）
func flash(file: String) -> void:
	_flash = Strings.exported(file) if file != "" else Strings.export_failed()
	_flash_until = OS.get_ticks_msec() + 4000
	mark_dirty()


func current_encounter():
	var s = tracker.session
	if s.current != null:
		return s.current
	if s.encounters.size() > 0:
		return s.encounters.back()
	return null


func _skew() -> float:
	return clamp(float(tracker.config.value("SkewDegrees")), -60.0, 60.0)


# 鼠标在浮窗上（或正拖着它、或在设置里预览背景）时淡入背景和按钮，否则淡出
func _tick(delta: float) -> bool:
	var shown = force_frame or root.is_hovered(self) or _pressing or root.preview_opacity >= 0.0
	var target = 1.0 if shown else 0.0
	if _fade == target:
		return false
	_fade = move_toward(_fade, target, delta / FADE_SECONDS)
	return true


func _notification(what: int) -> void:
	# 收起再出现时从「没有背景」开始，不闪一下
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		_fade = 0.0


# ===========================================================================
# 排版：先把树摊平成一行一行
# ===========================================================================

func _layout() -> void:
	var enc = current_encounter()
	var ov = tracker.overkill
	var names = tracker.names
	_rows = []
	var total = enc.total(view, ov) if enc != null else 0.0
	var dur = enc.duration if enc != null else 0.0
	var max_rows = int(clamp(int(tracker.config.value("MaxRows")), 1, 12))

	if enc != null:
		var multi = enc.players().size() > 1
		var groups := []
		var ruler := 0.0
		for ps in Model.sorted_rows(enc, view, Model.GROUP_PLAYER, ov):
			var cats = _categories(enc, ps.player)
			groups.append([ps, cats])
			if multi:
				ruler = max(ruler, ps.metric(ov))
			else:
				for c in cats:
					ruler = max(ruler, c[1])
		for g in groups:
			var ps = g[0]
			var depth = 0
			if multi:
				var pkey = "%d|%d" % [view, ps.player]
				var popen = not _collapsed.has(pkey)
				_rows.append({"kind": "player", "depth": 0, "label": names.player_label(ps.player, enc),
					"value": ps.metric(ov), "color": names.player_color(ps.player), "key": pkey, "open": popen})
				if not popen:
					continue
				depth = 1
			for c in g[1]:
				var ckey = "%d|%d|%s" % [view, ps.player, c[0]]
				var copen = not _collapsed.has(ckey)
				_rows.append({"kind": "cat", "depth": depth, "label": names.category_label(c[0]),
					"value": c[1], "color": names.category_color(c[0]), "key": ckey, "open": copen})
				if not copen:
					continue
				var srcs = c[2]
				for i in range(min(srcs.size(), max_rows)):
					var s = srcs[i]
					_rows.append({"kind": "src", "depth": depth + 1, "label": names.source_row_label(enc, view, s),
						"value": s.metric(ov), "color": names.row_color(view, Model.GROUP_SOURCE, s), "key": s.key,
						"src": s.src})
				if srcs.size() > max_rows:
					_rows.append({"kind": "more", "depth": depth + 1, "label": Strings.more_items(srcs.size() - max_rows)})
		for r in _rows:
			if r.kind == "more":
				continue
			r["per_sec"] = Fmt.per_sec(r.value, dur)
			r["share"] = r.value / total if total > 0.0 else 0.0
			r["frac"] = clamp(r.value / ruler, 0.0, 1.0) if ruler > 0.0 else 0.0

	# 标题栏要放下段名、统计和右边的按钮：放不下时窗口按标题加宽。取整到 20，
	# 同一段里只加宽不缩回，按钮不会跟着数字的位数左右跳
	_title = names.encounter_title(enc)
	_stats = "%s · %s · %s/s" % [Fmt.dur(dur), Fmt.short(total), Fmt.short(Fmt.per_sec(total, dur))]
	var buttons = 6.0 + 28.0 + 30.0 + _pill_w(Strings.view_label(view)) + 6.0
	var need = 36.0 + skin.text_width(_title, skin.FONT_BODY, true) + skin.text_width("   " + _stats, skin.FONT_BODY) + 8.0 + buttons
	need = min(ceil(need / 20.0) * 20.0, 600.0)
	if enc != _header_enc or view != _header_view:
		_header_enc = enc
		_header_view = view
		_header_w = 0.0
	_header_w = max(_header_w, need)

	var h = HEADER_H + 4.0
	if _rows.empty():
		h += ROW_H[0]
	for i in range(_rows.size()):
		var r = _rows[i]
		if r.kind == "player" and i > 0:
			h += GROUP_GAP
		h += _row_h(r) + GAP
	rect_size = Vector2(max(W, _header_w), h + 6.0)


# 一名玩家的来源按分类归拢：[[分类, 合计, [来源统计…（从大到小）]], …]，分类也从大到小
func _categories(enc, p: int) -> Array:
	var ov = tracker.overkill
	var by := {}
	for s in enc.by_source[view].values():
		if s.player != p:
			continue
		var c = tracker.names.category_of(view, s.src)
		var e = by.get(c)
		if e == null:
			e = [c, 0.0, []]
			by[c] = e
		e[1] += s.metric(ov)
		e[2].append(s)
	var sorter = Model.BctSorter.new()
	sorter.overkill = ov
	var out = by.values()
	for e in out:
		e[2].sort_custom(sorter, "desc")
	out.sort_custom(self, "_cat_desc")
	return out


func _cat_desc(a, b) -> bool:
	if a[1] == b[1]:
		return a[0] < b[0]
	return a[1] > b[1]


func _row_h(r) -> float:
	if r.kind == "more":
		return MORE_H
	return ROW_H[int(min(r.depth, 2))]


func _pill_w(label: String) -> float:
	return max(44.0, skin.button_width("", label, 8.0))


# ===========================================================================
# 绘制
# ===========================================================================

func _paint() -> void:
	var w = rect_size.x
	var op = opacity()
	skin.window_frame(self, Rect2(Vector2.ZERO, rect_size), skin.with_alpha(skin.OVERLAY_BG, op), _fade, op * 1.6)
	# 整窗可拖：最先登记，按钮和行压在它上面
	hit(Rect2(Vector2.ZERO, rect_size), "bg", null, HIT_DRAG_WINDOW | HIT_PASSIVE)

	# ---- 标题栏：按钮一组，跟着背景淡入淡出 ----
	var a = _fade
	button(Rect2(6, 4, 26, 22), "history", "", skin.GHOST, "log", null,
		Strings.tip_log(root.key_label("ToggleMainPanel")), false, true, a)
	var right = w - 6.0
	button(Rect2(right - 26.0, 4, 26, 22), "settings", "", skin.GHOST, "settings", null, Strings.tip_settings(), false, true, a)
	right -= 28.0
	button(Rect2(right - 26.0, 4, 26, 22), "refresh", "", skin.GHOST, "reset", null,
		Strings.tip_reset(root.key_label("Reset")), false, true, a)
	right -= 30.0
	var vl = Strings.view_label(view)
	var vw = _pill_w(vl)
	button(Rect2(right - vw, 5, vw, 20), "", vl, skin.SUBTLE, "view", null, Strings.tip_view(), false, true, a)
	right -= vw + 6.0

	# ---- 标题：段名加粗，后面是时长 · 总量 · 每秒 ----
	var stats = _stats
	var stats_color = skin.OVERLAY_DIM
	if _flash != "" and OS.get_ticks_msec() < _flash_until:
		stats = _flash
		stats_color = skin.LIVE
	skin.runs(self, Rect2(36, 0, max(0.0, right - 36.0), HEADER_H), [
		[_title, skin.FONT_BODY, skin.TEXT, true],
		["   " + stats, skin.FONT_BODY, stats_color, false]], true)

	# ---- 树 ----
	var y = HEADER_H + 4.0
	if _rows.empty():
		skin.text(self, Rect2(PAD, y, w - PAD * 2.0, ROW_H[0]), Strings.empty_hint(view), skin.FONT_BODY, skin.OVERLAY_DIM, 1, false, true)
		return
	var skew = _skew()
	# 先画所有色条（网格一次交出去），再在上面写字
	_mesh.begin(skin.px())
	var placed := []
	for i in range(_rows.size()):
		var r = _rows[i]
		if r.kind == "player" and i > 0:
			y += GROUP_GAP
		var h = _row_h(r)
		var x = PAD + r.depth * INDENT
		var rect = Rect2(x, y, w - PAD - x, h)
		var hover = false
		match r.kind:
			"player", "cat":
				# 点一下折叠 / 展开；按住拖动还是拖窗口
				hover = hit(rect, "toggle", r.key, HIT_DRAG_WINDOW)
			"src":
				hover = hit(rect, "source", r.key, HIT_DRAG_WINDOW)
		if r.kind != "more":
			var center = y + h * 0.5
			var shade = Color(0, 0, 0, 0.30 if r.depth == 0 else 0.22)
			var alpha = 0.55 if r.depth == 0 else 0.45
			var fill = skin.with_alpha(r.color.linear_interpolate(Color(1, 1, 1), 0.18), 0.85) if hover else skin.with_alpha(r.color, alpha)
			_mesh.parallelogram(x, y, rect.size.x, h, skew, shade, center)
			_mesh.parallelogram(x, y, rect.size.x * r.frac, h, skew, fill, center)
		placed.append([r, rect])
		y += h + GAP
	_mesh.commit(self)

	var open_key = root.detail.open_key(view, Model.GROUP_SOURCE)
	for p in placed:
		_row_text(p[0], p[1], open_key)


func _row_text(r, rect: Rect2, open_key) -> void:
	var x = rect.position.x
	var y = rect.position.y
	var h = rect.size.y
	var white = Color(1, 1, 1)
	if r.kind == "more":
		skin.text(self, Rect2(x + 16.0, y, rect.size.x - 16.0, h), r.label, skin.FONT_TINY, skin.OVERLAY_DIM, 0, false, true)
		return
	var top = r.depth == 0
	var tx = x + 5.0
	if r.kind == "player" or r.kind == "cat":
		# 折叠箭头
		skin.icon(self, "chevron_down" if r.open else "chevron_right", Vector2(x + 8.0, y + h * 0.5), 9.0, white)
		tx = x + 16.0
	elif r.kind == "src" and bool(tracker.config.value("ShowIcons")):
		var tex = tracker.names.source_icon(r.src)
		if tex != null:
			draw_texture_rect(tex, Rect2(x + 4.0, y + (h - ICON) * 0.5, ICON, ICON), false)
			tx = x + 4.0 + ICON + 4.0

	var right = rect.end.x - 4.0
	var pct_r = Rect2(right - COL_PCT, y, COL_PCT, h)
	var total_r = Rect2(right - COL_PCT - COL_TOTAL, y, COL_TOTAL, h)
	var dps_r = Rect2(right - COL_PCT - COL_TOTAL - COL_DPS, y, COL_DPS, h)
	var name_r = Rect2(tx, y, max(0.0, dps_r.position.x - 4.0 - tx), h)

	var name_color = white
	if r.kind == "src" and open_key != null and _same(open_key, r.key):
		name_color = skin.ACCENT
	# 顶层大一号；玩家和分类的名字加粗
	var big = skin.FONT_BODY if top else skin.FONT_SMALL
	var small = skin.FONT_SMALL if top else skin.FONT_TINY
	skin.text(self, name_r, r.label, big, name_color, 0, r.kind != "src", true)
	skin.text(self, dps_r, Fmt.short(r.per_sec) + "/s", small, skin.OVERLAY_DIM, 2, false, true)
	skin.text(self, total_r, Fmt.short(r.value), big, white, 2, top, true)
	skin.text(self, pct_r, Fmt.pct(r.share), skin.FONT_TINY, skin.OVERLAY_DIM, 2, false, true)


func _on_action(action: String, arg) -> void:
	match action:
		"log":
			root.toggle_main()
		"settings":
			root.open_settings()
		"reset":
			tracker.reset_current()
		"view":
			# 输出 → 承伤 → 治疗 → 输出
			view = (view + 1) % 3
		"toggle":
			if _collapsed.has(arg):
				_collapsed.erase(arg)
			else:
				_collapsed[arg] = true
		"source":
			var enc = current_encounter()
			var s = enc.bucket(view, Model.GROUP_SOURCE).get(arg) if enc != null else null
			var label = str(arg)
			if s != null:
				label = tracker.names.row_label(enc, view, Model.GROUP_SOURCE, s)
			root.detail.toggle(view, Model.GROUP_SOURCE, arg, label)
