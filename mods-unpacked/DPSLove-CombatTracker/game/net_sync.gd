extends Node

# 联机同步：适配创意工坊的 BrotatoOnline（six666）。
#
# BrotatoOnline 里每台机器只模拟自己那名玩家的命中（打的是本地的敌人副本），Host 只收击杀，
# 不收伤害——任何一台机器都没有全队的伤害。所以统计是「谁的玩家谁说了算」：
#   - 每台机器只记录自己拥有的玩家（owns_player），别的玩家的本地事件一律忽略
#   - 每 2 秒把自己玩家这一段的统计广播出去；收波时再发一次可靠的最终版
#   - 收到队友的快照，整名玩家替换进同一波的那一段
#
# 没装 BrotatoOnline、或者单机 / 本地合作时，所有玩家都算本机拥有，这个节点什么也不做。
# 走的是 BrotatoOnline 公开的 Mod 消息接口（节点组 brotato_online_api，API v1），
# 不依赖它的任何内部实现；以后要适配别的联机 Mod，在这里加一个分支即可。

signal snapshot_received(player, snapshot, wave)

const MOD_ID = "DPSLove-CombatTracker"
const ROUTE_SNAPSHOT = "snap"
const API_GROUP = "brotato_online_api"
const PROTOCOL = 1

var _api = null
var _lookup_in := 0.0


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func _process(delta: float) -> void:
	if _api != null and not is_instance_valid(_api):
		_api = null
	if _api == null:
		_lookup_in -= delta
		if _lookup_in <= 0.0:
			_lookup_in = 2.0
			_find_api()


func _find_api() -> void:
	for node in get_tree().get_nodes_in_group(API_GROUP):
		if not node.has_method("get_api_version") or not node.has_signal("mod_message_received"):
			continue
		if int(node.get_api_version()) < 1:
			continue
		_api = node
		if not node.is_connected("mod_message_received", self, "_on_mod_message"):
			node.connect("mod_message_received", self, "_on_mod_message")
		return


func has_api() -> bool:
	return _api != null and is_instance_valid(_api)


func is_online() -> bool:
	return has_api() and bool(_api.is_online())


func role() -> String:
	if not is_online():
		return "offline"
	return "host" if bool(_api.is_host()) else "client"


# 这名玩家的统计是不是由本机负责
func owns_player(p: int) -> bool:
	if not is_online():
		return true
	return bool(_api.owns_player(p))


func broadcast_snapshot(wave: int, players: Dictionary, final: bool) -> bool:
	if not is_online() or players.empty():
		return false
	var payload = {"v": PROTOCOL, "wave": wave, "p": players}
	# 中途的快照是「最新值覆盖旧值」，丢了下一包补上，不占可靠通道；
	# 收波那一包要可靠送达，且不带 battle 作用域——对方可能已经进了商店
	var options = {"reliable": final, "scope": "menu" if final else "battle"}
	return bool(_api.broadcast(MOD_ID, ROUTE_SNAPSHOT, payload, options))


func _on_mod_message(mod_id, route, payload, _meta) -> void:
	if str(mod_id) != MOD_ID or str(route) != ROUTE_SNAPSHOT:
		return
	if typeof(payload) != TYPE_DICTIONARY or int(payload.get("v", 0)) > PROTOCOL:
		return
	var players = payload.get("p", {})
	if typeof(players) != TYPE_DICTIONARY:
		return
	var wave = int(payload.get("wave", 0))
	for key in players.keys():
		var p = int(key)
		# 广播也会投递给自己；自己玩家的数据以本地为准
		if owns_player(p):
			continue
		var snap = players[key]
		if typeof(snap) == TYPE_DICTIONARY:
			emit_signal("snapshot_received", p, snap, wave)
