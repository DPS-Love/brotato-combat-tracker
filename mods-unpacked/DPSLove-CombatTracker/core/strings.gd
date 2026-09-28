extends Reference

# 所有由本 Mod 自己提供的文案，按游戏当前语言选中文 / 英文。
#
# 游戏有译文的东西（武器、物品、角色、敌人、属性名、「第 N 波」）走游戏的 tr()，
# 在 game/names.gd 里，不在这里。日志消息不在此列——那是给开发者看的。
#
# 繁体中文暂时也用简体：面板上的字不多，比显示英文更好读。

static func chinese() -> bool:
	return TranslationServer.get_locale().begins_with("zh")


static func pick(zh: String, en: String) -> String:
	return zh if chinese() else en


# ================================================================ 视图与分组

static func view_label(v: int) -> String:
	match v:
		1:
			return pick("承伤", "Taken")
		2:
			return pick("治疗", "Healing")
		_:
			return pick("输出", "Damage")


static func group_label(g: int) -> String:
	return pick("玩家", "Players") if g == 1 else pick("来源", "Sources")


static func empty_hint(v: int) -> String:
	match v:
		1:
			return pick("尚未承受伤害…", "No damage taken yet…")
		2:
			return pick("尚未产生治疗…", "No healing yet…")
		_:
			return pick("等待伤害数据…", "Waiting for damage…")


# ================================================================ 浮窗

static func btn_log() -> String:
	return pick("记录", "Log")


static func btn_reset() -> String:
	return pick("重置", "Reset")


static func hits_count(n: int) -> String:
	return pick("%d 次" % n, "%d hits" % n)


static func crit_rate(rate: float) -> String:
	return pick("暴 %d%%" % int(round(rate * 100.0)), "Crit %d%%" % int(round(rate * 100.0)))


static func crit_none() -> String:
	return pick("暴 —", "Crit —")


static func dodge_rate(rate: float) -> String:
	return pick("闪 %d%%" % int(round(rate * 100.0)), "Dodge %d%%" % int(round(rate * 100.0)))


static func max_hit(v: String) -> String:
	return pick("最大 " + v, "Max " + v)


static func kills(n: int) -> String:
	return pick("击杀 %d" % n, "%d kills" % n)


static func more_cards(n: int) -> String:
	return "+%d" % n


static func remote_missing(player: String) -> String:
	return pick("%s 没有数据（未装本 Mod？）" % player, "%s: no data (mod not installed?)" % player)


# ================================================================ 分段标题

static func wave_fallback(n: int) -> String:
	return pick("第 %d 波" % n, "Wave %d" % n)


static func no_wave() -> String:
	return pick("战斗", "Combat")


static func horde() -> String:
	return pick("怪潮", "Horde")


static func run_repeat(n: int) -> String:
	return "#%d" % n


static func part(n: int) -> String:
	return pick("（%d）" % n, " (%d)" % n)


# ================================================================ 来源与拆分项（游戏里没有译文的）

static func unknown_source() -> String:
	return pick("未知来源", "Unknown")


static func other_effects() -> String:
	return pick("其他效果", "Other effects")


static func burn() -> String:
	return pick("燃烧", "Burning")


static func explosion() -> String:
	return pick("爆炸", "Explosion")


static func form_label(form: String) -> String:
	match form:
		"b":
			return burn()
		"x":
			return explosion()
		"e":
			return pick("效果", "Effect")
		_:
			return pick("直接命中", "Direct hit")


static func crit_label(item: String) -> String:
	return pick("暴击", "Critical") if item == "c" else pick("普通", "Normal")


static func outcome_label(item: String) -> String:
	match item:
		"dodge":
			return pick("闪避", "Dodged")
		"prot":
			return pick("抵挡", "Blocked")
		_:
			return pick("命中", "Hit")


static func charmed(name: String) -> String:
	return pick(name + "（魅惑）", name + " (charmed)")


static func tree() -> String:
	return pick("树", "Tree")


static func self_damage() -> String:
	return pick("自身效果", "Self-inflicted")


static func heal_over_time() -> String:
	return pick("持续恢复", "Heal over time")


static func consumables() -> String:
	return pick("消耗品", "Consumables")


static func other_healing() -> String:
	return pick("其他恢复", "Other healing")


static func no_class() -> String:
	return pick("无类别", "No class")


static func player_tag(p: int) -> String:
	return "P%d" % (p + 1)


# ================================================================ 战斗记录主面板

static func main_title() -> String:
	return pick("Brotato Combat Tracker — 战斗记录", "Brotato Combat Tracker — Combat Log")


static func _encounters_en(n: int) -> String:
	return "%d encounter" % n if n == 1 else "%d encounters" % n


static func live_session(n: int) -> String:
	return pick("本局 · %d 段" % n, "This session · " + _encounters_en(n))


static func imported_session(file: String, n: int) -> String:
	return pick("导入 %s · %d 段" % [file, n], "Imported %s · %s" % [file, _encounters_en(n)])


static func btn_import() -> String:
	return pick("导入", "Import")


static func btn_log_folder() -> String:
	return pick("日志目录", "Log folder")


static func btn_export_csv() -> String:
	return pick("导出 CSV", "Export CSV")


static func btn_back_to_live() -> String:
	return pick("回到本局", "Back to live")


static func btn_cancel() -> String:
	return pick("取消", "Cancel")


static func no_encounters() -> String:
	return pick("还没有战斗记录", "No encounters yet")


static func live_tag() -> String:
	return pick("实时", "Live")


static func live_hint() -> String:
	return pick("实时更新中", "Updating live")


static func dropped_hint(n: int) -> String:
	return pick("更早的 %d 段在日志里" % n, "%d older in the log" % n)


static func summary(outgoing: String, dps: String, taken: String, healing: String) -> String:
	return pick("输出 %s（%s/s）   承伤 %s   治疗 %s" % [outgoing, dps, taken, healing],
		"Damage %s (%s/s)   Taken %s   Healing %s" % [outgoing, dps, taken, healing])


static func col_name() -> String:
	return pick("名字", "Name")


static func col_item() -> String:
	return pick("项目", "Item")


static func col_total() -> String:
	return pick("总量", "Total")


static func col_share() -> String:
	return pick("占比", "Share")


static func col_per_sec() -> String:
	return pick("每秒", "Per sec")


static func col_crit() -> String:
	return pick("暴击", "Crit")


static func col_dodge() -> String:
	return pick("闪避", "Dodge")


static func col_hits() -> String:
	return pick("次数", "Hits")


static func col_max() -> String:
	return pick("最高", "Max")


static func col_kills() -> String:
	return pick("击杀", "Kills")


static func col_top_source() -> String:
	return pick("主要来源", "Top source")


static func peak(v: String) -> String:
	return pick("峰值 %s/s" % v, "Peak %s/s" % v)


static func chart_hint() -> String:
	return pick("每秒数值 · 5 秒平滑", "Per second · 5 s smoothing")


static func select_hint() -> String:
	return pick("点上面表格里的一行看它的拆分", "Click a row above for its breakdown")


static func pick_log() -> String:
	return pick("选择要导入的日志：读入后按当前版本重新解析", "Choose a log: it is re-parsed with this version")


static func no_logs() -> String:
	return pick("日志目录里还没有日志", "No logs in the log folder yet")


static func current_file_tag() -> String:
	return pick("（本局，正在写）", "  (this session, still writing)")


static func parsing(file: String) -> String:
	return pick("正在解析 %s …" % file, "Parsing %s …" % file)


static func import_done(n: int, events: int) -> String:
	return pick("已导入 %d 段（%d 条事件）" % [n, events], "Imported %s (%d events)" % [_encounters_en(n), events])


static func import_truncated() -> String:
	return pick("，末尾不完整（游戏没正常退出）", "; the log ends abruptly (the game did not exit cleanly)")


static func import_current_file() -> String:
	return pick("，本局日志读到最近一次落盘", "; this session's log, up to its last flush")


static func import_failed(why: String) -> String:
	return pick("导入失败：" + why, "Import failed: " + why)


static func exported(file: String) -> String:
	return pick("已导出 " + file, "Exported " + file)


static func export_failed() -> String:
	return pick("导出失败，详见日志", "Export failed, see the log")


static func overkill_on() -> String:
	return pick("含溢出", "incl. overkill")


# ================================================================ 明细窗口

static func detail_title(name: String, view: String, segment: String) -> String:
	return "%s — %s  ·  %s" % [name, view, segment]


static func tab_label(dim: String) -> String:
	match dim:
		"src":
			return pick("来源", "Sources")
		"form":
			return pick("形式", "Forms")
		"tgt":
			return pick("目标", "Targets")
		"cls":
			return pick("类别", "Classes")
		"crit":
			return pick("暴击", "Crits")
		"res":
			return pick("结果", "Outcomes")
		_:
			return dim


static func no_breakdown() -> String:
	return pick("暂无细分数据", "No breakdown yet")


static func no_data_in_segment() -> String:
	return pick("这一段没有它的数据", "No data in this segment")


static func more_items(n: int) -> String:
	return pick("…另有 %d 项" % n, "…%d more" % n)


# ================================================================ CSV

static func csv_header() -> String:
	return pick("视图,玩家,来源,总量,占比,每秒,次数,暴击/闪避,最高,击杀,含溢出总量",
		"View,Player,Source,Total,Share,PerSec,Hits,Crits/Dodges,Max,Kills,TotalInclOverkill")


static func csv_title(segment: String, duration: String) -> String:
	return pick("# %s，时长 %s" % [segment, duration], "# %s, duration %s" % [segment, duration])
