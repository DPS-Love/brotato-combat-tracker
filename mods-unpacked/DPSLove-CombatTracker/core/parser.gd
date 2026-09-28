extends Reference

# 战斗事件 → 统计。实时统计和导入日志走同一个入口 apply()，所以面板上看到的数字
# 和日后导入这份日志看到的逐项一致。
#
# 事件是数组，第一项是事件字母，第二项是波次时钟（秒，开波清零，暂停不走）。
# 各字母的字段见 docs/eventlog.md；这里对字段个数宽容：多的忽略，少的按「不知道」。
#
# 纯 GDScript，不引用游戏类型：导入在后台线程里跑。

const Model = preload("model.gd")

const SNAPSHOT_VERSION = 1


static func apply(s, ev: Array) -> void:
	if ev.size() < 2:
		s.bad_lines += 1
		return
	s.event_count += 1
	match str(ev[0]):
		"D":
			_damage(s, ev)
		"T":
			_taken(s, ev)
		"H":
			_heal(s, ev)
		"W":
			_wave(s, ev)
		"C":
			_character(s, ev)
		"L":
			_loadout(s, ev)
		"R":
			_reset(s, ev)
		"P":
			_remote(s, ev)
		_:
			s.unknown_lines += 1


# 本局实时时钟推进：不是事件，不写日志，只让进行中那段的时长跟着走
static func tick(s, clock: float) -> void:
	var e = s.current
	if e != null and clock - e.t0 > e.duration:
		e.duration = clock - e.t0


# 会话结束（导入读到末尾、游戏退出）时把进行中的段收掉
static func finish(s) -> void:
	if s.current != null:
		_close(s, s.current.t0 + s.current.duration)


# ---------------------------------------------------------------------------
# 分段
# ---------------------------------------------------------------------------

static func _wave(s, ev: Array) -> void:
	var t = float(ev[1])
	var sub = str(ev[2]) if ev.size() > 2 else ""
	if sub == "start":
		_close(s, t)
		var wave = int(ev[3]) if ev.size() > 3 else 0
		var tags = int(ev[4]) if ev.size() > 4 else 0
		var run_seq = int(ev[5]) if ev.size() > 5 else 0
		var unix = int(ev[6]) if ev.size() > 6 else 0
		_open(s, wave, tags, run_seq, t, unix, null)
	elif sub == "end":
		if s.current != null:
			if ev.size() > 3:
				s.current.tags |= int(ev[3])
			_close(s, t)
	elif sub == "tags":
		if s.current != null and ev.size() > 3:
			s.current.tags |= int(ev[3])


static func _reset(s, ev: Array) -> void:
	var prev = s.current
	if prev == null:
		return
	var t = float(ev[1])
	_close(s, t)
	var unix = prev.started_unix + int(max(0.0, t - prev.t0))
	_open(s, prev.wave, prev.tags, prev.run_seq, t, unix, prev)


static func _open(s, wave: int, tags: int, run_seq: int, t: float, unix: int, split_from) -> Object:
	var e = Model.BctEncounter.new()
	e.index = s.next_index
	s.next_index += 1
	e.wave = wave
	e.tags = tags
	e.run_seq = run_seq
	e.t0 = t
	e.started_unix = unix
	if split_from != null:
		# 手动重置：同一波的下一段，沿用波次、第几次、角色与配装
		e.manual = true
		e.run = split_from.run
		e.part = split_from.part + 1
		e.characters = split_from.characters.duplicate()
		e.loadout = split_from.loadout.duplicate(true)
		e.weapon_counts = split_from.weapon_counts.duplicate()
	else:
		var k = str(run_seq) + ":" + str(wave)
		e.run = int(s.wave_runs.get(k, 0)) + 1
		s.wave_runs[k] = e.run
	s.current = e
	return e


static func _close(s, t: float) -> void:
	var e = s.current
	if e == null:
		return
	if t >= e.t0:
		e.duration = max(e.duration, t - e.t0)
	e.ended = true
	s.current = null
	# 手动重置切出来的空段没有意义，丢掉；整波没有数据的段保留（那一波确实存在）
	if e.manual and e.is_empty():
		return
	s.encounters.append(e)
	s.trim()


# 事件先于开波信号到达时（只会出现在残缺的日志里）补一个无波次的段
static func _enc(s, t: float) -> Object:
	if s.current == null:
		_open(s, 0, 0, 0, t, 0, null)
	var e = s.current
	if t - e.t0 > e.duration:
		e.duration = t - e.t0
	return e


static func _stats(bucket: Dictionary, key, player: int, src: String) -> Object:
	var st = bucket.get(key)
	if st == null:
		st = Model.BctStats.new()
		st.key = str(key)
		st.player = player
		st.src = src
		bucket[key] = st
	return st


# ---------------------------------------------------------------------------
# 数据事件
# ---------------------------------------------------------------------------

# D  时钟 玩家 来源 目标 数值 有效值 标志 形式 类别
static func _damage(s, ev: Array) -> void:
	if ev.size() < 8:
		s.bad_lines += 1
		return
	var t = float(ev[1])
	var e = _enc(s, t)
	var p = int(ev[2])
	var src = str(ev[3])
	var tgt = str(ev[4])
	var value = float(ev[5])
	var eff = float(ev[6])
	var flags = int(ev[7])
	var form = str(ev[8]) if ev.size() > 8 and str(ev[8]) != "" else Model.FORM_HIT
	var cls = str(ev[9]) if ev.size() > 9 else ""
	var crit = (flags & Model.F_CRIT) != 0
	var kill = (flags & Model.F_KILL) != 0
	var sec = int(t - e.t0)
	var crit_item = Model.CRIT_YES if crit else Model.CRIT_NO

	var a = _stats(e.by_source[Model.VIEW_OUT], str(p) + "|" + src, p, src)
	var b = _stats(e.by_player[Model.VIEW_OUT], p, p, "")
	for st in [a, b]:
		st.add(sec, value, eff, crit, kill)
		st.add_dim(Model.DIM_FORM, form, value, eff, crit)
		if tgt != "":
			st.add_dim(Model.DIM_TARGET, tgt, value, eff, crit)
		if cls != "":
			st.add_dim(Model.DIM_CLASS, cls, value, eff, crit)
		st.add_dim(Model.DIM_CRIT, crit_item, value, eff, crit)
	b.add_dim(Model.DIM_SOURCE, src, value, eff, crit)


# T  时钟 玩家 攻击者 数值 有效值 标志
static func _taken(s, ev: Array) -> void:
	if ev.size() < 7:
		s.bad_lines += 1
		return
	var t = float(ev[1])
	var e = _enc(s, t)
	var p = int(ev[2])
	var attacker = str(ev[3])
	var value = float(ev[4])
	var eff = float(ev[5])
	var flags = int(ev[6])
	var dodge = (flags & Model.F_DODGE) != 0
	var died = (flags & Model.F_DIED) != 0
	var outcome = Model.OUTCOME_HIT
	if dodge:
		outcome = Model.OUTCOME_DODGE
	elif (flags & Model.F_PROTECTED) != 0:
		outcome = Model.OUTCOME_PROTECTED
	var sec = int(t - e.t0)

	var a = _stats(e.by_source[Model.VIEW_TAKEN], str(p) + "|" + attacker, p, attacker)
	var b = _stats(e.by_player[Model.VIEW_TAKEN], p, p, "")
	for st in [a, b]:
		st.add(sec, value, eff, dodge, died)
		st.add_dim(Model.DIM_OUTCOME, outcome, value, eff, dodge)
	b.add_dim(Model.DIM_SOURCE, attacker, value, eff, dodge)


# H  时钟 玩家 来源 数值
static func _heal(s, ev: Array) -> void:
	if ev.size() < 5:
		s.bad_lines += 1
		return
	var t = float(ev[1])
	var e = _enc(s, t)
	var p = int(ev[2])
	var src = str(ev[3])
	var value = float(ev[4])
	var sec = int(t - e.t0)

	var a = _stats(e.by_source[Model.VIEW_HEAL], str(p) + "|" + src, p, src)
	var b = _stats(e.by_player[Model.VIEW_HEAL], p, p, "")
	a.add(sec, value, value, false, false)
	b.add(sec, value, value, false, false)
	b.add_dim(Model.DIM_SOURCE, src, value, value, false)


# C  时钟 玩家 角色
static func _character(s, ev: Array) -> void:
	if ev.size() < 4:
		s.bad_lines += 1
		return
	var e = s.current
	if e != null:
		e.characters[int(ev[2])] = str(ev[3])


# L  时钟 玩家 武器键,武器键,…
static func _loadout(s, ev: Array) -> void:
	if ev.size() < 4:
		s.bad_lines += 1
		return
	var e = s.current
	if e == null:
		return
	var p = int(ev[2])
	var keys = []
	for k in str(ev[3]).split(",", false):
		keys.append(k)
		var ck = str(p) + "|" + k
		e.weapon_counts[ck] = int(e.weapon_counts.get(ck, 0)) + 1
	e.loadout[p] = keys


# P  时钟 玩家 快照 波次
# 联机队友的整段统计。快照是它自己那边的权威数据，直接替换这名玩家在这一段里的全部行。
static func _remote(s, ev: Array) -> void:
	if ev.size() < 4:
		s.bad_lines += 1
		return
	var p = int(ev[2])
	var snap = ev[3]
	var text = ""
	if typeof(snap) == TYPE_STRING:
		text = snap
		var parsed = JSON.parse(snap)
		if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
			s.bad_lines += 1
			return
		snap = parsed.result
	elif typeof(snap) == TYPE_DICTIONARY:
		text = to_json(snap)
	else:
		s.bad_lines += 1
		return
	var wave = int(ev[4]) if ev.size() > 4 else 0
	var e = _find_for_wave(s, wave)
	if e == null:
		return
	apply_snapshot(e, p, snap)
	e.remote_snapshots[p] = text


static func _find_for_wave(s, wave: int) -> Object:
	if s.current != null and (wave <= 0 or s.current.wave == wave):
		return s.current
	# 最后一次快照可能在本地已经收波之后才到
	var n = s.encounters.size()
	for i in range(n - 1, max(-1, n - 6), -1):
		var e = s.encounters[i]
		if e.wave == wave:
			return e
	return null


# ---------------------------------------------------------------------------
# 快照：一名玩家在一段里的全部统计，联机时在队友之间传
# ---------------------------------------------------------------------------

static func export_snapshot(e, p: int) -> Dictionary:
	var rows := []
	for v in range(3):
		for st in e.by_source[v].values():
			if st.player != p:
				continue
			rows.append([v, st.src, _r(st.total), _r(st.eff), st.hits, st.crits, _r(st.max_hit), st.kills,
				_ints(st.series), _ints(st.series_eff), _dims_out(st.dims)])
	var counts := {}
	var prefix = str(p) + "|"
	for k in e.weapon_counts.keys():
		if str(k).begins_with(prefix):
			counts[str(k).substr(prefix.length())] = int(e.weapon_counts[k])
	return {
		"v": SNAPSHOT_VERSION,
		"d": stepify(e.duration, 0.01),
		"c": str(e.characters.get(p, "")),
		"w": counts,
		"s": rows,
	}


static func apply_snapshot(e, p: int, snap: Dictionary) -> void:
	for v in range(3):
		for key in e.by_source[v].keys():
			if e.by_source[v][key].player == p:
				e.by_source[v].erase(key)
		e.by_player[v].erase(p)

	var rows = snap.get("s", [])
	if typeof(rows) != TYPE_ARRAY:
		return
	for row in rows:
		if typeof(row) != TYPE_ARRAY or row.size() < 8:
			continue
		var v = int(row[0])
		if v < 0 or v > 2:
			continue
		var src = str(row[1])
		var a = _stats(e.by_source[v], str(p) + "|" + src, p, src)
		a.remote = true
		a.total = float(row[2])
		a.eff = float(row[3])
		a.hits = int(row[4])
		a.crits = int(row[5])
		a.max_hit = float(row[6])
		a.kills = int(row[7])
		a.series = _floats(row[8]) if row.size() > 8 else []
		a.series_eff = _floats(row[9]) if row.size() > 9 else []
		a.dims = {}
		if row.size() > 10 and typeof(row[10]) == TYPE_DICTIONARY:
			for dim in row[10].keys():
				var items = row[10][dim]
				if typeof(items) != TYPE_DICTIONARY:
					continue
				for item in items.keys():
					var r = items[item]
					if typeof(r) == TYPE_ARRAY and r.size() >= 5:
						a.merge_dim_row(str(dim), str(item), r)

		var b = _stats(e.by_player[v], p, p, "")
		b.remote = true
		b.total += a.total
		b.eff += a.eff
		b.hits += a.hits
		b.crits += a.crits
		b.kills += a.kills
		if a.max_hit > b.max_hit:
			b.max_hit = a.max_hit
		b.merge_series(b.series, a.series)
		b.merge_series(b.series_eff, a.series_eff)
		for dim in a.dims.keys():
			for item in a.dims[dim].keys():
				b.merge_dim_row(dim, item, a.dims[dim][item])
		b.merge_dim_row(Model.DIM_SOURCE, src, [a.total, a.eff, a.hits, a.crits, a.max_hit])

	var ch = str(snap.get("c", ""))
	if ch != "":
		e.characters[p] = ch
	var counts = snap.get("w", {})
	if typeof(counts) == TYPE_DICTIONARY:
		for k in counts.keys():
			e.weapon_counts[str(p) + "|" + str(k)] = int(counts[k])


static func _r(v: float):
	return int(round(v)) if abs(v) < 1e15 else v


static func _ints(series: Array) -> Array:
	var out := []
	out.resize(series.size())
	for i in range(series.size()):
		out[i] = int(round(series[i]))
	return out


static func _floats(arr) -> Array:
	var out := []
	if typeof(arr) != TYPE_ARRAY:
		return out
	out.resize(arr.size())
	for i in range(arr.size()):
		out[i] = float(arr[i])
	return out


static func _dims_out(dims: Dictionary) -> Dictionary:
	var out := {}
	for dim in dims.keys():
		var d := {}
		for item in dims[dim].keys():
			var r = dims[dim][item]
			d[item] = [_r(r[0]), _r(r[1]), int(r[2]), int(r[3]), _r(r[4])]
		out[dim] = d
	return out
