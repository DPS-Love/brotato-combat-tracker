extends Reference

# 抗锯齿网格：在 GDScript 里拼三角形，一次交给 VisualServer 画。
# 斜切色块、环形图、图标的线条都用它：几何交给 GPU 光栅化，每条边外侧再铺一圈
# 透明度从 1 降到 0 的羽化带，宽度正好一个画面像素——这就是抗锯齿（和 TBH 的 MeshBuilder 同一做法）。
#
# 坐标是所在窗口的本地单位；px 是一个画面像素折合多少本地单位（= 1 / 缩放），羽化带就这么宽。

var px := 1.0
var _pts := PoolVector2Array()
var _cols := PoolColorArray()
var _idx := PoolIntArray()


func begin(pixel: float) -> void:
	px = max(0.05, pixel)
	_pts = PoolVector2Array()
	_cols = PoolColorArray()
	_idx = PoolIntArray()


func is_empty() -> bool:
	return _idx.size() == 0


func commit(ci: CanvasItem) -> void:
	if _idx.size() > 0:
		VisualServer.canvas_item_add_triangle_array(ci.get_canvas_item(), _idx, _pts, _cols)
	begin(px)


# 拼好的几何原样留着，下次形状没变时直接再交一次（环形图）
func snapshot() -> Array:
	return [_idx, _pts, _cols]


static func commit_snapshot(ci: CanvasItem, snap: Array) -> void:
	if snap.size() == 3 and snap[0].size() > 0:
		VisualServer.canvas_item_add_triangle_array(ci.get_canvas_item(), snap[0], snap[1], snap[2])


func _v(x: float, y: float, c: Color) -> int:
	_pts.append(Vector2(x, y))
	_cols.append(c)
	return _pts.size() - 1


func _quad(a: int, b: int, c: int, d: int) -> void:
	_idx.append(a)
	_idx.append(b)
	_idx.append(c)
	_idx.append(a)
	_idx.append(c)
	_idx.append(d)


static func _clear(c: Color) -> Color:
	return Color(c.r, c.g, c.b, 0.0)


# ---------------------------------------------------------------------------
# 基本形状
# ---------------------------------------------------------------------------

# 实心矩形，不羽化（像素对齐的条、块用它最清楚）
func rect(x: float, y: float, w: float, h: float, color: Color) -> void:
	if w <= 0.0 or h <= 0.0:
		return
	var a = _v(x, y, color)
	_v(x + w, y, color)
	_v(x + w, y + h, color)
	_v(x, y + h, color)
	_quad(a, a + 1, a + 2, a + 3)


# 斜切角度对应的水平偏移率：第 y 行比中线右移 slope × (y - 中线)
static func slope(deg: float) -> float:
	return -tan(deg2rad(clamp(deg, -75.0, 75.0)))


# 斜切的平行四边形（浮窗卡片的色块）。center_y 是斜切的中线（不给就是自己的中线）：
# 卡片的色块和下面的占比条用同一条中线，两条斜边才在一条直线上。四条边都羽化
func parallelogram(x: float, y: float, w: float, h: float, deg: float, color: Color, center_y = null) -> void:
	if w <= 0.0 or h <= 0.0:
		return
	var k = slope(deg)
	var cy = y + h * 0.5 if center_y == null else float(center_y)
	var f = px
	# 斜边的垂直羽化宽度是 f，换成水平方向要乘上 √(1 + k²)
	var fx = f * sqrt(1.0 + k * k)
	var off = _clear(color)
	var ys = [y - f, y, y + h, y + h + f]
	var base = _pts.size()
	for r in range(4):
		var dx = k * (ys[r] - cy)
		var edge = r == 0 or r == 3
		var x0 = x + dx
		var x1 = x + w + dx
		_v(x0 - fx, ys[r], off)
		_v(x0, ys[r], off if edge else color)
		_v(x1, ys[r], off if edge else color)
		_v(x1 + fx, ys[r], off)
	for r in range(3):
		for c in range(3):
			var a = base + r * 4 + c
			_quad(a, a + 1, a + 5, a + 4)


# 抗锯齿折线：每个点沿法线铺 4 个顶点（外羽化 / 线身 / 线身 / 外羽化），相邻点之间连 3 条带。
# 拐角用斜接，夹角很尖时限制长度，免得尖刺冲出去
func polyline(pts: PoolVector2Array, width: float, color: Color) -> void:
	var n = pts.size()
	if n < 2:
		return
	var off = _clear(color)
	var hw = max(width * 0.5, px * 0.5)
	var f = px
	var first = _pts.size()
	for i in range(n):
		var p = pts[i]
		var din = Vector2.ZERO
		var dout = Vector2.ZERO
		if i > 0:
			din = (p - pts[i - 1]).normalized()
		if i < n - 1:
			dout = (pts[i + 1] - p).normalized()
		var t = (din + dout).normalized()
		if t == Vector2.ZERO:
			t = din if din != Vector2.ZERO else (dout if dout != Vector2.ZERO else Vector2.RIGHT)
		var nrm = Vector2(-t.y, t.x)
		var seg = din if din != Vector2.ZERO else dout
		var cosv = abs(nrm.dot(Vector2(-seg.y, seg.x)))
		var m = hw / max(cosv, 0.4)
		_v(p.x + nrm.x * (m + f), p.y + nrm.y * (m + f), off)
		_v(p.x + nrm.x * m, p.y + nrm.y * m, color)
		_v(p.x - nrm.x * m, p.y - nrm.y * m, color)
		_v(p.x - nrm.x * (m + f), p.y - nrm.y * (m + f), off)
	for i in range(n - 1):
		var a = first + i * 4
		var b = a + 4
		_quad(a, b, b + 1, a + 1)
		_quad(a + 1, b + 1, b + 2, a + 2)
		_quad(a + 2, b + 2, b + 3, a + 3)


# 环形的一段：角度从 12 点方向起、顺时针，单位弧度。内外圆和两端都羽化；
# gap 是两段之间的缝（本地单位，沿切线方向平移，内外圈缝宽一致）
func ring(cx: float, cy: float, r_in: float, r_out: float, a0: float, a1: float, color: Color, gap: float = 0.0) -> void:
	var sweep = a1 - a0
	if sweep <= 0.0 or r_out <= r_in:
		return
	# 太窄的一段（内圈弧长连缝都不够）画不出来。环形图已经把这种行并进「其他」，这里只是兜底
	if sweep * r_in <= gap + px and sweep < TAU - 0.001:
		return
	var full = sweep >= TAU - 0.001
	if full:
		gap = 0.0
	var steps = int(max(2, ceil(sweep / TAU * 160.0)))
	var off = _clear(color)
	var f = px
	var radii = [r_out + f, r_out, r_in, max(0.0, r_in - f)]
	var first = _pts.size()
	var cols = 0
	var half = gap * 0.5
	if not full:
		_column(cx, cy, radii, a0, half - f, true, color, off)
		cols += 1
	for s in range(steps + 1):
		var a = a0 + sweep * s / steps
		var shift = 0.0
		if not full:
			if s == 0:
				shift = half
			elif s == steps:
				shift = -half
		_column(cx, cy, radii, a, shift, false, color, off)
		cols += 1
	if not full:
		_column(cx, cy, radii, a1, -half + f, true, color, off)
		cols += 1
	# 整圈时最后一列落在第一列上，不用回绕
	for s in range(cols - 1):
		var a = first + s * 4
		var b = a + 4
		for k in range(3):
			_quad(a + k, b + k, b + k + 1, a + k + 1)


func _column(cx: float, cy: float, radii: Array, a: float, shift: float, fade: bool, on: Color, off: Color) -> void:
	var sx = sin(a)
	var sy = -cos(a)
	var tx = cos(a)   # 顺时针方向的切线
	var ty = sin(a)
	for k in range(4):
		var r = radii[k]
		var edge = fade or k == 0 or k == 3
		_v(cx + sx * r + tx * shift, cy + sy * r + ty * shift, off if edge else on)


# 实心圆点（外沿羽化）
func disc(cx: float, cy: float, r: float, color: Color) -> void:
	ring(cx, cy, 0.0, r, 0.0, TAU, color)
