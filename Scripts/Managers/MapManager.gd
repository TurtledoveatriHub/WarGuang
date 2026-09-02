extends Node

## 地图系统管理器（Autoload）
##
## 职责：
##   - 管理地图打开/关闭状态
##   - 管理 MapUI 场景的生命周期
##   - 管理房间探索记录
##   - 管理传送阵激活记录

signal map_visibility_changed(is_visible: bool)
signal room_discovered(room_id: String)

var is_map_open: bool = false

## 已探索的房间列表
var discovered_rooms: Array = []

## MapUI 实例引用
var _map_ui_instance: Node = null


func _ready() -> void:
	## 预加载 MapUI 场景
	var map_ui_scene := preload("res://Scenes/UI/MapUI.tscn")
	_map_ui_instance = map_ui_scene.instantiate()
	## 先不添加到场景树，等第一次打开时再添加。
	## 关键修正：地图在未暂停的游戏内打开，必须用 ALWAYS（WHEN_PAUSED 会使其 tween 永不推进）。
	_map_ui_instance.process_mode = Node.PROCESS_MODE_ALWAYS


## 切换地图开/关
func toggle_map() -> void:
	if is_map_open:
		close_map()
	else:
		open_map()


## 打开地图
func open_map() -> void:
	if is_map_open:
		return
	is_map_open = true
	
	if _map_ui_instance and not _map_ui_instance.is_inside_tree():
		get_tree().root.add_child(_map_ui_instance)
	
	if _map_ui_instance and _map_ui_instance.has_method("open"):
		_map_ui_instance.open()
	
	map_visibility_changed.emit(true)


## 关闭地图
func close_map() -> void:
	if not is_map_open:
		return
	is_map_open = false
	
	if _map_ui_instance and _map_ui_instance.has_method("close"):
		_map_ui_instance.close()
	
	map_visibility_changed.emit(false)


## 标记一个房间为已探索
func discover_room(room_id: String) -> void:
	if room_id in discovered_rooms:
		return
	discovered_rooms.append(room_id)
	room_discovered.emit(room_id)
	## 通知 MapUI 刷新
	if _map_ui_instance and _map_ui_instance.has_method("on_room_discovered"):
		_map_ui_instance.on_room_discovered(room_id)


## 检查房间是否已探索
func is_room_discovered(room_id: String) -> bool:
	return room_id in discovered_rooms


## 从存档加载恢复探索数据
func load_save_data(data: Dictionary) -> void:
	if data.has("discovered_rooms"):
		discovered_rooms = data["discovered_rooms"] as Array


## 重置状态（新游戏时调用）
func reset_state() -> void:
	discovered_rooms.clear()
	is_map_open = false
	if _map_ui_instance and _map_ui_instance.is_inside_tree():
		_map_ui_instance.queue_free()
		var map_ui_scene := preload("res://Scenes/UI/MapUI.tscn")
		_map_ui_instance = map_ui_scene.instantiate()
		_map_ui_instance.process_mode = Node.PROCESS_MODE_ALWAYS
