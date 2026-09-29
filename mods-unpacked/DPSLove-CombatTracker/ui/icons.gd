extends Reference

# 界面图标。TBH 用 Windows 自带的图标字体（Segoe Fluent Icons / MDL2 Assets）；Brotato 还跑在 macOS 和
# Steam Deck 上，这里照着那几个字形用线条画一遍，哪个平台都一样。
# 图形按 16×16 的格子描述，画的时候缩放到指定大小、居中，线宽随大小变。

const AaMesh = preload("aa_mesh.gd")


# 把图标拼进网格 m，以原点为中心（由调用方平移过去）
static func build(m, name: String, size: float, color: Color, px: float) -> void:
	m.begin(px)
	if size <= 0.0:
		return
	var u = size / 16.0
	var o = -Vector2(8.0, 8.0) * u
	var width = max(size / 13.0, px)
	for stroke in _strokes(name):
		var pts := PoolVector2Array()
		for p in stroke:
			pts.append(o + Vector2(p[0], p[1]) * u)
		m.polyline(pts, width, color)
	for d in _dots(name):
		m.disc(o.x + d[0] * u, o.y + d[1] * u, d[2] * u, color)


# 圆弧上的点（16 格坐标）：角度 0 在右边、顺时针增大（屏幕 y 向下）
static func _arc(cx: float, cy: float, r: float, a0_deg: float, a1_deg: float) -> Array:
	var out := []
	var n = int(max(6, abs(a1_deg - a0_deg) / 12.0))
	for i in range(n + 1):
		var a = deg2rad(a0_deg + (a1_deg - a0_deg) * i / n)
		out.append([cx + cos(a) * r, cy + sin(a) * r])
	return out


# 箭头：尖在 tip，朝 dir 方向（16 格坐标）
static func _head(tip: Array, dir: Vector2, length: float) -> Array:
	var back = -dir.normalized() * length
	var w1 = back.rotated(0.75)
	var w2 = back.rotated(-0.75)
	return [[tip[0] + w1.x, tip[1] + w1.y], tip, [tip[0] + w2.x, tip[1] + w2.y]]


static func _strokes(name: String) -> Array:
	match name:
		"close":
			return [[[4, 4], [12, 12]], [[12, 4], [4, 12]]]
		"chevron_up":
			return [[[3.5, 10.5], [8, 6], [12.5, 10.5]]]
		"chevron_down":
			return [[[3.5, 5.5], [8, 10], [12.5, 5.5]]]
		"refresh":
			# ⟳：从 1 点钟顺时针绕到 11 点钟，箭头朝着缺口
			var arc = _arc(8, 8.3, 5.4, 300.0, 590.0)
			var a = deg2rad(590.0)
			return [arc, _head(arc.back(), Vector2(-sin(a), cos(a)), 3.2)]
		"history":
			# 表盘外一圈逆时针的箭头（缺口在左下），加两根指针
			var arc = _arc(8.3, 8, 5.6, 180.0, 450.0)
			var a = deg2rad(180.0)
			return [arc, _head(arc[0], Vector2(sin(a), -cos(a)), 3.2), [[8.3, 4.8], [8.3, 8.2], [10.8, 9.7]]]
		"settings":
			var gear := []
			for i in range(8):
				var c = i * TAU / 8.0
				for pair in [[-0.34, 5.0], [-0.19, 6.7], [0.19, 6.7], [0.34, 5.0]]:
					var a = c + pair[0]
					gear.append([8 + cos(a) * pair[1], 8 + sin(a) * pair[1]])
			gear.append(gear[0])
			return [gear, _arc(8, 8, 2.2, 0.0, 360.0)]
		"folder":
			return [[[1.5, 4], [6, 4], [7.5, 5.5], [14.5, 5.5], [14.5, 13], [1.5, 13], [1.5, 4]], [[1.5, 7.5], [14.5, 7.5]]]
		"import":
			return [[[8, 1.8], [8, 10]], [[4.8, 6.8], [8, 10], [11.2, 6.8]], [[2.5, 9.5], [2.5, 13.5], [13.5, 13.5], [13.5, 9.5]]]
		"export":
			return [[[6.5, 2.5], [2.5, 2.5], [2.5, 13.5], [13.5, 13.5], [13.5, 9.5]], [[7, 9], [13.5, 2.5]], [[9.5, 2.5], [13.5, 2.5], [13.5, 6.5]]]
		"chart":
			return [[[2, 2], [2, 14], [14, 14]], [[4.5, 11.5], [7.5, 7], [10, 9.5], [13.5, 4]]]
		"list":
			return [[[6, 4], [14, 4]], [[6, 8], [14, 8]], [[6, 12], [14, 12]]]
		"document":
			return [[[3.5, 1.5], [9.5, 1.5], [12.5, 4.5], [12.5, 14.5], [3.5, 14.5], [3.5, 1.5]], [[9.5, 1.5], [9.5, 4.5], [12.5, 4.5]]]
		"keyboard":
			return [[[1.5, 4], [14.5, 4], [14.5, 12], [1.5, 12], [1.5, 4]], [[5, 9.6], [11, 9.6]]]
		"color":
			return [_arc(8, 8, 6.0, 0.0, 360.0)]
		"sliders":
			return [[[2, 4.5], [14, 4.5]], [[2, 8], [14, 8]], [[2, 11.5], [14, 11.5]]]
		"check":
			return [[[3, 8.5], [6.5, 12], [13, 4.5]]]
		"disk":
			return [[[2.5, 2.5], [11, 2.5], [13.5, 5], [13.5, 13.5], [2.5, 13.5], [2.5, 2.5]], [[5, 2.5], [5, 6], [10.5, 6], [10.5, 2.5]], [[4.5, 13.5], [4.5, 9.5], [11.5, 9.5], [11.5, 13.5]]]
	return []


# 实心圆点：[x, y, 半径]
static func _dots(name: String) -> Array:
	match name:
		"list":
			return [[2.8, 4, 1.0], [2.8, 8, 1.0], [2.8, 12, 1.0]]
		"keyboard":
			return [[4, 6.6, 0.8], [6.7, 6.6, 0.8], [9.3, 6.6, 0.8], [12, 6.6, 0.8]]
		"color":
			return [[5, 7, 1.1], [8, 4.8, 1.1], [11, 7, 1.1], [10.3, 10.3, 1.1]]
		"sliders":
			return [[5, 4.5, 1.7], [10.5, 8, 1.7], [7, 11.5, 1.7]]
	return []
