extends Node

## 地图系统管理器（Autoload）
##
## 职责：
##   - 管理地图打开/关闭状态与 MapUI 场景生命周期
##   - 管理房间探索状态：进入房间先记为"待绘制"，与静态检查点交互后才正式绘制到地图上
##   - 提供地图整图贴图与权威房间布局数据的统一读取入口
##
## 探索状态机：
##   进入房间（RoomManager.load_room） → mark_room_pending()
##   与 ChairSavePoint 交互             → commit_pending_rooms()
## 只有已绘制（painted_rooms）的房间会出现在地图上，未绘制房间及其联通通道都不可见。

## 地图开关状态变化
signal map_visibility_changed(is_visible: bool)
## 房间绘制状态变化，参数为本次新绘制的房间列表（可能为空数组）
signal map_rooms_changed(newly_painted: Array)

## 权威布局数据资源路径（与 RoomManager 共用同一份）
const LAYOUT_DATA_PATH := "res://Assets/Configs/RoomLayoutData.tres"
## 地图整图贴图目录
const MAP_TEXTURE_DIR := "res://Assets/Textures/Maps"
## 详情版整图贴图文件名（放大时显示，能看清房间内部结构）
const MAP_DETAIL_TEXTURE_FILE := "map_detail.png"
## 概览版整图贴图文件名（缩小时显示，只保留房间块轮廓）
const MAP_BLOCK_TEXTURE_FILE := "map_block.png"

## 地图是否处于打开状态
var is_map_open: bool = false

## 已绘制房间列表（在地图上可见）
var painted_rooms: Array = []

## 已走过但尚未绘制的房间列表
var pending_rooms: Array = []

## MapUI 实例引用
var _map_ui_instance: Node = null

## 权威布局数据资源引用
var _layout_data: RoomLayoutData = null

## 详情版整图贴图缓存（美术资源缺失时为 null）
var _detail_texture: Texture2D = null

## 概览版整图贴图缓存（美术资源缺失时为 null）
var _block_texture: Texture2D = null

func _ready() -> void:
	## 预加载 MapUI 场景
	var map_ui_scene: PackedScene = preload("res://Scenes/UI/MapUI.tscn")
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
	if _map_ui_instance == null:
		return
	is_map_open = true
	if not _map_ui_instance.is_inside_tree():
		get_tree().root.add_child(_map_ui_instance)
	if _map_ui_instance.has_method("open"):
		_map_ui_instance.open()
	map_visibility_changed.emit(true)

## 关闭地图
func close_map() -> void:
	if not is_map_open:
		return
	is_map_open = false
	if _map_ui_instance != null and _map_ui_instance.has_method("close"):
		_map_ui_instance.close()
	map_visibility_changed.emit(false)

## 登记房间为"已走过、待绘制"状态（进入房间时调用）
func mark_room_pending(room_id: String) -> void:
	if room_id == "":
		return
	if painted_rooms.has(room_id) or pending_rooms.has(room_id):
		return
	pending_rooms.append(room_id)
	_notify_map_ui([])

## 提交全部待绘制房间（与静态检查点交互时调用），返回本次新绘制的房间列表
func commit_pending_rooms() -> Array:
	if pending_rooms.is_empty():
		return []
	var newly_painted: Array = pending_rooms.duplicate()
	painted_rooms.append_array(newly_painted)
	pending_rooms.clear()
	_notify_map_ui(newly_painted)
	return newly_painted

## 房间是否已绘制到地图上
func is_room_painted(room_id: String) -> bool:
	return painted_rooms.has(room_id)

## 房间是否已走过但尚未绘制
func is_room_pending(room_id: String) -> bool:
	return pending_rooms.has(room_id)

## 获取已绘制房间列表
func get_painted_rooms() -> Array:
	return painted_rooms

## 获取待绘制房间列表
func get_pending_rooms() -> Array:
	return pending_rooms

## 获取权威房间布局数据
func get_layout_data() -> RoomLayoutData:
	if _layout_data == null and ResourceLoader.exists(LAYOUT_DATA_PATH):
		var loaded: Resource = load(LAYOUT_DATA_PATH)
		if loaded is RoomLayoutData:
			_layout_data = loaded
	return _layout_data

## 获取详情版地图整图贴图（美术资源缺失时返回 null）
func get_detail_texture() -> Texture2D:
	if _detail_texture == null:
		_detail_texture = _load_map_texture(MAP_DETAIL_TEXTURE_FILE)
	return _detail_texture

## 获取概览版地图整图贴图（美术资源缺失时返回 null）
func get_block_texture() -> Texture2D:
	if _block_texture == null:
		_block_texture = _load_map_texture(MAP_BLOCK_TEXTURE_FILE)
	return _block_texture

## 返回缺失的地图整图贴图文件名（可直接作为美术工作清单）
func get_missing_map_textures() -> Array[String]:
	var missing: Array[String] = []
	for file_name in [MAP_DETAIL_TEXTURE_FILE, MAP_BLOCK_TEXTURE_FILE]:
		if not ResourceLoader.exists(MAP_TEXTURE_DIR.path_join(file_name)):
			missing.append(file_name)
	return missing

## 从地图贴图目录加载指定贴图文件
func _load_map_texture(file_name: String) -> Texture2D:
	var path: String = MAP_TEXTURE_DIR.path_join(file_name)
	if not ResourceLoader.exists(path):
		return null
	var loaded: Resource = load(path)
	if loaded is Texture2D:
		return loaded
	return null

## 从存档恢复探索数据
func load_save_data(data: Dictionary) -> void:
	painted_rooms = _to_string_array(data.get("painted_rooms", []))
	pending_rooms = _to_string_array(data.get("pending_rooms", []))
	_notify_map_ui([])

## 重置探索状态（新游戏时调用）
func reset_state() -> void:
	painted_rooms.clear()
	pending_rooms.clear()
	close_map()
	_notify_map_ui([])

## 把存档中的通用数组安全转换为字符串数组
func _to_string_array(source: Variant) -> Array:
	var result: Array = []
	if source is Array:
		for item in source:
			result.append(str(item))
	return result

## 通知 MapUI 刷新房间绘制并广播信号
func _notify_map_ui(newly_painted: Array) -> void:
	if _map_ui_instance != null and _map_ui_instance.is_inside_tree() and _map_ui_instance.has_method("on_map_rooms_changed"):
		_map_ui_instance.on_map_rooms_changed(newly_painted)
	map_rooms_changed.emit(newly_painted)
