extends CanvasLayer

@onready var background: ColorRect = $Background
@onready var content_root: Node2D = $ContentRoot
@onready var map_container: Node2D = $ContentRoot/MapContainer
@onready var map_texture: Sprite2D = $ContentRoot/MapContainer/MapTexture
@onready var player_icon: Sprite2D = $ContentRoot/MapContainer/PlayerIcon
@onready var close_btn: TextureButton = $ContentRoot/CloseBtn

## 暗化倍率（与 GameSettingScene 一致：0.3=70%暗）
@export var darken_multiplier: float = 0.3
## PlayerIcon 更新间隔（秒）
@export var player_icon_update_interval: float = 0.2

var is_open: bool = false
var _original_modulate: Color
var _canvas_modulate: CanvasModulate
var _icon_timer: float = 0.0


func _ready() -> void:
	layer = 98
	visible = false
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	background.color = Color(0, 0, 0, 0)
	content_root.visible = false
	
	## 连接关闭按钮信号
	close_btn.pressed.connect(_on_close_pressed)


func _input(event: InputEvent) -> void:
	## 保底：TextureButton 是 Control 类型，作为 Node2D(ContentRoot) 子节点时
	## 鼠标事件路由可能不可靠，在 CanvasLayer 层额外检测关闭按钮点击区域
	if not is_open or not visible:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if close_btn.get_global_rect().has_point(get_viewport().get_mouse_position()):
			_on_close_pressed()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not is_open:
		return
	_icon_timer += delta
	if _icon_timer >= player_icon_update_interval:
		_icon_timer = 0.0
		_update_player_position()


func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	content_root.visible = true
	background.color = Color(0, 0, 0, 0.85)
	_icon_timer = 999.0
	_adjust_lighting()
	_update_player_position()


func close() -> void:
	if not is_open:
		return
	is_open = false
	_restore_lighting()
	content_root.visible = false
	visible = false


func _on_close_pressed() -> void:
	MapManager.close_map()


## 暗化场景（与 GameSettingScene 一致）
func _adjust_lighting() -> void:
	if RoomManager and RoomManager.global_canvas_modulate:
		_canvas_modulate = RoomManager.global_canvas_modulate
		_original_modulate = _canvas_modulate.color
		_canvas_modulate.color = Color(
			_original_modulate.r * darken_multiplier,
			_original_modulate.g * darken_multiplier,
			_original_modulate.b * darken_multiplier,
			1.0
		)


func _restore_lighting() -> void:
	if _canvas_modulate and is_instance_valid(_canvas_modulate):
		_canvas_modulate.color = _original_modulate


## PlayerIcon 定位（每隔 player_icon_update_interval 秒更新一次）
func _update_player_position() -> void:
	if not player_icon:
		return
	var player := get_tree().get_first_node_in_group("player")
	if player:
		player_icon.position = _world_to_map_position(player.global_position)
		player_icon.visible = true
	else:
		player_icon.visible = false


func _world_to_map_position(world_pos: Vector2) -> Vector2:
	## 占位：后续替换为 MapData 的房间→地图坐标映射
	return world_pos * 0.05


func on_room_discovered(_room_id: String) -> void:
	pass
