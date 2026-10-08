extends Node2D

## 交互提示统一纹理（房间里所有 InteractionPrompt 都会被换成它）
const INTERACTION_PROMPT_TEXTURE: Texture2D = preload("res://Assets/Textures/UIs/InstanceUIs/交互提示.png")
## 交互提示上下悬浮的幅度（像素）与单程时长（秒）
const PROMPT_FLOAT_HEIGHT: float = 3.0
const PROMPT_FLOAT_DURATION: float = 0.8
## 交互提示整体放大倍数（1 = 保持场景里的原始尺寸；按场景里已有的 scale 再乘一次）
const PROMPT_SCALE_MULTIPLIER: float = 1.0

## 房间设置
@export_category("房间设置")
@export var room_id: String = "GrassLand1"

## 房间 BGM 流（在 Inspector 中拖拽 .ogg 文件）
@export var room_bgm_stream: AudioStream

## 相邻房间 ID 列表
@export var adjacent_rooms: Array[String] = []

## 房间颜色（用于全局 CanvasModulate）
@export var room_color: Color = Color.WHITE

## 相机设置
@export_category("相机设置")
@export var limit_camera_in_room: bool = true
@export var camera_margin: Vector2 = Vector2(20, 20)

## 房间边界引用（在场景中手动指定）
@export var room_bounds: TextArea

# 节点引用
@onready var room_trigger = $RoomTrigger

func _ready():
	setup_room_trigger()
	set_room_active(false)
	
	call_deferred("_correct_container_children_world_positions")
	call_deferred("_setup_interaction_prompts")


## 统一本房间里所有交互提示（InteractionPrompt）：换统一纹理 + 加「上下悬浮」动效。
## ★ 悬浮用代码 Tween，不是帧动画：不占额外贴图/内存，也不需要准备帧素材。
## ★ 旧提示用的是图集（旧版UI2.png + region_rect），换成整图纹理后必须关掉 region，
##   否则新纹理会按旧图集的碎片区域被裁掉。
## 想让某个提示保留自己的纹理：给它加 meta "keep_prompt_texture" = true。
func _setup_interaction_prompts() -> void:
	for node: Node in find_children("InteractionPrompt", "Sprite2D", true, false):
		var prompt: Sprite2D = node
		# ★ 用 meta 标记「已经处理过」：房间被重复加载/重复扫描时不会把纹理和缩放反复乘一遍
		if not prompt.has_meta("prompt_float_started"):
			if not bool(prompt.get_meta("keep_prompt_texture", false)):
				prompt.texture = INTERACTION_PROMPT_TEXTURE
				prompt.region_enabled = false
			prompt.scale *= PROMPT_SCALE_MULTIPLIER
		_add_prompt_float(prompt)


## 给单个提示加循环上下悬浮（幅度与周期在上面的常量里统一调）
## ★ 提示大部分时间都是隐藏的，所以 Tween 默认先暂停，只在可见时才跑（跟随 visibility_changed）。
func _add_prompt_float(prompt: Sprite2D) -> void:
	if prompt.has_meta("prompt_float_started"):
		return
	prompt.set_meta("prompt_float_started", true)
	var base_y: float = prompt.position.y
	var tween: Tween = create_tween().set_loops()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(prompt, "position:y", base_y - PROMPT_FLOAT_HEIGHT, PROMPT_FLOAT_DURATION)
	tween.tween_property(prompt, "position:y", base_y, PROMPT_FLOAT_DURATION)
	tween.pause()
	if not prompt.visibility_changed.is_connected(_on_prompt_visibility_changed):
		prompt.visibility_changed.connect(_on_prompt_visibility_changed.bind(prompt, tween))
	_sync_prompt_tween(prompt, tween)


## 提示显隐变化 → 同步悬浮 Tween 的跑/停
func _on_prompt_visibility_changed(prompt: Sprite2D, tween: Tween) -> void:
	_sync_prompt_tween(prompt, tween)


## 让 Tween 跟随可见性：可见才跑，隐藏就暂停（不占逐帧插值开销）
func _sync_prompt_tween(prompt: Sprite2D, tween: Tween) -> void:
	if prompt == null or not is_instance_valid(prompt):
		return
	if tween == null or not tween.is_valid():
		return
	if prompt.is_visible_in_tree():
		tween.play()
	else:
		tween.pause()

func _correct_container_children_world_positions():
	var container_names = ["NPCs", "Doors", "Instances", "HurtBoxs", "Props", "DynamicCheckpoints", "ChairSavePoints"]
	
	for container_name in container_names:
		var container = get_node_or_null(container_name)
		if container and container.position != Vector2.ZERO:
			# 先保存所有子节点的世界坐标，再置零容器，最后统一恢复
			# 避免边读边改 bug：处理第一个子节点时置零容器，后续子节点丢失偏移量
			var saved: Array[Vector2] = []
			for child in container.get_children():
				if child is Node2D:
					saved.append(child.global_position)
			container.position = Vector2.ZERO
			var idx := 0
			for child in container.get_children():
				if child is Node2D:
					child.global_position = saved[idx]
					idx += 1

func setup_room_trigger():
	if room_trigger and room_trigger is Area2D and room_bounds:
		var collision_shape = room_trigger.get_node("CollisionShape2D")
		if collision_shape and collision_shape.shape is RectangleShape2D:
			collision_shape.shape.size = room_bounds.get_actual_size()
			
			# 使用 global_position 确保坐标系统一
			# 无论 RoomTrigger 和 RoomBounds 在哪个层级，都能正确对齐
			room_trigger.global_position = room_bounds.global_position
	if room_trigger and not room_trigger.body_entered.is_connected(_on_player_entered):
		room_trigger.body_entered.connect(_on_player_entered)

func set_room_active(active: bool):
	if active:
		process_mode = PROCESS_MODE_INHERIT
	else:
		process_mode = PROCESS_MODE_DISABLED
	
	visible = active

func _on_player_entered(body):
	if body.is_in_group("player"):
		RoomManager.player_entered_room(room_id)

func get_camera_limits() -> Rect2:
	if limit_camera_in_room and room_bounds:
		var bounds = room_bounds.get_global_rect()
		
		var limits = Rect2(
			bounds.position + camera_margin,
			bounds.size - camera_margin * 2
		)
		
		return limits
	else:
		return Rect2()

func get_room_data() -> Dictionary:
	return {
		"id": room_id,
		"bounds_size": room_bounds.get_actual_size() if room_bounds else Vector2.ZERO,
		"bounds_position": room_bounds.global_position if room_bounds else Vector2.ZERO,
		"bgm_stream": room_bgm_stream,
		"adjacent": adjacent_rooms,
		"color": room_color
	}

func get_room_color() -> Color:
	return room_color
