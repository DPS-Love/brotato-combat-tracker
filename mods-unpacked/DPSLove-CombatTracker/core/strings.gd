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


static func _key_tag(key: String) -> String:
	if key == "":
		return ""
	return pick("（%s）" % key, " (%s)" % key)


static func _count(n: int) -> String:
	var s = str(abs(n))
	var out := ""
	var i = s.length()
	while i > 3:
		out = "," + s.substr(i - 3, 3) + out
		i -= 3
	return ("-" if n < 0 else "") + s.substr(0, i) + out


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

static func tip_log(key: String) -> String:
	return pick("战斗记录", "Combat log") + _key_tag(key)


static func tip_view() -> String:
	return pick("切换：输出 / 承伤 / 治疗", "Switch: damage / taken / healing")


static func tip_reset(key: String) -> String:
	return pick("重置当前统计", "Reset the current encounter") + _key_tag(key)


static func tip_settings() -> String:
	return pick("设置", "Settings")


static func tip_close() -> String:
	return pick("关闭", "Close")


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


# 环形图上并起来的那一段（一屏之外的、占比太小的项）
static func other() -> String:
	return pick("其他", "Other")


# 浮窗树形里来源的分类
static func cat_weapons() -> String:
	return pick("武器", "Weapons")


static func cat_items() -> String:
	return pick("物品", "Items")


static func cat_enemies() -> String:
	return pick("敌人", "Enemies")


static func cat_stats() -> String:
	return pick("属性回复", "Stats")


static func cat_other() -> String:
	return pick("其他", "Other")


# ================================================================ 战斗记录

static func main_title() -> String:
	return pick("战斗记录", "Combat Log")


static func _encounters_en(n: int) -> String:
	return "%d encounter" % n if n == 1 else "%d encounters" % n


static func tip_imported_chip(file: String) -> String:
	return pick("正在看导入的日志 %s；点 × 回到本局" % file, "Showing the imported log %s; click × to go back" % file)


static func tip_back_to_live() -> String:
	return pick("回到本局", "Back to this session")


static func tip_import() -> String:
	return pick("导入一份战斗日志，按当前版本重新解析", "Import a combat log and re-parse it with this version")


static func tip_log_folder() -> String:
	return pick("打开战斗日志所在的文件夹", "Open the combat log folder")


static func tip_export() -> String:
	return pick("把选中的这一段导出成 CSV", "Export the selected encounter as CSV")


static func tip_page_up() -> String:
	return pick("上一页", "Page up")


static func tip_page_down() -> String:
	return pick("下一页", "Page down")


static func btn_import() -> String:
	return pick("导入", "Import")


static func btn_log_folder() -> String:
	return pick("日志目录", "Log folder")


static func btn_export_csv() -> String:
	return pick("导出 CSV", "Export CSV")


static func btn_cancel() -> String:
	return pick("取消", "Cancel")


static func no_encounters() -> String:
	return pick("还没有战斗记录", "No encounters yet")


static func live_tag() -> String:
	return pick("实时", "Live")


static func dropped_hint(n: int) -> String:
	return pick("更早的 %d 段在日志里" % n, "%d older in the log" % n)


static func summary_stats(duration: String, outgoing: String, dps: String, taken: String, healing: String) -> String:
	return pick("%s  ·  输出 %s（%s/s）  ·  承伤 %s  ·  治疗 %s" % [duration, outgoing, dps, taken, healing],
		"%s  ·  Damage %s (%s/s)  ·  Taken %s  ·  Healing %s" % [duration, outgoing, dps, taken, healing])


static func all_sources() -> String:
	return pick("全部", "Everyone")


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


static func col_crit_short() -> String:
	return pick("暴击", "Crit")


static func col_dodge() -> String:
	return pick("闪避", "Dodge")


static func col_hits() -> String:
	return pick("次数", "Hits")


static func col_max() -> String:
	return pick("最高", "Max")


static func col_top_source() -> String:
	return pick("主要来源", "Top source")


static func peak(v: String) -> String:
	return pick("峰值 %s/s" % v, "Peak %s/s" % v)


static func tip_mode_chart() -> String:
	return pick("曲线与拆分", "Chart and breakdown")


static func tip_mode_events() -> String:
	return pick("逐条事件", "Event list")


static func events_header(who: String, view: String, n: int) -> String:
	return pick("%s · %s · %s 条" % [who, view, _count(n)], "%s · %s · %s events" % [who, view, _count(n)])


static func events_loading() -> String:
	return pick("正在从日志读取这一段的事件…", "Reading this encounter's events from the log…")


static func events_no_log() -> String:
	return pick("战斗日志没有开，只能看实时这一段的事件", "Combat logging is off; only the live encounter has an event list")


static func events_not_found() -> String:
	return pick("日志里对不上这一段（日志可能不完整）", "This encounter does not match the log (the log may be incomplete)")


static func events_empty() -> String:
	return pick("这一段没有这类事件", "No events of this kind in this encounter")


static func events_capped(n: int) -> String:
	return pick("只保留了前 %s 条" % _count(n), "Only the first %s are kept" % _count(n))


static func load_failed(why: String) -> String:
	return pick("读取失败：" + why, "Loading failed: " + why)


static func col_time() -> String:
	return pick("时间", "Time")


static func col_source() -> String:
	return pick("来源", "Source")


static func col_target() -> String:
	return pick("目标", "Target")


static func col_victim() -> String:
	return pick("承受者", "Victim")


static func col_recipient() -> String:
	return pick("对象", "Recipient")


static func col_amount() -> String:
	return pick("数值", "Amount")


static func col_form() -> String:
	return pick("形式", "Form")


static func col_result() -> String:
	return pick("结果", "Result")


static func crit_mark() -> String:
	return pick("暴", "Crit")


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


# ================================================================ 拆分窗口

static func detail_title(name: String, view: String) -> String:
	return "%s  ·  %s" % [name, view]


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


# ================================================================ 设置

static func settings_title() -> String:
	return pick("设置", "Settings")


static func tab_display() -> String:
	return pick("界面", "Display")


static func tab_tracking() -> String:
	return pick("统计", "Tracking")


static func tab_logs() -> String:
	return pick("日志", "Logs")


static func tab_hotkeys() -> String:
	return pick("热键", "Hotkeys")


static func tab_colors() -> String:
	return pick("颜色", "Colours")


static func restart_tag() -> String:
	return pick("重启后生效", "Needs restart")


static func settings_footer(path: String) -> String:
	return pick("改动自动保存到 " + path, "Saved automatically to " + path)


static func set_ui_scale() -> String:
	return pick("界面缩放", "UI scale")


static func set_ui_scale_desc() -> String:
	return pick("所有窗口一起缩放，松手后生效", "Scales every window; applies when you let go")


static func set_skew() -> String:
	return pick("色条斜切", "Bar slant")


static func set_skew_desc() -> String:
	return pick("浮窗色条的斜切角度，0 为直角", "Slant of the overlay's bars; 0 is square")


static func set_bg() -> String:
	return pick("窗口背景", "Window background")


static func set_bg_desc() -> String:
	return pick("浮窗、拆分窗口和战斗记录背景的浓淡。浮窗只在鼠标移上去时显示背景和按钮",
		"Background opacity of the overlay, breakdown and combat log windows. The overlay shows its background and buttons only while the cursor is on it")


static func set_max_rows() -> String:
	return pick("每组最多几项", "Items per group")


static func set_max_rows_desc() -> String:
	return pick("浮窗里每一组（武器 / 物品 / 其他…）最多列几项，其余并成「另有 n 项」",
		"Most items listed under each group on the overlay (weapons / items / other…); the rest become \"n more\"")


static func set_icons() -> String:
	return pick("显示图标", "Show icons")


static func set_icons_desc() -> String:
	return pick("浮窗卡片上显示武器 / 物品图标", "Weapon and item icons on the overlay cards")


static func set_shop() -> String:
	return pick("商店里显示浮窗", "Overlay in the shop")


static func set_shop_desc() -> String:
	return pick("商店里也显示浮窗（显示刚打完的那一波）；默认不显示，免得挡住物品说明",
		"Also show the overlay in the shop (the wave just finished); off by default so it doesn't cover item descriptions")


static func set_overkill() -> String:
	return pick("计入溢出伤害", "Count overkill")


static func set_overkill_desc() -> String:
	return pick("打死怪时超出它剩余血量的部分也算。默认不算，和游戏里武器的伤害统计一致",
		"Also count damage beyond an enemy's remaining HP. Off by default, matching the game's own weapon damage counters")


static func set_trees() -> String:
	return pick("统计树木", "Count trees")


static func set_trees_desc() -> String:
	return pick("对树木的伤害也算进输出", "Include damage dealt to trees")


static func set_history() -> String:
	return pick("保留段数", "Encounters kept")


static func set_history_desc() -> String:
	return pick("战斗记录里本局最多留多少段，更早的仍在日志里，可以导入",
		"How many of this session's encounters the combat log keeps; older ones stay in the log and can be imported")


static func set_share() -> String:
	return pick("联机互传统计", "Share stats online")


static func set_share_desc() -> String:
	return pick("BrotatoOnline 联机时和装了本 Mod 的队友互传各自的统计；关掉则只看得到自己",
		"In BrotatoOnline co-op, exchange stats with teammates who also run this mod; when off you only see yourself")


static func set_log_events() -> String:
	return pick("记录战斗日志", "Write combat logs")


static func set_log_events_desc() -> String:
	return pick("每局一份，可导入重新解析；已经结束的段靠它看逐条事件",
		"One per session, importable; ended encounters read their event list from it")


static func set_retention() -> String:
	return pick("日志保留", "Keep logs for")


static func set_retention_desc() -> String:
	return pick("超过的在游戏启动时删除", "Older logs are deleted when the game starts")


static func btn_open_log_folder() -> String:
	return pick("打开日志目录", "Open log folder")


static func key_toggle() -> String:
	return pick("显示 / 隐藏浮窗", "Show / hide the overlay")


static func key_main() -> String:
	return pick("打开战斗记录", "Open the combat log")


static func key_reset() -> String:
	return pick("重置当前统计", "Reset the current encounter")


static func key_export() -> String:
	return pick("导出当前段的 CSV", "Export the current encounter as CSV")


static func key_press() -> String:
	return pick("按下新按键…", "Press a key…")


static func key_none() -> String:
	return pick("未设置", "None")


static func key_hint() -> String:
	return pick("点按钮，再按下新的按键。Esc 取消，Delete 清除", "Click a button, then press a key. Esc cancels, Delete clears")


static func colors_hint() -> String:
	return pick("多人时各玩家在卡片、表格和曲线上的颜色；恢复默认就用游戏里的玩家颜色",
		"Each player's colour on the cards, tables and charts in co-op; reset to use the game's player colours")


static func tip_reset_color() -> String:
	return pick("恢复默认", "Reset to default")


static func player_name(p: int) -> String:
	return pick("玩家 %d" % (p + 1), "Player %d" % (p + 1))


static func segments(n: int) -> String:
	if n <= 0:
		return pick("不限", "All")
	return pick("%d 段" % n, "%d" % n)


static func days(n: int) -> String:
	if n <= 0:
		return pick("永久", "Forever")
	return pick("%d 天" % n, "%d days" % n)


# ================================================================ CSV

static func csv_header() -> String:
	return pick("视图,玩家,来源,总量,占比,每秒,次数,暴击/闪避,最高,击杀,含溢出总量",
		"View,Player,Source,Total,Share,PerSec,Hits,Crits/Dodges,Max,Kills,TotalInclOverkill")


static func csv_title(segment: String, duration: String) -> String:
	return pick("# %s，时长 %s" % [segment, duration], "# %s, duration %s" % [segment, duration])
