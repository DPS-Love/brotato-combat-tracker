extends AbstractPlatform

# 测试包专用：替换游戏的 Platform 自动加载，固定走 LocalPlatform。
# 不初始化 Steam——不碰云存档、成就和统计；用户 id 为 "user"，存档落在测试用户目录里。
# 其余方法原样转发，与游戏的 platform.gd 一致。

var _platform_impl: AbstractPlatform


func _init() -> void:
	_platform_impl = LocalPlatform.new()
	add_child(_platform_impl)


func get_type() -> int:
	return _platform_impl.get_type()


func get_type_as_string() -> String:
	var type: = _platform_impl.get_type()
	return PlatformType.get_type_as_string(type)


func get_user_id() -> String:
	return _platform_impl.get_user_id()


func is_challenge_completed(chal_id: String) -> bool:
	return _platform_impl.is_challenge_completed(chal_id)


func complete_challenge(chal_id: int) -> void:
	_platform_impl.complete_challenge(chal_id)


func is_dlc_owned(dlc_my_id: String) -> bool:
	return _platform_impl.is_dlc_owned(dlc_my_id)


func get_language() -> String:
	var lang = OS.get_environment("BCT_TEST_LANG")
	return lang if lang != "" else _platform_impl.get_language()


func reinitialize_store_data() -> void:
	_platform_impl.reinitialize_store_data()


func open_store_page(url: String) -> void:
	pass


func open_mods_page() -> void:
	pass


func get_dlc_url() -> String:
	return _platform_impl.get_dlc_url()


func get_more_games_url() -> String:
	return _platform_impl.get_more_games_url()


func get_subscribed_mods() -> Array:
	return []
