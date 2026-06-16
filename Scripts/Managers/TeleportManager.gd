extends Node

## 传送阵管理器（Autoload）
## 管理所有传送阵的注册、激活、坐标信息

signal teleport_activated(teleport_id: String)

## 所有传送阵数据：teleport_id → {room_id, position, display_name, node}
var _teleports: Dictionary = {}

## 已激活的传送阵 ID 列表
var activated: Array = []


## 注册一个传送阵
func register(point: Node, teleport_id: String, room_id: String, position: Vector2) -> void:
	_teleports[teleport_id] = {
		"room_id": room_id,
		"position": position,
		"node": point
	}


## 从 ID 获取传送阵数据
func get_data(teleport_id: String) -> Dictionary:
	return _teleports.get(teleport_id, {})


## 获取所有已激活的传送阵数据列表
func get_activated_list() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for tid in activated:
		var data = _teleports.get(tid, {})
		if data.is_empty():
			continue
		data["id"] = tid
		result.append(data)
	return result


## 激活一个传送阵
func activate(teleport_id: String) -> void:
	if teleport_id in activated:
		return
	activated.append(teleport_id)
	teleport_activated.emit(teleport_id)


func is_activated(teleport_id: String) -> bool:
	return teleport_id in activated


## 从存档加载恢复激活数据
func load_save_data(data: Dictionary) -> void:
	if data.has("activated_teleports"):
		activated = data["activated_teleports"] as Array


## 重置（新游戏时调用）
func reset() -> void:
	_teleports.clear()
	activated.clear()
