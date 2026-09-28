extends Reference

# 来源键 → 显示名 / 颜色 / 图标。界面只通过这里认识游戏里的东西。
#
# 来源键（日志里存的就是这些，不随语言变）：
#   w:<weapon_id>:<tier>   武器，同名同品质合在一起（冲锋枪 III ×3）
#   i:<id>                 物品 / 角色 / 其它带追踪键的来源（炮塔、地雷、反击…），id 即游戏里的 my_id
#   m:<enemy_id>           被魅惑的敌人
#   o:burn / o:explosion / o:effect / o:unknown   归不到具体来源的
#   e:<enemy_id> / b:<id> / l:<id>   普通敌人 / Boss / 精英（承伤的攻击者、输出的目标）
#   n:<id>                 中立单位（树）
#   p:self                 自身效果造成的伤害
#   h:regen / h:lifesteal / h:hot / h:consumable / h:other   恢复来源
#
# 游戏数据全部按名字查、查不到就退回可读的键名：游戏更新删了某件物品，旧日志照样能看。

const Strings = preload("../core/strings.gd")
const Config = preload("../core/config.gd")

const GREY = Color(0.62, 0.62, 0.64)
const TIER0 = Color(0.66, 0.68, 0.70)

# 切片 / 攻击者配色：色相拉开，和 TBH Combat Tracker 的饼图一致
const PALETTE = [
	Color("4fa3e3"), Color("e87d3e"), Color("6cc24a"), Color("d1548c"), Color("f2c94c"),
	Color("9b6bd6"), Color("3fc1b0"), Color("c45b4a"), Color("8a9ba8"),
]

var config = null
var _label_cache := {}
var _locale := ""
var _weapons := {}     # weapon_id -> WeaponData（任一品质）
var _items := {}       # my_id -> 资源（物品 / 角色 / 武器 / 消耗品 / 图鉴里的敌人）
var _indexed := false


func _check_locale() -> void:
	var loc = TranslationServer.get_locale()
	if loc != _locale:
		_locale = loc
		_label_cache.clear()


# ---------------------------------------------------------------------------
# 游戏数据索引
# ---------------------------------------------------------------------------

func _index() -> void:
	if _indexed:
		return
	_indexed = true
	var service = _service("ItemService")
	if service == null:
		return
	for list_name in ["items", "characters", "consumables", "entities", "elites", "bosses", "upgrades"]:
		var list = service.get(list_name)
		if typeof(list) != TYPE_ARRAY:
			continue
		for res in list:
			if res == null:
				continue
			var id = res.get("my_id")
			if typeof(id) == TYPE_STRING and id != "" and not _items.has(id):
				_items[id] = res
	var weapons = service.get("weapons")
	if typeof(weapons) == TYPE_ARRAY:
		for w in weapons:
			if w == null:
				continue
			var wid = w.get("weapon_id")
			if typeof(wid) == TYPE_STRING and wid != "" and not _weapons.has(wid):
				_weapons[wid] = w
			var id = w.get("my_id")
			if typeof(id) == TYPE_STRING and id != "" and not _items.has(id):
				_items[id] = w


func _service(name: String):
	var loop = Engine.get_main_loop()
	if loop == null or not loop is SceneTree:
		return null
	return loop.root.get_node_or_null(name)


func _tr(key: String) -> String:
	var loop = Engine.get_main_loop()
	if loop != null and loop is SceneTree:
		return loop.root.tr(key)
	return key


static func prettify(id: String) -> String:
	var s = id
	for prefix in ["weapon_", "item_", "character_", "consumable_"]:
		if s.begins_with(prefix):
			s = s.substr(prefix.length())
			break
	return s.replace("_", " ").capitalize()


# ---------------------------------------------------------------------------
# 名字
# ---------------------------------------------------------------------------

func source_label(view: int, src: String) -> String:
	_check_locale()
	var ck = str(view) + ">" + src
	if _label_cache.has(ck):
		return _label_cache[ck]
	var label = _source_label(view, src)
	_label_cache[ck] = label
	return label


func _source_label(_view: int, src: String) -> String:
	var colon = src.find(":")
	if colon < 0:
		return src
	var kind = src.substr(0, colon)
	var rest = src.substr(colon + 1)
	match kind:
		"w":
			return weapon_label(rest)
		"i":
			return item_label(rest)
		"m":
			return Strings.charmed(enemy_label(rest))
		"e", "b", "l":
			return enemy_label(rest)
		"n":
			return Strings.tree()
		"p":
			return Strings.self_damage()
		"h":
			match rest:
				"regen":
					return _tr_or("STAT_HP_REGENERATION", Strings.pick("生命再生", "HP Regeneration"))
				"lifesteal":
					return _tr_or("STAT_LIFESTEAL", Strings.pick("生命窃取", "Life Steal"))
				"hot":
					return Strings.heal_over_time()
				"consumable":
					return Strings.consumables()
				_:
					return Strings.other_healing()
		"o":
			match rest:
				"burn":
					return Strings.burn()
				"explosion":
					return Strings.explosion()
				"effect":
					return Strings.other_effects()
				_:
					return Strings.unknown_source()
	return src


func _tr_or(key: String, fallback: String) -> String:
	var t = _tr(key)
	return fallback if t == key or t == "" else t


# "weapon_smg:2" -> 冲锋枪 III
func weapon_label(rest: String) -> String:
	_index()
	var parts = rest.split(":")
	var wid = parts[0]
	var tier = int(parts[1]) if parts.size() > 1 and parts[1].is_valid_integer() else 0
	var data = _weapons.get(wid)
	var name = prettify(wid)
	if data != null and typeof(data.get("name")) == TYPE_STRING and data.name != "":
		name = _tr_or(data.name, name)
	var numeral = ["", " II", " III", " IV"]
	if tier > 0 and tier < numeral.size():
		name += numeral[tier]
	return name


func item_label(id: String) -> String:
	_index()
	var res = _items.get(id)
	if res != null and typeof(res.get("name")) == TYPE_STRING and res.name != "":
		return _tr_or(res.name, prettify(id))
	# 追踪键不一定是物品 id（比如炮塔用的是效果上的键），按约定再试一次
	return _tr_or(id.to_upper(), prettify(id))


func enemy_label(id: String) -> String:
	_index()
	var res = _items.get(id)
	if res != null and typeof(res.get("name")) == TYPE_STRING and res.name != "":
		return _tr_or(res.name, prettify(id))
	return _tr_or(id.to_upper() + "_NAME", prettify(id))


func character_label(id: String) -> String:
	if id == "":
		return ""
	_check_locale()
	var ck = "c>" + id
	if _label_cache.has(ck):
		return _label_cache[ck]
	var label = item_label(id)
	_label_cache[ck] = label
	return label


# 拆分项的显示名
func dim_label(view: int, dim: String, item: String) -> String:
	match dim:
		"src":
			return source_label(view, item)
		"tgt":
			return source_label(view, item)
		"form":
			return Strings.form_label(item)
		"crit":
			return Strings.crit_label(item)
		"res":
			return Strings.outcome_label(item)
		"cls":
			if item == "":
				return Strings.no_class()
			_check_locale()
			var ck = "cls>" + item
			if not _label_cache.has(ck):
				_label_cache[ck] = _tr_or(item.to_upper(), prettify(item.replace("stat_", "")))
			return _label_cache[ck]
	return item


# 表格 / 卡片上一行的名字：按玩家分组是「P1 角色」；按来源是来源名，同名武器带「×3」，多人时前面带 P2
func row_label(enc, view: int, group: int, s) -> String:
	if s == null:
		return "?"
	if group == 1:
		return player_label(s.player, enc)
	var label = source_label(view, s.src)
	var n = int(enc.weapon_counts.get(s.key, 0)) if enc != null else 0
	if n > 1:
		label += " ×%d" % n
	if enc != null and enc.players().size() > 1:
		label = Strings.player_tag(s.player) + " " + label
	return label


func row_color(view: int, group: int, s) -> Color:
	if s == null:
		return GREY
	if group == 1:
		return player_color(s.player)
	return source_color(view, s.src, s.player)


func player_label(p: int, enc = null) -> String:
	var tag = Strings.player_tag(p)
	if enc != null and enc.characters.has(p):
		var ch = character_label(str(enc.characters[p]))
		if ch != "":
			return tag + " " + ch
	return tag


# 分段标题：第 5 波 #2（3）· 精英
func encounter_title(enc) -> String:
	if enc == null:
		return "—"
	var title = ""
	if enc.wave > 0:
		var text_service = _service("Text")
		if text_service != null and text_service.has_method("text"):
			title = str(text_service.text("WAVE", [str(enc.wave)]))
		if title == "" or title == "WAVE":
			title = Strings.wave_fallback(enc.wave)
	else:
		title = Strings.no_wave()
	if enc.run > 1:
		title += " " + Strings.run_repeat(enc.run)
	if enc.part > 1:
		title += Strings.part(enc.part)
	var tags := PoolStringArray()
	if enc.tags & 1:
		tags.append(_tr_or("BOSS", "Boss"))
	if enc.tags & 2:
		tags.append(_tr_or("ELITE", Strings.pick("精英", "Elite")))
	if enc.tags & 4:
		tags.append(Strings.horde())
	if tags.size() > 0:
		title += " · " + tags.join(" · ")
	return title


# ---------------------------------------------------------------------------
# 颜色与图标
# ---------------------------------------------------------------------------

func player_color(p: int) -> Color:
	if config != null and p >= 0 and p < 4:
		var custom = Config.parse_color(str(config.value("Player%d" % (p + 1))))
		if custom != null:
			return custom
	var coop = _service("CoopService")
	if coop != null and coop.has_method("get_player_color") and p >= 0 and p < 4:
		return coop.get_player_color(p)
	return PALETTE[posmod(p, PALETTE.size())]


func tier_color(tier: int) -> Color:
	if tier <= 0:
		return TIER0
	var service = _service("ItemService")
	if service != null and service.has_method("get_color_from_tier"):
		return service.get_color_from_tier(tier)
	return [TIER0, Color("4fa3e3"), Color("9b6bd6"), Color("c45b4a")][clamp(tier, 0, 3)]


func source_color(view: int, src: String, player: int) -> Color:
	var colon = src.find(":")
	var kind = src.substr(0, colon) if colon >= 0 else src
	var rest = src.substr(colon + 1) if colon >= 0 else ""
	match kind:
		"w":
			var parts = rest.split(":")
			return tier_color(int(parts[1]) if parts.size() > 1 and parts[1].is_valid_integer() else 0)
		"i":
			_index()
			var res = _items.get(rest)
			if res != null and typeof(res.get("tier")) == TYPE_INT:
				return tier_color(res.tier)
			return TIER0
		"m":
			return Color("e05cd6")
		"b":
			return Color("c0392b")
		"l":
			return Color("e87d3e")
		"e":
			return PALETTE[posmod(rest.hash(), PALETTE.size())]
		"n":
			return Color("5fb04a")
		"p":
			return Color("9b6bd6")
		"h":
			match rest:
				"regen":
					return Color("6cc24a")
				"lifesteal":
					return Color("d1548c")
				"hot":
					return Color("3fc1b0")
				"consumable":
					return Color("f2c94c")
			return GREY
		"o":
			match rest:
				"burn":
					return Color("e87d3e")
				"explosion":
					return Color("f2c94c")
				"effect":
					return Color("9b6bd6")
			return GREY
	return player_color(player) if view == 0 else GREY


func source_icon(src: String) -> Texture:
	var colon = src.find(":")
	if colon < 0:
		return null
	var kind = src.substr(0, colon)
	var rest = src.substr(colon + 1)
	_index()
	var res = null
	match kind:
		"w":
			res = _weapons.get(rest.split(":")[0])
		"i", "m", "e", "b", "l":
			res = _items.get(rest)
	if res == null:
		return null
	var icon = res.get("icon")
	return icon if icon is Texture else null
