extends "res://entities/units/player/player.gd"

# 治疗归因。游戏所有的生命恢复都汇进 on_healing_effect，但生命再生、生命窃取、
# 持续恢复这三条路进来时 tracking_key 都是空的，分不出来。这里在三条路的入口记下
# 上下文，恢复落地后把实际回复量、tracking_key 和上下文一起交给统计节点。
#
# 只读：参数和返回值原样透传，签名与原方法逐字一致（GDScript 3 要求覆写签名相同）。
# 统计节点不在（Mod 初始化失败、被停用）时什么也不做。

var _bct_heal_ctx := ""


func on_health_regen(loop_count: int) -> void:
	_bct_heal_ctx = "regen"
	.on_health_regen(loop_count)
	_bct_heal_ctx = ""


func on_lifesteal_effect(value: int) -> void:
	_bct_heal_ctx = "lifesteal"
	.on_lifesteal_effect(value)
	_bct_heal_ctx = ""


func on_heal_over_time_timer_timeout() -> void:
	_bct_heal_ctx = "hot"
	.on_heal_over_time_timer_timeout()
	_bct_heal_ctx = ""


func on_healing_effect(value: int, tracking_key: int = Keys.empty_hash, from_torture: bool = false) -> int:
	var healed = .on_healing_effect(value, tracking_key, from_torture)
	if typeof(healed) == TYPE_INT and healed > 0 and Engine.has_meta("dpslove_bct"):
		var tracker = Engine.get_meta("dpslove_bct")
		if is_instance_valid(tracker):
			tracker.on_player_healed(self, healed, tracking_key, _bct_heal_ctx)
	return healed
