extends Reference

# 界面配色、字体和绘制工具。配色与版式沿用 TBH Combat Tracker：
# 浮窗仿 FFXIV ACT 的 Horizoverlay（斜切卡片），主面板仿 ACT 主窗口。
#
# 所有尺寸按游戏的 1920×1080 设计分辨率给；游戏按窗口大小整体缩放，UiScale 在此基础上再乘。
# 字体取游戏自带的思源黑体（Noto Sans SC / TC / JP / KR），中日韩都能显示。

const TEXT = Color(0.93, 0.93, 0.95)
const DIM = Color(0.66, 0.66, 0.70)
const HEAD = Color(0.60, 0.62, 0.68)
const LIVE = Color(0.45, 0.85, 0.45)
const WARN = Color(0.95, 0.72, 0.30)
const SELECTED = Color(0.26, 0.46, 0.78, 0.55)
const SELECTED_ROW = Color(0.26, 0.46, 0.78, 0.45)
const HOVER = Color(1, 1, 1, 0.07)
const PANEL_BG = Color(0.06, 0.06, 0.08, 0.94)
const LIST_BG = Color(1, 1, 1, 0.03)
const CHART_BG = Color(0.11, 0.11, 0.14, 0.95)
const PICKER_BG = Color(0.10, 0.10, 0.13, 0.98)
const WINDOW_BG = Color(0.08, 0.08, 0.10, 0.78)
const WINDOW_BORDER = Color(1, 1, 1, 0.12)
const TITLE = Color(0.78, 0.78, 0.82)
const BUTTON = Color(0.22, 0.22, 0.26, 0.95)
const BUTTON_HOVER = Color(0.34, 0.34, 0.40, 0.98)
const BUTTON_BORDER = Color(1, 1, 1, 0.16)
const TAB_ON = Color(0.26, 0.46, 0.78, 0.75)
const TAB_OFF = Color(1, 1, 1, 0.07)
const BLOCK_SHADOW = Color(0, 0, 0, 0.30)
const EMPTY_RING = Color(0.19, 0.19, 0.21, 0.75)

# 饼图切片配色：色相拉开，与 TBH Combat Tracker 一致
const PALETTE = [
	Color("4fa3e3"), Color("e87d3e"), Color("6cc24a"), Color("d1548c"), Color("f2c94c"),
	Color("9b6bd6"), Color("3fc1b0"), Color("c45b4a"), Color("8a9ba8"),
]

const FONT_PATHS = [
	"res://resources/fonts/raw/NotoSansSC-Medium.otf",
	"res://resources/fonts/raw/NotoSansTC-Medium.otf",
	"res://resources/fonts/raw/NotoSansJP-Medium.otf",
	"res://resources/fonts/raw/NotoSansKR-Medium.otf",
]

# 描边字：浮窗和明细窗口底下是一直在动的游戏画面，纯白字很容易糊掉
var o_title: Font
var o_header: Font
var o_name: Font
var o_num: Font
var o_small: Font
var o_center: Font
var o_sub: Font
# 主面板：自带深色底，不描边
var p_text: Font
var p_small: Font
var p_bold: Font
var p_head: Font
var p_center: Font

var _datas := []


func _init() -> void:
	for p in FONT_PATHS:
		if ResourceLoader.exists(p):
			var data = load(p)
			if data != null:
				_datas.append(data)
	o_title = make_font(14, 1)
	o_header = make_font(15, 1)
	o_name = make_font(15, 1)
	o_num = make_font(16, 1)
	o_small = make_font(12, 1)
	o_center = make_font(19, 1)
	o_sub = make_font(13, 1)
	p_text = make_font(15, 0)
	p_small = make_font(13, 0)
	p_bold = make_font(16, 0)
	p_head = make_font(13, 0)
	p_center = make_font(18, 0)


func make_font(size: int, outline: int) -> Font:
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
	f.size = size
	f.use_filter = true
	if outline > 0:
		f.outline_size = outline
		f.outline_color = Color(0, 0, 0, 0.85)
	return f


static func palette(i: int) -> Color:
	return PALETTE[posmod(i, PALETTE.size())]


static func with_alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)


# ---------------------------------------------------------------------------
# 绘制工具：都在某个 CanvasItem 的 _draw() 里调用
# ---------------------------------------------------------------------------

# 在矩形里画一行字：纵向居中，横向按 align（0 左 1 中 2 右），放不下就截断加省略号
static func text(ci: CanvasItem, font: Font, r: Rect2, s: String, color: Color, align: int = 0) -> void:
	if s == "" or font == null:
		return
	var w = r.size.x
	var width = font.get_string_size(s).x
	if w > 0.0 and width > w:
		s = ellipsize(font, s, w)
		width = font.get_string_size(s).x
	var x = r.position.x
	if align == 1:
		x += (w - width) * 0.5
	elif align == 2:
		x += w - width
	var y = r.position.y + (r.size.y - font.get_height()) * 0.5 + font.get_ascent()
	ci.draw_string(font, Vector2(round(x), round(y)), s, color)


static func ellipsize(font: Font, s: String, w: float) -> String:
	var dots = "…"
	if font.get_string_size(dots).x >= w:
		return ""
	var lo = 0
	var hi = s.length()
	while lo < hi:
		var mid = (lo + hi + 1) / 2
		if font.get_string_size(s.substr(0, mid) + dots).x <= w:
			lo = mid
		else:
			hi = mid - 1
	return s.substr(0, lo) + dots


static func text_width(font: Font, s: String) -> float:
	return font.get_string_size(s).x if font != null else 0.0


static func fill(ci: CanvasItem, r: Rect2, color: Color) -> void:
	if r.size.x > 0.0 and r.size.y > 0.0:
		ci.draw_rect(r, color, true)


static func frame(ci: CanvasItem, r: Rect2, color: Color) -> void:
	ci.draw_rect(Rect2(r.position + Vector2(0.5, 0.5), r.size - Vector2(1, 1)), color, false, 1.0)


# 斜切平行四边形——Horizoverlay 的标志性造型。deg 与 TBH 的 SkewDegrees 同义：
# 上沿往一侧、下沿往另一侧各错开 tan(deg)·h/2
static func skewed(ci: CanvasItem, r: Rect2, color: Color, deg: float) -> void:
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	var k = -tan(deg2rad(clamp(deg, -60.0, 60.0)))
	var half = r.size.y * 0.5
	var top = -k * half
	var bottom = k * half
	var pts = PoolVector2Array([
		Vector2(r.position.x + top, r.position.y),
		Vector2(r.end.x + top, r.position.y),
		Vector2(r.end.x + bottom, r.end.y),
		Vector2(r.position.x + bottom, r.end.y),
	])
	ci.draw_colored_polygon(pts, color)


# 小按钮（点击区由调用方登记）
static func button(ci: CanvasItem, font: Font, r: Rect2, label: String, hover: bool) -> void:
	fill(ci, r, BUTTON_HOVER if hover else BUTTON)
	frame(ci, r, BUTTON_BORDER)
	text(ci, font, r, label, TEXT, 1)


static func tab(ci: CanvasItem, font: Font, r: Rect2, label: String, on: bool, hover: bool) -> void:
	var c = TAB_ON if on else TAB_OFF
	if hover and not on:
		c = Color(1, 1, 1, 0.13)
	fill(ci, r, c)
	text(ci, font, r, label, TEXT, 1)


# 环形图：slices 为 [[数值, 颜色], …]，从 12 点钟方向顺时针
static func donut(ci: CanvasItem, center: Vector2, r_out: float, r_in: float, slices: Array) -> void:
	var total := 0.0
	for s in slices:
		total += max(0.0, float(s[0]))
	if total <= 0.0:
		_ring(ci, center, r_out, r_in, 0.0, TAU, EMPTY_RING)
		return
	var a := 0.0
	for s in slices:
		var v = max(0.0, float(s[0]))
		if v <= 0.0:
			continue
		var span = v / total * TAU
		_ring(ci, center, r_out, r_in, a, a + span, s[1])
		a += span


static func _ring(ci: CanvasItem, c: Vector2, r_out: float, r_in: float, a0: float, a1: float, color: Color) -> void:
	# 大于半圈的切成两半画，免得多边形首尾相接退化
	if a1 - a0 > PI:
		var mid = (a0 + a1) * 0.5
		_ring(ci, c, r_out, r_in, a0, mid, color)
		_ring(ci, c, r_out, r_in, mid, a1, color)
		return
	var steps = int(max(2, ceil((a1 - a0) / TAU * 96.0)))
	var pts := PoolVector2Array()
	for i in range(steps + 1):
		var t = a0 + (a1 - a0) * i / steps
		pts.append(c + Vector2(sin(t), -cos(t)) * r_out)
	for i in range(steps, -1, -1):
		var t = a0 + (a1 - a0) * i / steps
		pts.append(c + Vector2(sin(t), -cos(t)) * r_in)
	ci.draw_colored_polygon(pts, color)
	# 内外沿各描一道抗锯齿弧线，边缘不毛
	var arc_out := PoolVector2Array()
	var arc_in := PoolVector2Array()
	for i in range(steps + 1):
		var t = a0 + (a1 - a0) * i / steps
		arc_out.append(c + Vector2(sin(t), -cos(t)) * (r_out - 0.5))
		arc_in.append(c + Vector2(sin(t), -cos(t)) * (r_in + 0.5))
	ci.draw_polyline(arc_out, color, 1.2, true)
	ci.draw_polyline(arc_in, color, 1.2, true)
