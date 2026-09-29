extends Reference

# 环形图：各段按占比、段间留缝，环心写总量和每秒。和旁边的拆分表 / 图例联动：
# 光标停在某一段上，hovered 报出是哪一行（表里对应的行跟着高亮）；表里某一行被指着时，
# 调用方把它作为 highlight 传进 paint()，这一段往外凸出、别的变淡，环心改写这一项。
# 行是从大到小排的：一屏之外的、窄到画不出来的都在尾巴上，并成最后一段灰色的「其他」；
# 「其他」自己也画不出来时，这点角度并给最后一段——跳过不画的话，这些角度会在 12 点方向攒成一道时宽时窄的缝。
# 形状没变（按 0.1% 取整的各段和高亮项）就不重建网格。与 TBH 的 DonutChart 一致。

const AaMesh = preload("aa_mesh.gd")
const Fmt = preload("../core/fmt.gd")
const Strings = preload("../core/strings.gd")

const OTHER = -2
const GAP = 2.0
# 单独成段至少要在内圈留出的实色宽度（画面像素），不够就并进「其他」
const MIN_SOLID_PX = 1.5

var max_slices := 7
var folded := 0      # 单独成段的行数：行号不小于它的都算在「其他」里，表里用灰点
var hovered := -1    # 光标停在哪一段：行号，「其他」是 OTHER，-1 没有
var _ends := []
var _ids := []
var _sig := ""
var _snap := []
var _rect := Rect2()
var _mesh = AaMesh.new()


func _init(slices: int = 7) -> void:
	max_slices = slices


# 这一帧不画（没有数据）：光标停在原来的位置也不算指着
func hide() -> void:
	_rect = Rect2()
	_ends = []
	hovered = -1
	folded = 0


# values：从大到小排好的各行数值。highlight：要突出的行号或 OTHER（-1 = 不突出）；
# 并进「其他」的行突出的是「其他」那段
func paint(ci: CanvasItem, skin, r: Rect2, values: Array, big_text: String, small_text: String, highlight: int) -> void:
	_rect = r
	var total := 0.0
	for v in values:
		total += float(v)
	if highlight >= values.size():
		highlight = -1

	var c = r.size.x * 0.5
	var outer = c - 4.0            # 留出凸出的余地
	var inner = outer * 0.64
	var px = skin.px()

	# 哪些行单独成段：列得下，而且突出时（内圈缩 1）扣掉缝还剩 MIN_SOLID_PX 的实色。
	# 行从大到小排，头一个不够的往后全都不够
	var min_share = (GAP + MIN_SOLID_PX * px) / max(1.0, inner - 1.0) / TAU
	var fold = 0
	if total > 0.0:
		while fold < values.size() and fold < max_slices and float(values[fold]) / total >= min_share:
			fold += 1
	var rest := 0.0
	for i in range(fold, values.size()):
		rest += float(values[i])
	var other_shown = total > 0.0 and rest > 0.0 and rest / total >= min_share
	folded = fold
	if highlight == OTHER and rest <= 0.0:
		highlight = -1

	var big = big_text
	var small = small_text
	if highlight == OTHER:
		big = Fmt.short(rest)
		small = Strings.other() + " " + Fmt.pct(rest / total)
	elif highlight >= 0 and total > 0.0:
		big = Fmt.short(float(values[highlight]))
		small = Fmt.pct(float(values[highlight]) / total)

	_ends = []
	_ids = []
	var acc := 0.0
	for i in range(fold):
		acc += float(values[i])
		# 「其他」画不出来：最后一段直接接到 12 点，段间的缝都一样宽
		_ends.append(1.0 if (i == fold - 1 and not other_shown) else acc / total)
		_ids.append(i)
	if other_shown:
		_ends.append(1.0)
		_ids.append(OTHER)

	var hot = OTHER if highlight >= fold else highlight
	var sig = "%.3f|%s|%d|" % [skin.scale, str(r), hot]
	for k in range(_ends.size()):
		sig += "%d:%.3f;" % [_ids[k], _ends[k]]
	if sig != _sig:
		_sig = sig
		_mesh.begin(px)
		var cx = r.position.x + c
		var cy = r.position.y + c
		if _ends.empty():
			_mesh.ring(cx, cy, inner, outer, 0.0, TAU, Color(1, 1, 1, 0.08))
		else:
			var a0 = 0.0
			for k in range(_ends.size()):
				var id = _ids[k]
				var a1 = _ends[k] * TAU
				var color = skin.OTHER_SLICE if id == OTHER else skin.palette(id)
				if hot != -1 and id != hot:
					color = skin.with_alpha(color, 0.35)
				var on = id == hot
				_mesh.ring(cx, cy, inner - 1.0 if on else inner, outer + 3.5 if on else outer, a0, a1, color, GAP)
				a0 = a1
		_snap = _mesh.snapshot()
	AaMesh.commit_snapshot(ci, _snap)

	skin.text(ci, Rect2(r.position.x, r.position.y + c - 17.0, r.size.x, 20.0), big, 14, skin.TEXT, 1, true)
	skin.text(ci, Rect2(r.position.x, r.position.y + c + 3.0, r.size.x, 14.0), small, skin.FONT_TINY, skin.TEXT_DIM, 1)


# 光标移动时调（窗口本地坐标）：算出指着的是哪一段（按角度，12 点方向起顺时针）。换了一段返回 true
func update_hover(local: Vector2) -> bool:
	var idx = -1
	if _rect.size.x > 0.0 and _ends.size() > 0:
		var c = _rect.size.x * 0.5
		var d = local - (_rect.position + Vector2(c, c))
		var rr = d.length()
		var outer = c - 4.0
		var inner = outer * 0.64
		if rr >= inner - 3.0 and rr <= outer + 6.0:
			var a = atan2(d.x, -d.y)   # y 向下：12 点方向是 0，顺时针增大
			if a < 0.0:
				a += TAU
			var t = a / TAU
			for i in range(_ends.size()):
				if t > _ends[i]:
					continue
				idx = _ids[i]
				break
	if idx == hovered:
		return false
	hovered = idx
	return true
