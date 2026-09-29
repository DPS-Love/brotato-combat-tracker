extends Reference

# 纵向列表的滚动状态：行高固定，只画看得见的那几行。滚动是平滑的——滚轮给目标位置，
# 每帧往目标靠；视口裁掉的半行照样画一半（由 clip_pane 裁）。右边一条细滚动条，可拖。

var row_h := 20.0
var view_h := 100.0
var count := 0
var offset := 0.0
var target := 0.0


func _init(row_height: float = 20.0) -> void:
	row_h = row_height


func setup(n: int, height: float) -> void:
	count = int(max(0, n))
	view_h = max(0.0, height)
	target = clamp(target, 0.0, max_offset())
	offset = clamp(offset, 0.0, max_offset())


func max_offset() -> float:
	return max(0.0, count * row_h - view_h)


# 第一行（可能只露出一半）的下标
func first() -> int:
	return int(floor(offset / row_h)) if row_h > 0.0 else 0


# 至少要画这么多行才铺得满
func visible_rows() -> int:
	return int(ceil(view_h / row_h)) + 1 if row_h > 0.0 else 0


func scroll_by(px: float) -> void:
	target = clamp(target + px, 0.0, max_offset())


func page(dir: int) -> void:
	scroll_by(dir * max(row_h, floor(view_h / row_h) * row_h))


func to_top() -> void:
	target = 0.0
	offset = 0.0


# 滚到最底（逐条事件跟着最新的走）
func to_end() -> void:
	target = max_offset()
	offset = target


# 已经在最底（容差半行）：新内容进来时要不要跟着往下滚
func at_end() -> bool:
	return offset >= max_offset() - row_h * 0.5


# 每帧调：往目标位置靠。位置变了返回 true
func tick(dt: float) -> bool:
	if abs(target - offset) < 0.25:
		if offset == target:
			return false
		offset = target
		return true
	offset = lerp(offset, target, 1.0 - exp(-dt * 18.0))
	return true


# 完整露出来的第一行和最后一行（从 1 数），底栏的「a–b / N」用
func visible_range() -> Array:
	if count == 0:
		return [0, 0]
	var from = int(clamp(ceil(offset / row_h - 0.35), 0, count - 1)) + 1
	var to = int(clamp(floor((offset + view_h) / row_h + 0.35), from, count))
	return [from, to]


# 滚动条：[y, 高度]；内容不超出视口时为空
func thumb() -> Array:
	var content = count * row_h
	if content <= view_h + 0.5:
		return []
	var h = max(24.0, view_h * view_h / content)
	var t = offset / max_offset() if max_offset() > 0.0 else 0.0
	return [(view_h - h) * t, h]


func drag_thumb(dy: float) -> void:
	var content = count * row_h
	if content <= view_h:
		return
	var h = max(24.0, view_h * view_h / content)
	target = clamp(target + dy * (content - view_h) / max(1.0, view_h - h), 0.0, max_offset())
	offset = target
