# Scripts/Instances/Props/Switch.gd
## 机关开关 —— 支持“交互激活”与“被碰撞体按压激活”两种方式：
##   INTERACT：玩家进入范围显示 InteractionPrompt，按 interactive 键切换；
##             可选“只能交互一次”（interact_once_only）；可反复切换时带冷却，防连按。
##   PRESS   ：任意物理体（含 Player）压住按压区即 ON；可选“离开后恢复 OFF”。
## 通过 state_changed(is_on) 信号通知 Gate。
## 约定：加入 ignore_group 组的物理体不会被按压检测（例：TrampolineBug 不应触发机关）。
## 碰撞层建议：本节点 collision_layer=0，collision_mask 默认 233（Player/JumpBox/Good/NPC/Enemy），
##             故意不含 Ground/Wall/HurtBox，避免地板把开关一直压住。
extends Area2D
class_name Switch

## 激活方式
enum ActivationMode { INTERACT = 0, PRESS = 1 }

## 状态变化信号（true=ON）
signal state_changed(is_on: bool)

## ── 开关设置 ──
@export_category("开关设置")
## 激活方式：0=交互激活，1=被碰撞体按压激活
@export var activation_mode: ActivationMode = ActivationMode.INTERACT
## 初始是否已激活
@export var start_on: bool = false

## ── 存档持久化 ──
@export_category("存档持久化")
## 是否把激活状态写入存档（仅“交互激活”模式生效；PRESS 模式忽略）
@export var persistent: bool = true
## 存档用唯一 ID（留空则自动用“房间_坐标”生成）
@export var switch_id: String = ""

## ── 交互激活 ──
@export_category("交互激活")
## 是否只能交互一次（true=激活后永久 ON，无法再关闭）
@export var interact_once_only: bool = false
## 反复开关的冷却时间（秒）
@export var interact_cooldown: float = 0.6

## ── 按压激活 ──
@export_category("按压激活")
## 物理体全部离开后是否恢复 OFF
@export var off_when_released: bool = true
## 不参与按压检测的组（例：TrampolineBug 加入此组）
@export var ignore_group: StringName = &"ignore_switch_press"

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
## 交互提示节点（可空）
@onready var _prompt: Node = get_node_or_null("InteractionPrompt")

## 当前是否 ON
var _on: bool = false
## 玩家是否在交互范围内
var _player_in_range: bool = false
## 交互冷却剩余（秒）
var _cooldown: float = 0.0
## 正在按压的物理体（instance_id -> body）
var _press_bodies: Dictionary = {}
## 已解析的存档 ID
var _resolved_id: String = ""


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_resolve_save_id()
	_apply_saved_state()
	_sync_visual()
	_update_prompt()
	# 兼容“初始化时就已重叠”的物理体（body_entered 不会补发）
	call_deferred("_check_overlaps")
	# 存档加载后刷新（若加载发生在场景已构建之后）
	var global := get_node_or_null("/root/Global")
	if global and global.has_signal("switch_states_changed"):
		global.switch_states_changed.connect(_on_switch_states_changed)


func _physics_process(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown = maxf(_cooldown - delta, 0.0)


func _input(event: InputEvent) -> void:
	if activation_mode != ActivationMode.INTERACT:
		return
	if not event.is_action_pressed("interactive"):
		return
	if not _player_in_range or _cooldown > 0.0:
		return
	if interact_once_only and _on:
		return
	# 冲刺状态不交互（与存档点一致）
	var player := get_tree().get_first_node_in_group("player")
	if player and player.has_method("get_player_state") and player.get_player_state() == player.PlayerState.DASH:
		return
	_set_state(not _on, false)
	_cooldown = maxf(interact_cooldown, 0.0)


## 当前是否已激活（供 Gate 查询）
func is_on() -> bool:
	return _on


## 外部强制设置状态
func set_on(value: bool) -> void:
	_set_state(value, true)


## 检查初始化时已重叠的物理体
func _check_overlaps() -> void:
	if not is_inside_tree():
		return
	for body in get_overlapping_bodies():
		_on_body_entered(body)


func _set_state(value: bool, force: bool) -> void:
	if _on == value and not force:
		return
	_on = value
	_sync_visual()
	_update_prompt()
	state_changed.emit(_on)
	_write_saved_state()


func _sync_visual() -> void:
	_play_anim(ANIM_NAMES[Anim.ON] if _on else ANIM_NAMES[Anim.OFF])


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


func _update_prompt() -> void:
	if _prompt == null:
		return
	var show_prompt: bool = false
	if activation_mode == ActivationMode.INTERACT and _player_in_range:
		show_prompt = not (interact_once_only and _on)
	if _prompt is CanvasItem:
		(_prompt as CanvasItem).visible = show_prompt


func _on_body_entered(body: Node) -> void:
	if activation_mode == ActivationMode.INTERACT:
		if _is_player(body):
			_player_in_range = true
			_update_prompt()
		return
	# PRESS：任意可按压物理体
	if not _can_press(body):
		return
	_press_bodies[body.get_instance_id()] = body
	if not _on:
		_set_state(true, false)


func _on_body_exited(body: Node) -> void:
	if activation_mode == ActivationMode.INTERACT:
		if _is_player(body):
			_player_in_range = false
			_update_prompt()
		return
	if _press_bodies.has(body.get_instance_id()):
		_press_bodies.erase(body.get_instance_id())
		if off_when_released and _press_bodies.is_empty() and _on:
			_set_state(false, false)


func _is_player(body: Node) -> bool:
	return body != null and body.is_in_group("player")


## 该物理体是否可触发按压（忽略 ignore_group 组）
func _can_press(body: Node) -> bool:
	if body == null:
		return false
	if ignore_group != &"" and body.is_in_group(ignore_group):
		return false
	return body is PhysicsBody2D


## ── 存档持久化 ──
## 解析存档 ID（留空则用“房间_坐标”自动生成）
func _resolve_save_id() -> void:
	_resolved_id = switch_id
	if _resolved_id != "":
		return
	var room: String = _get_room_id()
	_resolved_id = "%s_%d_%d" % [room, roundi(global_position.x), roundi(global_position.y)]


## 取房间标识（优先 RoomManager.current_room，其次当前场景名，最后 noroom）
func _get_room_id() -> String:
	var rm := get_node_or_null("/root/RoomManager")
	if rm:
		var cr: Variant = rm.get("current_room")
		if cr != null and str(cr) != "":
			return str(cr)
	var tree := get_tree()
	if tree and tree.current_scene:
		return str(tree.current_scene.name)
	return "noroom"


## 是否应写入存档（仅交互式开关）
func _can_persist() -> bool:
	return persistent and activation_mode == ActivationMode.INTERACT and _resolved_id != ""


## 从 Global 存档读取并应用状态
func _apply_saved_state() -> void:
	if not _can_persist():
		return
	var global := get_node_or_null("/root/Global")
	if global == null or not global.has_method("has_switch_state"):
		return
	if global.has_switch_state(_resolved_id):
		_on = bool(global.get_switch_state(_resolved_id))


## 写入 Global 存档状态
func _write_saved_state() -> void:
	if not _can_persist():
		return
	var global := get_node_or_null("/root/Global")
	if global and global.has_method("set_switch_state"):
		global.set_switch_state(_resolved_id, _on)


## 存档加载后刷新（Global 发出 switch_states_changed）
func _on_switch_states_changed() -> void:
	if not _can_persist():
		return
	var global := get_node_or_null("/root/Global")
	if global == null or not global.has_method("has_switch_state"):
		return
	if global.has_switch_state(_resolved_id):
		_set_state(bool(global.get_switch_state(_resolved_id)), false)
