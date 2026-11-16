extends RefCounted
class_name PlayerBreathService

## 水下呼吸 / 气泡系统（参考《泰拉瑞亚》与《我的世界》）
##
## 规则：
##  - 进入水域 → 显示气泡（数量 = max_bubbles，默认 3），每个气泡撑 `bubble_interval` 秒；
##  - 只有**浸没**（头部入水）时才消耗气泡；露出水面立刻补满（与泰拉瑞亚 / MC 一致）；
##  - 气泡全部耗尽 → 每隔 `drown_damage_interval` 秒受到 `drown_damage` 点溺水伤害，直到出水；
##  - 拿到「水下呼吸」道具 → 不显示气泡、不受溺水伤害；
##  - 拿到「额外气泡」道具 → 调 `player.set_max_bubbles(n)` 直接加气泡数。
##
## ★ 溺水伤害从「水面脚本」搬到这里：水面只负责上报「进水 / 出水 / 是否浸没」，
##   这样任何水域（不同房间、不同参数的水面）都共用同一套呼吸规则。
##
## 表现层：气泡由 PlayerUI.set_bubble_count(当前, 上限) 负责（传 -1 = 隐藏）。

## 计算用：气泡消耗的时间片下限（避免 bubble_interval 被设成 0 时爆炸）
const MIN_INTERVAL: float = 0.05

## 气泡柱（水下上升气泡）所在组名
const BUBBLE_COLUMN_GROUP: String = "bubble_column_zone"

## 每帧推进（在 Player 的物理帧里调用）
static func tick(player: Node, delta: float) -> void:
	player.in_bubble_column = _is_in_bubble_column(player)
	## ★ 气泡只在「完全浸没」时显示（与浸入判定同一套阈值，默认 80%）；
	##   只是碰到水但不浸没 → 不显示气泡、不显示屏幕滤镜。
	var show_bubbles: bool = player.is_submerged_in_water and not player.water_breathing and player.max_bubbles > 0
	if not show_bubbles:
		## 没完全浸没（或已有水下呼吸）：数值照常回满，但隐藏气泡
		player.breath_timer = 0.0
		player.breath_damage_timer = -1.0
		_refill_step(player, delta)
		## 屏幕滤镜也只跟随「完全浸没」
		_push_water_tint(player, 1.0 if player.is_submerged_in_water else 0.0, 0.0)
		if player.bubbles_visible:
			_push_ui(player, false)
		return
	## ★ 刚入水立刻把气泡显示出来（不要等到第一个气泡被消耗才出现）
	if not player.bubbles_visible:
		player.breath_timer = 0.0
		player.breath_damage_timer = -1.0
		player.bubbles_left = player.max_bubbles
		_push_ui(player, true)
	if not player.is_submerged_in_water or player.in_bubble_column:
		## 头部露出水面 / 在气泡柱里：不消耗，并按回充速度补气泡
		player.breath_timer = 0.0
		player.breath_damage_timer = -1.0
		_refill_step(player, delta)
		_push_ui(player, true)
		_push_water_tint(player, 1.0, 0.0)
		return
	player.breath_timer += delta
	var consumed: int = int(floor(player.breath_timer / maxf(player.bubble_interval, MIN_INTERVAL)))
	var left: int = maxi(player.max_bubbles - consumed, 0)
	if left != player.bubbles_left:
		player.bubbles_left = left
		_push_ui(player, true)
	## 水色滤镜：气泡越少越深（与受伤的红色渐晕可叠加）
	var danger: float = 0.0
	if player.max_bubbles > 0:
		danger = clampf(1.0 - float(player.bubbles_left) / float(player.max_bubbles), 0.0, 1.0)
	_push_water_tint(player, 1.0, danger)
	if left > 0:
		return
	## 气泡耗尽 → 持续受到溺水伤害
	if player.breath_damage_timer < 0.0:
		player.breath_damage_timer = 0.0
	player.breath_damage_timer += delta
	if player.breath_damage_timer >= maxf(player.drown_damage_interval, MIN_INTERVAL):
		player.breath_damage_timer = 0.0
		_apply_drown_damage(player)

## 回充一步：bubble_refill_interval <= 0 时瞬间回满，否则按间隔逐个回
static func _refill_step(player: Node, delta: float) -> void:
	if player.bubbles_left >= player.max_bubbles:
		player.bubbles_left = player.max_bubbles
		player.bubble_refill_timer = 0.0
		return
	if player.bubble_refill_interval <= 0.0:
		player.bubbles_left = player.max_bubbles
		player.bubble_refill_timer = 0.0
		if player.in_water:
			_push_ui(player, true)
		return
	player.bubble_refill_timer += delta
	var refilled: bool = false
	while player.bubble_refill_timer >= player.bubble_refill_interval and player.bubbles_left < player.max_bubbles:
		player.bubble_refill_timer -= player.bubble_refill_interval
		player.bubbles_left += 1
		refilled = true
	if refilled and player.in_water:
		_push_ui(player, true)

## 玩家当前是否位于某个「气泡柱」内
static func _is_in_bubble_column(player: Node) -> bool:
	var tree: SceneTree = player.get_tree()
	if tree == null:
		return false
	for zone in tree.get_nodes_in_group(BUBBLE_COLUMN_GROUP):
		if not is_instance_valid(zone) or not zone.has_method("contains_position"):
			continue
		if bool(zone.contains_position(player.global_position)):
			return true
	return false

## 补满气泡并暂停溺水计时（出水 / 有水下呼吸 / 不设气泡时调用）
static func refill(player: Node) -> void:
	player.breath_timer = 0.0
	player.breath_damage_timer = -1.0
	player.bubbles_left = player.max_bubbles
	player.bubble_refill_timer = 0.0

## 推送水色滤镜
static func _push_water_tint(player: Node, strength: float, danger: float) -> void:
	var ui: Node = player.get("player_ui")
	if ui == null or not is_instance_valid(ui) or not ui.has_method("set_water_tint"):
		return
	ui.set_water_tint(strength, danger)

## 把气泡数量推给 UI（visible = false 时传 -1 → UI 隐藏整行）
static func _push_ui(player: Node, visible: bool) -> void:
	player.bubbles_visible = visible
	var ui: Node = player.get("player_ui")
	if ui == null or not is_instance_valid(ui) or not ui.has_method("set_bubble_count"):
		return
	ui.set_bubble_count(player.bubbles_left if visible else -1, player.max_bubbles)

## 造成溺水伤害（无视无敌时间，但会刷新无敌计时，与旧水面行为保持一致）
static func _apply_drown_damage(player: Node) -> void:
	if not player.has_method("take_damage"):
		return
	var was_invincible: bool = false
	if "is_invincible" in player:
		was_invincible = player.is_invincible
	if was_invincible:
		player.is_invincible = false
	player.take_damage(player.global_position, player.drown_damage, 0, Vector2(0, -100))
	if was_invincible and "is_invincible" in player:
		player.is_invincible = true
		if "invincible_timer" in player and "hurt_invincible_time" in player:
			player.invincible_timer = player.hurt_invincible_time
