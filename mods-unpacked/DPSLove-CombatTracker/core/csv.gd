extends Reference

# 导出一段的统计为 CSV（UTF-8 带 BOM，Excel 直接打开不乱码）。
# 三个视图、按来源的全部行都在一张表里；首行写明段名和时长。

const Model = preload("model.gd")
const Strings = preload("strings.gd")
const Fmt = preload("fmt.gd")


static func write(enc, names, overkill: bool, dir: String, tag: String) -> String:
	if enc == null:
		return ""
	var d = Directory.new()
	if not d.dir_exists(dir) and d.make_dir_recursive(dir) != OK:
		return ""
	var dt = OS.get_datetime()
	var path = dir.plus_file("bct-%s-w%02d-%04d%02d%02d-%02d%02d%02d.csv" % [
		tag, enc.wave, dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second])
	var lines := PoolStringArray()
	lines.append(Strings.csv_title(names.encounter_title(enc), Fmt.dur(enc.duration)))
	lines.append(Strings.csv_header())
	for view in Model.VIEWS:
		var rows = Model.sorted_rows(enc, view, Model.GROUP_SOURCE, overkill)
		var total = enc.total(view, overkill)
		for s in rows:
			var value = s.metric(overkill)
			lines.append(PoolStringArray([
				_cell(Strings.view_label(view)),
				_cell(names.player_label(s.player, enc)),
				_cell(names.source_label(view, s.src)),
				str(int(round(value))),
				Fmt.pct(value / total if total > 0.0 else 0.0),
				"%.1f" % Fmt.per_sec(value, enc.duration),
				str(s.hits),
				str(s.crits),
				str(int(round(s.max_hit))),
				str(s.kills),
				str(int(round(s.total))),
			]).join(","))
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		return ""
	f.store_string("﻿" + lines.join("\r\n") + "\r\n")
	f.close()
	return path


static func _cell(s: String) -> String:
	if s.find(",") >= 0 or s.find("\"") >= 0 or s.find("\n") >= 0:
		return "\"" + s.replace("\"", "\"\"") + "\""
	return s
