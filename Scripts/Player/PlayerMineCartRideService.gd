# Scripts/Player/PlayerMineCartRideService.gd
## 矿车骑乘服务 —— 供 PlayerRuntimeFlowService 独占分支与伤害入口调用。
## 职责：
##  1. handle_ride_physics：每物理帧把“矿车物理/输入”转发给矿车节点，并负责骑乘外观
##     （受击短暂 Hurt 动画后回到 Idle）。
##  2. try_riding_damage：骑乘时的“非致命伤害”——照常扣血/反馈/iframes，但不下车、
##     不打常规击退，而是把击退交给矿车转成沿轨道方向的冲量；致命伤害返回 false 走正常死亡。
extends RefCounted
class_name PlayerMineCartRideService

## 每物理帧的骑乘处理（由 PlayerRuntimeFlowService 独占分支调用）。
static func handle_ride_physics(player: Node, delta: float) -> void:
	var cart: Node = player.get("riding_minecart")
	if cart == null or not is_instance_valid(cart):
		# 兜底：矿车引用丢失则强制恢复普通控制
		_force_leave(player)
		return
	if cart.has_method("ride_process"):
		cart.ride_process(player, delta)
	# 可能下车后已恢复普通状态，无需再管外观
	if player.get("riding_minecart") == null:
		return
	# 骑乘期间正常递减无敌计时（否则第一次受伤后全程无敌）
	if float(player.get("invincible_timer")) > 0.0:
		player.invincible_timer = maxf(float(player.get("invincible_timer")) - delta, 0.0)
		if player.invincible_timer <= 0.0:
			player.is_invincible = false
	_update_rider_visual(player, delta)


## 骑乘外观：受击时短暂播放 Hurt，平时回到 Idle；无敌期间保持半透明（与普通无敌一致）。
## 注：玩家/车身/轮子的朝向在上车时已由矿车按出发方向固定，行驶中不再翻转。
static func _update_rider_visual(player: Node, delta: float) -> void:
	var remain: float = float(player.get("riding_hurt_remaining"))
	if remain > 0.0:
		player.riding_hurt_remaining = maxf(remain - delta, 0.0)
		if player.current_animation != "HURT":
			player.current_animation = "HURT"
			player.animated_sprite.play("HURT")
	else:
		if player.current_animation != "IDLE":
			player.current_animation = "IDLE"
			player.animated_sprite.play("IDLE")
	# 无敌期间半透明（规则与 PlayerAnimationService 一致：非 HURT/DIE、非重生无敌 → alpha 0.5）
	var want_alpha: float = 1.0
	var is_inv: bool = bool(player.get("is_invincible"))
	var respawn_inv: bool = bool(player.get("is_respawn_invincible"))
	if is_inv and not respawn_inv:
		want_alpha = 0.5
	if not is_equal_approx(player.animated_sprite.modulate.a, want_alpha):
		player.animated_sprite.modulate.a = want_alpha


## 骑乘时的非致命伤害入口。返回 true 表示已处理（不下车）；false 表示应走正常伤害流程（可能致死）。
static func try_riding_damage(player: Node, damage: int, damage_type: int, knockback_force: Vector2, source_pos: Vector2) -> bool:
	var cart: Node = player.get("riding_minecart")
	if cart == null or not is_instance_valid(cart):
		return false
	var cur_health: int = int(player.player_ui.get_health())
	if damage >= cur_health:
		# 致命：交回正常流程（矿车会在死亡反馈里强制下车并复位）
		return false
	# 扣血 + 反馈事件 + 屏幕效果（apply_damage_and_emit 不改状态、不加常规击退）
	var new_health: int = int(player.PlayerDamageFlowServiceScript.apply_damage_and_emit(
		player, damage, damage_type, knockback_force, source_pos
	))
	if new_health <= 0:
		return false
	player.is_invincible = true
	player.invincible_timer = float(player.get("hurt_invincible_time"))
	player.riding_hurt_remaining = 0.4
	# 骑乘受伤也要 Hit Stop / 相机抖动 / 遮罩（与普通受伤一致，由 play_hurt_visual 统一触发）
	if player.PlayerDamageStateServiceScript and player.PlayerDamageStateServiceScript.has_method("play_hurt_visual"):
		player.PlayerDamageStateServiceScript.play_hurt_visual(player, int(damage_type))
	if cart.has_method("apply_riding_knockback"):
		cart.apply_riding_knockback(knockback_force)
	return true


## 兜底：强制离开矿车并恢复普通控制。
static func _force_leave(player: Node) -> void:
	if player.get("riding_minecart") != null:
		var cart: Node = player.get("riding_minecart")
		if cart and cart.has_method("force_eject"):
			cart.force_eject()
			return
		player.riding_minecart = null
	if player.current_state == player.PlayerState.RIDECART:
		player.change_state(player.PlayerState.IDLE)
