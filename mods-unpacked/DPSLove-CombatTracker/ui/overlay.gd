extends "window_base.gd"

# 横向伤害浮窗，形制参考 FFXIV ACT 的 Horizoverlay（与 TBH Combat Tracker 一致）：
# 每个来源一张窄卡片横向并排，卡片主体是 skew(-30°) 的平行四边形，
# 按品质（武器 / 物品）或玩家颜色上色，底部一条占比条。
#
# 只看当前这一波；波次之间（商店里）显示刚结束的那一波。已经结束的段在「记录」打开的主面板里看。
# 单机按来源（武器 / 物品）排；多人时标题栏多一个「来源 / 玩家」切换。

const Model = preload("../core/model.gd")
const Strings = preload("../core/strings.gd")
const Fmt = preload("../core/fmt.gd")

# 版式常量：TBH 的数值（Horizoverlay 的 .row max-width:140px）按 1080p 放大约 1.3 倍
const CARD_W = 184.0
const CARD_GAP = 12.0
const PAD = 12.0
const TITLE_H = 22.0
const HEADER_H = 26.0
const NAME_H = 21.0
const BLOCK_H = 28.0
const PCT_BAR_H = 4.0
const PCT_TEXT_H = 16.0
const DETAIL_H = 16.0
const LOG_BTN_W = 52.0
const BTN_W = 60.0
const BTN_H = 22.0
const ICON = 18.0
const MIN_W = 470.0

var view: int = Model.VIEW_OUT
var group: int = Model.GROUP_SOURCE

var _rows := []
var _hidden := 0
var _flash := ""
var _flash_until := 0


func _init() -> void:
	pos_keys = ["OverlayX", "OverlayY"]
	drag_anywhere = true


# 标题栏上短暂显示一条消息（F11 导出的结果）。显示与否由 ui_root 管
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
	var n = max(1, _rows.size())
	var w = max(PAD * 2.0 + n * CARD_W + (n - 1) * CARD_GAP, MIN_W)
	var h = TITLE_H + HEADER_H + NAME_H + BLOCK_H + PCT_BAR_H + PCT_TEXT_H + DETAIL_H + PAD + 6.0
	rect_size = Vector2(w, h)


func _paint() -> void:
	var enc = current_encounter()
	var w = rect_size.x

	# 窗口底和标题
	skin.fill(self, Rect2(Vector2.ZERO, rect_size), skin.WINDOW_BG)
	skin.frame(self, Rect2(Vector2.ZERO, rect_size), skin.WINDOW_BORDER)
	var title = "Brotato Combat Tracker"
	var title_color = skin.TITLE
	if _flash != "" and OS.get_ticks_msec() < _flash_until:
		title = _flash
		title_color = skin.LIVE
	skin.text(self, skin.o_title, Rect2(PAD, 2, w - PAD * 2.0, TITLE_H - 2), title, title_color, 1)

	# ---- 头部：「记录」+ 波次标题 + 时长 + 总量 + 团队每秒 + 按钮 ----
	var y = TITLE_H
	var r_log = Rect2(PAD, y + 2, LOG_BTN_W, BTN_H)
	skin.button(self, skin.o_small, r_log, Strings.btn_log(), hit(r_log, "log"))

	var x_right = w - PAD
	var r_reset = Rect2(x_right - BTN_W, y + 2, BTN_W, BTN_H)
	skin.button(self, skin.o_small, r_reset, Strings.btn_reset(), hit(r_reset, "reset"))
	x_right -= BTN_W + 4.0
	var r_view = Rect2(x_right - BTN_W, y + 2, BTN_W, BTN_H)
	skin.button(self, skin.o_small, r_view, Strings.view_label(view), hit(r_view, "view"))
	x_right -= BTN_W + 4.0
	if _multi(enc):
		var r_group = Rect2(x_right - BTN_W, y + 2, BTN_W, BTN_H)
		skin.button(self, skin.o_small, r_group, Strings.group_label(group), hit(r_group, "group"))
		x_right -= BTN_W + 4.0

	var total = enc.total(view, tracker.overkill) if enc != null else 0.0
	var duration = enc.duration if enc != null else 0.0
	var head = "%s   %s   %s   %s/s" % [
		tracker.names.encounter_title(enc), Fmt.secs(duration), Fmt.short(total),
		Fmt.short(Fmt.per_sec(total, duration))]
	if _hidden > 0:
		head += "   " + Strings.more_cards(_hidden)
	var title_x = PAD + LOG_BTN_W + 8.0
	var head_color = skin.TEXT if tracker.is_live() else skin.DIM
	skin.text(self, skin.o_header, Rect2(title_x, y, x_right - title_x - 4.0, HEADER_H), head, head_color)
	y += HEADER_H + 4.0

	if _rows.empty():
		skin.text(self, skin.o_name, Rect2(PAD, y + 14.0, w - PAD * 2.0, 22.0), Strings.empty_hint(view), skin.TEXT, 1)
		return

	# ---- 卡片区 ----
	var max_value = _rows[0].metric(tracker.overkill)
	for i in range(_rows.size()):
		var at = Rect2(PAD + i * (CARD_W + CARD_GAP), y, CARD_W,
			NAME_H + BLOCK_H + PCT_BAR_H + PCT_TEXT_H + DETAIL_H + 2.0)
		_card(enc, _rows[i], at, total)
		# 卡片可点开明细；按住拖动时让给拖窗口
		hit(at, "card", _rows[i].key, true)


func _card(enc, s, at: Rect2, total: float) -> void:
	var value = s.metric(tracker.overkill)
	var share = value / total if total > 0.0 else 0.0
	var color = _color_of(s)
	var skew = float(tracker.config.value("SkewDegrees"))
	var y = at.position.y

	# 名字（可带图标）
	var label = _label_of(enc, s)
	var name_rect = Rect2(at.position.x, y, CARD_W, NAME_H)
	var icon = null
	if group == Model.GROUP_SOURCE and bool(tracker.config.value("ShowIcons")):
		icon = tracker.names.source_icon(s.src)
	if icon != null:
		var tw = min(skin.text_width(skin.o_name, label), CARD_W - ICON - 6.0)
		var x0 = at.position.x + (CARD_W - tw - ICON - 4.0) * 0.5
		draw_texture_rect(icon, Rect2(x0, y + (NAME_H - ICON) * 0.5, ICON, ICON), false)
		skin.text(self, skin.o_name, Rect2(x0 + ICON + 4.0, y, CARD_W - (x0 - at.position.x) - ICON - 4.0, NAME_H), label, skin.TEXT, 0)
	else:
		skin.text(self, skin.o_name, name_rect, label, skin.TEXT, 1)
	# 多人按来源看时，卡片左上角一个玩家色的小方块，一眼分出是谁的
	if group == Model.GROUP_SOURCE and _multi(enc):
		skin.fill(self, Rect2(at.position.x + 2.0, y + NAME_H * 0.5 - 3.0, 6.0, 6.0), tracker.names.player_color(s.player))
	y += NAME_H

	# 主体平行四边形：整块按来源上色（对应 Horizoverlay 的 .data-items:before rgba(…, .5)）
	var block = Rect2(at.position.x, y, CARD_W, BLOCK_H)
	skin.skewed(self, block, skin.BLOCK_SHADOW, skew)
	skin.skewed(self, block, skin.with_alpha(color, 0.5), skew)
	# 块内左每秒、右总量
	skin.text(self, skin.o_num, Rect2(block.position.x + 10.0, y + 1.0, CARD_W * 0.55, BLOCK_H - 2.0),
		Fmt.short(Fmt.per_sec(value, enc.duration)) + "/s", skin.TEXT, 0)
	skin.text(self, skin.o_num, Rect2(block.position.x + CARD_W * 0.45 - 10.0, y + 1.0, CARD_W * 0.55, BLOCK_H - 2.0),
		Fmt.short(value), skin.TEXT, 2)
	y += BLOCK_H + 1.0

	# 占比条（同样斜切）
	var bar = Rect2(at.position.x + 2.0, y, CARD_W - 4.0, PCT_BAR_H)
	skin.skewed(self, bar, skin.BLOCK_SHADOW, skew)
	skin.skewed(self, Rect2(bar.position, Vector2(bar.size.x * clamp(share, 0.0, 1.0), PCT_BAR_H)), skin.with_alpha(color, 0.7), skew)
	y += PCT_BAR_H + 1.0

	skin.text(self, skin.o_small, Rect2(at.position.x, y, CARD_W - 6.0, PCT_TEXT_H), Fmt.pct(share), skin.TEXT, 2)
	y += PCT_TEXT_H

	# ACT 风格的补充信息：输出看暴击和最大一击，承伤看闪避，治疗看主要来源和次数
	var detail = ""
	if view == Model.VIEW_OUT:
		var crit = Strings.crit_rate(float(s.crits) / s.hits) if s.hits > 0 else Strings.crit_none()
		detail = crit + "   " + Strings.max_hit(Fmt.short(s.max_hit))
	elif view == Model.VIEW_TAKEN:
		var dodge = Strings.dodge_rate(float(s.crits) / s.hits) if s.hits > 0 else ""
		detail = dodge + "   " + Strings.max_hit(Fmt.short(s.max_hit))
	else:
		var lead = ""
		if group == Model.GROUP_PLAYER:
			var top = Model.sorted_dim(s, Model.DIM_SOURCE, tracker.overkill)
			if top.size() > 0:
				lead = tracker.names.source_label(view, top[0][0]) + "   "
		detail = lead + Strings.hits_count(s.hits)
	skin.text(self, skin.o_small, Rect2(at.position.x, y, CARD_W - 6.0, DETAIL_H), detail, skin.TEXT, 2)


func _label_of(enc, s) -> String:
	return tracker.names.row_label(enc, view, group, s)


func _color_of(s) -> Color:
	return tracker.names.row_color(view, group, s)


func _on_action(action: String, arg) -> void:
	match action:
		"log":
			root.main_panel.toggle()
		"reset":
			tracker.reset_current()
		"view":
			# 输出 → 承伤 → 治疗 → 输出
			view = (view + 1) % 3
		"group":
			group = Model.GROUP_PLAYER if group == Model.GROUP_SOURCE else Model.GROUP_SOURCE
		"card":
			var enc = current_encounter()
			var key = _bucket_key(arg)
			var s = enc.bucket(view, group).get(key) if enc != null else null
			var label = _label_of(enc, s) if s != null else str(arg)
			root.detail.open(view, group, key, label)


# 按玩家分组的桶用整数玩家序号做键，卡片上登记的是字符串
func _bucket_key(key):
	if group == Model.GROUP_PLAYER and typeof(key) == TYPE_STRING and key.is_valid_integer():
		return int(key)
	return key
