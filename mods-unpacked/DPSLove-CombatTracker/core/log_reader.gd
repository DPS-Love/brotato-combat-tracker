extends Reference

# 读战斗日志，按当前版本的解析器重新解析成一个会话。
# 纯 GDScript，不碰场景树：主面板在后台线程里调它。

const Model = preload("model.gd")
const Parser = preload("parser.gd")
const LogFormat = preload("log_format.gd")

const EXTENSIONS = [".bctlog", ".bctlog.gz"]


static func is_log_name(name: String) -> bool:
	return name.ends_with(".bctlog") or name.ends_with(".bctlog.gz")


# 日志目录里的全部日志，新的在前：[{path, name, size, mtime}]
static func list_logs(dir: String) -> Array:
	var out := []
	var d = Directory.new()
	if d.open(dir) != OK:
		return out
	if d.list_dir_begin(true, true) != OK:
		return out
	var f = File.new()
	while true:
		var name = d.get_next()
		if name == "":
			break
		if d.current_is_dir() or not is_log_name(name):
			continue
		var p = dir.plus_file(name)
		var size := 0
		if f.open(p, File.READ) == OK:
			size = f.get_len()
			f.close()
		out.append({"path": p, "name": name, "size": size, "mtime": f.get_modified_time(p)})
	d.list_dir_end()
	out.sort_custom(BctByTime.new(), "desc")
	return out


class BctByTime extends Reference:
	func desc(a, b) -> bool:
		if a.mtime == b.mtime:
			return a.name > b.name
		return a.mtime > b.mtime


# 读出文本；失败时 error 非空
static func load_text(path: String) -> Dictionary:
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return {"text": "", "error": "open failed"}
	if not path.ends_with(".gz"):
		var text = f.get_as_text()
		f.close()
		return {"text": text, "error": ""}
	var bytes = f.get_buffer(f.get_len())
	f.close()
	if bytes.size() < 18:
		return {"text": "", "error": "file too short"}
	# gzip 尾部 4 字节是原文长度（小端，模 2^32）
	var n = bytes.size()
	var isize = int(bytes[n - 4]) | (int(bytes[n - 3]) << 8) | (int(bytes[n - 2]) << 16) | (int(bytes[n - 1]) << 24)
	if isize <= 0 or isize > 512 * 1024 * 1024:
		return {"text": "", "error": "bad gzip size"}
	var raw = bytes.decompress(isize, File.COMPRESSION_GZIP)
	if raw.size() == 0:
		return {"text": "", "error": "gzip decompress failed"}
	return {"text": raw.get_string_from_utf8(), "error": ""}


static func read(path: String, history_size: int = 0) -> Object:
	var s = Model.BctSession.new()
	s.source_path = path
	s.history_size = history_size
	var loaded = load_text(path)
	if loaded.error != "":
		s.meta["error"] = loaded.error
		return s
	var lines = loaded.text.split("\n", false)
	if lines.size() == 0 or not lines[0].begins_with("#BCTLOG|"):
		s.meta["error"] = "not a combat log"
		return s
	var ended := false
	for i in range(1, lines.size()):
		var line = lines[i]
		if line.ends_with("\r"):
			line = line.substr(0, line.length() - 1)
		if line.empty():
			continue
		if line.begins_with("#"):
			if line.begins_with("#META|"):
				for kv in line.substr(6).split("|", false):
					var eq = kv.find("=")
					if eq > 0:
						s.meta[kv.substr(0, eq)] = LogFormat.unescape(kv.substr(eq + 1))
			elif line.begins_with("#END"):
				ended = true
			continue
		var ev = LogFormat.decode(line)
		if ev == null:
			s.bad_lines += 1
			continue
		Parser.apply(s, ev)
	Parser.finish(s)
	s.truncated = not ended
	if s.meta.has("start_unix") and str(s.meta["start_unix"]).is_valid_integer():
		s.started_unix = int(s.meta["start_unix"])
	return s
