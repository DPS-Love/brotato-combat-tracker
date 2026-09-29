extends Control

# 悬停提示：光标在带提示的按钮上停够一会儿，旁边浮出一行字。自己不接鼠标，也不算窗口。

var skin = null
var _text := ""


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	focus_mode = FOCUS_NONE
	visible = false


func show_tip(s: String, mouse: Vector2) -> void:
	if s == "":
		_text = ""
		if visible:
			visible = false
		return
	var k = skin.scale
	var w = ceil(skin.text_width(s, skin.FONT_SMALL)) + 16.0
	var h = 22.0
	rect_scale = Vector2(k, k)
	rect_size = Vector2(w, h)
	var view = get_viewport_rect().size
	var x = clamp(mouse.x + 12.0, 0.0, max(0.0, view.x - w * k))
	var y = mouse.y + 20.0
	if y + h * k > view.y:
		y = mouse.y - h * k - 6.0
	rect_position = Vector2(round(x), round(y))
	if s != _text or not visible:
		_text = s
		visible = true
		update()


func _draw() -> void:
	if _text == "":
		return
	skin.box(self, Rect2(Vector2.ZERO, rect_size), skin.TIP_BG, 4.0)
	skin.text(self, Rect2(8, 0, rect_size.x - 16.0, rect_size.y), _text, skin.FONT_SMALL, skin.TEXT)
