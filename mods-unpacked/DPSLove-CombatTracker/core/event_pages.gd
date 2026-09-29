extends Reference

# 「逐条事件」视图的数据：某一段的原始事件，从日志文件里重新读出来。
#
# 本局进行中的那段不走这里（统计节点在内存里留着这一段的事件）；已经结束的段和导入的日志，
# 原始事件只在日志里——从头解析到那一段结束为止，把属于它的伤害 / 承伤 / 治疗事件挑出来。
# 一段最多留 MAX_EVENTS 条（罕见的超长段，别把内存撑爆）。
#
# 纯 GDScript，不碰场景树：战斗记录窗口在后台线程里调它。

const Model = preload("model.gd")
const Parser = preload("parser.gd")
const LogFormat = preload("log_format.gd")
const LogReader = preload("log_reader.gd")

const MAX_EVENTS = 30000


# 读 path 里序号为 index 的那一段。wave 用来核对是不是同一段（序号对上、波次对不上就不是）。
# 返回 {events, error, capped}；error 为 "notFound" 表示日志里对不上这一段
static func read(path: String, index: int, wave: int, max_events: int = MAX_EVENTS) -> Dictionary:
	var out = {"events": [], "error": "", "capped": false}
	var loaded = LogReader.load_text(path)
	if loaded.error != "":
		out.error = loaded.error
		return out
	var lines = loaded.text.split("\n", false)
	if lines.size() == 0 or not lines[0].begins_with("#BCTLOG|"):
		out.error = "not a combat log"
		return out
	# 只留最近一段的详细数据：长日志不会把整局都载进内存
	var s = Model.BctSession.new()
	s.history_size = 1
	var matched := false
	var events := []
	for i in range(1, lines.size()):
		var line = lines[i]
		if line.ends_with("\r"):
			line = line.substr(0, line.length() - 1)
		if line.empty() or line.begins_with("#"):
			continue
		var ev = LogFormat.decode(line)
		if ev == null:
			continue
		Parser.apply(s, ev)
		var cur = s.current
		if cur == null:
			if matched:
				break   # 那一段收掉了，不用往下读
			continue
		if cur.index > index:
			break
		if cur.index != index:
			continue
		if not matched:
			if cur.wave != wave:
				break
			matched = true
		var k = ev[0]
		if k == "D" or k == "T" or k == "H":
			if events.size() < max_events:
				events.append(ev)
			else:
				out.capped = true
	out.events = events
	if not matched:
		out.error = "notFound"
	return out
