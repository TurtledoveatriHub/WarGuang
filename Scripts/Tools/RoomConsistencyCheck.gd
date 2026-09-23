# Scripts/Tools/RoomConsistencyCheck.gd
## 房间一致性校验器（编辑器工具，只读）
## 逐项检查房间 ID 在「场景文件名 / room_id 导出值 / ScenePaths 注册表 / 布局数据 /
## 门与相邻关系引用 / 门配对」之间是否自洽，并输出可读报告。
## 不修改任何文件。
@tool
class_name RoomConsistencyCheck
extends RefCounted

## 房间扫描器脚本（本会话新建，用 preload 而非 class_name 引用，避免全局类名注册延迟）
const RoomScannerScript := preload("res://Scripts/Tools/RoomScanner.gd")

## 构建完整校验报告文本
static func build_report(layout_data: RoomLayoutData) -> String:
	var registry: Dictionary = RoomScannerScript.get_room_registry()
	if registry.is_empty():
		return "校验失败：无法取得 ROOM_PATHS 房间注册表"

	# 场景文件名与 room_id 不一致的房间
	var name_mismatch: Array = []
	# 房间场景中的 room_id 与注册表键不一致的房间
	var id_mismatch: Array = []
	# 读取失败的房间场景
	var read_failed: Array = []
	# 指向未登记房间的相邻关系
	var bad_adjacent: Array = []
	# 指向未登记房间的门目标
	var bad_door_target: Array = []
	# door_id 在全局只出现一次（缺少配对门）
	var unpaired_doors: Array = []
	# 所有房间声明的相邻关系：room_id → 相邻列表
	var adjacency: Dictionary = {}
	# 全局 door_id 出现次数：door_id → 次数
	var door_id_counts: Dictionary = {}

	for room_id in registry.keys():
		var scene_path: String = str(registry[room_id])
		var scene_text: String = _read_text(scene_path)
		if scene_text == "":
			read_failed.append(room_id)
			continue
		var file_stem: String = scene_path.get_file().get_basename()
		if file_stem != room_id:
			name_mismatch.append("%s(文件 %s.tscn)" % [room_id, file_stem])
		var declared_ids: Array[String] = _extract_all_string_values(scene_text, "room_id")
		if not declared_ids.is_empty() and declared_ids[0] != room_id:
			id_mismatch.append("%s(场景内写的是 %s)" % [room_id, declared_ids[0]])
		var adjacent: Array[String] = _extract_adjacent_rooms(scene_text)
		adjacency[room_id] = adjacent
		for neighbor in adjacent:
			if not registry.has(neighbor):
				bad_adjacent.append("%s → %s" % [room_id, neighbor])
		for target in _extract_all_string_values(scene_text, "target_room_id"):
			if target != "" and not registry.has(target):
				bad_door_target.append("%s → %s" % [room_id, target])
		for door_id in _extract_all_string_values(scene_text, "door_id"):
			if door_id == "":
				continue
			door_id_counts[door_id] = int(door_id_counts.get(door_id, 0)) + 1

	for door_id in door_id_counts.keys():
		if int(door_id_counts[door_id]) != 2:
			unpaired_doors.append("%s(%d 处)" % [door_id, int(door_id_counts[door_id])])

	# 相邻关系是否双向一致
	var asymmetric: Array = []
	for room_id in adjacency.keys():
		for neighbor in adjacency[room_id]:
			if not adjacency.has(neighbor):
				continue
			if not (adjacency[neighbor] as Array).has(room_id):
				asymmetric.append("%s → %s（未回指）" % [room_id, neighbor])

	# 布局数据侧
	var missing_position: Array = []
	var missing_bounds: Array = []
	var overlapping: Array = []
	var extra_entries: Array = []
	if layout_data != null:
		for room_id in registry.keys():
			if not layout_data.has_room(room_id):
				missing_position.append(room_id)
			if not layout_data.has_room_bounds(room_id):
				missing_bounds.append(room_id)
		for room_id in layout_data.room_positions.keys():
			if not registry.has(room_id):
				extra_entries.append(room_id)
		overlapping = _find_overlaps(layout_data, registry)
	else:
		missing_position.append("（布局数据未加载）")

	var lines: Array[String] = []
	lines.append("========== 房间一致性校验报告 ==========")
	lines.append("登记房间数：%d" % registry.size())
	lines.append(_format_section("场景文件名与房间 ID 不一致", name_mismatch))
	lines.append(_format_section("场景 room_id 与注册表键不一致", id_mismatch))
	lines.append(_format_section("房间场景读取失败", read_failed))
	lines.append(_format_section("相邻关系指向未登记房间", bad_adjacent))
	lines.append(_format_section("门目标指向未登记房间", bad_door_target))
	lines.append(_format_section("相邻关系未双向回指", asymmetric))
	lines.append(_format_section("门未成对（door_id 出现次数 ≠ 2）", unpaired_doors))
	lines.append(_format_section("缺少位置偏移", missing_position))
	lines.append(_format_section("缺少房间尺寸（未扫描）", missing_bounds))
	lines.append(_format_section("世界矩形互相重叠", overlapping))
	lines.append(_format_section("布局数据中存在未登记房间", extra_entries))
	lines.append("========================================")
	return "\n".join(lines)

## 读取文本文件；失败返回空字符串
static func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text

## 提取场景文本中所有 `键 = "值"` 形式的值
static func _extract_all_string_values(scene_text: String, key: String) -> Array[String]:
	var results: Array[String] = []
	var needle: String = key + " = \""
	var search_from: int = 0
	while true:
		var key_index: int = scene_text.find(needle, search_from)
		if key_index < 0:
			break
		var value_start: int = key_index + needle.length()
		var value_end: int = scene_text.find("\"", value_start)
		if value_end < 0:
			break
		results.append(scene_text.substr(value_start, value_end - value_start))
		search_from = value_end + 1
	return results

## 提取 adjacent_rooms 数组内容
static func _extract_adjacent_rooms(scene_text: String) -> Array[String]:
	var results: Array[String] = []
	var needle := "adjacent_rooms = Array[String]("
	var key_index: int = scene_text.find(needle)
	if key_index < 0:
		return results
	var value_end: int = scene_text.find(")", key_index)
	if value_end < 0:
		return results
	var inner: String = scene_text.substr(key_index + needle.length(), value_end - key_index - needle.length())
	for piece in inner.split(","):
		var value: String = piece.replace("[", "").replace("]", "").replace("\"", "").strip_edges()
		if value != "":
			results.append(value)
	return results

## 找出世界矩形互相重叠的房间
static func _find_overlaps(layout_data: RoomLayoutData, registry: Dictionary) -> Array:
	var entries: Array = []
	for room_id in registry.keys():
		var rect: Rect2 = layout_data.get_room_world_rect(room_id)
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue
		entries.append({"id": room_id, "rect": rect})
	var result: Array = []
	for i in range(entries.size()):
		for j in range(i + 1, entries.size()):
			var a: Dictionary = entries[i]
			var b: Dictionary = entries[j]
			if (a["rect"] as Rect2).intersects(b["rect"] as Rect2, false):
				result.append("%s ↔ %s" % [a["id"], b["id"]])
	return result

## 把一组问题项格式化为报告段落
static func _format_section(title: String, items: Array) -> String:
	if items.is_empty():
		return "  [OK] " + title
	return "  [!] %s（%d）：%s" % [title, items.size(), "; ".join(items)]
