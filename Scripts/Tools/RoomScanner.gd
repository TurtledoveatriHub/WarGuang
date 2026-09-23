# Scripts/Tools/RoomScanner.gd
## 房间边界扫描器（编辑器工具）
## 遍历 ScenePaths.ROOM_PATHS 登记的房间场景，从 .tscn 文本中解析 room_bounds 节点的
## 位置与尺寸，写回 RoomLayoutData.room_bounds_rects。
##
## 采用文本解析而非实例化：房间场景内含大量瓦片数据，实例化 20+ 个房间会显著拖慢甚至
## 拖垮编辑器；文本解析只读取节点头部几行，代价极低。
@tool
class_name RoomScanner
extends RefCounted

## 房间路径注册表脚本路径
## ScenePaths 是无 @tool 的 Autoload，在编辑器上下文中拿不到单例，
## 因此直接加载脚本并读取其常量表。
const SCENE_PATHS_SCRIPT := "res://Scripts/Managers/ScenePaths.gd"

## TextArea 的默认基础尺寸（与 Scripts/UI/TextArea.gd 的默认值保持一致）
const DEFAULT_BOUNDS_SIZE := Vector2(320.0, 320.0)

## 获取「房间 ID → 场景路径」注册表；失败时返回空字典
static func get_room_registry() -> Dictionary:
	var paths_script: GDScript = load(SCENE_PATHS_SCRIPT)
	if paths_script == null:
		push_error("RoomScanner: 无法加载 " + SCENE_PATHS_SCRIPT)
		return {}
	var constants: Dictionary = paths_script.get_script_constant_map()
	if not constants.has("ROOM_PATHS"):
		push_error("RoomScanner: ScenePaths 中找不到 ROOM_PATHS 常量")
		return {}
	return constants["ROOM_PATHS"]

## 从场景文本中提取 room_bounds 导出引用指向的节点名
static func _extract_bounds_node_name(scene_text: String) -> String:
	const KEY := "room_bounds = NodePath("
	var key_index: int = scene_text.find(KEY)
	if key_index < 0:
		return ""
	var value_start: int = key_index + KEY.length()
	var value_end: int = scene_text.find(")", value_start)
	if value_end < 0:
		return ""
	return scene_text.substr(value_start, value_end - value_start).replace("\"", "").strip_edges()

## 从场景文本中解析指定节点的属性块，返回「属性名 → 值文本」
static func _extract_node_properties(scene_text: String, node_name: String) -> Dictionary:
	var header := "[node name=\"" + node_name + "\""
	var header_index: int = scene_text.find(header)
	if header_index < 0:
		return {}
	var block_end: int = scene_text.find("\n[", header_index)
	var block: String = scene_text.substr(header_index, block_end - header_index) if block_end > header_index else scene_text.substr(header_index)
	var properties: Dictionary = {}
	for line in block.split("\n"):
		var trimmed: String = line.strip_edges()
		var eq_index: int = trimmed.find("=")
		if eq_index <= 0:
			continue
		properties[trimmed.substr(0, eq_index).strip_edges()] = trimmed.substr(eq_index + 1).strip_edges()
	return properties

## 解析 "Vector2(x, y)" 形式的文本；失败返回 null
static func _parse_vector2(text: String) -> Variant:
	var open_index: int = text.find("(")
	var close_index: int = text.find(")")
	if open_index < 0 or close_index <= open_index:
		return null
	var parts: PackedStringArray = text.substr(open_index + 1, close_index - open_index - 1).split(",")
	if parts.size() < 2:
		return null
	return Vector2(float(parts[0].strip_edges()), float(parts[1].strip_edges()))

## 扫描单个房间场景，返回其 room_bounds 的本地矩形；失败返回空矩形
## TextArea 以自身 position 为矩形中心，故左上角 = position - 实际尺寸 * 0.5。
static func scan_room(scene_path: String) -> Rect2:
	if not FileAccess.file_exists(scene_path):
		push_warning("RoomScanner: 房间场景不存在 " + scene_path)
		return Rect2()
	var file: FileAccess = FileAccess.open(scene_path, FileAccess.READ)
	if file == null:
		push_warning("RoomScanner: 无法读取 " + scene_path)
		return Rect2()
	var scene_text: String = file.get_as_text()
	file.close()
	var bounds_node_name: String = _extract_bounds_node_name(scene_text)
	if bounds_node_name == "":
		push_warning("RoomScanner: 场景未声明 room_bounds 引用 " + scene_path)
		return Rect2()
	var properties: Dictionary = _extract_node_properties(scene_text, bounds_node_name)
	if properties.is_empty():
		push_warning("RoomScanner: 找不到边界节点 " + bounds_node_name + "（" + scene_path + "）")
		return Rect2()
	# 边界节点相对房间根节点的中心位置，缺省为原点
	var center: Vector2 = Vector2.ZERO
	# 边界节点的缩放，缺省为 1
	var node_scale: Vector2 = Vector2.ONE
	# 边界节点的基础尺寸，缺省取 TextArea 默认值
	var base_size: Vector2 = DEFAULT_BOUNDS_SIZE
	if properties.has("position"):
		var parsed_position: Variant = _parse_vector2(properties["position"])
		if parsed_position is Vector2:
			center = parsed_position
	if properties.has("scale"):
		var parsed_scale: Variant = _parse_vector2(properties["scale"])
		if parsed_scale is Vector2:
			node_scale = parsed_scale
	if properties.has("size"):
		var parsed_size: Variant = _parse_vector2(properties["size"])
		if parsed_size is Vector2:
			base_size = parsed_size
	var actual_size: Vector2 = base_size * node_scale
	if actual_size.x <= 0.0 or actual_size.y <= 0.0:
		push_warning("RoomScanner: 房间边界尺寸无效 " + scene_path)
		return Rect2()
	return Rect2(center - actual_size * 0.5, actual_size)

## 扫描全部登记房间并写入 data.room_bounds_rects，返回统计报告
static func scan_all(data: RoomLayoutData) -> Dictionary:
	var report: Dictionary = {
		"scanned": [],           # 成功扫描到边界的房间
		"failed": [],            # 扫描失败（无场景 / 无 room_bounds）的房间
		"missing_position": [],  # 已扫描到尺寸但还没有位置偏移的房间
	}
	if data == null:
		report["error"] = "RoomLayoutData 为空"
		return report
	var registry: Dictionary = get_room_registry()
	for room_id in registry.keys():
		var rect: Rect2 = scan_room(str(registry[room_id]))
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			report["failed"].append(room_id)
			continue
		data.room_bounds_rects[room_id] = rect
		report["scanned"].append(room_id)
		if not data.has_room(room_id):
			report["missing_position"].append(room_id)
	return report

## 把扫描报告整理成多行可读文本，便于编辑器日志输出
static func format_report(report: Dictionary) -> String:
	var scanned: Array = report.get("scanned", [])
	var failed: Array = report.get("failed", [])
	var missing: Array = report.get("missing_position", [])
	var text := "扫描完成：成功 %d，失败 %d，缺位置 %d" % [scanned.size(), failed.size(), missing.size()]
	if not failed.is_empty():
		text += "\n  扫描失败：" + ", ".join(failed)
	if not missing.is_empty():
		text += "\n  缺少位置偏移：" + ", ".join(missing)
	return text
