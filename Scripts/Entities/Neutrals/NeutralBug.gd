# Scripts/Entities/Neutrals/NeutralBug.gd
## 中立小虫基类（StoneBug / TrampolineBug 共用）
## 行为：
##   - 子节点 PlayerDetector 检测玩家进入/离开范围。
##   - 玩家在范围内且“在地面”时：以玩家当前位置为水平目标持续跟随。
##   - 玩家离地时：保持“离地前最后一次地面位置”为目标，走到后切回 Idle 静止。
## 说明：只做地面水平跟随（受重力、被地形阻挡），不做跳跃/寻路。
## 额外：可选“遇到悬崖停止前进”（stop_at_cliff，默认开启），避免走到悬崖边掉下去。
## 碰撞建议：collision_layer=32(Good，Player 会碰撞→可踩)，collision_mask=6(Ground|Wall)。
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
## 到达目标的判定距离（像素）
@export var arrive_distance: float = 20.0
## 决策/检测间隔（秒，低频省性能）
@export var detect_interval: float = 0.15
## 遇到悬崖时是否停止前进（默认开启）
@export var stop_at_cliff: bool = true
## 悬崖检测射线节点（与敌人同一套设置：RayCast2D 子节点，朝“前方偏下”）
@export var cliff_detector_path: NodePath = NodePath("CliffDetector")
## 同类虫子检测节点（Area2D 前方探测框）。它自身处在 NeutralBug 层，
## 因此“别的虫子的同名探测框”就是它的同类标记。
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

## 当前追踪的玩家
var _player: Node = null
## 目标 X（水平）
var _target_x: float = 0.0
## 是否处于“跟随中”
var _following: bool = false
## 决策计时
var _tick: float = 0.0
## 贴图基准 scale.x（用于左右翻转）
var _base_scale_x: float = 1.0
## 悬崖射线基准 target_position（左右镜像时使用）
var _cliff_base_target: Vector2 = Vector2.ZERO
## 同类检测探测框的基准位置（左右镜像时使用）
var _bug_base_position: Vector2 = Vector2.ZERO


func _ready() -> void:
	_target_x = global_position.x
	if sprite:
		_base_scale_x = absf(sprite.scale.x)
	if player_detector:
		player_detector.body_entered.connect(_on_detector_body_entered)
		player_detector.body_exited.connect(_on_detector_body_exited)
	if cliff_detector:
		_cliff_base_target = cliff_detector.target_position
	if bug_detector:
		_bug_base_position = bug_detector.position
	_play_anim(Anim.IDLE)


func _physics_process(delta: float) -> void:
	_tick += delta
	if _tick >= detect_interval:
		_tick = 0.0
		_update_target()
	_apply_gravity(delta)
	_move(delta)


## 低频决策：是否更新追踪目标
func _update_target() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	if _player.has_method("is_on_floor") and _player.is_on_floor():
		# 玩家在地面：持续跟随玩家当前位置
		_target_x = _player.global_position.x
		_following = true
	else:
		# 玩家离地：保持最后一次“地面位置”为目标，走过去后停下
		_following = true


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y += gravity * delta


func _move(delta: float) -> void:
	var dx: float = _target_x - global_position.x
	var want_x: float = 0.0
	if _following and absf(dx) > arrive_distance:
		var dir: float = signf(dx)
		if _is_cliff_ahead(dir):
			# 前方是悬崖：停在边缘（速度会自然衰减到 0）
			_following = false
			want_x = 0.0
		elif _is_bug_ahead(dir):
			# 前方是同类虫子：互斥，立即停住
			# （必须硬停：若只把目标速度设为 0 让加速度自然减速，还会继续滑行约 15px，
			#   实测两只会互相钻进对方身体里）
			_following = false
			want_x = 0.0
			velocity.x = 0.0
		else:
			want_x = dir * move_speed
	velocity.x = move_toward(velocity.x, want_x, acceleration * delta)
	if absf(velocity.x) > 1.0:
		_set_facing(velocity.x > 0.0)
	move_and_slide()
	if _following and absf(dx) <= arrive_distance and absf(velocity.x) < 1.0:
		_following = false
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


## 前方是否有同类虫子（同类互斥：检测到就不再前进）
## 实现：BugDetector 是前方的 Area2D 探测框，它自身就在 NeutralBug 层（项目物理层 9），
## 因此直接用“区域互检”找同类：别的虫子的 BugDetector 就是同类标记。
## 不用物理体互检的原因：虫子场景的 collision_layer 会被房间实例覆盖
## （TrampolineBug 在房间里就是 0，故意不与 Player 交互），一旦依赖物理体所在层，
## 同类互检会直接失效；用 Area2D 层则不受房间覆盖影响。
## 用框而不是射线：两只虫子高度略有差异（跳跃/被弹起）时水平射线会漏检。
## 注：Area2D 不会把自己算进 overlapping_areas，因此无需手动排除自己。
func _is_bug_ahead(dir: float) -> bool:
	if dir == 0.0 or bug_detector == null:
		return false
	var side: float = 1.0 if dir > 0.0 else -1.0
	var target_x: float = absf(_bug_base_position.x) * side
	if not is_equal_approx(bug_detector.position.x, target_x):
		bug_detector.position = Vector2(target_x, _bug_base_position.y)
	return not bug_detector.get_overlapping_areas().is_empty()


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
		_player = body


func _on_detector_body_exited(body: Node) -> void:
	if body == _player:
		_player = null
		_following = false
