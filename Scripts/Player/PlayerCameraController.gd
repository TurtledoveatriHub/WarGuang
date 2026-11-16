class_name PlayerCameraController
extends Node

# 相机限制在传送后会临时放开到极大范围，避免被边界夹回。
const CAMERA_LIMIT_DISABLED: int = 10000000
# 调试开关，用于追踪传送或抖动后的相机同步问题。
const CAMERA_TELEPORT_DEBUG: bool = false
# 复用玩家相机数学工具，统一处理中心点与边界裁剪。
const PlayerCameraMathUtil = preload("res://Scripts/Player/PlayerCameraMath.gd")
# Warp 追镜在等待玩家真正落位时的默认超时（秒）。
const DEFAULT_WARP_CAMERA_HOLD_TIMEOUT: float = 6.0

@export_category("Focus Capture")
## 是否启用焦点抢夺系统。
## 关闭后所有 Beacon 区域都不会影响相机目标。
@export var focus_capture_enabled: bool = true
## 焦点抢夺全局倍率。
## >1.0 会增强 Beacon 影响；<1.0 会减弱。
@export var focus_capture_global_blend: float = 0.9
## 焦点抢夺单帧目标偏移上限（像素）。
## 防止目标过远导致镜头跳变。
@export var focus_capture_max_offset: float = 320.0
## 抢夺偏移平滑收敛速度系数。
## 值越大越“跟手”，值越小越平滑。
@export var focus_capture_smooth: float = 10.0

# 当前绑定的 Player 节点引用。
var player: Player = null
# 当前绑定的 PhantomCamera2D 节点引用。
var phantom_camera: Node = null
# 传送守卫剩余时长（秒）。
var camera_transition_guard_timer: float = 0.0
# 是否启用传送守卫流程。
var camera_transition_guard_active: bool = false
# 传送守卫前 dead zone 备份（x=width, y=height）。
var camera_transition_dead_zone_backup: Vector2 = Vector2(0.125, 0.1)
# 当前守卫已运行时长（秒）。
var camera_transition_guard_elapsed: float = 0.0
# 守卫最短持续时长（秒）。
var camera_transition_guard_min_duration: float = 0.12
# setup 是否已经执行完成。
var setup_completed: bool = false
# 相机异常日志节流用时间戳（毫秒）。
var invalid_camera_debug_last_log_ms: int = -1000000
# Warp 追镜是否正在运行。
var warp_camera_catchup_active: bool = false
# Warp 追镜前 dead zone 备份（x=width, y=height）。
var warp_camera_dead_zone_backup: Vector2 = Vector2.ZERO
# Warp dead zone 备份是否有效。
var warp_camera_dead_zone_backup_valid: bool = false
# Warp 追镜前的 follow_target 备份。
var warp_camera_follow_target_backup: Node = null
# Warp 追镜使用的临时锚点节点。
var warp_camera_anchor: Node2D = null
# 是否正在等待玩家完成最终落位。
var warp_camera_waiting_for_player_teleport: bool = false
# 等待玩家落位的剩余时间（秒）。
var warp_camera_wait_timeout: float = 0.0
## 传送伤害追镜的最长等待时间。
@export var warp_camera_hold_timeout: float = DEFAULT_WARP_CAMERA_HOLD_TIMEOUT
# Door 追镜模式是否激活。
var door_camera_catchup_active: bool = false
# Door 追镜前 dead zone 备份（x=width, y=height）。
var door_camera_dead_zone_backup: Vector2 = Vector2.ZERO
# 死亡冻结镜头是否接管相机更新。
var death_camera_freeze_active: bool = false
# 死亡冻结使用的相机中心位置。
var death_camera_freeze_position: Vector2 = Vector2.ZERO
# 黑屏过场是否正在接管相机状态。
var blackout_transition_active: bool = false
# 黑屏过场期间的限制与状态备份。
var blackout_transition_backup := {
	"valid": false,
	"pcam": {
		"left": -CAMERA_LIMIT_DISABLED,
		"top": -CAMERA_LIMIT_DISABLED,
		"right": CAMERA_LIMIT_DISABLED,
		"bottom": CAMERA_LIMIT_DISABLED
	},
	"camera": {
		"left": -CAMERA_LIMIT_DISABLED,
		"top": -CAMERA_LIMIT_DISABLED,
		"right": CAMERA_LIMIT_DISABLED,
		"bottom": CAMERA_LIMIT_DISABLED
	}
}
# 调试轨迹日志的上次输出时间戳（毫秒）。
var camera_trace_last_tick_ms: int = -1000000
# 调试轨迹日志最小刷新间隔（毫秒）。
const CAMERA_TRACE_TICK_INTERVAL_MS: int = 240
# 常规跟随模式使用的中间锚点。
var normal_follow_anchor: Node2D = null
# 当前注册到控制器的焦点区列表。
var active_focus_zones: Array[Node] = []
# 当前帧平滑后的焦点抢夺偏移。
var focus_capture_current_offset: Vector2 = Vector2.ZERO

# 初始化相机控制器的绑定对象。
func setup(player_ref: Player) -> void:
	player = player_ref
	phantom_camera = player.get_node_or_null("PhantomCamera2D")
	_ensure_normal_follow_anchor()
	if phantom_camera:
		if phantom_camera.follow_target == null:
			_set_normal_follow_target()
		camera_transition_dead_zone_backup = Vector2(phantom_camera.dead_zone_width, phantom_camera.dead_zone_height)
	setup_completed = true
	_debug_camera_trace("setup")

# 每帧检查传送守卫是否应该结束。
func physics_process(fixed_delta: float) -> void:
	if not setup_completed:
		return
	if not is_instance_valid(player) or not is_instance_valid(phantom_camera):
		return
	if not player.is_inside_tree() or not phantom_camera.is_inside_tree():
		return
	_update_normal_follow_anchor(fixed_delta)
	_ensure_valid_follow_target()
	_track_camera_motion(fixed_delta)
	_update_run_camera_offset(fixed_delta)
	_update_limit_zone_state(fixed_delta)
	var camera := player.get_viewport().get_camera_2d()
	if (camera and (not camera.global_position.is_finite() or not camera.offset.is_finite())) or not phantom_camera.global_position.is_finite():
		_recover_from_invalid_camera_position()
	if death_camera_freeze_active:
		var frozen_center := _clamp_camera_center_by_limits(death_camera_freeze_position, phantom_camera, camera)
		if not frozen_center.is_finite():
			frozen_center = death_camera_freeze_position if death_camera_freeze_position.is_finite() else player.global_position
		phantom_camera.global_position = frozen_center
		if camera:
			camera.global_position = frozen_center
			camera.offset = Vector2.ZERO
		return
	if warp_camera_waiting_for_player_teleport:
		warp_camera_wait_timeout -= fixed_delta
		if warp_camera_wait_timeout <= 0.0:
			_release_warp_camera_hold(true)
	_update_camera_transition_guard(fixed_delta)
	_enforce_runtime_limit_guard(camera)
	_debug_camera_tick(camera)

# 将相机 follow_offset 平滑回零。
func reset_camera_position() -> void:
	if not player or not phantom_camera:
		return
	var tween = player.create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(phantom_camera, "follow_offset", Vector2.ZERO, player.camera_offset_transition_duration)

# 开启传送后的临时守卫，避免相机立刻回落到错误 dead zone。
func start_camera_transition_guard(duration: float = 0.18, max_duration: float = 1.0) -> void:
	if not phantom_camera:
		return
	camera_transition_guard_active = true
	camera_transition_guard_elapsed = 0.0
	camera_transition_guard_min_duration = maxf(duration, 0.01)
	camera_transition_guard_timer = maxf(max_duration, camera_transition_guard_min_duration)
	if CAMERA_TELEPORT_DEBUG:
		print("[CameraGuard] lock begin min=", camera_transition_guard_min_duration, " max=", camera_transition_guard_timer)

# 处理传送后相机轴锁恢复与回位时机。
func _update_camera_transition_guard(fixed_delta: float) -> void:
	if not camera_transition_guard_active:
		return
	camera_transition_guard_elapsed += fixed_delta
	camera_transition_guard_timer -= fixed_delta
	if camera_transition_guard_elapsed < camera_transition_guard_min_duration:
		return

	if camera_transition_guard_timer > 0.0 and not _is_player_inside_normal_camera_dead_zone():
		return
	camera_transition_guard_active = false
	if phantom_camera:
		_safe_teleport_phantom_camera()
	if CAMERA_TELEPORT_DEBUG:
		print("[CameraGuard] lock end elapsed=", camera_transition_guard_elapsed, " timeout_left=", camera_transition_guard_timer)

# 同步房间传送后的相机最终位置。
func sync_camera_after_room_teleport() -> void:
	if not setup_completed:
		return
	if not player or not phantom_camera:
		return
	if not player.is_inside_tree() or not phantom_camera.is_inside_tree():
		return
	if phantom_camera.follow_target == null:
		_set_normal_follow_target()

	var camera := player.get_viewport().get_camera_2d()
	if CameraShakeManager and CameraShakeManager.has_method("stop_shake"):
		CameraShakeManager.stop_shake(phantom_camera)
	if camera:
		camera.offset = Vector2.ZERO

	# 传送：先解开上一位置的限制区，落点在区域内则立即套用（一步到位，不播过渡）
	rebase_limit_zone_now()
	_restore_room_limits_if_needed(camera)

	var desired_center: Vector2 = player.global_position + phantom_camera.follow_offset
	var clamped_center := _clamp_camera_center_by_limits(desired_center, phantom_camera, camera)
	if not clamped_center.is_finite():
		clamped_center = desired_center if desired_center.is_finite() else player.global_position

	phantom_camera.global_position = clamped_center
	_safe_teleport_phantom_camera()

	if camera:
		camera.global_position = clamped_center
		if camera.has_method("reset_smoothing"):
			camera.reset_smoothing()
		if camera.has_method("reset_physics_interpolation"):
			camera.reset_physics_interpolation()

	if CAMERA_TELEPORT_DEBUG:
		print("[CameraTeleportSync] desired=", desired_center, " clamped=", clamped_center)
	_debug_camera_trace("sync_camera_after_room_teleport", {
		"desired": desired_center,
		"clamped": clamped_center
	})

	start_camera_transition_guard(0.10, 0.65)

# 黑屏期间用于重生/远距离回档点：优先让相机以玩家为中心（受房间限制时自动夹取）。
func sync_camera_to_player_center() -> void:
	if not setup_completed:
		return
	if not player or not phantom_camera:
		return
	if not player.is_inside_tree() or not phantom_camera.is_inside_tree():
		return
	end_death_camera_freeze()

	# 重生同步时强制退出 warp 追镜模式，避免 follow_target 残留在锚点导致镜头静止。
	warp_camera_catchup_active = false
	warp_camera_waiting_for_player_teleport = false
	warp_camera_wait_timeout = 0.0
	if warp_camera_dead_zone_backup_valid:
		phantom_camera.dead_zone_width = warp_camera_dead_zone_backup.x
		phantom_camera.dead_zone_height = warp_camera_dead_zone_backup.y
		warp_camera_dead_zone_backup_valid = false
	_set_normal_follow_target()

	# 重生场景不需要观察偏移，直接回归零偏移保证“尽量以玩家为中心”。
	if phantom_camera.has_method("set_follow_offset"):
		phantom_camera.set_follow_offset(Vector2.ZERO)
	else:
		phantom_camera.follow_offset = Vector2.ZERO

	var camera := player.get_viewport().get_camera_2d()
	if CameraShakeManager and CameraShakeManager.has_method("stop_shake"):
		CameraShakeManager.stop_shake(phantom_camera)
	if camera:
		camera.offset = Vector2.ZERO

	# 重生/传送居中：先解开限制区，落点在区域内则立即套用（读档 / 死亡 / 挑战传送都走这里）
	rebase_limit_zone_now()
	_restore_room_limits_if_needed(camera)

	var desired_center: Vector2 = player.global_position
	var clamped_center := _clamp_camera_center_by_limits(desired_center, phantom_camera, camera)
	if not clamped_center.is_finite():
		clamped_center = desired_center if desired_center.is_finite() else player.global_position

	phantom_camera.global_position = clamped_center
	# 重生黑屏同步阶段不调用 teleport_position，避免越界对焦后再被限制拉回。

	if camera:
		camera.global_position = clamped_center
		if camera.has_method("reset_smoothing"):
			camera.reset_smoothing()
		if camera.has_method("reset_physics_interpolation"):
			camera.reset_physics_interpolation()
	_debug_camera_trace("sync_camera_to_player_center", {
		"desired": desired_center,
		"clamped": clamped_center,
		"immediate": false
	})

func begin_blackout_camera_transition() -> void:
	if not setup_completed or blackout_transition_active:
		return
	if not is_instance_valid(player) or not is_instance_valid(phantom_camera):
		return
	blackout_transition_backup.valid = false
	blackout_transition_active = true
	death_camera_freeze_active = false
	warp_camera_catchup_active = false
	warp_camera_waiting_for_player_teleport = false
	warp_camera_wait_timeout = 0.0
	warp_camera_dead_zone_backup_valid = false
	# 传送前立即解锁临时限制区：传送过程中不被它夹位
	release_limit_zone_now()
	if phantom_camera:
		_set_normal_follow_target()
		phantom_camera.follow_offset = Vector2.ZERO
	var camera := player.get_viewport().get_camera_2d()
	if camera:
		camera.offset = Vector2.ZERO

func restore_blackout_camera_transition() -> void:
	if not blackout_transition_active:
		return
	blackout_transition_active = false
	blackout_transition_backup.valid = false

# 黑屏阶段使用：在中心同步后立即刷新 Phantom 跟随锚点，避免淡入后仍出现补偿滑动。
func sync_camera_to_player_center_immediate() -> void:
	sync_camera_to_player_center()
	_safe_teleport_phantom_camera()
	_debug_camera_trace("sync_camera_to_player_center_immediate")

func begin_death_camera_freeze() -> void:
	if not setup_completed:
		return
	if not is_instance_valid(player) or not is_instance_valid(phantom_camera):
		return
	var camera := player.get_viewport().get_camera_2d()
	death_camera_freeze_position = camera.global_position if camera and camera.global_position.is_finite() else phantom_camera.global_position
	if not death_camera_freeze_position.is_finite():
		death_camera_freeze_position = player.global_position
	death_camera_freeze_active = true
	if CameraShakeManager and CameraShakeManager.has_method("stop_shake"):
		CameraShakeManager.stop_shake(phantom_camera)

func end_death_camera_freeze() -> void:
	death_camera_freeze_active = false

# 在极端情况下强制把 Camera2D 放到目标位置。
func force_sync_camera_position_after_teleport() -> void:
	if not setup_completed:
		return
	if not player or not phantom_camera:
		return
	if not player.is_inside_tree() or not phantom_camera.is_inside_tree():
		return
	var camera = player.get_viewport().get_camera_2d()
	if not camera:
		return

	var desired_position = player.global_position + phantom_camera.follow_offset
	var original_left = camera.limit_left
	var original_top = camera.limit_top
	var original_right = camera.limit_right
	var original_bottom = camera.limit_bottom

	if CAMERA_TELEPORT_DEBUG:
		print("DEBUG: 传送后强制同步相机 - 玩家位置:", player.global_position, " 期望相机位置:", desired_position, " 限制:", original_left, ",", original_top, ",", original_right, ",", original_bottom)

	camera.limit_left = -CAMERA_LIMIT_DISABLED
	camera.limit_top = -CAMERA_LIMIT_DISABLED
	camera.limit_right = CAMERA_LIMIT_DISABLED
	camera.limit_bottom = CAMERA_LIMIT_DISABLED
	camera.global_position = desired_position
	await player.get_tree().process_frame
	camera.limit_left = original_left
	camera.limit_top = original_top
	camera.limit_right = original_right
	camera.limit_bottom = original_bottom

	if CAMERA_TELEPORT_DEBUG:
		print("DEBUG: 相机位置设置后:", camera.global_position)

# 传送伤害后使用快速追镜，而不是瞬移相机。
func start_warp_damage_camera_catchup(duration: float = 0.22) -> void:
	start_warp_damage_camera_follow(duration)

# 传送伤害飞行期间：压缩 dead zone 并持续跟随玩家。
func start_warp_damage_camera_follow(_duration: float = 0.22) -> void:
	if not setup_completed:
		return
	if not is_instance_valid(player) or not is_instance_valid(phantom_camera):
		return

	warp_camera_waiting_for_player_teleport = false
	warp_camera_wait_timeout = 0.0
	warp_camera_catchup_active = false
	warp_camera_follow_target_backup = phantom_camera.follow_target
	warp_camera_dead_zone_backup = Vector2(phantom_camera.dead_zone_width, phantom_camera.dead_zone_height)
	warp_camera_dead_zone_backup_valid = false

	phantom_camera.follow_target = player
	# Warp 受伤跟随不再收缩 dead zone，也不触发 guard/teleport，彻底避免瞬移对焦。

func start_warp_damage_camera_catchup_to_position(target_position: Vector2, duration: float = 0.22) -> void:
	if not setup_completed:
		return
	if not is_instance_valid(player) or not is_instance_valid(phantom_camera):
		return
	if warp_camera_catchup_active:
		return
	var camera := player.get_viewport().get_camera_2d()
	if camera == null:
		return
	if not _ensure_warp_camera_anchor():
		return
	warp_camera_catchup_active = true
	warp_camera_waiting_for_player_teleport = false
	warp_camera_wait_timeout = 0.0
	warp_camera_follow_target_backup = phantom_camera.follow_target
	warp_camera_dead_zone_backup = Vector2(phantom_camera.dead_zone_width, phantom_camera.dead_zone_height)
	# 临时接管相机，使用有效锚点避免 PhantomCamera follow_target 为空。
	phantom_camera.follow_target = warp_camera_anchor
	phantom_camera.dead_zone_width = 0.02
	phantom_camera.dead_zone_height = 0.02
	var start_center: Vector2 = camera.global_position
	if not start_center.is_finite():
		start_center = phantom_camera.global_position if phantom_camera.global_position.is_finite() else player.global_position
	var end_center: Vector2 = target_position + phantom_camera.follow_offset
	if not end_center.is_finite():
		end_center = target_position if target_position.is_finite() else start_center
	warp_camera_anchor.global_position = start_center
	var tween := player.create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_method(Callable(self, "_set_warp_camera_center"), start_center, end_center, maxf(duration, 0.05))
	start_camera_transition_guard(0.06, maxf(duration + 0.25, 0.3))
	tween.finished.connect(func():
		if not is_instance_valid(phantom_camera):
			warp_camera_catchup_active = false
			warp_camera_waiting_for_player_teleport = false
			return
		phantom_camera.dead_zone_width = warp_camera_dead_zone_backup.x
		phantom_camera.dead_zone_height = warp_camera_dead_zone_backup.y
		# 追镜到目标后先保持在目标，不要在玩家真正传送前回弹到玩家当前位置。
		if is_instance_valid(warp_camera_anchor):
			phantom_camera.follow_target = warp_camera_anchor
		warp_camera_waiting_for_player_teleport = true
		warp_camera_wait_timeout = maxf(warp_camera_hold_timeout, 0.5)
		warp_camera_catchup_active = false
	)

# 玩家实际完成传送后调用，恢复正常跟随。
func notify_warp_player_teleported() -> void:
	if not has_pending_warp_camera_hold():
		return
	_release_warp_camera_hold(true)

func has_pending_warp_camera_hold() -> bool:
	return warp_camera_dead_zone_backup_valid or warp_camera_catchup_active or warp_camera_waiting_for_player_teleport

func _set_warp_camera_center(center: Vector2) -> void:
	if not is_instance_valid(player) or not is_instance_valid(phantom_camera):
		return
	if not center.is_finite():
		return
	if is_instance_valid(warp_camera_anchor):
		warp_camera_anchor.global_position = center
	phantom_camera.global_position = center
	var camera := player.get_viewport().get_camera_2d()
	if camera:
		camera.global_position = center

func is_warp_camera_catchup_active() -> bool:
	return warp_camera_catchup_active

func _safe_teleport_phantom_camera() -> void:
	if not is_instance_valid(phantom_camera):
		return
	if phantom_camera.follow_target == null and is_instance_valid(player):
		phantom_camera.follow_target = player
	if phantom_camera.follow_target == null:
		return
	if phantom_camera.has_method("teleport_position"):
		phantom_camera.teleport_position()

func _release_warp_camera_hold(follow_player: bool) -> void:
	warp_camera_waiting_for_player_teleport = false
	warp_camera_wait_timeout = 0.0
	if not is_instance_valid(phantom_camera):
		return
	if warp_camera_dead_zone_backup_valid:
		phantom_camera.dead_zone_width = warp_camera_dead_zone_backup.x
		phantom_camera.dead_zone_height = warp_camera_dead_zone_backup.y
		warp_camera_dead_zone_backup_valid = false
	if follow_player and is_instance_valid(player):
		_set_normal_follow_target()
		_safe_teleport_phantom_camera()
	elif is_instance_valid(warp_camera_follow_target_backup):
		phantom_camera.follow_target = warp_camera_follow_target_backup

func _ensure_warp_camera_anchor() -> bool:
	if is_instance_valid(warp_camera_anchor):
		return true
	if not is_instance_valid(player):
		return false
	var parent_node := player.get_parent()
	if parent_node == null:
		return false
	warp_camera_anchor = Node2D.new()
	warp_camera_anchor.name = "WarpCameraAnchor"
	parent_node.add_child(warp_camera_anchor)
	return true

func _ensure_valid_follow_target() -> void:
	if not is_instance_valid(phantom_camera):
		return
	if int(phantom_camera.follow_axis_lock) != int(PhantomCamera2D.FollowLockAxis.NONE):
		phantom_camera.follow_axis_lock = PhantomCamera2D.FollowLockAxis.NONE
	if (warp_camera_catchup_active or warp_camera_waiting_for_player_teleport) and is_instance_valid(warp_camera_anchor):
		if phantom_camera.follow_target != warp_camera_anchor:
			phantom_camera.follow_target = warp_camera_anchor
		return
	_set_normal_follow_target()

func _ensure_normal_follow_anchor() -> void:
	if not is_instance_valid(player):
		return
	if is_instance_valid(normal_follow_anchor):
		return
	var parent_node := player.get_parent()
	if parent_node == null:
		return
	normal_follow_anchor = Node2D.new()
	normal_follow_anchor.name = "PlayerCameraFollowAnchor"
	parent_node.add_child(normal_follow_anchor)
	normal_follow_anchor.global_position = player.global_position

func _set_normal_follow_target() -> void:
	if not is_instance_valid(phantom_camera):
		return
	_ensure_normal_follow_anchor()
	if is_instance_valid(normal_follow_anchor):
		phantom_camera.follow_target = normal_follow_anchor
	elif is_instance_valid(player):
		phantom_camera.follow_target = player

## ── 临时相机限制区（CameraLimitZone）──
## 判定方式：每帧在组 "camera_limit_zone" 里按「玩家是否在区域矩形内」自行判定；
## 不依赖物理进出信号，所以传送 / 读档后位置已经变了也能立刻判定到。
## 已生效的限制框（Rect2() = 未接管，用房间限制）
var limit_zone_current_rect: Rect2 = Rect2()
## 限制框的收敛目标（Rect2() = 收敛回房间限制）
var limit_zone_target_rect: Rect2 = Rect2()
## 是否已接管相机限制框
var limit_zone_rect_applied: bool = false
## 上一次区域限制框（用于释放时算一个“放宽”的中间目标）
var limit_zone_last_rect: Rect2 = Rect2()
## 当前区域的进/出死区（像素）
var limit_zone_dead_zone: float = 32.0
## 当前区域的最大收敛速度（像素/秒；0 = 不设上限）
var limit_zone_slide_speed: float = 480.0
## 当前区域的收敛加速度（像素/秒÷秒）：加速与减速都靠它
var limit_zone_slide_accel: float = 360.0
## 当前是否处于「隐藏房间模式」（仅用于调试展示）
var limit_zone_hidden_mode: bool = false
## 隐藏区的「滞后状态」：zone 实例 id → 本帧是否算「玩家在区内」（解除限制）。
## 死区必须双向：进要深入 margin、出要走出 margin，否则边界拉扯时限制会每帧翻转。
var limit_zone_hidden_inside: Dictionary = {}
## 相机中心上一帧位置（用于取相机自身速度）
var limit_zone_camera_prev_pos: Vector2 = Vector2.ZERO
## 相机中心上一帧位置是否有效
var limit_zone_camera_prev_valid: bool = false
## 相机中心当前速度（像素/秒）
var limit_zone_camera_speed: float = 0.0
## 当前滑动速度（像素/秒；目标框变化时不重置，所以来回切换不会突然变速）
var limit_zone_slide_velocity: float = 0.0
## 上一帧是否因为「相机流程」暂停了限制区（用于流程刚结束时立刻一步到位）
var limit_zone_suspended_last_frame: bool = false
## 上一帧是否处于「全黑」（用于抓「黑屏刚结束」那一帧，把限制与相机一步到位）
var limit_zone_black_last_frame: bool = false

## 每物理帧推进临时限制区的状态：
##  1) 收集所有当前生效的区域约束，取交集（可以同时生效；普通区域用进/出死区判定）
##  2) 没有任何约束 → 目标交回房间限制
## ★ 两种情况下都**不重置速度**：靠 limit_slide_accel 加减速、并以相机自身速度为下限，
##   所以限制反复切换（进出区、区域之间切换）时速度是连续平滑变化的 —— 不靠“锁住限制”来回避问题。
func _update_limit_zone_state(delta: float) -> void:
	## ★ 每帧先检查旧框：切房/传送那一两帧里，旧框必须立刻作废，
	##   否则相机会被「上一个房间的限制」夹住（先无视限制、再突然被拉回）。
	if _is_limit_zone_rect_stale():
		release_limit_zone_now()
	## ★ 黑屏过渡里的相机/限制调整必须一步到位（硬规则）。抓两个时刻：
	##   1) 全黑期间 —— 每帧都把限制框与相机对齐到「当前应该生效」的框；
	##   2) 黑屏刚结束那一帧 —— 再补一次，并把门传送的解限窗口提前收尾。
	##   少了第 2 步：解限窗口比淡入结束得晚 → 玩家看到「黑屏结束才开始被限制」。
	var full_black: bool = _is_full_black_now()
	if full_black:
		limit_zone_black_last_frame = true
		finish_camera_flow_unlock_now()
		rebase_limit_zone_now()
		return
	if limit_zone_black_last_frame:
		limit_zone_black_last_frame = false
		finish_camera_flow_unlock_now()
		rebase_limit_zone_now()
		return
	if limit_zone_suspended_by_camera_flow():
		limit_zone_suspended_last_frame = true
		return
	if limit_zone_suspended_last_frame:
		limit_zone_suspended_last_frame = false
		# ★ 只有「屏幕是全黑」时才允许一步到位（给玩家看的准备工作不能暴露）。
		#   已经不是全黑就交给下面的平滑收敛：速度不清零、按加速度变化，绝对不跳。
		if _is_full_black_now():
			rebase_limit_zone_now()
			return
	var rect: Rect2 = _collect_zone_limit_rect()
	if rect.has_area():
		limit_zone_target_rect = rect
		limit_zone_last_rect = rect
		_step_limit_zone_rect(delta)
		return
	if limit_zone_target_rect == Rect2() and not limit_zone_rect_applied:
		return
	limit_zone_target_rect = Rect2()
	_step_limit_zone_rect(delta)

## 收集所有当前生效的区域约束并取交集（空 = 本次没有任何区域限制）。
##  - 普通区域：玩家要闯进区域边缘 dead_zone 深才算「进入」（避免边缘反复蹭导致抽搯）
##  - 隐藏房间模式：区域是房间里“挖掉”的一块 —— 玩家在外面时**一直生效**（把房间裁掉玩家那一侧），
##    玩家在里面时这个约束不参与（要能正常看到区域内部）
##  - ★ 多个区域同时生效就取交集：这样能同时“拍不到”两块区域（比如中间留出一条正常活动带）
func _collect_zone_limit_rect() -> Rect2:
	if not is_instance_valid(player):
		return Rect2()
	var room_rect: Rect2 = _get_room_limit_rect()
	if not room_rect.has_area():
		return Rect2()
	var tree: SceneTree = player.get_tree()
	if tree == null:
		return Rect2()
	var result: Rect2 = Rect2()
	var has_any: bool = false
	var has_hidden: bool = false
	var has_normal_outside_band: bool = false
	## 本帧见到的隐藏区 id（用于清理已经不在场景里的滞后状态）
	var seen_hidden_zones: Array[int] = []
	for zone in tree.get_nodes_in_group("camera_limit_zone"):
		if not is_instance_valid(zone) or not zone.has_method("get_limit_zone_config"):
			continue
		var cfg: Dictionary = zone.get_limit_zone_config()
		var rect: Rect2 = cfg.get("rect", Rect2())
		if not rect.has_area():
			continue
		var is_hidden: bool = bool(cfg.get("hidden_room_mode", false))
		var part: Rect2 = Rect2()
		var zone_margin: float = maxf(float(cfg.get("dead_zone", limit_zone_dead_zone)), 0.0)
		if is_hidden:
			has_hidden = true
			## ★ 死区是**双向**的（与 CameraLimitZone.dead_zone 的定义一致）：
			##   进 → 深入区内侧 margin 才算「进入」（解除限制）；
			##   出 → 走到区外侧 margin 才算「离开」（恢复限制）。
			##   只做「进」的判定时，玩家刚出边界就恢复限制 → 在边界反复拉扯时
			##   限制框每帧翻转，画面极度卡顿（实测）。
			var zone_key: int = zone.get_instance_id()
			seen_hidden_zones.append(zone_key)
			## 该隐藏区上一帧的滞后状态（首次见到默认 false = 在区外）
			var was_inside: bool = bool(limit_zone_hidden_inside.get(zone_key, false))
			var now_inside: bool = false
			if was_inside:
				## 已在区内：要走到区外 margin 外才算真的离开
				now_inside = _is_player_inside_zone(rect, zone_margin, false)
			else:
				## 在区外：要深入区内 margin 才算真的进入
				now_inside = _is_player_inside_zone(rect, zone_margin, true)
			limit_zone_hidden_inside[zone_key] = now_inside
			if now_inside:
				continue
			part = _hidden_mode_allowed_rect(rect, room_rect, zone_margin)
		else:
			var margin: float = maxf(float(cfg.get("dead_zone", limit_zone_dead_zone)), 0.0)
			if not _is_player_inside_zone(rect, margin, true):
				if _is_player_inside_zone(rect, margin, false):
					has_normal_outside_band = true
				continue
			part = rect
		if not part.has_area():
			continue
		_apply_limit_zone_config(cfg)
		result = part if not has_any else result.intersection(part)
		has_any = true
	## 清掉本帧没见到的隐藏区滞后状态（房间卸载后不会残留、字典不会无限增长）
	for stale_key in limit_zone_hidden_inside.keys():
		if not seen_hidden_zones.has(stale_key):
			limit_zone_hidden_inside.erase(stale_key)
	limit_zone_hidden_mode = has_hidden
	if not has_any:
		if has_normal_outside_band and limit_zone_rect_applied and limit_zone_target_rect.has_area():
			# 玩家还在区域的死区缓冲带里：保持现状，不进入也不放开
			return limit_zone_target_rect
		return Rect2()
	var allowed: Rect2 = result.intersection(room_rect)
	if not _has_camera_space(allowed):
		return Rect2()
	return allowed

## 玩家是否落在区域矩形的「深区」（内缩 margin）或「外带」（外扩 margin）里
func _is_player_inside_zone(rect: Rect2, margin: float, deep: bool) -> bool:
	if not is_instance_valid(player):
		return false
	var test_rect: Rect2 = rect
	if deep:
		var inner: Rect2 = rect.grow(-margin)
		# 区域本身比死区还窄时，直接拿原矩形当进入区域（避免内缩成负尺寸而永远进不去）
		test_rect = inner if inner.has_area() else rect
	else:
		test_rect = rect.grow(margin)
	return test_rect.has_point(player.global_position)

## 传送 / 读档瞬间调用：
##  - 先立刻结束旧限制（不再带着上一个位置的限制框，相机也不会被它夹位）
##  - 若落点在某个限制区内，则**立即**套用该区域限制（一步到位，不播过渡）
func rebase_limit_zone_now() -> void:
	var rect: Rect2 = _collect_zone_limit_rect()
	if not rect.has_area():
		_release_limit_zone_rect()
		_finish_limit_zone_rebase()
		return
	limit_zone_target_rect = rect
	limit_zone_last_rect = rect
	limit_zone_current_rect = rect
	limit_zone_rect_applied = true
	_snap_limit_zone_slide_state(rect)
	_finish_limit_zone_rebase()

## 传送/读档收尾：把跟随目标重新指回常规锚点、立刻把锚点更新到落点位置，
## 并让 PhantomCamera 立刻落到新位置。
## 不做的话，传送后相机会有概率留在原地或被旧限制框夹住（表现为固定的错误位置）。
func _finish_limit_zone_rebase() -> void:
	if not setup_completed:
		return
	if not is_instance_valid(phantom_camera):
		return
	_set_normal_follow_target()
	_update_normal_follow_anchor(0.0)
	_safe_teleport_phantom_camera()

## 立刻解除区域限制接管（传送前用：把相机限制交回房间）
func release_limit_zone_now() -> void:
	_release_limit_zone_rect()

## 内部：解除区域限制接管
func _release_limit_zone_rect() -> void:
	limit_zone_target_rect = Rect2()
	limit_zone_current_rect = Rect2()
	limit_zone_rect_applied = false
	limit_zone_hidden_mode = false
	_snap_limit_zone_slide_state(Rect2())

## 把滑动状态同步到「已到位」（from = goal = rect）
func _snap_limit_zone_slide_state(_rect: Rect2) -> void:
	limit_zone_slide_velocity = 0.0

## 记录某个区域提供的参数
func _apply_limit_zone_config(cfg: Dictionary) -> void:
	limit_zone_dead_zone = maxf(float(cfg.get("dead_zone", limit_zone_dead_zone)), 0.0)
	limit_zone_slide_speed = maxf(float(cfg.get("limit_slide_speed", limit_zone_slide_speed)), 0.0)
	limit_zone_slide_accel = maxf(float(cfg.get("limit_slide_accel", limit_zone_slide_accel)), 1.0)

## 黑屏期间 / 黑屏刚结束调用：立刻结束 Door 传送的「解限窗口」。
## ★ 不解限窗口往往比淡入结束得晚 —— 那段时间相机既不守房间范围也不守限制区，
##   然后才被限制纠正，表现就是「黑屏结束了才响应限制」。这里提前收尾并重算一次。
func finish_camera_flow_unlock_now() -> void:
	if not door_camera_catchup_active:
		return
	door_camera_catchup_active = false
	refresh_camera_limits_now()


## 这些相机流程自己在管 limit_*，限制区不插手（避免多方写同一批属性导致抖动）
func limit_zone_suspended_by_camera_flow() -> bool:
	return door_camera_catchup_active \
		or warp_camera_catchup_active \
		or warp_camera_waiting_for_player_teleport \
		or death_camera_freeze_active \
		or blackout_transition_active

## 取玩家所在范围的限制区（已被 _collect_zone_limit_rect 取代，保留为空实现可删除）

## 隐藏房间模式：把房间限制裁到「玩家所在的那一侧」。
## ★ 玩家在死区缓冲带里（擦边/浅进）时按「离最近的那条边」判断方向 ——
##   否则浅进会被误判成从对面接近，限制会翻到相反的一侧（相机跳到房间另一头）。
func _hidden_mode_allowed_rect(zone_rect: Rect2, room_rect: Rect2, margin: float) -> Rect2:
	var allowed: Rect2 = room_rect
	if not is_instance_valid(player):
		return allowed
	var player_pos: Vector2 = player.global_position
	var cut_x: bool = false
	var cut_left_or_top: bool = true
	if player_pos.x <= zone_rect.position.x - margin:
		cut_x = true
		cut_left_or_top = true
	elif player_pos.x >= zone_rect.end.x + margin:
		cut_x = true
		cut_left_or_top = false
	elif player_pos.y <= zone_rect.position.y - margin:
		cut_x = false
		cut_left_or_top = true
	elif player_pos.y >= zone_rect.end.y + margin:
		cut_x = false
		cut_left_or_top = false
	else:
		## 缓冲带内：取离得最近的那条边作为裁剪方向
		var d_left: float = absf(player_pos.x - zone_rect.position.x)
		var d_right: float = absf(player_pos.x - zone_rect.end.x)
		var d_top: float = absf(player_pos.y - zone_rect.position.y)
		var d_bottom: float = absf(player_pos.y - zone_rect.end.y)
		var d_min: float = minf(minf(d_left, d_right), minf(d_top, d_bottom))
		if d_min <= d_left and d_min <= d_right:
			cut_x = true
			cut_left_or_top = d_left <= d_right
		elif d_min <= d_top and d_min <= d_bottom:
			cut_x = false
			cut_left_or_top = d_top <= d_bottom
		else:
			cut_x = true
			cut_left_or_top = d_left <= d_right
	if cut_x:
		if cut_left_or_top:
			allowed.size.x = maxf(zone_rect.position.x - allowed.position.x, 0.0)
		else:
			var new_left: float = zone_rect.end.x
			allowed.size.x = maxf(allowed.end.x - new_left, 0.0)
			allowed.position.x = new_left
	else:
		if cut_left_or_top:
			allowed.size.y = maxf(zone_rect.position.y - allowed.position.y, 0.0)
		else:
			var new_top: float = zone_rect.end.y
			allowed.size.y = maxf(allowed.end.y - new_top, 0.0)
			allowed.position.y = new_top
	return allowed

## 限制框内缩半个视野后还有没有能放相机中心的空间
## ★ 允许「正好等于视野」：那种区域相机只有一个合法位置，是有意为之的设计，不能当成没空间。
func _has_camera_space(limits: Rect2) -> bool:
	if not limits.has_area():
		return false
	var half_view: Vector2 = _get_half_view_size()
	if half_view.x <= 0.0 or half_view.y <= 0.0:
		return true
	return (limits.size.x >= half_view.x * 2.0 - 0.5) and (limits.size.y >= half_view.y * 2.0 - 0.5)

## 把当前限制框向目标推进一步。
## 速度模型（外部参数都在 CameraLimitZone 上）：
##   limit_slide_accel 加速度（像素/秒÷秒）—— 加速与减速都由它控制，是唯一的速度参数
##   limit_slide_speed 最大速度（像素/秒，0 = 不设上限）
## ★ 速度**不是从 0 加速**：会以相机当前速度作为下限。
##   相机本来就跟着玩家在跑（比如持续奔跑进区域），限制框必须跟上这个速度，
##   否则会先顿一下再从 0 加速，看起来就是「先停顿、再突然冲」。
## ★ 四条边按「同一个绝对速度」移动（不是按比例），所以真正夹住相机的那条边
##   一定是以当前速度在走；行程不同的边各自先到先停。
##   按比例会出问题：边行程差 4 倍时，夹住相机的那条边只走 1/4 速度，表现为「慢得不像预设」。
## ★ 目标框中途变化时不重置当前框、也不把速度清零 → 边界来回切换时速度连续。
## ★ 起点不再用「房间框」：见下面 _snap_limit_zone_edges_to_allowed 的说明。
func _step_limit_zone_rect(delta: float) -> void:
	var goal: Rect2 = limit_zone_target_rect
	if not goal.has_area():
		# 目标是放开：优先回房间限制，房间本身无限制时用一个放宽后的中间框
		goal = _get_room_limit_rect()
		if not goal.has_area():
			goal = limit_zone_last_rect.grow(maxf(limit_zone_dead_zone, 0.0))
	if not limit_zone_rect_applied:
		limit_zone_rect_applied = true
	# ★ 先把「不该慢滑的边」吸附到位，再做速度推进：
	#   目标边不会夹住相机 → 直接给到目标（收紧或放宽都不会让相机跳）
	#   目标边会夹住相机 → 只给到「刚好贴住相机」的位置，之后按速度推进（推相机就是这一步在做）
	#   旧实现是从房间框整体慢慢滑过去：跨度 1000+ 像素的边会把真正夹住相机的那条边
	#   一起拖慢，表现为「黑屏结束后相机半天不动、然后才突然挪一下」，而且滑动期间
	#   生效的是房间框而不是区域框 → 玩家看到的就是相机完全不受区域限制。
	limit_zone_current_rect = _snap_limit_zone_edges_to_allowed(limit_zone_current_rect, goal)
	if not limit_zone_current_rect.has_area():
		limit_zone_current_rect = goal
		limit_zone_slide_velocity = 0.0
		if limit_zone_target_rect == Rect2():
			_release_limit_zone_rect()
		return
	var remaining: float = _rect_slide_distance(limit_zone_current_rect, goal)
	if remaining <= 0.5:
		limit_zone_current_rect = goal
		limit_zone_slide_velocity = 0.0
		if limit_zone_target_rect == Rect2():
			# 已经完全回到房间限制：停止接管
			_release_limit_zone_rect()
		return
	var accel: float = maxf(limit_zone_slide_accel, 1.0)
	# 制动受限速度：v = sqrt(2 * a * s)，保证能在剩余距离内减到 0
	var target_speed: float = sqrt(maxf(2.0 * accel * remaining, 0.0))
	if limit_zone_slide_speed > 0.0:
		target_speed = minf(target_speed, limit_zone_slide_speed)
	limit_zone_slide_velocity = move_toward(limit_zone_slide_velocity, target_speed, accel * delta)
	# 速度下限 = 相机自身速度（但不超目标速度）：不人为从 0 起步
	if limit_zone_camera_speed > limit_zone_slide_velocity:
		limit_zone_slide_velocity = minf(limit_zone_camera_speed, target_speed)
	var step: float = limit_zone_slide_velocity * delta
	var left: float = move_toward(limit_zone_current_rect.position.x, goal.position.x, step)
	var top: float = move_toward(limit_zone_current_rect.position.y, goal.position.y, step)
	var right: float = move_toward(limit_zone_current_rect.end.x, goal.end.x, step)
	var bottom: float = move_toward(limit_zone_current_rect.end.y, goal.end.y, step)
	limit_zone_current_rect = Rect2(left, top, maxf(right - left, 0.0), maxf(bottom - top, 0.0))

## 取相机中心（世界坐标）：限制框「刚好贴住相机」的位置由它算出来。
## 优先用 PhantomCamera（它才是相机中心），取不到再退化成 Camera2D，最后退回当前框中心。
func _get_limit_zone_camera_center() -> Vector2:
	if is_instance_valid(phantom_camera):
		return phantom_camera.global_position
	if is_instance_valid(player) and player.get_viewport():
		var camera: Camera2D = player.get_viewport().get_camera_2d()
		if camera != null:
			return camera.global_position
	return limit_zone_current_rect.get_center()


## 把限制框的四条边吸附到「本帧允许的范围」后返回：
##   左边/上边：允许范围 = [min(目标边, 贴住相机的位置), 目标边]
##   右边/下边：允许范围 = [目标边, max(目标边, 贴住相机的位置)]
##  - 目标边不夹相机 → 范围收成一个点（= 目标边）→ 一步到位
##  - 目标边夹相机 → 范围的另一端就是「刚好贴住相机」→ 本帧不产生任何位移，
##    之后由 _step_limit_zone_rect 的速度推进把它推向目标（推相机就是靠这一步）
## 这样限制框本身永远不会比目标松（相机始终受正确限制），也不会一瞬间夹到相机（不跳）。
func _snap_limit_zone_edges_to_allowed(current: Rect2, goal: Rect2) -> Rect2:
	if not goal.has_area():
		return goal
	var half: Vector2 = _get_half_view_size()
	if half.x <= 0.0 or half.y <= 0.0:
		return goal
	var center: Vector2 = _get_limit_zone_camera_center()
	## ★★ 相机离目标框太远（典型：刚切房、相机还没被搬过去）时**不许顺着相机放宽**：
	##   否则会造出一个横跨两个房间的巨型框，再按速度慢慢滑十几秒 ——
	##   实测就是这样：房间12 进房瞬间 zone_rect=(-312,-440,10532x903)，
	##   从 -312 滑向 7700 要 16 秒，期间隐藏区一直被暴露、房间限制也被它盖掉。
	##   这种情况直接吸附到目标；相机位移由传送/同步流程负责（或由下面的速度推进补）。
	var far_limit: float = maxf(goal.size.x, goal.size.y) + half.x + half.y + maxf(limit_zone_dead_zone, 0.0)
	if center.distance_to(goal.get_center()) > far_limit:
		return goal
	if not current.has_area():
		return _compute_limit_zone_start_rect(goal, center, half)
	## ★ 放宽（loosen）**一律交给速度推进**，绝不在这里一步到位：
	##   否则隐藏区一解除限制（玩家刚深入 CameraLimitZone2 那种），限制框下边界会瞬间从
	##   -16 放到 380 → 相机瞬间挪几百像素；出来又被瞬间夹回 —— 在界限高度反复拉扯时
	##   就表现为「相机疯狂变化」（实测）。放宽是**玩家看得见**的变化，必须平滑。
	##   这里只做「收紧到起点」：收紧永远不会夹到相机，所以安全（且只发生一次）。
	var left: float = maxf(current.position.x, minf(goal.position.x, center.x - half.x))
	var top: float = maxf(current.position.y, minf(goal.position.y, center.y - half.y))
	var right: float = minf(current.end.x, maxf(goal.end.x, center.x + half.x))
	var bottom: float = minf(current.end.y, maxf(goal.end.y, center.y + half.y))
	return Rect2(left, top, maxf(right - left, 0.0), maxf(bottom - top, 0.0))


## 第一次接管（当前框还空着）时的起点框：
## 夹住相机的边放在「刚好贴住相机」处，其余边直接给目标（不参与慢滑）。
func _compute_limit_zone_start_rect(goal: Rect2, center: Vector2, half: Vector2) -> Rect2:
	var left: float = minf(goal.position.x, center.x - half.x)
	var top: float = minf(goal.position.y, center.y - half.y)
	var right: float = maxf(goal.end.x, center.x + half.x)
	var bottom: float = maxf(goal.end.y, center.y + half.y)
	return Rect2(left, top, maxf(right - left, 0.0), maxf(bottom - top, 0.0))


## 每物理帧记录相机中心速度（供限制框速度下限使用）
func _track_camera_motion(delta: float) -> void:
	if not is_instance_valid(phantom_camera) or delta <= 0.0:
		return
	var current: Vector2 = phantom_camera.global_position
	if limit_zone_camera_prev_valid:
		limit_zone_camera_speed = limit_zone_camera_prev_pos.distance_to(current) / delta
	limit_zone_camera_prev_pos = current
	limit_zone_camera_prev_valid = true

## 两个矩形之间的滑动行程：四条边位移的最大值
func _rect_slide_distance(from_rect: Rect2, to_rect: Rect2) -> float:
	return maxf(
		maxf(absf(from_rect.position.x - to_rect.position.x), absf(from_rect.position.y - to_rect.position.y)),
		maxf(absf(from_rect.end.x - to_rect.end.x), absf(from_rect.end.y - to_rect.end.y))
	)

## 当前视野的一半尺寸（世界单位）；取不到时返回 ZERO
func _get_half_view_size() -> Vector2:
	if not is_instance_valid(player):
		return Vector2.ZERO
	var camera: Camera2D = player.get_viewport().get_camera_2d()
	if camera == null:
		return Vector2.ZERO
	var viewport_size: Vector2 = player.get_viewport_rect().size
	var zoom: Vector2 = camera.zoom
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0 or zoom.x <= 0.0 or zoom.y <= 0.0:
		return Vector2.ZERO
	return Vector2(viewport_size.x * 0.5 / zoom.x, viewport_size.y * 0.5 / zoom.y)

## 把跟随锚点夹进当前生效的区域限制框（内缩半个视野，与 limit_* 的语义一致）。
## 不夹的话：锚点（= PhantomCamera 的跟随目标）落在限制框外，相机被 limit 夹住又一直想往框外挪，
## 就会表现为「相机被夹住还持续轻微抖动」。
func _clamp_anchor_to_limit_zone(point: Vector2) -> Vector2:
	if not limit_zone_rect_applied or not limit_zone_current_rect.has_area():
		return point
	var half_view: Vector2 = _get_half_view_size()
	var inner: Rect2 = limit_zone_current_rect
	if half_view.x > 0.0 and half_view.y > 0.0:
		var shrunk: Rect2 = Rect2(limit_zone_current_rect.position + half_view, limit_zone_current_rect.size - half_view * 2.0)
		if shrunk.has_area():
			inner = shrunk
	return Vector2(clampf(point.x, inner.position.x, inner.end.x), clampf(point.y, inner.position.y, inner.end.y))

## 当前实际应当应用的相机限制框（空 Rect2 = 不做任何限制）
func _get_effective_limit_rect() -> Rect2:
	if limit_zone_rect_applied and limit_zone_current_rect.has_area():
		return limit_zone_current_rect
	return _get_room_limit_rect()

## 当前房间的相机限制框（空 Rect2 = 房间没有配置限制）
func _get_room_limit_rect() -> Rect2:
	if RoomManager == null or not RoomManager.has_method("get_current_room_data"):
		return Rect2()
	var room_data = RoomManager.get_current_room_data()
	if typeof(room_data) != TYPE_DICTIONARY:
		return Rect2()
	var room_node = room_data.get("node", null)
	if room_node == null or not room_node.has_method("get_camera_limits"):
		return Rect2()
	var limits: Rect2 = room_node.get_camera_limits()
	if not limits.has_area():
		return Rect2()
	return limits

## 房间是否**配置**了相机限制（已不再使用，保留空实现可删除）

## 奔跑方向相机偏移（空洞骑士式）：同方向持续奔跑时，相机往奔跑方向多让出一点视野
@export_category("奔跑方向相机偏移")
## 是否启用
@export var run_camera_offset_enabled: bool = true
## 最大偏移距离（像素）
@export var run_camera_offset_distance: float = 128.0
## 偏移的响应速度（像素/秒，越大越跟手）
@export var run_camera_offset_speed: float = 128.0
## 偏移归位的速度（像素/秒）：停下后多快回到无偏移
@export var run_camera_offset_return_speed: float = 128.0
## 条件不再满足后，偏移先保持多久再开始归位（秒）。
## ★ 必须有这段：否则“速度掉到阈值以下 / 松开方向键”的同一帧就开始回弹，看得出抖动。
@export var run_camera_offset_hold_time: float = 0.25
## 奔跑中起跳（短按跳跃）时，偏移额外保持多久（秒）。
## ★ 你习惯边跑边短跳：跳跃过程中不该把偏移收回去，否则一跳一收很碎。
@export var run_camera_offset_air_keep_time: float = 0.45
## 判定为「速度快」所需的最小水平速度（像素/秒）；地面奔跑态不再要求速度
@export var run_camera_offset_min_speed: float = 180.0
## 「奔跑中或速度够大」需要持续这么久之后才真正开始产生偏移（秒）。
## ★ 避免刚起步的一瞬间相机就朝前窜一下。
@export var run_camera_offset_trigger_delay: float = 0.9
## 当前奔跑方向偏移量（正 = 朝右；0 = 无偏移）
var run_camera_offset_current: float = 0.0
## 条件不满足已经持续的时长（秒）
var run_camera_offset_idle_time: float = 0.0
## 「奔跑中或速度够大」条件已经持续的时长（秒）
var run_camera_offset_active_time: float = 0.0
## 奔跑后离地剩余保持时间（秒）
var run_camera_offset_air_grace: float = 0.0

## 更新奔跑方向相机偏移：
## 触发条件（任一满足即可）：奔跑中（地面 + 奔跑态）、或水平速度够大、或它们「刚满足过」的保持时间内
## （保持窗口用于边跑边短跳：跳起来后速度可能瞬间很小，不该把偏移收回去）。
## ★ 额外延迟：条件需要连续满足 `run_camera_offset_trigger_delay` 秒后才开始产生偏移，避免起步瞬间抽一下。
## 条件不满足后先保持 `run_camera_offset_hold_time`，之后才平滑归位（避免瞬间回弹抖动）。
## 推进与归位用各自的速度，且不会每帧切换 —— 所以偏移过程是连续的，不卡顿。
## 偏移只加在「跟随锚点」上，因此照样受房间限制与所有 CameraLimitZone 夹取。
func _update_run_camera_offset(delta: float) -> void:
	var velocity_x: float = 0.0
	var running_now: bool = false
	var fast_now: bool = false
	if run_camera_offset_enabled and is_instance_valid(player):
		velocity_x = player.velocity.x
		## 条件 A：地面 + 奔跑态（不再额外要求速度够大）
		running_now = player.is_on_floor() and bool(player.get("is_running"))
		## 条件 B：水平速度够大（离地也算）
		fast_now = absf(velocity_x) >= run_camera_offset_min_speed
	var condition_now: bool = running_now or fast_now
	if condition_now:
		run_camera_offset_active_time += delta
		run_camera_offset_idle_time = 0.0
	else:
		run_camera_offset_active_time = 0.0
		## ★ 「条件断开的时长」与「空中保持」并行计时 —— 不能串联：
		##   串联的话「奔跑→急停」要等 空中保持(0.45) + 保持(0.25) + 归位(128px ÷ 128px/s = 1.0s)
		##   ≈ 1.7 秒，其中前 0.7 秒相机完全不动。
		run_camera_offset_idle_time += delta
		if run_camera_offset_air_grace > 0.0:
			run_camera_offset_air_grace = maxf(run_camera_offset_air_grace - delta, 0.0)
	## 只有「条件持续够久」才算真正触发；触发过之后才给空中保持窗口
	var triggered: bool = condition_now and run_camera_offset_active_time >= run_camera_offset_trigger_delay
	if triggered:
		run_camera_offset_air_grace = run_camera_offset_air_keep_time
	## ★ 保持窗口（含奔跑起跳的那些帧）里不再要求“速度够大”：
	##   起跳瞬间水平速度本来就可能很小，要求速度就会把偏移收回去。
	var keep_offset: bool = triggered or run_camera_offset_air_grace > 0.0
	var direction: float = 0.0
	if absf(velocity_x) > 1.0:
		direction = signf(velocity_x)
	elif not is_zero_approx(run_camera_offset_current):
		# 速度几乎为 0 时沿用当前偏移方向，不要在起跳瞬间把偏移归零
		direction = signf(run_camera_offset_current)
	var target: float = run_camera_offset_distance * direction if keep_offset and not is_zero_approx(direction) else 0.0
	if is_zero_approx(target):
		## 保持时间用「条件断开时长」判定：与空中保持并行，不再叠加（见上面注释）
		if run_camera_offset_idle_time < run_camera_offset_hold_time:
			return
	var speed: float = run_camera_offset_speed if absf(target) > absf(run_camera_offset_current) else run_camera_offset_return_speed
	run_camera_offset_current = move_toward(run_camera_offset_current, target, speed * delta)

func _update_normal_follow_anchor(fixed_delta: float) -> void:
	if not is_instance_valid(player):
		return
	_ensure_normal_follow_anchor()
	if not is_instance_valid(normal_follow_anchor):
		return
	var focus_offset := _compute_focus_capture_offset(fixed_delta)
	var desired_offset := focus_offset
	var target_position: Vector2 = player.global_position + desired_offset
	# 区域限制生效时，把跟随锚点也夹进限制框内：
	# 否则锚点在框外，相机会被 limit 夹住却又一直想往框外跑，表现为持续抖动。
	# 奔跑方向偏移：往奔跑方向多让一点视野；偏移同样要受限制框夹取
	target_position.x += run_camera_offset_current
	target_position = _clamp_anchor_to_limit_zone(target_position)
	normal_follow_anchor.global_position = Vector2(round(target_position.x), round(target_position.y))

func _compute_focus_capture_offset(fixed_delta: float) -> Vector2:
	if not focus_capture_enabled:
		focus_capture_current_offset = focus_capture_current_offset.lerp(Vector2.ZERO, clampf(focus_capture_smooth * fixed_delta, 0.0, 1.0))
		return focus_capture_current_offset

	var best_weight := -1.0
	var best_offset := Vector2.ZERO
	var stale_zones: Array[Node] = []
	for zone in active_focus_zones:
		if not is_instance_valid(zone):
			stale_zones.append(zone)
			continue
		if not zone.has_method("get_focus_capture_sample_for_player"):
			continue
		var sample: Dictionary = zone.get_focus_capture_sample_for_player(player)
		if not bool(sample.get("valid", false)):
			continue
		var weight: float = float(sample.get("weight", 0.0))
		if weight > best_weight:
			best_weight = weight
			best_offset = sample.get("offset", Vector2.ZERO)

	for stale_zone in stale_zones:
		active_focus_zones.erase(stale_zone)

	var target_offset := Vector2.ZERO
	if best_weight > 0.0:
		target_offset = best_offset * maxf(focus_capture_global_blend, 0.0)
		if focus_capture_max_offset > 0.0 and target_offset.length() > focus_capture_max_offset:
			target_offset = target_offset.normalized() * focus_capture_max_offset

	var smooth := clampf(focus_capture_smooth * fixed_delta, 0.0, 1.0)
	focus_capture_current_offset = focus_capture_current_offset.lerp(target_offset, smooth)
	return focus_capture_current_offset

func register_focus_capture_zone(zone: Node) -> void:
	if zone == null:
		return
	if active_focus_zones.has(zone):
		return
	active_focus_zones.append(zone)

func unregister_focus_capture_zone(zone: Node) -> void:
	if zone == null:
		return
	active_focus_zones.erase(zone)

# Door 传送测试路径：短时解限 + 快速追镜 + 自动恢复目标房间限制。
## ★ 屏幕是全黑时不走这套：黑屏里的相机/限制调整必须一步到位。
##   实测症状（用户描述 + 日志）：解限窗口 0.32s 比「淡出 0.2s + 淡入 0.3s」结束得晚，
##   于是淡入结束时相机还处于「解限 + 死区 0.02」= 完全跟随玩家，
##   然后才被拉回房间范围/限制区 —— 表现就是
##   「黑屏结束后（玩家都开始自动走位了）相机才从以玩家为中心的位置移回正确限制位置」。
func start_door_teleport_camera_catchup(catchup_duration: float = 0.20, unlock_duration: float = 0.32) -> void:
	if not setup_completed:
		return
	if not is_instance_valid(player) or not is_instance_valid(phantom_camera):
		return
	if _is_full_black_now():
		## rebase 里已经包含「跟随目标复位 + 相机瞬移到位」；再补一次限制写入
		## （_write_camera_limits 是限制框唯一写入点，pcam 与 Camera2D 一起写）。
		rebase_limit_zone_now()
		refresh_camera_limits_now()
		_debug_camera_trace("door_teleport_instant_sync", {})
		return
	if door_camera_catchup_active:
		return
	
	door_camera_catchup_active = true
	door_camera_dead_zone_backup = Vector2(phantom_camera.dead_zone_width, phantom_camera.dead_zone_height)
	## ★ 这里不再备份「传送前」的 pcam 限制：那是上一个房间的框，收尾时按当前房间重算。
	
	phantom_camera.dead_zone_width = 0.02
	phantom_camera.dead_zone_height = 0.02
	phantom_camera.set("limit_left", -CAMERA_LIMIT_DISABLED)
	phantom_camera.set("limit_top", -CAMERA_LIMIT_DISABLED)
	phantom_camera.set("limit_right", CAMERA_LIMIT_DISABLED)
	phantom_camera.set("limit_bottom", CAMERA_LIMIT_DISABLED)
	
	var camera := player.get_viewport().get_camera_2d()
	## ★ 解限期间不再缓存「传送前的限制」：那段限制属于**上一个房间**，
	##   收尾时必须按「当前房间 + 当前限制区」重算（见下面的 restore_timer）。
	if camera:
		camera.limit_left = -CAMERA_LIMIT_DISABLED
		camera.limit_top = -CAMERA_LIMIT_DISABLED
		camera.limit_right = CAMERA_LIMIT_DISABLED
		camera.limit_bottom = CAMERA_LIMIT_DISABLED
	
	start_camera_transition_guard(0.06, maxf(catchup_duration + unlock_duration, 0.35))
	
	var dead_zone_timer := player.get_tree().create_timer(maxf(catchup_duration, 0.05))
	dead_zone_timer.timeout.connect(func():
		if not is_instance_valid(phantom_camera):
			return
		phantom_camera.dead_zone_width = door_camera_dead_zone_backup.x
		phantom_camera.dead_zone_height = door_camera_dead_zone_backup.y
	)
	
	var restore_timer := player.get_tree().create_timer(maxf(unlock_duration, catchup_duration))
	restore_timer.timeout.connect(func():
		## 已被「黑屏结束」提前收尾（finish_camera_flow_unlock_now）→ 这里绝不能再写任何限制
		if not door_camera_catchup_active:
			return
		if not is_instance_valid(phantom_camera):
			door_camera_catchup_active = false
			return
		## ★★ 「黑屏都结束了才响应限制」的根因就在这几行：
		##    原来是把 door_limits_backup / camera_limits_backup（= 传送前、上一个房间的框）
		##    原样写回去 —— 解限窗口一结束，相机就被**旧房间的框**夹住，
		##    再等限制区控制器下一帧把它纠正过来 → 玩家看到「先无视限制、再突然被夹」。
		##    现在改成按当前房间 + 当前限制区重算一遍（_write_camera_limits 是唯一写入点），一步到位。
		refresh_camera_limits_now()
		door_camera_catchup_active = false
	)

# 返回当前相机守卫和跟随状态的调试快照。
func get_debug_snapshot() -> Dictionary:
	return {
		"setup_completed": setup_completed,
		"guard_active": camera_transition_guard_active,
		"guard_elapsed": camera_transition_guard_elapsed,
		"guard_remaining": camera_transition_guard_timer,
		"axis_lock": int(phantom_camera.follow_axis_lock) if phantom_camera else -1,
		"player_inside_tree": is_instance_valid(player) and player.is_inside_tree() if player else false,
		"camera_inside_tree": is_instance_valid(phantom_camera) and phantom_camera.is_inside_tree() if phantom_camera else false,
		"camera_pos": phantom_camera.global_position if phantom_camera else Vector2.ZERO,
		"follow_offset": phantom_camera.get_follow_offset() if phantom_camera and phantom_camera.has_method("get_follow_offset") else Vector2.ZERO
	}

# 通过限制范围把目标中心点夹回可用区域。
func _clamp_camera_center_by_limits(target_center: Vector2, pcam: Node, camera: Camera2D) -> Vector2:
	return PlayerCameraMathUtil.clamp_camera_center_by_limits(
		target_center,
		pcam,
		camera,
		player.get_viewport_rect().size,
		CAMERA_LIMIT_DISABLED
	)

# 判断玩家是否已经回到正常 dead zone 内，允许守卫结束。
func _is_player_inside_normal_camera_dead_zone() -> bool:
	if not phantom_camera or not player:
		return true
	var camera := player.get_viewport().get_camera_2d()
	if camera == null:
		return true

	var target_world: Vector2 = player.global_position + phantom_camera.follow_offset
	var camera_center: Vector2 = camera.global_position
	var viewport_size: Vector2 = player.get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return true

	var zoom: Vector2 = camera.zoom
	if not target_world.is_finite() or not camera_center.is_finite() or not zoom.is_finite():
		return true
	if is_zero_approx(zoom.x) or is_zero_approx(zoom.y):
		return true
	var half_dead_w: float = viewport_size.x * camera_transition_dead_zone_backup.x * 0.5 / zoom.x
	var half_dead_h: float = viewport_size.y * camera_transition_dead_zone_backup.y * 0.5 / zoom.y
	var half_view_w: float = viewport_size.x * 0.5 / zoom.x
	var half_view_h: float = viewport_size.y * 0.5 / zoom.y

	var limit_left: float = float(int(phantom_camera.get("limit_left")))
	var limit_top: float = float(int(phantom_camera.get("limit_top")))
	var limit_right: float = float(int(phantom_camera.get("limit_right")))
	var limit_bottom: float = float(int(phantom_camera.get("limit_bottom")))

	if limit_left <= -CAMERA_LIMIT_DISABLED + 1 and limit_right >= CAMERA_LIMIT_DISABLED - 1 and limit_top <= -CAMERA_LIMIT_DISABLED + 1 and limit_bottom >= CAMERA_LIMIT_DISABLED - 1:
		return true

	var inside_x: bool = absf(target_world.x - camera_center.x) <= half_dead_w
	var inside_y: bool = absf(target_world.y - camera_center.y) <= half_dead_h

	var free_min_x: float = limit_left + half_view_w + half_dead_w
	var free_max_x: float = limit_right - half_view_w - half_dead_w
	var free_min_y: float = limit_top + half_view_h + half_dead_h
	var free_max_y: float = limit_bottom - half_view_h - half_dead_h
	if free_min_x > free_max_x:
		inside_x = true
	if free_min_y > free_max_y:
		inside_y = true

	if CAMERA_TELEPORT_DEBUG:
		print("[CameraGuard] target=", target_world, " cam=", camera_center, " dead=", half_dead_w, ",", half_dead_h, " freeX=", free_min_x, "..", free_max_x, " freeY=", free_min_y, "..", free_max_y, " inside=", inside_x and inside_y)

	return inside_x and inside_y

# 当相机坐标出现 NaN/Inf 时，立即重置到玩家附近并刷新相机同步。
func _recover_from_invalid_camera_position() -> void:
	if not is_instance_valid(player) or not is_instance_valid(phantom_camera):
		return
	var camera := player.get_viewport().get_camera_2d()
	var camera_before := camera.global_position if camera else Vector2.ZERO
	var offset_before := camera.offset if camera else Vector2.ZERO
	var pcam_before: Vector2 = phantom_camera.global_position
	var now_ms := Time.get_ticks_msec()
	if player.camera_damage_debug and now_ms - invalid_camera_debug_last_log_ms >= 250:
		invalid_camera_debug_last_log_ms = now_ms
		var room_name := RoomManager.current_room if RoomManager else ""
		print("[CameraInvalidRecover] room=", room_name,
			" player_pos=", player.global_position,
			" pcam_before=", pcam_before,
			" cam_before=", camera_before,
			" cam_offset_before=", offset_before,
			" state=", player.current_state,
			" anim=", player.current_animation,
			" warp=", player.is_warp_damage)
	var safe_center: Vector2 = player.global_position + phantom_camera.follow_offset
	if not phantom_camera.follow_offset.is_finite():
		phantom_camera.follow_offset = Vector2.ZERO
		safe_center = player.global_position
	if not safe_center.is_finite():
		safe_center = player.global_position if player.global_position.is_finite() else Vector2.ZERO
	if camera:
		safe_center = _clamp_camera_center_by_limits(safe_center, phantom_camera, camera)
	phantom_camera.global_position = safe_center
	if phantom_camera.has_method("teleport_position"):
		phantom_camera.teleport_position()
	if camera:
		if not camera.offset.is_finite():
			camera.offset = Vector2.ZERO
		camera.global_position = safe_center
		if camera.has_method("reset_smoothing"):
			camera.reset_smoothing()
		if camera.has_method("reset_physics_interpolation"):
			camera.reset_physics_interpolation()
	if CameraShakeManager and CameraShakeManager.has_method("stop_shake"):
		CameraShakeManager.stop_shake(phantom_camera)
	start_camera_transition_guard(0.10, 0.65)
	_debug_camera_trace("recover_invalid_camera", {
		"safe_center": safe_center
	})

func _is_full_black_now() -> bool:
	if FadeManager == null:
		return false
	if FadeManager.has_method("is_fully_black"):
		return FadeManager.is_fully_black()
	return false

func _is_strict_limit_phase() -> bool:
	if blackout_transition_active and _is_full_black_now():
		return false
	return true

func _enforce_runtime_limit_guard(camera: Camera2D) -> void:
	if not _is_strict_limit_phase():
		return
	if not is_instance_valid(phantom_camera):
		return
	_restore_room_limits_if_needed(camera)

	var pcam_center: Vector2 = phantom_camera.global_position
	if pcam_center.is_finite():
		var pcam_clamped: Vector2 = _clamp_camera_center_by_limits(pcam_center, phantom_camera, camera)
		if pcam_clamped.is_finite() and pcam_clamped.distance_squared_to(pcam_center) > 0.0001:
			phantom_camera.global_position = pcam_clamped

	if camera:
		var camera_center: Vector2 = camera.global_position
		if camera_center.is_finite():
			var cam_clamped: Vector2 = _clamp_camera_center_by_limits(camera_center, phantom_camera, camera)
			if cam_clamped.is_finite() and cam_clamped.distance_squared_to(camera_center) > 0.0001:
				camera.global_position = cam_clamped
		if not camera.offset.is_finite():
			camera.offset = Vector2.ZERO
		camera.offset = _clamp_offset_to_camera_limits(camera, camera.offset)

func _clamp_offset_to_camera_limits(camera: Camera2D, raw_offset: Vector2) -> Vector2:
	if camera == null:
		return raw_offset
	var limit_left: int = camera.limit_left
	var limit_top: int = camera.limit_top
	var limit_right: int = camera.limit_right
	var limit_bottom: int = camera.limit_bottom
	if limit_left <= -CAMERA_LIMIT_DISABLED + 1 and limit_top <= -CAMERA_LIMIT_DISABLED + 1 and limit_right >= CAMERA_LIMIT_DISABLED - 1 and limit_bottom >= CAMERA_LIMIT_DISABLED - 1:
		return raw_offset
	var viewport := camera.get_viewport()
	if viewport == null:
		return raw_offset
	var viewport_size: Vector2 = viewport.get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return raw_offset
	var zoom: Vector2 = camera.zoom
	if is_zero_approx(zoom.x) or is_zero_approx(zoom.y):
		return raw_offset
	var half_w: float = viewport_size.x * 0.5 / zoom.x
	var half_h: float = viewport_size.y * 0.5 / zoom.y
	var min_x: float = float(limit_left) + half_w
	var max_x: float = float(limit_right) - half_w
	var min_y: float = float(limit_top) + half_h
	var max_y: float = float(limit_bottom) - half_h
	if min_x > max_x:
		min_x = (float(limit_left) + float(limit_right)) * 0.5
		max_x = min_x
	if min_y > max_y:
		min_y = (float(limit_top) + float(limit_bottom)) * 0.5
		max_y = min_y
	var center: Vector2 = camera.global_position
	if not center.is_finite():
		return Vector2.ZERO
	var center_x: float = clampf(center.x, min_x, max_x)
	var center_y: float = clampf(center.y, min_y, max_y)
	var dx_min: float = min_x - center_x
	var dx_max: float = max_x - center_x
	var dy_min: float = min_y - center_y
	var dy_max: float = max_y - center_y
	return Vector2(clampf(raw_offset.x, dx_min, dx_max), clampf(raw_offset.y, dy_min, dy_max))

## 把「当前应当生效的相机限制框」写进 PhantomCamera 与视口主相机。
## 没有临时限制区时结果就是房间限制（与原来完全一致）；
## 有临时限制区时写的是已经平滑过渡的限制框（房间限制 ↔ 区域限制之间）。
func _restore_room_limits_if_needed(camera: Camera2D) -> void:
	var limits: Rect2 = _get_effective_limit_rect()
	if not limits.has_area():
		return
	_write_camera_limits(limits, camera)

## 把限制框写进 PhantomCamera 与视口主相机（限制框的唯一写入点）
func _write_camera_limits(limits: Rect2, camera: Camera2D) -> void:
	var left := int(limits.position.x)
	var top := int(limits.position.y)
	var right := int(limits.end.x)
	var bottom := int(limits.end.y)
	var changed: bool = false
	if int(phantom_camera.get("limit_left")) != left:
		phantom_camera.set("limit_left", left)
		changed = true
	if int(phantom_camera.get("limit_top")) != top:
		phantom_camera.set("limit_top", top)
		changed = true
	if int(phantom_camera.get("limit_right")) != right:
		phantom_camera.set("limit_right", right)
		changed = true
	if int(phantom_camera.get("limit_bottom")) != bottom:
		phantom_camera.set("limit_bottom", bottom)
		changed = true
	if camera:
		if not camera.limit_enabled:
			camera.limit_enabled = true
			changed = true
		if camera.limit_left != left:
			camera.limit_left = left
			changed = true
		if camera.limit_top != top:
			camera.limit_top = top
			changed = true
		if camera.limit_right != right:
			camera.limit_right = right
			changed = true
		if camera.limit_bottom != bottom:
			camera.limit_bottom = bottom
			changed = true
	if changed:
		_debug_camera_trace("restore_room_limits", {
			"limits": Vector4(left, top, right, bottom)
		})

## 房间没有配置相机限制时：按旧行为把限制放开（当前已不再调用，保留备用）
func _disable_camera_limits(camera: Camera2D) -> void:
	var changed: bool = false
	if is_instance_valid(phantom_camera):
		if int(phantom_camera.get("limit_left")) != -CAMERA_LIMIT_DISABLED:
			phantom_camera.set("limit_left", -CAMERA_LIMIT_DISABLED)
			changed = true
		if int(phantom_camera.get("limit_top")) != -CAMERA_LIMIT_DISABLED:
			phantom_camera.set("limit_top", -CAMERA_LIMIT_DISABLED)
			changed = true
		if int(phantom_camera.get("limit_right")) != CAMERA_LIMIT_DISABLED:
			phantom_camera.set("limit_right", CAMERA_LIMIT_DISABLED)
			changed = true
		if int(phantom_camera.get("limit_bottom")) != CAMERA_LIMIT_DISABLED:
			phantom_camera.set("limit_bottom", CAMERA_LIMIT_DISABLED)
			changed = true
	if camera:
		camera.limit_enabled = false
		camera.limit_left = -CAMERA_LIMIT_DISABLED
		camera.limit_top = -CAMERA_LIMIT_DISABLED
		camera.limit_right = CAMERA_LIMIT_DISABLED
		camera.limit_bottom = CAMERA_LIMIT_DISABLED
		changed = true
	if changed:
		_debug_camera_trace("disable_camera_limits", {})

## 让限制框与「当前房间 + 当前限制区」保持一致（旧入口，保留兼容）。
func refresh_camera_limits_now() -> void:
	apply_limit_zone_over_room_limits()

## 房间限制刚被 RoomManager 重写过（进房 / 门传送 / 传送阵）：
## 把当前正在生效的区域限制框（区域 ∩ 房间）立刻叠加回去。
## ★ 只叠加，不会放宽房间限制；没有区域接管时什么都不做。
## 不做的话，RoomManager 写裸房间限制的那一帧会把区域限制冲掉 ——
## 表现就是「相机无视 CameraLimitZone 动了一下」。
## 当前生效的限制框是不是「上一个房间的旧框」（离玩家太远，已经不属于本次位置）。
## 判据：普通模式下玩家连「外扩 dead_zone 的缓冲带」都不在框里 → 这个框一定是旧的。
## 隐藏模式不适用（玩家本来就在框外的区域里）。
func _is_limit_zone_rect_stale() -> bool:
	if not limit_zone_rect_applied or not limit_zone_current_rect.has_area():
		return false
	if limit_zone_hidden_mode:
		return false
	if not is_instance_valid(player):
		return false
	return not limit_zone_current_rect.grow(maxf(limit_zone_dead_zone, 0.0)).has_point(player.global_position)


## 房间限制刚被写好后调用：如果临时限制区还留着「上一个房间的旧框」，先作废它。
func apply_limit_zone_over_room_limits() -> void:
	if not setup_completed or not is_instance_valid(phantom_camera):
		return
	## ★ 必须有这一步：切房/传送后 RoomManager 刚写好新房间限制，
	##   若此时 zone_rect 还是上一个房间的框（离玩家几千像素），
	##   它会盖掉新限制 —— 相机会先被旧框夹住（表现为「以玩家为中心 / 无视房间范围」），
	##   等限制区下一帧更新后才跳回正确位置。
	if _is_limit_zone_rect_stale():
		release_limit_zone_now()
	if not limit_zone_rect_applied or not limit_zone_current_rect.has_area():
		return
	var camera: Camera2D = null
	if is_instance_valid(player) and player.get_viewport():
		camera = player.get_viewport().get_camera_2d()
	_write_camera_limits(limit_zone_current_rect, camera)

func _is_camera_debug_enabled() -> bool:
	return is_instance_valid(player) and player.camera_damage_debug

func _debug_camera_tick(camera: Camera2D) -> void:
	if not _is_camera_debug_enabled():
		return
	var now_ms := Time.get_ticks_msec()
	if now_ms - camera_trace_last_tick_ms < CAMERA_TRACE_TICK_INTERVAL_MS:
		return
	camera_trace_last_tick_ms = now_ms
	_debug_camera_trace("tick", {
		"strict_limit_phase": _is_strict_limit_phase(),
		"guard_active": camera_transition_guard_active,
		"blackout_transition_active": blackout_transition_active,
		"camera_offset": camera.offset if camera else Vector2.ZERO,
		# ★ 限制区/限制框逐帧状态：排查「传送后一段时间相机才反应」时看这几个值
		"room_limit": _get_room_limit_rect(),
		"zone_rect": limit_zone_current_rect,
		"zone_target": limit_zone_target_rect,
		"zone_applied": limit_zone_rect_applied,
		"zone_suspended": limit_zone_suspended_by_camera_flow(),
		"zone_velocity": limit_zone_slide_velocity,
		"cam_limit": Vector4(camera.limit_left, camera.limit_top, camera.limit_right, camera.limit_bottom) if camera else Vector4.ZERO
	})

func _debug_camera_trace(tag: String, payload: Dictionary = {}) -> void:
	if not _is_camera_debug_enabled():
		return
	var room_name := RoomManager.current_room if RoomManager else ""
	var camera := player.get_viewport().get_camera_2d() if player and player.get_viewport() else null
	var follow_target_name := "null"
	if phantom_camera and phantom_camera.follow_target:
		follow_target_name = String(phantom_camera.follow_target.name)
	var line: String = "[CameraTrace] " + tag + " room=" + room_name \
		+ " player=" + str(player.global_position if player else Vector2.ZERO) \
		+ " pcam=" + str(phantom_camera.global_position if phantom_camera else Vector2.ZERO) \
		+ " cam=" + str(camera.global_position if camera else Vector2.ZERO) \
		+ " follow_target=" + follow_target_name \
		+ " payload=" + str(payload)
	## ★ 调试信息只写文件、不打印到控制台：避免游戏里刷屏（日志自动收入 user://camera_trace.log）。
	##   开关关闭时这一段完全不执行，不留开销。
	_append_camera_trace_file(line)


## 调试：把一行 CameraTrace 追加写入 user://camera_trace.log。
## 超过 2MB 自动清空重来，避免长期开着调试无限增长。
func _append_camera_trace_file(line: String) -> void:
	var path: String = "user://camera_trace.log"
	var file: FileAccess = null
	if FileAccess.file_exists(path):
		file = FileAccess.open(path, FileAccess.READ_WRITE)
	else:
		file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	if file.get_length() > 2 * 1024 * 1024:
		file.close()
		file = FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			return
	file.seek_end()
	file.store_line(line)
	file.close()
