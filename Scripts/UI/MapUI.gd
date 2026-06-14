extends CanvasLayer

## 地图 UI
## 层级：98（DarkOverlay=95 之上，GameSetting=100 之下）
## 不暂停游戏

@onready var background: ColorRect = $Background
@onready var content_root: Control = $ContentRoot
@onready var map_container: Node2D = $ContentRoot/MapContainer
@onready var map_texture: Sprite2D = $ContentRoot/MapContainer/MapTexture
@onready var player_icon: Sprite2D = $ContentRoot/MapContainer/PlayerIcon
@onready var close_btn: TextureButton = $ContentRoot/CloseBtn

## 场景暗化倍率（与 GameSettingScene 一致：值越小越暗，0.3=70%暗）
@export var darken_multiplier: float = 0.3

var is_open: bool = false
var _original_modulate_color: Color
var _game_canvas_modulate: CanvasModulate


func _ready() -> void:
	layer = 98
	visible = false
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	background.color = Color(0, 0, 0, 0)
	content_root.scale = Vector2.ZERO
	close_btn.pressed.connect(_on_close_pressed)


## ── 打开 ──
func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	content_root.scale = Vector2.ZERO
	
	_adjust_lighting()
	_update_player_position()
	
	## 开启动画：背景渐暗 + 内容弹性放大（模仿 GameSettingScene）
	var tween := create_tween().set_parallel(true)
	tween.tween_property(background, "color", Color(0, 0, 0, 0.85), 0.12)
	tween.tween_property(content_root, "scale", Vector2(1.1, 1.1), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.chain().tween_property(content_root, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## ── 关闭 ──
func close() -> void:
	if not is_open:
		return
	is_open = false
	
	## 立即恢复光照（不依赖 await，确保一定执行）
	_restore_lighting()
	
	## 播放关闭动画（缩小 → 隐藏）
	var tween := create_tween().set_parallel(true)
	tween.tween_property(content_root, "scale", Vector2(1.1, 1.1), 0.08).set_trans(Tween.TRANS_SINE)
	tween.tween_property(background, "color", Color(0, 0, 0, 0), 0.18)
	tween.chain().tween_property(content_root, "scale", Vector2.ZERO, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tween.finished.connect(func():
		visible = false
		content_root.scale = Vector2.ZERO
		background.color = Color(0, 0, 0, 0)
	)


func _on_close_pressed() -> void:
	MapManager.close_map()


## 暗化场景（与 GameSettingScene 一致）
func _adjust_lighting() -> void:
	if RoomManager and RoomManager.global_canvas_modulate:
		_game_canvas_modulate = RoomManager.global_canvas_modulate
		_original_modulate_color = _game_canvas_modulate.color
		_game_canvas_modulate.color = Color(
			_original_modulate_color.r * darken_multiplier,
			_original_modulate_color.g * darken_multiplier,
			_original_modulate_color.b * darken_multiplier,
			1.0
		)


## 立即恢复光照（同步执行，不 await）
func _restore_lighting() -> void:
	if _game_canvas_modulate and is_instance_valid(_game_canvas_modulate):
		_game_canvas_modulate.color = _original_modulate_color


## 更新玩家地图图标位置（概览模式隐藏，具体模式显示）
func _update_player_position() -> void:
	if not player_icon:
		return
	var player := get_tree().get_first_node_in_group("player")
	if player:
		player_icon.position = _world_to_map_position(player.global_position)
		player_icon.visible = true
	else:
		player_icon.visible = false


## 世界坐标 → 地图坐标（后续由 MapData 映射）
func _world_to_map_position(world_pos: Vector2) -> Vector2:
	return world_pos * 0.05  ## 占位系数，后续替换为 MapData 映射


func on_room_discovered(_room_id: String) -> void:
	pass
