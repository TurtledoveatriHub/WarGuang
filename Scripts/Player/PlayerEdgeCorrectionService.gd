extends RefCounted
class_name PlayerEdgeCorrectionService

## 统一处理跳跃、冲刺与「跑出边缘台阶修正」，避免轻微角点碰撞直接打断动作。
static func apply_edge_correction(player: Node, fixed_delta: float) -> void:
	if not is_instance_valid(player):
		return
	## ★ 穿越单向平台的窗口内不做任何边缘校正：
	##   奔跑状态下「跑出边缘台阶修正」会把玩家抬回平台顶面（还会把向下速度清零），
	##   表现就是「奔跑中按下+跳跃，人抽搐一下、没穿过去、也没跳跃」。
	if float(player.get("_one_way_drop_timer")) > 0.0:
		return
	if _apply_run_off_ledge_step_up(player, fixed_delta):
		return
	if _apply_wall_jump_edge_correction(player, fixed_delta):
		return
	if _apply_jump_edge_correction(player, fixed_delta):
		return
	_apply_dash_edge_correction(player, fixed_delta)

## 奔跑跑出边缘的「台阶修正」入口。
## ★ 两个调用点：
##   1) apply_edge_correction（每帧、move_and_slide 之前）—— 提前把玩家抬过矮障碍；
##   2) PlayerMovementService 的撞墙分支（已经贴上墙时）—— 优先修正，修正不成才走撞墙僵直。
static func try_run_off_ledge_step_up(player: Node, fixed_delta: float) -> bool:
	return _apply_run_off_ledge_step_up(player, fixed_delta)

## 奔跑时撞到矮障碍（≤ run_off_ledge_step_up_height）就抬上去，不触发撞墙僵直。
## 四个条件全满才动手：
##   1) 玩家正在奔跑（见 _is_step_up_allowed）；
##   2) 不是向上运动（正在上升时交给跳跃边缘校正）；
##   3) 再往前走一小段的位置被挡住（说明贴上了障碍）；
##   4) 抬高后能继续前进，且抬高量不超过 run_off_ledge_step_up_height。
## ★ 判定关键：探测距离是「前进一个小段（至少 6 像素）」，不是这一帧的位移。
##   否则贴墙时会只抬 1 像素就算“成功”，抬完还是被挡住 → 下一帧仍然撞墙。
static func _apply_run_off_ledge_step_up(player: Node, fixed_delta: float) -> bool:
	if not _is_step_up_allowed(player):
		return false
	# 正在上升（跳起来了）：交给跳跃边缘校正处理，不要在这里抬
	if player.velocity.y < 0.0:
		return false
	var direction: int = sign(player.velocity.x)
	if direction == 0:
		direction = player.run_off_ledge_assist_direction
	if direction == 0:
		return false
	var probe: float = maxf(absf(player.velocity.x) * fixed_delta * 3.0, 6.0)
	var forward := Vector2(float(direction) * probe, 0.0)
	if _is_future_position_free(player, forward, Vector2.ZERO):
		return false
	# 从 1 像素开始逐像素往上试：第一个「抬上去后能继续前进」的高度就是台阶高度
	var max_step: int = int(ceilf(player.run_off_ledge_step_up_height))
	for step_index in range(1, max_step + 1):
		var nudge := Vector2(0.0, -float(step_index))
		if not _is_future_position_free(player, forward, nudge):
			continue
		player.global_position += nudge
		# move_and_slide 撞到墙会把水平速度清零；用离地瞬间记住的速度还原，
		# 否则玩家会在台阶上「顿」一下再重新加速。
		if player.run_off_ledge_assist_speed > 0.0 and absf(player.velocity.x) < player.run_off_ledge_assist_speed:
			player.velocity.x = float(direction) * player.run_off_ledge_assist_speed
		# 已经抬到台阶上沿了，别再往缝里插
		if player.velocity.y > 0.0:
			player.velocity.y = 0.0
		return true
	return false


## 是否允许做台阶修正。
## ★ 判据只有一个：玩家「正在奔跑」（RUN 状态，或奔跑标记还在）。
##   绝不依赖「0.2 秒窗口」或「奔跑离地保持链路」—— 那两个标记在离地那一帧未必已经就位，
##   一旦没就位就是「第一次过断口必定撞墙、第二次才通过」这种现象的来源。
##   真正的安全阀是抬高上限 run_off_ledge_step_up_height：高过它的墙照样撞。
static func _is_step_up_allowed(player: Node) -> bool:
	return player.current_state == player.PlayerState.RUN or bool(player.is_running)

## 跳跃边缘校正：当上升中的未来位置被极小碰撞卡住时，尝试横向微移。
static func _apply_jump_edge_correction(player: Node, fixed_delta: float) -> bool:
	if player.current_state != player.PlayerState.JUMP and player.current_state != player.PlayerState.DOWN:
		return false
	if player.velocity.y >= 0.0:
		return false
	var base_motion: Vector2 = player.velocity * fixed_delta
	if _is_future_position_free(player, base_motion, Vector2.ZERO):
		return false
	var preferred_direction: int = sign(player.velocity.x)
	if player.current_state == player.PlayerState.WALLJUMP and player.wall_grip_direction != 0:
		preferred_direction = -player.wall_grip_direction
	if preferred_direction == 0:
		preferred_direction = 1 if player.is_facing_right else -1
	return _try_perpendicular_nudges(player, base_motion, preferred_direction, player.jump_edge_correction_step, player.jump_edge_correction_steps, true)

## 冲刺边缘校正：当 dash 的未来位置只差一点角点时，尝试竖向微移。
static func _apply_dash_edge_correction(player: Node, fixed_delta: float) -> bool:
	if player.current_state != player.PlayerState.DASH and player.current_state != player.PlayerState.SUPERDASH:
		return false
	var base_motion: Vector2 = player.velocity * fixed_delta
	if _is_future_position_free(player, base_motion, Vector2.ZERO):
		return false
	var preferred_direction: int = -1
	if player.velocity.y > 0.0:
		preferred_direction = 1
	return _try_perpendicular_nudges(player, base_motion, preferred_direction, player.dash_edge_correction_step, player.dash_edge_correction_steps, false)

## 按给定方向做有限次小幅偏移，并检查未来位置是否完全空闲。
static func _try_perpendicular_nudges(player: Node, base_motion: Vector2, preferred_direction: int, step_size: float, max_steps: int, horizontal_nudge: bool) -> bool:
	if step_size <= 0.0 or max_steps <= 0:
		return false
	var directions: Array[int] = [preferred_direction, -preferred_direction]
	for direction in directions:
		if direction == 0:
			continue
		for step_index in range(1, max_steps + 1):
			var nudge: Vector2 = Vector2.ZERO
			if horizontal_nudge:
				nudge.x = step_size * float(step_index) * float(direction)
			else:
				nudge.y = step_size * float(step_index) * float(direction)
			if _is_future_position_free(player, base_motion, nudge):
				player.global_position += nudge
				return true
	return false

## 墙跳边缘校正：复用跳跃校正，但将优先方向固定为离墙方向。
static func _apply_wall_jump_edge_correction(player: Node, fixed_delta: float) -> bool:
	if player.current_state != player.PlayerState.WALLJUMP:
		return false
	if player.velocity.y >= 0.0:
		return false
	var base_motion: Vector2 = player.velocity * fixed_delta
	if _is_future_position_free(player, base_motion, Vector2.ZERO):
		return false
	var preferred_direction: int = -player.wall_grip_direction
	if preferred_direction == 0:
		preferred_direction = sign(player.velocity.x)
	if preferred_direction == 0:
		preferred_direction = 1 if player.is_facing_right else -1
	return _try_perpendicular_nudges(player, base_motion, preferred_direction, player.wall_jump_edge_correction_step, player.wall_jump_edge_correction_steps, true)

## 检查未来位置是否空闲，依赖玩家自身碰撞形状和场景物理空间。
static func _is_future_position_free(player: Node, base_motion: Vector2, nudge: Vector2) -> bool:
	if not is_instance_valid(player):
		return false
	var collision_shape: CollisionShape2D = _find_collision_shape_node(player)
	if collision_shape == null or collision_shape.shape == null:
		return false
	if player.get_world_2d() == null:
		return false
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = collision_shape.shape
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.collision_mask = player.collision_mask
	query.exclude = [player.get_rid()]
	var transform := collision_shape.global_transform
	transform.origin += base_motion + nudge
	query.transform = transform
	var results: Array = player.get_world_2d().direct_space_state.intersect_shape(query, 1)
	return results.is_empty()

## 从玩家节点树中递归查找可用的碰撞形状。
static func _find_collision_shape_node(root: Node) -> CollisionShape2D:
	for child in root.get_children():
		if child is CollisionShape2D and child.shape != null:
			return child
		if child is Node:
			var nested_shape: CollisionShape2D = _find_collision_shape_node(child)
			if nested_shape != null:
				return nested_shape
	return null