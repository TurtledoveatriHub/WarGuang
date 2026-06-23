# Scripts/Resources/RoomLayoutData.gd
## 房间布局数据资源
## 存储每个房间在世界空间中的位置（偏移量），由 RoomLayoutReference 工具编辑，
## 由 RoomManager 读取用于房间实例化时的偏移设置。
## 注意：@tool 必不可少，否则在 RoomLayoutViewer（也是 @tool）中
## 加载此资源时会变成 placeholder 实例，无法调用方法。
@tool
class_name RoomLayoutData
extends Resource

## 房间位置字典：room_id → Vector2（世界坐标偏移）
@export var room_positions: Dictionary = {}

## 获取房间位置偏移
func get_room_offset(room_id: String) -> Vector2:
	return room_positions.get(room_id, Vector2.ZERO)

## 设置房间位置偏移
func set_room_offset(room_id: String, offset: Vector2) -> void:
	room_positions[room_id] = offset

## 是否包含指定房间
func has_room(room_id: String) -> bool:
	return room_positions.has(room_id)
