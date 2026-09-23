# Scripts/Entities/Neutrals/TrampolineBug.gd
## 蹦床虫：行为继承 NeutralBug（地面跟随玩家），顶部可弹起任意物理体（Player / StoneBug 等）。
##  - 弹跳力度随“下落速度”增大：force = clamp(base_bounce_force + 下落速度*fall_speed_factor,
##    base_bounce_force, max_bounce_force)（base 即最小力，无需额外下限）
##  - 踩踏检测：每物理帧扫描 BounceArea 内的物理体，按“下落速度>阈值 且 从上方接触”判定，
##    每个物理体各自有重触发冷却，避免“进入过一次后不再触发”的问题
##  - 可用 bounce_while_moving 控制“移动（Move）状态下是否也会触发弹跳”（默认关）
##  - 悬崖检测与“遇悬崖停止前进”由基类 NeutralBug 提供（stop_at_cliff）
##  - 自带碰撞体不可删（重力/站立需要），但设为不与 Player 等交互：collision_layer=0、mask=6(地面/墙)
##  - 加入 ignore_switch_press 组：不触发按压式开关
extends "res://Scripts/Entities/Neutrals/NeutralBug.gd"
class_name TrampolineBug

## ── 弹跳 ──
@export_category("弹跳")
## 基础弹跳力（像素/秒，也等于最小弹跳力）
@export var base_bounce_force: float = 120.0
## 下落速度对弹跳力的加成系数（落下越快弹得越高）
@export var fall_speed_factor: float = 0.8
## 弹跳力上限（像素/秒）
@export var max_bounce_force: float = 960.0
## 最小下落速度阈值（低于它不触发弹跳，避免平移/静止误触）
@export var min_fall_speed: float = 20.0
## 同一物理体的重触发冷却（秒）
@export var retrigger_lock: float = 0.16
## Move（移动）状态下是否也会触发弹跳（默认关：移动中不触发）
@export var bounce_while_moving: bool = false

## ── 表现 ──
@export_category("表现")
## Trigger 最长占用时间（秒，无动画/循环动画时的兜底）
@export var trigger_time: float = 0.25

## ── 动画（内部固定，不导出）──
## 弹跳动画名枚举
enum BounceAnim {
	TRIGGER = 0,   ## 触发弹跳
}
## 弹跳动画名映射（与 BounceAnim 一一对应）
const BOUNCE_ANIM_NAMES: PackedStringArray = ["Trigger"]

## 弹跳检测区（顶部）
@onready var _bounce_area: Area2D = get_node_or_null("BounceArea") as Area2D

## Trigger 动画是否正在占用
var _triggering: bool = false
## Trigger 兜底计时
var _trigger_timer: float = 0.0
## 每个物理体的上次弹跳时间戳（instance_id -> 毫秒）
var _last_bounce_ms: Dictionary = {}


func _ready() -> void:
	super._ready()
	# 明确“不触发按压式开关”
	add_to_group(&"ignore_switch_press")
	if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation(BOUNCE_ANIM_NAMES[BounceAnim.TRIGGER]):
		sprite.animation_finished.connect(_on_sprite_anim_finished)


func _physics_process(delta: float) -> void:
	if _triggering:
		_trigger_timer -= delta
		if _trigger_timer <= 0.0:
			_triggering = false
	# 每物理帧扫描弹跳区（比只靠 body_entered 可靠：可处理“进入后速度才变大/静止在上方”等情况）
	_poll_bounce()
	super._physics_process(delta)


func _is_anim_locked() -> bool:
	return _triggering


## 每物理帧扫描顶部弹跳区，对“从上方落下”的物理体施加弹跳
func _poll_bounce() -> void:
	if _bounce_area == null or not _bounce_area.monitoring:
		return
	# 移动状态下默认不触发弹跳（可用 bounce_while_moving 打开）
	if not bounce_while_moving and absf(velocity.x) > 5.0:
		return
	var now_ms: int = Time.get_ticks_msec()
	var lock_ms: int = int(maxf(retrigger_lock, 0.0) * 1000.0)
	for body in _bounce_area.get_overlapping_bodies():
		if body == null or body == self:
			continue
		if not (body is CharacterBody2D or body is RigidBody2D):
			continue
		var fall_speed: float = maxf(float(body.velocity.y), 0.0)
		if fall_speed < min_fall_speed:
			continue
		# 只响应从上方接触（身体中心不应低于弹跳面太多）
		if body.global_position.y > global_position.y + 6.0:
			continue
		var bid: int = body.get_instance_id()
		if _last_bounce_ms.has(bid) and now_ms - int(_last_bounce_ms[bid]) < lock_ms:
			continue
		_last_bounce_ms[bid] = now_ms
		_bounce(body, fall_speed)


## 对物理体施加弹跳力（玩家走 JumpBox 弹跳手感，其它物理体直接设向上速度）
func _bounce(body: Node, fall_speed: float) -> void:
	var force: float = clampf(base_bounce_force + fall_speed * fall_speed_factor, base_bounce_force, max_bounce_force)
	if body.has_method("start_jumpbox_bounce"):
		body.start_jumpbox_bounce(force)
	else:
		body.velocity.y = -force
	_play_trigger()


## 播放一次 Trigger 动画（有帧才播；同时用计时兜底，避免循环动画卡住）
func _play_trigger() -> void:
	_triggering = true
	_trigger_timer = maxf(trigger_time, 0.01)
	var trigger_name: String = BOUNCE_ANIM_NAMES[BounceAnim.TRIGGER]
	if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation(trigger_name) \
	and sprite.sprite_frames.get_frame_count(trigger_name) > 0:
		sprite.play(trigger_name)


func _on_sprite_anim_finished() -> void:
	if sprite and sprite.animation == BOUNCE_ANIM_NAMES[BounceAnim.TRIGGER]:
		_triggering = false
