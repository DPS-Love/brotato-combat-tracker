extends Reference

# 统计数据模型：会话 → 分段（一波就是一段）→ 按来源 / 按玩家的统计。
#
# 纯 GDScript：不引用游戏和 Mod Loader 的任何全局类。实时统计和导入日志共用这一套，
# 解析器在后台线程里也能跑。
#
# 内部类里只用字面量和自己的方法：GDScript 3 的内部类看不到外层脚本的函数，
# 外层常量能否访问也随小版本而变，不去赌。

const VIEW_OUT = 0     # 输出：玩家一方对敌人造成的伤害
const VIEW_TAKEN = 1   # 承伤：玩家受到的伤害
const VIEW_HEAL = 2    # 治疗：玩家获得的生命恢复
const VIEWS = [VIEW_OUT, VIEW_TAKEN, VIEW_HEAL]

const GROUP_SOURCE = 0  # 按来源：武器 / 物品 / 攻击者 / 恢复来源
const GROUP_PLAYER = 1  # 按玩家

# 拆分维度。按玩家汇总的统计多一个 DIM_SOURCE。
const DIM_SOURCE = "src"
const DIM_FORM = "form"      # 输出：直接命中 / 燃烧 / 爆炸 / 效果
const DIM_TARGET = "tgt"     # 输出：被打的敌人
const DIM_CLASS = "cls"      # 输出：伤害类别（武器缩放属性：近战 / 远程 / 元素 / 工程…）
const DIM_CRIT = "crit"      # 输出：暴击 / 普通
const DIM_OUTCOME = "res"    # 承伤：命中 / 闪避 / 护盾抵挡

# D 行标志位
const F_CRIT = 1
const F_KILL = 2
const F_ONESHOT = 4
# T 行标志位
const F_DODGE = 1
const F_PROTECTED = 2
const F_ARMOR = 4
const F_DIED = 8

# 命中形式
const FORM_HIT = "h"
const FORM_BURN = "b"
const FORM_EXPLOSION = "x"
const FORM_EFFECT = "e"

# 暴击维度的两项
const CRIT_YES = "c"
const CRIT_NO = "n"

# 承伤结果
const OUTCOME_HIT = "hit"
const OUTCOME_DODGE = "dodge"
const OUTCOME_PROTECTED = "prot"

# 分段标签位
const TAG_BOSS = 1
const TAG_ELITE = 2
const TAG_HORDE = 4
const TAG_ENDLESS = 8

# 拆分行：[总量, 有效量, 次数, 暴击或闪避次数, 最高]
const ROW_TOTAL = 0
const ROW_EFF = 1
const ROW_HITS = 2
const ROW_CRITS = 3
const ROW_MAX = 4


# 明细窗口 / 主面板拆分区在某个视图、某种分组下有哪些维度（第一个是默认）
static func dims_for(view: int, group: int) -> Array:
	if view == VIEW_OUT:
		if group == GROUP_PLAYER:
			return [DIM_SOURCE, DIM_CLASS, DIM_TARGET]
		return [DIM_FORM, DIM_TARGET, DIM_CRIT]
	if view == VIEW_TAKEN:
		if group == GROUP_PLAYER:
			return [DIM_SOURCE, DIM_OUTCOME]
		return [DIM_OUTCOME]
	if group == GROUP_PLAYER:
		return [DIM_SOURCE]
	return []


# 一段里某个视图、某种分组的行，按当前口径从大到小
static func sorted_rows(enc, view: int, group: int, overkill: bool) -> Array:
	if enc == null:
		return []
	var list = enc.bucket(view, group).values()
	var sorter = BctSorter.new()
	sorter.overkill = overkill
	list.sort_custom(sorter, "desc")
	return list


# 某条统计的某个维度，转成 [[项, 行], …] 按当前口径从大到小
static func sorted_dim(stats, dim: String, overkill: bool) -> Array:
	var list := []
	if stats == null:
		return list
	var d = stats.dims.get(dim)
	if d == null:
		return list
	for item in d.keys():
		list.append([item, d[item]])
	var sorter = BctSorter.new()
	sorter.overkill = overkill
	list.sort_custom(sorter, "desc_row")
	return list


class BctSorter extends Reference:
	var overkill := false

	func desc(a, b) -> bool:
		var va = a.total if overkill else a.eff
		var vb = b.total if overkill else b.eff
		if va == vb:
			return a.key < b.key
		return va > vb

	func desc_row(a, b) -> bool:
		var va = a[1][0] if overkill else a[1][1]
		var vb = b[1][0] if overkill else b[1][1]
		if va == vb:
			return str(a[0]) < str(b[0])
		return va > vb


# ---------------------------------------------------------------------------
# 一个来源（或一名玩家）在一段里的统计
# ---------------------------------------------------------------------------
class BctStats extends Reference:
	var key := ""          # 在所属桶里的键：按来源是 "玩家|来源"，按玩家是玩家序号的字符串
	var player := -1
	var src := ""          # 来源键；按玩家汇总时为空
	# 输出：total 含溢出（打死怪时超出剩余血量的部分），eff 不含
	# 承伤：total 是结算后的伤害，eff 是实际掉的血
	# 治疗：两者相同
	var total := 0.0
	var eff := 0.0
	var hits := 0
	var crits := 0         # 输出：暴击次数；承伤：闪避次数
	var max_hit := 0.0
	var kills := 0         # 输出：击杀数；承伤：阵亡次数
	var series := []       # 每秒一桶（总量）
	var series_eff := []   # 每秒一桶（有效量）
	var dims := {}         # 维度 -> { 项 -> [总量, 有效量, 次数, 暴击, 最高] }
	var remote := false    # 来自联机队友的快照

	func add(sec: int, value: float, effective: float, crit: bool, kill: bool) -> void:
		total += value
		eff += effective
		hits += 1
		if crit:
			crits += 1
		if kill:
			kills += 1
		if value > max_hit:
			max_hit = value
		_bucket(series, sec, value)
		_bucket(series_eff, sec, effective)

	func add_dim(dim: String, item: String, value: float, effective: float, flag: bool) -> void:
		var d = dims.get(dim)
		if d == null:
			d = {}
			dims[dim] = d
		var row = d.get(item)
		if row == null:
			row = [0.0, 0.0, 0, 0, 0.0]
			d[item] = row
		row[0] += value
		row[1] += effective
		row[2] += 1
		if flag:
			row[3] += 1
		if value > row[4]:
			row[4] = value

	# 把一整行并进某个维度（快照、汇总时用）
	func merge_dim_row(dim: String, item: String, other: Array) -> void:
		var d = dims.get(dim)
		if d == null:
			d = {}
			dims[dim] = d
		var row = d.get(item)
		if row == null:
			row = [0.0, 0.0, 0, 0, 0.0]
			d[item] = row
		row[0] += float(other[0])
		row[1] += float(other[1])
		row[2] += int(other[2])
		row[3] += int(other[3])
		if float(other[4]) > row[4]:
			row[4] = float(other[4])

	func merge_series(target: Array, other: Array) -> void:
		for i in range(other.size()):
			_bucket(target, i, float(other[i]))

	func metric(overkill: bool) -> float:
		return total if overkill else eff

	func metric_series(overkill: bool) -> Array:
		return series if overkill else series_eff

	func _bucket(arr: Array, sec: int, value: float) -> void:
		# 每秒桶的上限 4 小时，防止异常时间戳把数组撑爆
		if sec < 0:
			sec = 0
		elif sec > 14400:
			sec = 14400
		while arr.size() <= sec:
			arr.append(0.0)
		arr[sec] += value


# ---------------------------------------------------------------------------
# 一段：通常就是一波。手动重置会在同一波里切出新的一段。
# ---------------------------------------------------------------------------
class BctEncounter extends Reference:
	var index := 0           # 会话内序号，从 1 开始
	var wave := 0
	var run := 1             # 同一局里同一波打第几次（重试波次时 > 1）
	var run_seq := 0         # 第几局（换角色重开就 +1）
	var tags := 0
	var t0 := 0.0            # 本段开始时的波次时钟
	var duration := 0.0
	var started_unix := 0
	var ended := false
	var manual := false      # 由手动重置切出来的段
	var part := 1            # 同一波被手动重置切成几段时的段号
	var characters := {}     # 玩家 -> 角色 id
	var loadout := {}        # 玩家 -> 开波时的武器键列表
	var weapon_counts := {}  # "玩家|w:…" -> 同名武器把数，用来显示「×3」
	var by_source := [{}, {}, {}]
	var by_player := [{}, {}, {}]
	var remote_snapshots := {}   # 玩家 -> 最近一次收到的快照（JSON 文本，写日志用）

	func bucket(view: int, group: int) -> Dictionary:
		return by_player[view] if group == 1 else by_source[view]

	func total(view: int, overkill: bool) -> float:
		var sum := 0.0
		for s in by_player[view].values():
			sum += s.total if overkill else s.eff
		return sum

	func is_empty() -> bool:
		for v in range(3):
			if not by_player[v].empty():
				return false
		return true

	func players() -> Array:
		var seen := {}
		for v in range(3):
			for p in by_player[v].keys():
				seen[p] = true
		for p in characters.keys():
			seen[p] = true
		var list = seen.keys()
		list.sort()
		return list


# ---------------------------------------------------------------------------
# 会话：本局游戏（进程）从启动到退出，或者导入的一份日志
# ---------------------------------------------------------------------------
class BctSession extends Reference:
	var encounters := []     # 已结束的段，旧的在前
	var current = null       # 进行中的段
	var dropped := 0         # 超出保留上限被丢掉的段数
	var history_size := 200
	var started_unix := 0
	var source_path := ""    # 导入的日志路径；本局为空
	var meta := {}
	var event_count := 0
	var unknown_lines := 0
	var bad_lines := 0
	var truncated := false
	var next_index := 1
	var wave_runs := {}      # "局:波" -> 次数

	func trim() -> void:
		if history_size <= 0:
			return
		while encounters.size() > history_size:
			encounters.pop_front()
			dropped += 1
