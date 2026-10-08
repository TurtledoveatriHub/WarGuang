# Scripts/Entities/Neutrals/NeutralBug.gd
## 中立小虫基类（StoneBug / TrampolineBug 共用）
## 行为：
##   - 子节点 PlayerDetector 检测玩家进入/离开范围。
##   - 玩家进入范围时如果在空中：先不跟随，等玩家落地后才开始跟随。
##   - 玩家站在地面时：实时跟随其水平位置。
##   - 玩家离地后：目标冻结在“离地那一刻”的水平位置，走到后停下。
##   - 玩家全程未落地就离开范围：目标以“离开范围那一刻”的水平位置为准。
##   - 与目标的水平距离小于 follow_dead_zone 时停下，避免在目标附近反复微调。
##   - 玩家站在自己身上时不移动（确保石头虫能当“垫脚石”）。
## 说明：只做地面水平跟随（受重力、被地形阻挡），不做跳跃/寻路。
## 额外（同类互斥）：
##   - 可选“遇到悬崖停止前进”（stop_at_cliff，默认开启），避免走到悬崖边掉下去。
##   - 探测框（BugDetector）里出现同类虫子时，不与之重叠，改为往反方向退避；
##     只有两侧都被同类夹住、或退避方向是悬崖时才停在原地。
## 碰撞建议：collision_layer=32(Good，Player 会碰撞→可踩)+256(NeutralBug，同类互检)，collision_mask=6(Ground|Wall)。
extends CharacterBody2D
class_name NeutralBug

## ── 移动 ──
@export_category("移动")
## 水平移动速度（像素/秒）
@export var move_speed: float = 60.0
## 重力（像素/秒²）
@export var gravity: float = 720.0
## 水平加速度（像素/秒²）
@export var acceleration: float = 120.0
## 跟随死区（像素）：与目标的水平距离小于它就不再移动，避免在目标附近反复微调
@export var follow_dead_zone: float = 12.0
## 遇到悬崖时是否停止前进（默认开启）
@export var stop_at_cliff: bool = true
## 悬崖检测射线节点（与敌人同一套设置：RayCast2D 子节点，朝“前方偏下”）
@export var cliff_detector_path: NodePath = NodePath("CliffDetector")
## 同类虫子探测框节点（Area2D，掩码 = NeutralBug 层，能看见 StoneBug / TrampolineBug 的躯体）
@export var bug_detector_path: NodePath = NodePath("BugDetector")

## ── 动画（内部固定，不导出）──
## 动画名枚举
enum Anim {
	IDLE = 0,   ## 静止
	MOVE = 1,   ## 移动
}
## 动画名映射（与 Anim 一一对应）
const ANIM_NAMES: PackedStringArray = ["Idle", "Move"]

## 动画节点
@onready var sprite: AnimatedSprite2D = get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
## 玩家检测区
@onready var player_detector: Area2D = get_node_or_null("PlayerDetector") as Area2D
## 悬崖检测射线（CliffDetector）
@onready var cliff_detector: RayCast2D = get_node_or_null(cliff_detector_path) as RayCast2D
## 同类虫子探测框（BugDetector）
@onready var bug_detector: Area2D = get_node_or_null(bug_detector_path) as Area2D

## 跟随状态机
##   INACTIVE：玩家在探测范围内但**从未落地** → 不跟随（只记录其水平位置，等离开范围时以那一刻为准）
##   LIVE：玩家正站在地面 → 实时跟随其水平位置
##   FROZEN：玩家已离地 → 目标冻结在“离地那一刻”的水平位置，不再更新
enum FollowState { INACTIVE, LIVE, FROZEN }

## 当前追踪的玩家（在探测范围内时才有效）
var _player: Node = null
## 目标 X（水平）
var _target_x: float = 0.0
## 当前跟随状态（见 FollowState）
var _follow_state: FollowState = FollowState.INACTIVE
## 贴图基准 scale.x（用于左右翻转）
var _base_scale_x: float = 1.0
## 悬崖射线基准 target_position（左右镜像时使用）
var _cliff_base_target: Vector2 = Vector2.ZERO


func _ready() -> void:
	_target_x = global_position.x
	if sprite:
		_base_scale_x = absf(sprite.scale.x)
	if player_detector:
		player_detector.body_entered.connect(_on_detector_body_entered)
		player_detector.body_exited.connect(_on_detector_body_exited)
	if cliff_detector:
		_cliff_base_target = cliff_detector.target_position
	_play_anim(Anim.IDLE)


func _physics_process(delta: float) -> void:
	_update_target()
	_apply_gravity(delta)
	_move(delta)


## 更新跟随目标：
##   - 玩家刚进入范围时如果在空中（未落地）→ 不跟随，只记录其水平位置；
##   - 玩家站在地面 → 实时跟随（LIVE）；
##   - 玩家离地 → 目标冻结在“离地那一刻”的位置（FROZEN）；
##   - 离开范围后不再更新：以当前保留的目标为准（即上面两种情况各自的位置）。
func _update_target() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var player_on_floor: bool = _player.has_method("is_on_floor") and _player.is_on_floor()
	if player_on_floor:
		_target_x = _player.global_position.x
		_follow_state = FollowState.LIVE
		return
	if _follow_state == FollowState.INACTIVE:
		# 全程未落地：持续记录玩家水平位置，保证“离开范围那一刻”的位置被保留下来
		_target_x = _player.global_position.x
	elif _follow_state == FollowState.LIVE:
		# 刚离地：目标就此冻结在离地那一刻的位置
		_follow_state = FollowState.FROZEN


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y += gravity * delta


func _move(delta: float) -> void:
	var dx: float = _target_x - global_position.x
	var want_x: float = 0.0
	if _is_player_on_top():
		# 玩家站在自己身上：不移动，保证“垫脚石”可用（否则会拖者玩家跑，玩家直接滑下去）
		want_x = 0.0
	elif _follow_state != FollowState.INACTIVE and absf(dx) > follow_dead_zone:
		var dir: float = signf(dx)
		if _is_bug_ahead(dir):
			# 前方有同类虫子：不与同类重叠，改为往反方向退避
			var away_dir: float = -dir
			if _is_bug_ahead(away_dir) or _is_cliff_ahead(away_dir):
				# 两侧都被同类虫子夹住，或退避方向是悬崖：放弃退避，停在原地
				want_x = 0.0
			else:
				want_x = away_dir * move_speed
		elif _is_cliff_ahead(dir):
			# 前方是悬崖：停在边缘（速度会自然衰减到 0）
			want_x = 0.0
		else:
			want_x = dir * move_speed
	velocity.x = move_toward(velocity.x, want_x, acceleration * delta)
	if absf(velocity.x) > 1.0:
		_set_facing(velocity.x > 0.0)
	move_and_slide()
	_update_anim()


func _update_anim() -> void:
	if _is_anim_locked():
		return
	_play_anim(Anim.MOVE if absf(velocity.x) > 5.0 else Anim.IDLE)


## 子类可重写：返回 true 时不覆盖当前动画（例：TrampolineBug 的 Trigger 播放中）
func _is_anim_locked() -> bool:
	return false


## 安全播放动画（无 SpriteFrames / 无该动画 / 无帧时跳过）
func _play(anim_name: String) -> void:
	if sprite == null or sprite.sprite_frames == null:
		return
	if not sprite.sprite_frames.has_animation(anim_name):
		return
	if sprite.sprite_frames.get_frame_count(anim_name) <= 0:
		return
	if sprite.animation != anim_name:
		sprite.play(anim_name)


## 按枚举播放动画
func _play_anim(id: int) -> void:
	_play(ANIM_NAMES[id])


## 前方是否为悬崖（前方地面中断）
## 与敌人 RegularEnemy 保持同一套设置：读子节点 CliffDetector（RayCast2D）的命中结果。
## 射线朝“前方偏下”，向左侧移动时把 target_position.x 镜像到左侧（同敌人 _sync_flip 的做法）。
func _is_cliff_ahead(dir: float) -> bool:
	if not stop_at_cliff or dir == 0.0:
		return false
	if cliff_detector == null:
		return false
	if not is_on_floor():
		return false
	_sync_cliff_ray_side(dir)
	return not cliff_detector.is_colliding()


## dir 一侧（左/右）是否有同类虫子（同类互斥：检测到就往反方向退避）
## 说明：BugDetector 是 Area2D 探测框，碰撞掩码设为 NeutralBug 层（项目物理层 9），
## 所以只看得见同类虫子，不会把地形/玩家当成障碍；用框而不是射线，
## 避免两只虫子高度略有差异（跳跃/被弹起）时水平射线漏检。
## 探测框以自身为中心、左右对称，因此直接按“对方在自己哪一侧”判定方向；
## 不能逐帧挪动探测框：物理重叠数据在物理步末尾才刷新，同帧挪动后会读到上一帧的
## 旧数据，导致“前方有虫子”与“身后有虫子”交替为真，退避会不停抖动。
## 注意：探测框包含自己的身体，必须排除自己。
func _is_bug_ahead(dir: float) -> bool:
	if dir == 0.0 or bug_detector == null:
		return false
	var side: float = 1.0 if dir > 0.0 else -1.0
	for body in bug_detector.get_overlapping_bodies():
		if body != self and signf(body.global_position.x - global_position.x) == side:
			return true
	return false


## 把悬崖射线镜像到移动方向一侧
func _sync_cliff_ray_side(dir: float) -> void:
	_sync_ray_side(cliff_detector, _cliff_base_target, dir)


## 按移动方向镜像 RayCast2D 的 target_position（与敌人 _sync_flip 同做法）
func _sync_ray_side(ray: RayCast2D, base_target: Vector2, dir: float) -> void:
	if ray == null:
		return
	var side: float = 1.0 if dir > 0.0 else -1.0
	var target_x: float = absf(base_target.x) * side
	if not is_equal_approx(ray.target_position.x, target_x):
		ray.target_position = Vector2(target_x, base_target.y)
		# 立即刷新，避免镜像后延迟一帧才生效
		ray.force_raycast_update()


func _set_facing(face_right: bool) -> void:
	if sprite == null:
		return
	var target_x: float = _base_scale_x if face_right else -_base_scale_x
	if not is_equal_approx(sprite.scale.x, target_x):
		sprite.scale.x = target_x


func _on_detector_body_entered(body: Node) -> void:
	if body != null and body.is_in_group("player"):
		if _player != body:
			# 新一次进入范围：重新判定（先按“未落地”处理，落地后再转为跟随）
			_follow_state = FollowState.INACTIVE
		_player = body


func _on_detector_body_exited(body: Node) -> void:
	if body == _player:
		# 玩家离开探测范围：不再更新目标，但保留“走到目标”的 FROZEN 状态
		# 这样“全程未落地”的情况也会走到“离开范围那一刻”记录的位置
		_player = null
		_follow_state = FollowState.FROZEN


## 玩家是否正站在自己身上（依据本帧 move_and_slide 的接触法线：朝上说明对方在上方）
func _is_player_on_top() -> bool:
	for i in range(get_slide_collision_count()):
		var col: KinematicCollision2D = get_slide_collision(i)
		if col == null:
			continue
		var body: Node = col.get_collider() as Node
		if body != null and body.is_in_group("player") and col.get_normal().y < -0.5:
			return true
	return false
