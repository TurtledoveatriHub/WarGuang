extends RefCounted
class_name PlayerEnvironmentZoneService

## 环境效果区 / 上升气流区的逐帧结算服务
##
## 数据流：
##   EnvironmentZone.gd / UpdraftZone.gd（场景脚本，只提供配置）
##     → 本服务每帧遍历组 "environment_zone" / "updraft_zone"
##       → 写入 player 的 env_* 字段（乘数 / 风速度 / 上升速度）
##         → PlayerAbilityService 用乘数算 effective_*；Player 用风与上升速度做额外位移
##
## ★ 关键设计：风速度与上升速度都是**独立速度**，只以「额外位移」的形式施加（move_and_collide），
##   绝不写入 player.velocity。因此：
##   - 玩家自身移动速度、起跳速度、被击退速度都不会被污染；
##   - 状态机判定（例如 IDLE 只看 move_input）不会因为「被风吹动」而改变 → 被风吹时保持 IDLE。

## 环境效果区（EnvironmentZone）所在组
const ENVIRONMENT_ZONE_GROUP: String = "environment_zone"
## 上升气流区（UpdraftZone）所在组
const UPDRAFT_ZONE_GROUP: String = "updraft_zone"

## 每帧刷新环境区结果（乘数 / 风 / 上升气流），并推进风速度与上升速度
## player: 玩家节点（需要具备 env_* 字段）
## fixed_delta: 本物理帧的固定步长
static func refresh(player: Node, fixed_delta: float) -> void:
	## 先复位本帧乘数：本帧没有任何区域时自然回到中性值 1.0
	player.env_zone_speed_mul_right = 1.0
	player.env_zone_speed_mul_left = 1.0
	player.env_zone_speed_mul_up = 1.0
	player.env_zone_speed_mul_down = 1.0
	player.env_zone_gravity_mul = 1.0
	player.env_zone_max_fall_mul = 1.0

	var wind_target: Vector2 = Vector2.ZERO
	var wind_acceleration: float = 0.0
	var wind_max_speed: float = 0.0
	var wind_active: bool = false

	var tree: SceneTree = player.get_tree()
	if tree != null:
		for zone in tree.get_nodes_in_group(ENVIRONMENT_ZONE_GROUP):
			if not is_instance_valid(zone) or not zone.has_method("get_environment_config"):
				continue
			var cfg: Dictionary = zone.get_environment_config(player)
			## 影响强度可为负（效果变化到反向端点）；-2.0 ~ 2.0
			var influence: float = clampf(float(cfg.get("influence", 0.0)), -2.0, 2.0)
			if is_zero_approx(influence):
				continue
			## 乘数：按影响强度在 1.0 与配置值之间插值；多个区域同时生效时相乘
			player.env_zone_speed_mul_right *= lerpf(1.0, float(cfg.get("speed_mul_right", 1.0)), influence)
			player.env_zone_speed_mul_left *= lerpf(1.0, float(cfg.get("speed_mul_left", 1.0)), influence)
			player.env_zone_speed_mul_up *= lerpf(1.0, float(cfg.get("speed_mul_up", 1.0)), influence)
			player.env_zone_speed_mul_down *= lerpf(1.0, float(cfg.get("speed_mul_down", 1.0)), influence)
			player.env_zone_gravity_mul *= lerpf(1.0, float(cfg.get("gravity_mul", 1.0)), influence)
			player.env_zone_max_fall_mul *= lerpf(1.0, float(cfg.get("max_fall_mul", 1.0)), influence)
			## 风：所有区域的风矢量相加（方向相反会自然相互抵消），加速度 / 上限取最大值
			if bool(cfg.get("wind_enabled", false)):
				var zone_wind: Vector2 = cfg.get("wind_velocity", Vector2.ZERO)
				wind_active = true
				wind_target += zone_wind * influence
				wind_acceleration = maxf(wind_acceleration, float(cfg.get("wind_acceleration", 0.0)))
				## 上限要按「实际强度」算：反向/加倍（例如 -2.0）时风速可以超过基准值
				wind_max_speed = maxf(wind_max_speed, zone_wind.length() * absf(influence))
				player.env_zone_wind_deceleration = maxf(player.env_zone_wind_deceleration, float(cfg.get("wind_deceleration", 0.0)))

	## 风速度推进：有风 → 按加速度逼近目标；无风 → 按衰减加速度归零
	if wind_active and wind_max_speed > 0.0:
		player.env_zone_wind_target = wind_target.limit_length(wind_max_speed)
		player.env_wind_velocity = player.env_wind_velocity.move_toward(player.env_zone_wind_target, wind_acceleration * fixed_delta)
		player.env_wind_velocity = player.env_wind_velocity.limit_length(wind_max_speed)
	else:
		player.env_zone_wind_target = Vector2.ZERO
		player.env_wind_velocity = player.env_wind_velocity.move_toward(Vector2.ZERO, player.env_zone_wind_deceleration * fixed_delta)

	## 上升气流：先复位本帧取到的加速度 / 上限，再取所有生效气流中的最强值
	player.env_updraft_acceleration = 0.0
	player.env_updraft_max_speed = 0.0
	if tree != null:
		for zone in tree.get_nodes_in_group(UPDRAFT_ZONE_GROUP):
			if not is_instance_valid(zone) or not zone.has_method("get_updraft_config"):
				continue
			var cfg: Dictionary = zone.get_updraft_config(player)
			if not bool(cfg.get("active", false)):
				continue
			var influence: float = clampf(float(cfg.get("influence", 0.0)), -2.0, 2.0)
			var zone_max_speed: float = float(cfg.get("max_speed", 0.0)) * influence
			## 取「幅度最大」的那一股（可能是向下推，符号由它决定）
			if absf(zone_max_speed) > absf(player.env_updraft_max_speed):
				player.env_updraft_max_speed = zone_max_speed
			player.env_updraft_acceleration = maxf(player.env_updraft_acceleration, absf(float(cfg.get("acceleration", 0.0)) * influence))
			player.env_updraft_deceleration = maxf(player.env_updraft_deceleration, float(cfg.get("deceleration", 0.0)))

	## 上升速度推进（负数 = 向上）：在气流里加速到上升上限，离开后衰减回 0
	if not is_zero_approx(player.env_updraft_max_speed):
		player.env_updraft_velocity = move_toward(player.env_updraft_velocity, -player.env_updraft_max_speed, player.env_updraft_acceleration * fixed_delta)
	else:
		player.env_updraft_velocity = move_toward(player.env_updraft_velocity, 0.0, player.env_updraft_deceleration * fixed_delta)

## 把环境速度作为**额外位移**施加到玩家身上（必须在 move_and_slide 之前调用）
## 内容 = 风速度 + 上/下方向速度乘数带来的额外位移 + 上升气流速度
static func apply_environment_motion(player: Node, fixed_delta: float) -> void:
	## 控制锁定期间（门传送自动走位 / 过场 / 睡眠 / 对话等）不施加环境位移
	if player.is_control_locked:
		return
	var motion: Vector2 = player.env_wind_velocity * fixed_delta
	## 上 / 下方向速度乘数：只补「乘数带来的额外位移」，玩家 velocity 本身保持不变
	var vertical_mul: float = 1.0
	if player.velocity.y < 0.0:
		vertical_mul = player.env_zone_speed_mul_up
	elif player.velocity.y > 0.0:
		vertical_mul = player.env_zone_speed_mul_down
	if not is_equal_approx(vertical_mul, 1.0):
		motion.y += player.velocity.y * (vertical_mul - 1.0) * fixed_delta
	## 上升气流（env_updraft_velocity 为负 = 向上）
	motion.y += player.env_updraft_velocity * fixed_delta
	if motion == Vector2.ZERO:
		return
	player.move_and_collide(motion)
