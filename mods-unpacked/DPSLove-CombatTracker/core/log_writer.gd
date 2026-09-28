extends Reference

# 本局的战斗日志。一次游戏（进程）一份：logs/bct-yyyyMMdd-HHmmss.bctlog
#
# 写的过程中是纯文本，每 2 秒追加一次（打开、追加、关闭），游戏被强杀最多丢最后 2 秒。
# 正常退出时写 #END，再压成标准 gzip（.bctlog.gz）并删掉文本版；上次没压成的，
# 下次启动时补压。解压后就是逐行的事件，用任何 gzip 工具都能打开。

const LogFormat = preload("log_format.gd")

var path := ""
var events := 0
var _pending := PoolStringArray()
var _ok := false


func is_open() -> bool:
	return _ok


func open(dir: String, meta: Dictionary) -> bool:
	var d = Directory.new()
	if not d.dir_exists(dir) and d.make_dir_recursive(dir) != OK:
		return false
	var dt = OS.get_datetime()
	var name = "bct-%04d%02d%02d-%02d%02d%02d.bctlog" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	path = dir.plus_file(name)
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		return false
	var parts := PoolStringArray()
	parts.append("#META")
	for k in meta.keys():
		parts.append(str(k) + "=" + LogFormat.escape(str(meta[k])))
	f.store_string(LogFormat.HEADER + "\n" + parts.join("|") + "\n")
	f.close()
	_ok = true
	return true


func write(ev: Array) -> void:
	if _ok:
		_pending.append(LogFormat.encode(ev))
		events += 1


func flush() -> void:
	if not _ok or _pending.size() == 0:
		return
	var f = File.new()
	if f.open(path, File.READ_WRITE) != OK:
		# 文件被删了或被占用：这一局不再写，统计本身不受影响
		_ok = false
		_pending = PoolStringArray()
		return
	f.seek_end()
	f.store_string(_pending.join("\n") + "\n")
	f.close()
	_pending = PoolStringArray()


# 收尾：写 #END、压缩。返回最终文件路径
func close() -> String:
	if not _ok:
		return ""
	flush()
	var f = File.new()
	if f.open(path, File.READ_WRITE) == OK:
		f.seek_end()
		f.store_string("#END|events=%d\n" % events)
		f.close()
	_ok = false
	var gz = compress_file(path)
	return gz if gz != "" else path


# 把文本日志压成 .gz（标准 gzip），成功后删掉原文件。失败返回空串，原文件保留
static func compress_file(p: String) -> String:
	var f = File.new()
	if f.open(p, File.READ) != OK:
		return ""
	var bytes = f.get_buffer(f.get_len())
	f.close()
	var gz = bytes.compress(File.COMPRESSION_GZIP)
	if gz.size() == 0 and bytes.size() > 0:
		return ""
	var out = p + ".gz"
	if f.open(out, File.WRITE) != OK:
		return ""
	f.store_buffer(gz)
	f.close()
	var d = Directory.new()
	d.remove(p)
	return out
