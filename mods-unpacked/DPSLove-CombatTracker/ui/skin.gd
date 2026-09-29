extends Reference

# 配色、字体和绘制工具。配色与版式照搬 TBH Combat Tracker v0.4：深色圆角窗口、淡边和阴影，
# 图标按钮悬停有提示；浮窗平时只有描边的文字和斜切卡片，鼠标移上去才淡入背景和按钮。
#
# 坐标：窗口里一律用 TBH 的界面单位（数值和 TBH 源码一一对应），窗口整体按 scale 缩放。
# scale = BASE × UiScale；BASE 是 Brotato 的 1080p 画面相对 TBH（桌面分辨率、10–13 号字）的放大倍数。
# 文字不能跟着缩放变糊：按缩放后的字号生成字体，画字时把缩放抵消掉，字形一个像素对一个像素。
# 字体取游戏自带的思源黑体（Noto Sans SC / TC / JP / KR），按游戏语言挑主字体，其余做后备。

const AaMesh = preload("aa_mesh.gd")
const Icons = preload("icons.gd")

const BASE = 1.3

# ---- 配色（与 TBH 的 Theme 一致）----
# 面板压在游戏画面上，底下什么颜色都有，所以底色要够暗、够不透明，边上再描一圈极淡的亮边
const WINDOW_BG = Color("fa14161b")
const OVERLAY_BG = Color("ff101217")
const BORDER = Color(1, 1, 1, 0.09)
const PANE = Color("ff1b1e25")
# 窗口里的分区底色（列表、右侧数据区）：再压一层半透明的黑，窗口背景调得很透明时字也有衬底
const PANEL = Color(0, 0, 0, 0.24)
# 分区里再分块（曲线）：叠一层淡白
const INSET = Color(1, 1, 1, 0.035)
# 浮窗上的次要文字：浮窗平时没有背景，得比窗口里的次要文字亮
const OVERLAY_DIM = Color("ffd3d7dd")
const HOVER = Color(1, 1, 1, 0.07)
const PRESSED = Color(1, 1, 1, 0.12)
const DIVIDER = Color(1, 1, 1, 0.06)
const CLEAR = Color(1, 1, 1, 0)

const TEXT = Color("ffe6e8eb")
const TEXT_DIM = Color("ffa0a6b0")
const TEXT_FAINT = Color("ff6c727d")

const ACCENT = Color("ff4c8df6")
const ACCENT_SOFT = Color("474c8df6")
const LIVE = Color("ff3ddc84")
const DANGER = Color("ffd94f4f")
const WARNING = Color("ffc88a12")
const SUCCESS = Color("ff2e9e57")
const TIP_BG = Color("f6262931")

# 拆分表 / 环形图的配色：色相拉开，和玩家颜色也错开
const PALETTE = [
	Color("4fa3e3"), Color("e87d3e"), Color("6cc24a"), Color("d1548c"), Color("f2c94c"),
	Color("9b6bd6"), Color("3fc1b0"), Color("c45b4a"), Color("8a9ba8"),
]
# 环形图上的「其他」和这些行的色点：不带色相的灰
const OTHER_SLICE = Color("ff7a8089")

const FONT_TITLE = 13
const FONT_BODY = 12
const FONT_SMALL = 11
const FONT_TINY = 10

const RADIUS_WINDOW = 8.0
const RADIUS_CONTROL = 5.0
const TITLE_H = 32.0

# 按钮样式
const GHOST = 0     # 平时透明，悬停才显出底色（标题栏、工具栏上的图标按钮）
const SUBTLE = 1    # 一直有一层淡底色（翻页、设置里的按钮）
const TAB = 2       # 页签 / 分段：选中的那个是强调色底

# 假粗体：同一行字错开这么多画面像素再画一遍（游戏只带了 Medium 一种字重）
const BOLD_DX = 0.6

var scale := BASE
var _datas := []
var _locale := "?"
var _fonts := {}
var _wraps := {}
var _icons := {}
var _box_sb := StyleBoxFlat.new()
var _line_sb := StyleBoxFlat.new()
var _frame_sb := StyleBoxFlat.new()


func _init() -> void:
	_box_sb.anti_aliasing = true
	_line_sb.anti_aliasing = true
	_line_sb.draw_center = false
	_frame_sb.anti_aliasing = true
	_frame_sb.set_border_width_all(1)
	_frame_sb.shadow_size = 10
	_frame_sb.shadow_offset = Vector2(0, 2)


func set_ui_scale(ui_scale: float) -> void:
	var s = BASE * clamp(ui_scale, 0.5, 2.5)
	if abs(s - scale) > 0.0001:
		scale = s
		_fonts.clear()
		_wraps.clear()
		_icons.clear()


# 一个画面像素折合多少本地单位（抗锯齿羽化带的宽度）
func px() -> float:
	return 1.0 / scale


static func palette(i: int) -> Color:
	return PALETTE[posmod(i, PALETTE.size())]


static func with_alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)


static func fade(c: Color, k: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * k)


# ---------------------------------------------------------------------------
# 字体与文字
# ---------------------------------------------------------------------------

func _check_locale() -> void:
	var loc = TranslationServer.get_locale()
	if loc == _locale:
		return
	_locale = loc
	_fonts.clear()
	_wraps.clear()
	_datas.clear()
	var order = ["SC", "TC", "JP", "KR"]
	if loc.begins_with("zh_TW") or loc.begins_with("zh_HK") or loc.begins_with("zh_Hant"):
		order = ["TC", "SC", "JP", "KR"]
	elif loc.begins_with("ja"):
		order = ["JP", "SC", "TC", "KR"]
	elif loc.begins_with("ko"):
		order = ["KR", "SC", "TC", "JP"]
	for tag in order:
		var p = "res://resources/fonts/raw/NotoSans%s-Medium.otf" % tag
		if ResourceLoader.exists(p):
			var data = load(p)
			if data != null:
				_datas.append(data)


# 指定字号（TBH 单位）在当前缩放下的字体
func font(size: int, outline: bool = false) -> Font:
	_check_locale()
	var px_size = int(max(1, round(size * scale)))
	var key = px_size * 2 + (1 if outline else 0)
	var f = _fonts.get(key)
	if f == null:
		f = _make_font(px_size, 1 if outline else 0)
		_fonts[key] = f
	return f


# 不随缩放的字体（预览图的大标题）
func make_font(px_size: int, outline: int) -> Font:
	_check_locale()
	return _make_font(px_size, outline)


func _make_font(px_size: int, outline: int) -> Font:
	if _datas.empty():
		# 游戏字体找不到（以后的版本换了路径）：退回引擎默认字体，至少能显示英文
		var probe = Control.new()
		var fallback = probe.get_font("font")
		probe.free()
		return fallback
	var f = DynamicFont.new()
	f.font_data = _datas[0]
	for i in range(1, _datas.size()):
		f.add_fallback(_datas[i])
	f.size = px_size
	f.use_filter = true
	if outline > 0:
		f.outline_size = outline
		f.outline_color = Color(0, 0, 0, 0.92)
	return f


# 一行字的宽度（本地单位）
func text_width(s: String, size: int, bold: bool = false) -> float:
	if s == "":
		return 0.0
	var w = font(size).get_string_size(s).x + (BOLD_DX if bold else 0.0)
	return w / scale


# 在矩形里画一行字：纵向居中，横向按 align（0 左 1 中 2 右），放不下就截断加省略号。返回画出的宽度
func text(ci: CanvasItem, r: Rect2, s: String, size: int, color: Color, align: int = 0,
		bold: bool = false, outline: bool = false) -> float:
	if s == "" or color.a <= 0.0:
		return 0.0
	var f = font(size, outline)
	var k = scale
	var extra = BOLD_DX if bold else 0.0
	var avail = r.size.x * k
	var w = f.get_string_size(s).x + extra
	if avail > 0.0 and w > avail + 0.5:
		s = _ellipsize(f, s, avail - extra)
		if s == "":
			return 0.0
		w = f.get_string_size(s).x + extra
	var x = r.position.x * k
	if align == 1:
		x += (avail - w) * 0.5
	elif align == 2:
		x += avail - w
	var y = r.position.y * k + (r.size.y * k - f.get_height()) * 0.5 + f.get_ascent()
	# 抵消窗口的缩放：这一段里一个单位就是一个画面像素；起点对齐到整像素，字才清楚
	var o = ci.get_global_transform().origin
	var pos = Vector2(round(o.x + x) - o.x, round(o.y + y) - o.y)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0 / k, 1.0 / k))
	ci.draw_string(f, pos, s, color)
	if bold:
		ci.draw_string(f, pos + Vector2(BOLD_DX, 0), s, color)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	return w / k


# 一行里接着画几段不同样式的字：[[文字, 字号, 颜色, 粗体], …]，放不下时最后一段截断
func runs(ci: CanvasItem, r: Rect2, parts: Array, outline: bool = false) -> void:
	var x = r.position.x
	var right = r.end.x
	for i in range(parts.size()):
		var p = parts[i]
		if x >= right - 1.0:
			return
		var w = text(ci, Rect2(x, r.position.y, right - x, r.size.y), str(p[0]), int(p[1]), p[2], 0, bool(p[3]), outline)
		x += w


static func _ellipsize(f: Font, s: String, avail: float) -> String:
	var dots = "…"
	if f.get_string_size(dots).x >= avail:
		return ""
	var lo = 0
	var hi = s.length()
	while lo < hi:
		var mid = (lo + hi + 1) / 2
		if f.get_string_size(s.substr(0, mid) + dots).x <= avail:
			lo = mid
		else:
			hi = mid - 1
	return s.substr(0, lo).strip_edges(false, true) + dots


# 自动换行（设置里的说明）：中日韩文字逐字断，其余按空格断；超出行数的截断加省略号
func text_wrap(ci: CanvasItem, r: Rect2, s: String, size: int, color: Color, max_lines: int, line_h: float) -> void:
	var lines = wrap_lines(s, size, r.size.x, max_lines)
	for i in range(lines.size()):
		text(ci, Rect2(r.position.x, r.position.y + i * line_h, r.size.x, line_h), lines[i], size, color)


func wrap_lines(s: String, size: int, width: float, max_lines: int) -> Array:
	var f = font(size)
	# 逐字量宽度很慢：同样的字、字号、宽度只折一次（换缩放、换语言时 font() 会清掉缓存）
	var ck = "%s|%d|%.1f|%d" % [s, size, width, max_lines]
	if _wraps.has(ck):
		return _wraps[ck]
	var lines = _wrap(f, s, width * scale, max_lines)
	_wraps[ck] = lines
	return lines


func _wrap(f: Font, s: String, avail: float, max_lines: int) -> Array:
	var tokens := []
	var word := ""
	for i in range(s.length()):
		var c = s[i]
		var code = s.ord_at(i)
		if code >= 0x2E80:
			if word != "":
				tokens.append(word)
				word = ""
			tokens.append(c)
		elif c == " ":
			tokens.append(word + " ")
			word = ""
		else:
			word += c
	if word != "":
		tokens.append(word)
	var lines := []
	var line := ""
	for t in tokens:
		if line != "" and f.get_string_size(line + t.strip_edges(false, true)).x > avail:
			lines.append(line.strip_edges(false, true))
			line = t.strip_edges(true, false)
		else:
			line += t
	if line.strip_edges() != "":
		lines.append(line.strip_edges(false, true))
	if lines.size() > max_lines:
		var rest = PoolStringArray(lines.slice(max_lines - 1, lines.size() - 1)).join(" ")
		lines = lines.slice(0, max_lines - 2) if max_lines > 1 else []
		lines.append(_ellipsize(f, rest, avail))
	return lines


# ---------------------------------------------------------------------------
# 形状
# ---------------------------------------------------------------------------

# 纯色块或圆角块。radius = 0 是直角
func box(ci: CanvasItem, r: Rect2, color: Color, radius: float = 0.0) -> void:
	if r.size.x <= 0.0 or r.size.y <= 0.0 or color.a <= 0.0:
		return
	if radius <= 0.0:
		ci.draw_rect(r, color)
		return
	_box_sb.bg_color = color
	_box_sb.set_corner_radius_all(int(round(min(radius, min(r.size.x, r.size.y) * 0.5))))
	ci.draw_style_box(_box_sb, r)


# 圆角框线（颜色块被选中时的外圈）
func outline(ci: CanvasItem, r: Rect2, color: Color, radius: float, width: float = 1.0) -> void:
	if color.a <= 0.0:
		return
	_line_sb.border_color = color
	_line_sb.set_border_width_all(int(max(1.0, round(width))))
	_line_sb.set_corner_radius_all(int(round(radius)))
	ci.draw_style_box(_line_sb, r)


# 窗口的底：阴影 + 淡边 + 圆角底板。frame_alpha 让三者一起淡出（浮窗平时没有背景）
func window_frame(ci: CanvasItem, r: Rect2, bg: Color, frame_alpha: float = 1.0, shadow_scale: float = 1.0) -> void:
	if frame_alpha <= 0.002:
		return
	var sb = _frame_sb
	sb.bg_color = Color(bg.r, bg.g, bg.b, bg.a * frame_alpha)
	sb.border_color = Color(1, 1, 1, BORDER.a * frame_alpha)
	sb.set_corner_radius_all(int(RADIUS_WINDOW))
	sb.shadow_color = Color(0, 0, 0, 0.30 * frame_alpha * clamp(shadow_scale, 0.0, 1.0))
	ci.draw_style_box(sb, r)


# 图标的网格按（名字、大小、颜色、缩放）缓存，以原点为中心；画的时候平移过去再交一次。
# 透明度按 0.05 取整（浮窗淡入淡出时不至于每一帧一份）
func icon(ci: CanvasItem, name: String, center: Vector2, size: float, color: Color) -> void:
	if color.a <= 0.0:
		return
	var c = Color(color.r, color.g, color.b, stepify(color.a, 0.05))
	var key = "%s|%.1f|%s|%.3f" % [name, size, c.to_html(true), scale]
	var snap = _icons.get(key)
	if snap == null:
		var m = AaMesh.new()
		Icons.build(m, name, size, c, px())
		snap = m.snapshot()
		_icons[key] = snap
	ci.draw_set_transform(center, 0.0, Vector2.ONE)
	AaMesh.commit_snapshot(ci, snap)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ---------------------------------------------------------------------------
# 控件的样子（点击区由窗口登记）
# ---------------------------------------------------------------------------

# 按钮：图标、文字或两者都有
func button(ci: CanvasItem, r: Rect2, icon_name: String, label: String, style: int, hover: bool, pressed: bool,
		on: bool = false, enabled: bool = true, alpha: float = 1.0) -> void:
	var bg = CLEAR
	var fg = TEXT_DIM
	match style:
		SUBTLE:
			bg = Color(1, 1, 1, 0.14 if pressed else (0.10 if hover else 0.055))
			fg = TEXT
		TAB:
			bg = ACCENT_SOFT if on else (PRESSED if pressed else (HOVER if hover else CLEAR))
			fg = TEXT if on or hover else TEXT_DIM
		_:
			bg = ACCENT_SOFT if on else (PRESSED if pressed else (HOVER if hover else CLEAR))
			fg = TEXT if on or hover or pressed else TEXT_DIM
	if not enabled:
		bg = Color(1, 1, 1, 0.04) if style == SUBTLE else CLEAR
		fg = TEXT_FAINT
	box(ci, r, fade(bg, alpha), RADIUS_CONTROL)
	fg = fade(fg, alpha)
	var mid = r.position.y + r.size.y * 0.5
	if icon_name != "" and label != "":
		icon(ci, icon_name, Vector2(r.position.x + 16.0, mid), 13.0, fg)
		text(ci, Rect2(r.position.x + 29.0, r.position.y, max(0.0, r.size.x - 33.0), r.size.y), label, FONT_SMALL, fg)
	elif icon_name != "":
		icon(ci, icon_name, Vector2(r.position.x + r.size.x * 0.5, mid), 13.0, fg)
	else:
		text(ci, r, label, FONT_SMALL, fg, 1)


# 按内容算按钮宽度：左右各留 pad
func button_width(icon_name: String, label: String, pad: float = 9.0) -> float:
	var w = pad * 2.0
	if icon_name != "":
		w += 16.0
	if label != "":
		w += ceil(text_width(label, FONT_SMALL)) + (5.0 if icon_name != "" else 0.0)
	return w


func toggle(ci: CanvasItem, pos: Vector2, on: bool, hover: bool) -> void:
	var track = Rect2(pos, Vector2(34, 18))
	var c = (with_alpha(ACCENT, 0.88) if hover else ACCENT) if on else Color(1, 1, 1, 0.24 if hover else 0.18)
	box(ci, track, c, 9.0)
	box(ci, Rect2(pos.x + (18.0 if on else 2.0), pos.y + 2.0, 14, 14), Color(1, 1, 1), 7.0)


# 滑杆：轨道 (x, y+7) 起、宽 w；t 是 0–1 的位置；数值标签放在轨道右边
func slider(ci: CanvasItem, x: float, y: float, w: float, t: float, big: bool, label: String) -> void:
	t = clamp(t, 0.0, 1.0)
	box(ci, Rect2(x, y + 7.0, w, 4.0), Color(1, 1, 1, 0.14), 2.0)
	box(ci, Rect2(x, y + 7.0, max(4.0, w * t), 4.0), ACCENT, 2.0)
	var d = 16.0 if big else 14.0
	box(ci, Rect2(x + w * t - d * 0.5, y + 9.0 - d * 0.5, d, d), Color(1, 1, 1), d * 0.5)
	text(ci, Rect2(x + w + 8.0, y, 56.0, 18.0), label, FONT_SMALL, TEXT, 2)


# 颜色块：selected 时外面描一圈
func swatch(ci: CanvasItem, r: Rect2, color: Color, selected: bool, hover: bool) -> void:
	var ring = Color(1, 1, 1) if selected else (Color(1, 1, 1, 0.35) if hover else CLEAR)
	outline(ci, r, ring, 5.0, 1.5)
	box(ci, Rect2(r.position + Vector2(2, 2), r.size - Vector2(4, 4)), color, 3.5)
