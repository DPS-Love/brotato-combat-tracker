extends Reference

# 战斗日志的行格式（v1）。说明见 docs/eventlog.md。
#
#   时钟|字母|字段|字段|…
#
# 文本字段里的 \、|、换行分别转义成 \\、\p、\n。空字段表示「不知道」。
# 只加不改：已发布的字母和字段含义永远不变，新信息用新字母或在行尾追加字段。

const HEADER = "#BCTLOG|1"
const VERSION = 1


static func escape(s: String) -> String:
	if s.find("\\") < 0 and s.find("|") < 0 and s.find("\n") < 0 and s.find("\r") < 0:
		return s
	return s.replace("\\", "\\\\").replace("|", "\\p").replace("\n", "\\n").replace("\r", "")


static func unescape(s: String) -> String:
	if s.find("\\") < 0:
		return s
	var out := ""
	var i := 0
	var n := s.length()
	while i < n:
		var c = s[i]
		if c == "\\" and i + 1 < n:
			var d = s[i + 1]
			if d == "p":
				out += "|"
			elif d == "n":
				out += "\n"
			else:
				out += d
			i += 2
		else:
			out += c
			i += 1
	return out


static func num(v) -> String:
	var f = float(v)
	if f == floor(f) and abs(f) < 1e15:
		return str(int(f))
	return str(stepify(f, 0.01))


static func clock(t: float) -> String:
	return "%.3f" % t


static func field(v) -> String:
	match typeof(v):
		TYPE_INT:
			return str(v)
		TYPE_REAL:
			return num(v)
		TYPE_BOOL:
			return "1" if v else "0"
		TYPE_STRING:
			return escape(v)
		TYPE_NIL:
			return ""
		TYPE_DICTIONARY, TYPE_ARRAY:
			return escape(to_json(v))
		_:
			return escape(str(v))


# 事件 → 行
static func encode(ev: Array) -> String:
	var parts := PoolStringArray()
	parts.append(clock(float(ev[1])))
	parts.append(str(ev[0]))
	for i in range(2, ev.size()):
		parts.append(field(ev[i]))
	return parts.join("|")


# 行 → 事件；认不出来返回 null
static func decode(line: String):
	var raw = line.split("|")
	if raw.size() < 2:
		return null
	var f := []
	for part in raw:
		f.append(unescape(part))
	if not f[0].is_valid_float():
		return null
	var t = float(f[0])
	var kind = f[1]
	match kind:
		"D":
			# D 时钟 玩家 来源 目标 数值 有效值 标志 [形式] [类别]
			if f.size() < 8:
				return null
			return ["D", t, int(f[2]), f[3], f[4], float(f[5]), float(f[6]), int(f[7]),
				f[8] if f.size() > 8 else "", f[9] if f.size() > 9 else ""]
		"T":
			# T 时钟 玩家 攻击者 数值 有效值 标志
			if f.size() < 7:
				return null
			return ["T", t, int(f[2]), f[3], float(f[4]), float(f[5]), int(f[6])]
		"H":
			# H 时钟 玩家 来源 数值
			if f.size() < 5:
				return null
			return ["H", t, int(f[2]), f[3], float(f[4])]
		"W":
			# W 时钟 start 波次 标签 局序 开始时刻 / W 时钟 end 标签 / W 时钟 tags 标签
			if f.size() < 3:
				return null
			var ev = ["W", t, f[2]]
			for i in range(3, f.size()):
				ev.append(int(f[i]) if f[i].is_valid_integer() else 0)
			return ev
		"C":
			# C 时钟 玩家 角色
			if f.size() < 4:
				return null
			return ["C", t, int(f[2]), f[3]]
		"L":
			# L 时钟 玩家 武器键,武器键,…
			if f.size() < 4:
				return null
			return ["L", t, int(f[2]), f[3]]
		"R":
			return ["R", t]
		"P":
			# P 时钟 玩家 快照(JSON) [波次]
			if f.size() < 4:
				return null
			return ["P", t, int(f[2]), f[3], int(f[4]) if f.size() > 4 and f[4].is_valid_integer() else 0]
		_:
			# 不认识的字母原样交给解析器，由它计入「不认识」
			return [kind, t]
