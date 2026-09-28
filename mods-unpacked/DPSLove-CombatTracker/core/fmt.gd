extends Reference

# 数字与时长的显示格式。


# 大数字缩写：1234567 -> 1.23M。后期伤害动辄七八位，不缩写根本看不了。
static func short(v: float) -> String:
	var a = abs(v)
	if a >= 1e12:
		return _trim(v / 1e12) + "T"
	if a >= 1e9:
		return _trim(v / 1e9) + "B"
	if a >= 1e6:
		return _trim(v / 1e6) + "M"
	if a >= 1e3:
		return _trim(v / 1e3) + "K"
	return _one(v)


static func _trim(v: float) -> String:
	# 最多两位小数，去掉末尾的 0
	var s = "%.2f" % v
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	if s.ends_with("."):
		s = s.substr(0, s.length() - 1)
	return s


static func _one(v: float) -> String:
	var s = "%.1f" % v
	if s.ends_with(".0"):
		s = s.substr(0, s.length() - 2)
	return s


static func dur(seconds: float) -> String:
	var s = int(round(max(0.0, seconds)))
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]


static func secs(seconds: float) -> String:
	return "%.1fs" % max(0.0, seconds)


static func pct(v: float) -> String:
	return "%.1f%%" % (v * 100.0)


static func count(n: int) -> String:
	var s = str(abs(n))
	var out := ""
	var i = s.length()
	while i > 3:
		out = "," + s.substr(i - 3, 3) + out
		i -= 3
	out = s.substr(0, i) + out
	return ("-" if n < 0 else "") + out


static func per_sec(total: float, duration: float) -> float:
	return total / duration if duration > 0.05 else 0.0


static func clock_of(unix: int) -> String:
	if unix <= 0:
		return ""
	var bias = int(OS.get_time_zone_info().get("bias", 0))
	var dt = OS.get_datetime_from_unix_time(unix + bias * 60)
	return "%02d:%02d" % [dt.hour, dt.minute]
