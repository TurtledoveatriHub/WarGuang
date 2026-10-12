# Scripts/Entities/Neutrals/TrampolineBug.gd
## 蹦床虫：行为继承 NeutralBug（地面跟随玩家），顶部可弹起任意物理体（Player / StoneBug 等）。
##  - 弹跳力度随“下落速度”增大：force = clamp(base_bounce_force + 下落速度*fall_speed_factor,
##    base_bounce_force, max_bounce_force)（base 即最小力，无需额外下限）
##  - 踩踏检测：每物理帧扫描 BounceArea 内的物理体，按“下落速度≥阈值 且 从上方接触”判定，
##    移动中同样会触发弹跳（蹦床不受自身移动影响），不设重触发冷却
##  - 玩家走专用弹跳入口（Player.start_trampoline_bounce），力度只受本虫 max_bounce_force 约束，
##    不受 JumpBox 的 jumpbox_max_vertical_force 限制
##  - Trigger 动画结束时把 Idle/Move 恢复到弹跳前的进度（不从头重播）
##  - 悬崖检测与“遇悬崖停止前进”由基类 NeutralBug 提供（stop_at_cliff）
##  - 碰撞层只含 NeutralBug（同类互检用），Player 的碰撞掩码不含该层 → 玩家可以穿过本虫，
##    只由顶部 BounceArea 弹起，不会与玩家产生碰撞体交互
##  - 加入 ignore_switch_press 组：不触发按压式开关
extends "res://Scripts/Entities/Neutrals/NeutralBug.gd"
class_name TrampolineBug

## ── 弹跳 ──
@export_category("弹跳")
## 基础弹跳力（像素/秒，也等于最小弹跳力）
@export var base_bounce_force: float = 240.0
## 下落速度对弹跳力的加成系数（落下越快弹得越高）
@export var fall_speed_factor: float = 0.8
## 弹跳力上限（像素/秒）
@export var max_bounce_force: float = 960.0
## 最小下落速度阈值（低于它不触发弹跳，避免上升/平移中误触）
@export var min_fall_speed: float = 5.0

## ── 表现 ──
@export_category("表现")
## Trigger 最长占用时间（秒，无动画/循环动画时的兜底）
@export var trigger_time: float = 0.2

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
## Trigger 播放前正在播的动画名（弹跳结束后原样恢复，避免 Idle/Move 从头重播）
var _resume_anim: String = ""
## Trigger 播放前的动画帧序号（恢复用）
var _resume_frame: int = 0
## Trigger 播放前的帧内进度（恢复用，保留动画节奏）
var _resume_frame_progress: float = 0.0


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
			_end_trigger()
	# 每物理帧扫描弹跳区（比只靠 body_entered 可靠：可处理“进入后速度才变大/静止在上方”等情况）
	_poll_bounce()
	super._physics_process(delta)


func _is_anim_locked() -> bool:
	return _triggering


## 每物理帧扫描顶部弹跳区，对“从上方落下”的物理体施加弹跳
## 命中判定是“扫掠式”的：只要本帧的下落距离内会到达（或已经越过）弹跳面就算命中，
## 因此与物理采样相位无关，不会因为“某一帧刚好跨过检测带”而整段漏检。
func _poll_bounce() -> void:
	if _bounce_area == null or not _bounce_area.monitoring:
		return
	## 弹跳面：本虫顶面（原点即碰撞盒顶面）
	var surface_y: float = global_position.y
	## 本帧物理步长（扫掠用）
	var step_delta: float = get_physics_process_delta_time()
	for body in _bounce_area.get_overlapping_bodies():
		if body == null or body == self:
			continue
		if not (body is CharacterBody2D or body is RigidBody2D):
			continue
		var fall_speed: float = maxf(float(body.velocity.y), 0.0)
		if fall_speed < min_fall_speed:
			continue
		## 本帧允许的接触范围：本帧下落距离 + 1px 容差（尽量贴合“踩到顶面”的时机）
		var reach: float = fall_speed * step_delta + 1.0
		## 还没落到弹跳面附近 → 继续下落（避免在半空中就弹）
		if body.global_position.y < surface_y - reach:
			continue
		## 已经明显穿到弹跳面以下 → 不再补触发
		if body.global_position.y > surface_y + reach:
			continue
		_bounce(body, fall_speed)


## 对物理体施加弹跳力：
##   - 玩家走专用蹦床弹跳入口（力度只受本虫上限约束，弹跳后空中能力恢复可用）
##   - 其它物理体（石头虫等）直接给一个向上速度
func _bounce(body: Node, fall_speed: float) -> void:
	var force: float = clampf(base_bounce_force + fall_speed * fall_speed_factor, base_bounce_force, max_bounce_force)
	if body.has_method("start_trampoline_bounce"):
		body.start_trampoline_bounce(force)
	else:
		body.velocity.y = -force
	_play_trigger()


## 播放一次 Trigger 动画（有帧才播；同时用计时兜底，避免循环动画卡住）
## 注意：会记录播放前的动画进度，结束后由 _end_trigger() 原样恢复
func _play_trigger() -> void:
	var trigger_name: String = BOUNCE_ANIM_NAMES[BounceAnim.TRIGGER]
	if _triggering:
		# 已在 Trigger 中：只重置计时并重播，不覆盖“恢复点”
		_trigger_timer = maxf(trigger_time, 0.01)
		if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation(trigger_name) \
		and sprite.sprite_frames.get_frame_count(trigger_name) > 0:
			sprite.play(trigger_name)
		return
	# 记录 Trigger 之前的动画进度，避免结束后 Idle/Move 从第 0 帧重播
	# 注意：若当前已经在播 Trigger（上一段 Trigger 刚结束、还没切回 Idle/Move），
	# 不能把“恢复点”记成 Trigger，否则结束后会反复重播 Trigger 而卡在弹跳动画。
	if sprite and sprite.animation != trigger_name:
		_resume_anim = sprite.animation
		_resume_frame = sprite.frame
		_resume_frame_progress = sprite.frame_progress
	_triggering = true
	_trigger_timer = maxf(trigger_time, 0.01)
	if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation(trigger_name) \
	and sprite.sprite_frames.get_frame_count(trigger_name) > 0:
		sprite.play(trigger_name)


## 结束 Trigger 占用：把动画恢复到弹跳前的进度（不从头重播）
func _end_trigger() -> void:
	_triggering = false
	if sprite == null or _resume_anim == "":
		return
	if sprite.sprite_frames == null or not sprite.sprite_frames.has_animation(_resume_anim):
		return
	sprite.play(_resume_anim)
	sprite.frame = _resume_frame
	sprite.frame_progress = _resume_frame_progress


func _on_sprite_anim_finished() -> void:
	if sprite and sprite.animation == BOUNCE_ANIM_NAMES[BounceAnim.TRIGGER]:
		_end_trigger()
