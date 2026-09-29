extends "window_base.gd"

# 实时浮窗，形制参考 FFXIV ACT 的 Horizoverlay（与 TBH Combat Tracker 一致）：
# 每个来源一张窄卡片横向并排，卡片主体是斜切的平行四边形，底下一条细的占比条。
# 标题栏：战斗记录、当前段、视图切换（多人时还有来源 / 玩家）、重置、设置。
#
# 平时只有描边的文字和卡片浮在游戏上；鼠标移上来，半透明的背景和标题栏按钮才淡入（浓淡在设置里调）。
# 整个窗口按住就能拖；点卡片（没拖动）打开那个来源的拆分窗口。
# 只看当前这一波；波次之间（商店里）显示刚结束的那一波。已经结束的段在战斗记录里看。

const Model = preload("../core/model.gd")
const Strings = preload("../core/strings.gd")
const Fmt = preload("../core/fmt.gd")
const AaMesh = preload("aa_mesh.gd")

# 版式常量：TBH 的界面单位（窗口整体再按 skin.scale 放大）
const CARD_W = 140.0
const CARD_GAP = 6.0
const PAD = 10.0
const HEADER_H = 30.0
const NAME_H = 16.0
const BLOCK_H = 22.0
const BAR_H = 3.0
const LINE_H = 13.0
const CARD_H = NAME_H + 1.0 + BLOCK_H + 3.0 + BAR_H + 2.0 + LINE_H * 2.0
const MIN_W = 360.0
const ICON = 14.0
# 背景和按钮淡入 / 淡出用多久
const FADE_SECONDS = 0.15

var view: int = Model.VIEW_OUT
var group: int = Model.GROUP_SOURCE
var force_frame := false     # 自测截图、预览图：背景和按钮一直显示

var _rows := []
var _hidden := 0
var _pad_l := PAD
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


func _multi(enc) -> bool:
	return enc != null and enc.players().size() > 1


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


func _layout() -> void:
	var enc = current_encounter()
	if not _multi(enc):
		group = Model.GROUP_SOURCE
	_rows = Model.sorted_rows(enc, view, group, tracker.overkill)
	var max_cards = int(clamp(int(tracker.config.value("MaxCards")), 1, 12))
	_hidden = int(max(0, _rows.size() - max_cards))
	if _hidden > 0:
		# Godot 3 的 slice 两端都含
		_rows = _rows.slice(0, max_cards - 1)
	# 占比条和下面两行跟着斜度往一边错开：往哪边斜，哪边就多留这么宽，免得最后一张卡的字出了窗口
	var slope = AaMesh.slope(_skew())
	var lean = ceil(abs(slope) * (BLOCK_H * 0.5 + 3.0 + BAR_H * 0.5))
	_pad_l = PAD + (lean if slope < 0.0 else 0.0)
	var pad_r = PAD + (lean if slope > 0.0 else 0.0)
	var n = max(1, _rows.size())
	var w = max(_pad_l + pad_r + n * CARD_W + (n - 1) * CARD_GAP, MIN_W)

	# 标题栏要放下段名、统计和右边的按钮：卡片少时窗口按标题加宽。取整到 20，
	# 同一段里只加宽不缩回，按钮不会跟着数字的位数左右跳
	_title = tracker.names.encounter_title(enc)
	var total = enc.total(view, tracker.overkill) if enc != null else 0.0
	var d = enc.duration if enc != null else 0.0
	_stats = "%s · %s · %s/s" % [Fmt.dur(d), Fmt.short(total), Fmt.short(Fmt.per_sec(total, d))]
	if _hidden > 0:
		_stats += "  " + Strings.more_cards(_hidden)
	var buttons = 6.0 + 28.0 + 30.0 + _pill_w(Strings.view_label(view)) + 6.0
	if _multi(enc):
		buttons += _pill_w(Strings.group_label(group)) + 6.0
	var need = 36.0 + skin.text_width(_title, skin.FONT_BODY, true) + skin.text_width("   " + _stats, skin.FONT_BODY) + 8.0 + buttons
	need = min(ceil(need / 20.0) * 20.0, 600.0)
	if enc != _header_enc or view != _header_view:
		_header_enc = enc
		_header_view = view
		_header_w = 0.0
	_header_w = max(_header_w, need)
	rect_size = Vector2(max(w, _header_w), HEADER_H + 4.0 + CARD_H + 10.0)


func _pill_w(label: String) -> float:
	return max(44.0, skin.button_width("", label, 8.0))


func _key_of(s):
	return s.player if group == Model.GROUP_PLAYER else s.key


func _paint() -> void:
	var enc = current_encounter()
	var w = rect_size.x
	var op = opacity()
	skin.window_frame(self, Rect2(Vector2.ZERO, rect_size), skin.with_alpha(skin.OVERLAY_BG, op), _fade, op * 1.6)
	# 整窗可拖：最先登记，按钮和卡片压在它上面
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
	if _multi(enc):
		var gl = Strings.group_label(group)
		var gw = _pill_w(gl)
		button(Rect2(right - gw, 5, gw, 20), "", gl, skin.SUBTLE, "group", null, Strings.tip_group(), false, true, a)
		right -= gw + 6.0

	# ---- 标题：段名加粗，后面是时长 · 总量 · 每秒 ----
	var stats = _stats
	var stats_color = skin.OVERLAY_DIM
	if _flash != "" and OS.get_ticks_msec() < _flash_until:
		stats = _flash
		stats_color = skin.LIVE
	skin.runs(self, Rect2(36, 0, max(0.0, right - 36.0), HEADER_H), [
		[_title, skin.FONT_BODY, skin.TEXT, true],
		["   " + stats, skin.FONT_BODY, stats_color, false]], true)
	var total = enc.total(view, tracker.overkill) if enc != null else 0.0

	# ---- 卡片 ----
	var top = HEADER_H + 4.0
	if _rows.empty():
		skin.text(self, Rect2(PAD, top, w - PAD * 2.0, CARD_H), Strings.empty_hint(view), skin.FONT_BODY, skin.OVERLAY_DIM, 1, false, true)
		return
	var skew = _skew()
	var ov = tracker.overkill
	# 先画所有色块（网格一次交出去），再在上面写字
	_mesh.begin(skin.px())
	var cards := []
	for i in range(_rows.size()):
		var s = _rows[i]
		var x = _pad_l + i * (CARD_W + CARD_GAP)
		var key = _key_of(s)
		# 拖卡片也是拖窗口；点一下（没拖动）打开拆分窗口
		var hover = hit(Rect2(x - 3.0, top - 2.0, CARD_W + 6.0, CARD_H + 4.0), "card", key, HIT_DRAG_WINDOW)
		var value = s.metric(ov)
		var share = clamp(value / total, 0.0, 1.0) if total > 0.0 else 0.0
		var color = tracker.names.row_color(view, group, s)
		# 色块和占比条用同一条斜切中线（色块的中线），两条斜边才在一条直线上。
		# 悬停时给斜切色块本身提亮（不另画框，框和斜边对不上）
		var by = top + NAME_H + 1.0
		var center = by + BLOCK_H * 0.5
		var fill = skin.with_alpha(color.linear_interpolate(Color(1, 1, 1), 0.18), 0.85) if hover else skin.with_alpha(color, 0.55)
		_mesh.parallelogram(x, by, CARD_W, BLOCK_H, skew, Color(0, 0, 0, 0.30), center)
		_mesh.parallelogram(x, by, CARD_W, BLOCK_H, skew, fill, center)
		var bar_y = by + BLOCK_H + 3.0
		_mesh.parallelogram(x, bar_y, CARD_W, BAR_H, skew, Color(0, 0, 0, 0.35), center)
		_mesh.parallelogram(x, bar_y, CARD_W * share, BAR_H, skew, skin.with_alpha(color, 0.85), center)
		cards.append([s, x, key, value, share])
	_mesh.commit(self)

	var open_key = root.detail.open_key(view, group)
	var slope = AaMesh.slope(skew)
	for c in cards:
		_card_text(enc, c, top, slope, open_key)


func _card_text(enc, c: Array, top: float, slope: float, open_key) -> void:
	var s = c[0]
	var x = c[1]
	var value = c[3]
	var share = c[4]
	var names = tracker.names

	# 名字（可带图标）；拆分窗口开着的那张卡片名字是强调色
	var label = names.row_label(enc, view, group, s)
	var name_color = skin.ACCENT if open_key != null and _same(open_key, c[2]) else skin.TEXT
	var icon = null
	if group == Model.GROUP_SOURCE and bool(tracker.config.value("ShowIcons")):
		icon = names.source_icon(s.src)
	if icon != null:
		var tw = min(skin.text_width(label, skin.FONT_SMALL, true), CARD_W - ICON - 4.0)
		var x0 = x + (CARD_W - tw - ICON - 3.0) * 0.5
		draw_texture_rect(icon, Rect2(x0, top + (NAME_H - ICON) * 0.5, ICON, ICON), false)
		skin.text(self, Rect2(x0 + ICON + 3.0, top, CARD_W - (x0 - x) - ICON - 3.0, NAME_H), label, skin.FONT_SMALL, name_color, 0, true, true)
	else:
		skin.text(self, Rect2(x, top, CARD_W, NAME_H), label, skin.FONT_SMALL, name_color, 1, true, true)
	# 多人按来源看时，卡片左上角一个玩家色的小方块，一眼分出是谁的
	if group == Model.GROUP_SOURCE and _multi(enc):
		skin.box(self, Rect2(x + 1.0, top + NAME_H * 0.5 - 2.5, 5, 5), names.player_color(s.player), 1.5)

	# 块内左每秒、右总量
	var by = top + NAME_H + 1.0
	var white = Color(1, 1, 1)
	skin.text(self, Rect2(x + 9.0, by, CARD_W * 0.55, BLOCK_H), Fmt.short(Fmt.per_sec(value, enc.duration)) + "/s", skin.FONT_BODY, white, 0, true, true)
	skin.text(self, Rect2(x + CARD_W * 0.45 - 9.0, by, CARD_W * 0.55, BLOCK_H), Fmt.short(value), skin.FONT_BODY, white, 2, true, true)

	# 下面两行跟着占比条的斜度错开，和条的两端对齐：
	# 第一行左边暴击率（承伤是闪避率，按玩家看治疗是主要来源）、右边占比；第二行居中最大一击（治疗是次数）
	var bar_y = by + BLOCK_H + 3.0
	var dx = slope * (bar_y + BAR_H * 0.5 - (by + BLOCK_H * 0.5))
	var line_y = bar_y + BAR_H + 2.0
	var left = ""
	var second = ""
	if view == Model.VIEW_OUT:
		left = Strings.crit_rate(float(s.crits) / s.hits) if s.hits > 0 else Strings.crit_none()
		second = Strings.max_hit(Fmt.short(s.max_hit))
	elif view == Model.VIEW_TAKEN:
		left = Strings.dodge_rate(float(s.crits) / s.hits) if s.hits > 0 else ""
		second = Strings.max_hit(Fmt.short(s.max_hit))
	else:
		if group == Model.GROUP_PLAYER:
			var lead = Model.sorted_dim(s, Model.DIM_SOURCE, tracker.overkill)
			if lead.size() > 0:
				left = names.source_label(view, lead[0][0])
		second = Strings.hits_count(s.hits)
	skin.text(self, Rect2(x + dx + 1.0, line_y, CARD_W * 0.6, LINE_H), left, skin.FONT_TINY, skin.OVERLAY_DIM, 0, false, true)
	skin.text(self, Rect2(x + dx, line_y, CARD_W - 1.0, LINE_H), Fmt.pct(share), skin.FONT_TINY, white, 2, false, true)
	skin.text(self, Rect2(x + dx, line_y + LINE_H, CARD_W, LINE_H), second, skin.FONT_TINY, skin.OVERLAY_DIM, 1, false, true)


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
		"group":
			group = Model.GROUP_PLAYER if group == Model.GROUP_SOURCE else Model.GROUP_SOURCE
		"card":
			var enc = current_encounter()
			var s = enc.bucket(view, group).get(arg) if enc != null else null
			var label = tracker.names.row_label(enc, view, group, s) if s != null else str(arg)
			root.detail.toggle(view, group, arg, label)
