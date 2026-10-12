# Scripts/Instances/Props/MechanismObject.gd
## 机关物体（基类，原 Gate）—— 接收多个开关，全部（或任一）激活时开启：
##  - OFF→ON：立即播放 ON 动画，并按 move_speed 移动到 初始位置+open_offset；
##            到达后若 disable_collision_when_open 则关闭碰撞体（Body/CollisionShape2D）。
##  - ON→OFF：立即播放 OFF 动画，恢复碰撞并移动回初始位置；
##            移动过程中若开关关闭，会立刻切回 OFF 并返回（符合“中途激活关闭”的需求）。
##  - 移动带加速/减速（acceleration_time / deceleration_time），所有机关共用。
## 开关通过 state_changed 信号驱动；对象只读取开关的 is_on()。
## 子类可重写 _on_motion_updated(is_moving) 改表现（例：机关平台“移动时 ON / 静止时 OFF”），
## 也可重写 _advance_physics(delta) 完全接管移动。
extends Node2D
class_name MechanismObject

## ── 开关连接 ──
@export_category("开关连接")
## 需要接收的开关节点（可拖拽多个 Switch）
@export var switches: Array[NodePath] = []
## true=全部开关都激活才开门；false=任一开关激活即开门
@export var all_active_required: bool = true

## ── 门设置 ──
@export_category("门设置")
## 开启时相对初始位置的偏移
@export var open_offset: Vector2 = Vector2(0, -64)
## 移动速度（像素/秒）
@export var move_speed: float = 60.0
## 加速时间（秒，0=瞬间到最大速度）
@export var acceleration_time: float = 0.3
## 减速时间（秒，0=瞬间停止）
@export var deceleration_time: float = 0.3
## 完全开启后是否关闭碰撞体
@export var disable_collision_when_open: bool = true

## 激活（开）前的延迟（秒）：开关激活后先等这么久再开始位移；
## 延迟期间开关反复切换会刷新这个延迟。默认 0 = 立即移动（原行为）。
## 只影响“开”的方向；“关”仍然立即回位。
@export var activation_delay: float = 0.0

## ── 表现 ──
## 动画名枚举（内部固定，不导出）
enum Anim {
	OFF = 0,   ## 关闭态
	ON = 1,    ## 开启态
}
## 动画名映射（与 Anim 一一对应）
const ANIM_NAMES: PackedStringArray = ["OFF", "ON"]

## 动画节点
@onready var _sprite: AnimatedSprite2D = get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
## 碰撞形状（位于 Body/CollisionShape2D）
@onready var _collision: CollisionShape2D = get_node_or_null("Body/CollisionShape2D") as CollisionShape2D

## 关闭位置（初始位置）
var _closed_pos: Vector2 = Vector2.ZERO
## 开启位置（初始位置 + open_offset）
var _open_pos: Vector2 = Vector2.ZERO
## 当前移动目标
var _target_pos: Vector2 = Vector2.ZERO
## 当前期望是否为开启态
var _want_open: bool = false
## 当前沿移动方向的速率（像素/秒）
var _speed: float = 0.0
## 本帧实际位移速度（像素/秒，供机关平台等子类对外暴露）
var _motion_velocity: Vector2 = Vector2.ZERO
## 激活延迟剩余时间（秒，>0 时不位移）
var _activation_delay_left: float = 0.0


func _ready() -> void:
	_closed_pos = position
	_open_pos = position + open_offset
	_target_pos = _closed_pos
	for p in switches:
		var sw := get_node_or_null(p)
		if sw and sw.has_signal("state_changed"):
			sw.state_changed.connect(_on_switch_changed)
	_set_collision_enabled(true)
	_play_anim(ANIM_NAMES[Anim.OFF])
	# 等开关初始化完再算一次（避免 _ready 顺序导致读到错误初始态）
	call_deferred("_recompute")


func _physics_process(delta: float) -> void:
	_advance_physics(delta)


## 每物理帧推进移动（带加速/减速；子类可重写接管）
func _advance_physics(delta: float) -> void:
	# 激活延迟：到点前保持静止（不位移），到点后才把目标设为开启位置
	if _activation_delay_left > 0.0:
		_activation_delay_left = maxf(_activation_delay_left - delta, 0.0)
		if _activation_delay_left > 0.0:
			_motion_velocity = Vector2.ZERO
			_speed = 0.0
			_on_motion_updated(false)
			return
		_target_pos = _open_pos
	var before_global: Vector2 = global_position
	if not position.is_equal_approx(_target_pos):
		var to_target: Vector2 = _target_pos - position
		var remaining: float = to_target.length()
		if remaining <= 0.001:
			position = _target_pos
			_speed = 0.0
		else:
			var dir: Vector2 = to_target / remaining
			var max_speed: float = maxf(move_speed, 0.0)
			var accel: float = max_speed / maxf(acceleration_time, 0.001)
			var decel: float = max_speed / maxf(deceleration_time, 0.001)
			# 进入制动距离则减速，否则加速
			var stop_distance: float = (_speed * _speed) / (2.0 * maxf(decel, 0.001))
			if remaining <= stop_distance:
				_speed = move_toward(_speed, 0.0, decel * delta)
			else:
				_speed = move_toward(_speed, max_speed, accel * delta)
			position += dir * minf(_speed * delta, remaining)
	else:
		_speed = 0.0
	_motion_velocity = (global_position - before_global) / maxf(delta, 0.0001)
	var is_moving: bool = _motion_velocity != Vector2.ZERO
	if not is_moving:
		_speed = 0.0
	_on_motion_updated(is_moving)
	if position.is_equal_approx(_target_pos):
		_on_reached_target()


## 移动状态变化钩子（子类可重写改表现；默认不动，动画由 _recompute 按激活态控制）
func _on_motion_updated(_is_moving: bool) -> void:
	pass


func _on_switch_changed(_is_on: bool) -> void:
	_recompute()


## 重新计算“应当开/关”，并处理动画与移动目标
func _recompute() -> void:
	var want: bool = _compute_want_open()
	if want == _want_open:
		return
	_want_open = want
	if _want_open:
		# 开门：立即切 ON；开启过程中保留碰撞，到达后再按需关闭
		_play_anim(ANIM_NAMES[Anim.ON])
		_set_collision_enabled(true)
		# 激活延迟：延迟内目标仍是当前位置（因此不会位移）；反复激活会刷新延迟
		if activation_delay > 0.0:
			_activation_delay_left = activation_delay
		else:
			_activation_delay_left = 0.0
			_target_pos = _open_pos
	else:
		# 关门：立即切 OFF；恢复碰撞并移回初始位置（关不延迟）
		_play_anim(ANIM_NAMES[Anim.OFF])
		_activation_delay_left = 0.0
		_target_pos = _closed_pos
		_set_collision_enabled(true)


func _on_reached_target() -> void:
	if _want_open and disable_collision_when_open:
		_set_collision_enabled(false)


## 依据开关状态计算是否应开启
func _compute_want_open() -> bool:
	var count: int = 0
	var active: int = 0
	for p in switches:
		var sw := get_node_or_null(p)
		if sw == null or not sw.has_method("is_on"):
			continue
		count += 1
		if sw.is_on():
			active += 1
	if count == 0:
		return false
	return active == count if all_active_required else active > 0


func _set_collision_enabled(enabled: bool) -> void:
	if _collision == null:
		return
	if _collision.disabled == (not enabled):
		return
	_collision.set_deferred("disabled", not enabled)


## 安全播放动画（无 SpriteFrames / 无该动画 / 无帧时跳过）
func _play_anim(anim_name: String) -> void:
	if _sprite == null or _sprite.sprite_frames == null:
		return
	if not _sprite.sprite_frames.has_animation(anim_name):
		return
	if _sprite.sprite_frames.get_frame_count(anim_name) <= 0:
		return
	if _sprite.animation != anim_name:
		_sprite.play(anim_name)
