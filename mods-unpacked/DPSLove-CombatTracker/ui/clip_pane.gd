extends Control

# 窗口里的一块子画布：会滚动的列表（裁掉视口外的半行）、曲线（数据没变就不重画）。
# 自己不处理鼠标，画什么由所在的窗口决定（_paint_pane）。

var host = null
var pane_id := ""


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	focus_mode = FOCUS_NONE
	rect_clip_content = true


func _draw() -> void:
	if host != null:
		host._paint_pane(pane_id, self)
