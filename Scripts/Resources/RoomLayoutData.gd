# Scripts/Resources/RoomLayoutData.gd
## 房间布局数据资源
## 集中存储所有房间在世界空间中的权威布局信息，由 Scenes/Tools/WorldLayout.tscn 摆放场景生成与维护。
## RoomManager 读取 room_positions 用于房间实例化定位；
## 地图系统读取同一份数据换算地图坐标，保证“地图”与“实机布局”永远同源。
## 注意：@tool 必不可少，否则在 WorldLayout（也是 @tool）中加载此资源时会变成 placeholder
## 实例，无法调用其方法。
@tool
class_name RoomLayoutData
extends Resource

## 房间位置字典：room_id → Vector2（房间根节点在世界空间中的原点）
@export var room_positions: Dictionary = {}

## 房间边界字典：room_id → Rect2（相对房间根节点的本地矩形，含自身位置与尺寸）
## 由 RoomScanner 扫描房间场景自动生成，不需要手工维护。
@export var room_bounds_rects: Dictionary = {}

## 地图裁图区域字典：room_id → Rect2（相对房间根节点的本地矩形）
## 留空表示与 room_bounds_rects 相同。
## 仅当美术把跨房间的联通通道画在房间矩形之外时，才需要单独扩大该房间参与地图显示的区域。
@export var map_region_rects: Dictionary = {}

## 世界像素 → 地图贴图像素 的比例（美术作画基准）
## 例如 0.1 表示一个 3200×1920 的房间对应 320×192 的地图贴图。
@export_range(0.001, 1.0, 0.001) var map_texture_scale: float = 0.1

## 获取房间根节点在世界空间中的原点
func get_room_offset(room_id: String) -> Vector2:
	return room_positions.get(room_id, Vector2.ZERO)

## 设置房间根节点在世界空间中的原点
func set_room_position(room_id: String, offset: Vector2) -> void:
	room_positions[room_id] = offset

## 获取房间边界的本地矩形（相对房间根节点）；未扫描到时返回空矩形
func get_room_bounds_local(room_id: String) -> Rect2:
	return room_bounds_rects.get(room_id, Rect2())

## 获取房间边界在世界空间中的矩形（房间根原点 + 本地矩形）
func get_room_world_rect(room_id: String) -> Rect2:
	var local: Rect2 = get_room_bounds_local(room_id)
	return Rect2(get_room_offset(room_id) + local.position, local.size)

## 获取房间参与地图显示的本地矩形（未单独指定时等同房间边界）
func get_room_map_region_local(room_id: String) -> Rect2:
	if map_region_rects.has(room_id):
		return map_region_rects[room_id]
	return get_room_bounds_local(room_id)

## 获取房间参与地图显示的世界矩形
func get_room_map_region_world(room_id: String) -> Rect2:
	var local: Rect2 = get_room_map_region_local(room_id)
	return Rect2(get_room_offset(room_id) + local.position, local.size)

## 是否已记录该房间的位置偏移
func has_room(room_id: String) -> bool:
	return room_positions.has(room_id)

## 是否已记录该房间的边界尺寸
func has_room_bounds(room_id: String) -> bool:
	return room_bounds_rects.has(room_id)
