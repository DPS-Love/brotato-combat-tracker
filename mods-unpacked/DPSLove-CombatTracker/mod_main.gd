extends Node

# Brotato Combat Tracker 的入口。Mod Loader 把它实例化后挂在 ModLoader 节点下，整局游戏都在。
#
# 这里只做两件事：
#   1. _init 里登记对 player.gd 的脚本扩展（治疗归因要知道恢复走的是哪条路）
#   2. _ready 里挂上统计节点，其余一切都在 game/tracker.gd
#
# 伤害统计本身只连游戏的信号，不改任何游戏数值。

const MOD_ID = "DPSLove-CombatTracker"
const LOG_NAME = "DPSLove-CombatTracker"

var mod_dir := ""


func _init() -> void:
	mod_dir = ModLoaderMod.get_unpacked_dir().plus_file(MOD_ID)
	ModLoaderMod.install_script_extension(mod_dir.plus_file("extensions/entities/units/player/player.gd"))


func _ready() -> void:
	var script = load(mod_dir.plus_file("game/tracker.gd"))
	if script == null:
		ModLoaderLog.error("game/tracker.gd 加载失败，统计不可用", LOG_NAME)
		return
	var tracker = script.new()
	tracker.name = "Tracker"
	add_child(tracker)
	ModLoaderLog.success("已加载 v%s" % tracker.VERSION, LOG_NAME)
