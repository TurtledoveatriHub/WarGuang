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


## 从存档加载恢复激活数据和坐标信息
func load_save_data(data: Dictionary) -> void:
	if data.has("activated_teleports"):
		activated = data["activated_teleports"] as Array
	# 恢复坐标（JSON 序列化会将 Vector2 转成字符串，需手动还原）
	if data.has("tp_coords"):
		var coords: Dictionary = data["tp_coords"] as Dictionary
		for tid in coords:
			var raw: Dictionary = coords[tid] as Dictionary
			raw = raw.duplicate()
			if raw.has("position"):
				var p = raw["position"]
				if typeof(p) == TYPE_STRING:
					# JSON 序列化后 Vector2 变为 "(x, y)" 格式
					var parts = p.trim_prefix("(").trim_suffix(")").split(",")
					if parts.size() == 2:
						raw["position"] = Vector2(float(parts[0].strip_edges()), float(parts[1].strip_edges()))
				elif typeof(p) == TYPE_ARRAY and p.size() == 2:
					raw["position"] = Vector2(p[0], p[1])
			_teleports[tid] = raw

## 获取存档用传送阵坐标（Vector2 转为数组避免 JSON 序列化问题）
func get_save_coords() -> Dictionary:
	var out: Dictionary = {}
	for tid in activated:
		var d: Dictionary = _teleports.get(tid, {}).duplicate()
		if not d.is_empty():
			d.erase("node")
			if d.has("position") and typeof(d["position"]) == TYPE_VECTOR2:
				d["position"] = [d["position"].x, d["position"].y]
			out[tid] = d
	return out

## 重置（新游戏时调用）
func reset() -> void:
	_teleports.clear()
	activated.clear()
