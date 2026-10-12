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

## 房间门清单：room_id → Array[{ "position": Vector2(房间本地), "door_id": String, "target": String }]
## 由 RoomScanner 扫房间场景文本自动生成，供 WorldLayout 摆放面板显示门的位置（方便对齐相邻房间）。
@export var room_doors: Dictionary = {}

## 地图裁图区域字典：room_id → Rect2（相对房间根节点的本地矩形）
## 留空表示与 room_bounds_rects 相同。
## 仅当美术把跨房间的联通通道画在房间矩形之外时，才需要单独扩大该房间参与地图显示的区域。
@export var map_region_rects: Dictionary = {}

## 地图画布原点：地图纹理像素 (0, 0) 对应的世界坐标
## 美术作画基准 —— 纹理左上角就是这个世界坐标点。
## 默认由 refresh_map_world_origin() 自动推导，不要手改（要手改请先关闭
## center_texture_on_world_origin）。
@export var map_world_origin: Vector2 = Vector2.ZERO

## 地图纹理尺寸（像素）。与美术实际导出的 map.png 尺寸保持一致。
## 它决定了「1 纹理像素 = world_units_per_map_pixel 世界像素」时整张图覆盖多大世界范围。
@export var map_texture_size: Vector2i = Vector2i(512, 288)

## 是否让「地图纹理正中心」对齐世界坐标原点
## true（默认，与美术约定一致）：纹理正中 = 世界 (0, 0) = GrassLand1 房间中心。
##      map_world_origin = -纹理尺寸 / 2 × world_units_per_map_pixel
##      → 好处：美术只要把地图画在以原点为中心的位置上，无论纹埋多大都不会偏。
## false：改回「包围盒左上角向外留白 map_padding_world」的旧式，用于兼容手工调过原点的旧资源。
@export var center_texture_on_world_origin: bool = true

## 地图纹理比例：地图纹理 1 像素对应多少世界像素（160 表示 1px = 160px）
## 世界坐标 → 纹理像素的换算 = (world - map_world_origin) / world_units_per_map_pixel
##
## ★ 这是整套地图里唯一需要「对齐美术」的数字。校准方法：
##     比例 = 某个房间的世界尺寸 ÷ 该房间在纹理上量到的像素尺寸
##   例：GrassLand1 世界尺寸 2560×1920，若在纹理上量到 16 像素宽 → 2560 / 16 = 160。
##   （当前值 160 就是按这个思路定的；改完记得让 WorldLayoutBoard 重新算一次原点，
##     或直接在 MapUI 上用 world_units_per_map_pixel_override 实时试到轮廓框正好套住房间。）
## 也可参考：全部 25 个房间的世界包围盒是 35584×11584，至少要不小于 114 才能全部装进 512×288 的纹理。
## 也可参考：全部房间的世界包围盒是 37120×11584，至少要不小于 73 才能全部装进 512×288 的纹理。
## ★ 当前 16：与 16×16 的瓦片一一对应（1 格地形 = 1 个地图像素），没有任何舍入误差。
@export_range(1.0, 1000.0, 1.0) var world_units_per_map_pixel: float = 16.0
## 每个房间边缘允许向外多画多少个像素（0~2）。
## 房间边缘的精度不重要，但 room_bounds 正好切在墙中间时会在边缘留下整齐的缺口，
## 所以每个房间按 ID 哈希取一个 0~该值的固定随机量向外放宽（每次重画结果一致）。
@export_range(0, 4, 1) var map_edge_tolerance_px: int = 2
## 自动计算地图画布原点时，四周预留的世界像素
## 320 世界像素 = 4 纹理像素，用于给后续新增房间留空间，避免边界房间紧贴画布边缘
@export var map_padding_world: float = 320.0

# ════════════════════════════════════════════════════════════
# 代码生成地图纹理的绘制规范
# ════════════════════════════════════════════════════════════

## 房间基础底色表：房间名前缀 → 颜色。
## 匹配规则是「房间 ID 是否以该前缀开头」，可自由增删。
## 整张地图就是由这些底色块拼出来的（不依赖任何美术贴图）。
@export var map_terrain_colors: Dictionary = {
	"GrassLand": Color(0.451, 0.529, 0.435, 1.0),
	"SnowMountain": Color(0.427, 0.529, 0.576, 1.0),
	"SuperMario": Color(0.529, 0.475, 0.337, 1.0),
	"Atlantis": Color(0.337, 0.502, 0.588, 1.0),
	"Cave": Color(0.686, 0.667, 0.706, 1.0),
	"Dream": Color(0.549, 0.427, 0.616, 1.0),
	"Town": Color(0.573, 0.478, 0.373, 1.0),
	"WindValley": Color(0.549, 0.569, 0.549, 1.0),
}

## 没有匹配到任何前缀时使用的房间底色
@export var map_default_terrain_color: Color = Color(0.55, 0.55, 0.58, 1.0)

## 实体地面（GroundTile / BlockTile / HiddenTile）相对房间底色的亮度系数：越小越暗
@export_range(0.0, 1.0, 0.01) var map_ground_brightness: float = 0.55

## 房间底色的不透明度（1 = 实心）
@export_range(0.0, 1.0, 0.01) var map_room_fill_alpha: float = 1.0

## 门连线粗细（纹理像素）。
@export_range(1, 6, 1) var map_connector_width_px: int = 2

# ════════════════════════════════════════════
# 特殊标志（存档点 / 传送阵 / 商店……）—— 地图上用像素点表示
# ════════════════════════════════════════════

## 标志配色表：房间内「容器节点名前缀」→ 颜色。
## 房间场景里的特殊标志都放在同名容器下（ChairSavePoints / TeleportPoints……），
## 脚本按前缀命中容器，再给容器下每个「带 CollisionShape2D」的子节点，按其碰撞体大小画一个矩形块。
## ★ 只有写在这张表里的类型才会被画到地图上（动态检查点故意不放进来）。
## 以后加商店之类的标志：在房间场景里放一个以对应前缀命名的容器，再在这里加一行就行。
@export var map_landmark_colors: Dictionary = {
	"ChairSavePoint": Color(0.31, 0.8, 0.478, 1.0),
	"TeleportPoint": Color(0.851, 0.686, 0.208, 1.0),
	"Shop": Color(1.0, 0.72, 0.25, 1.0),
}

## 容器节点名是否对应一个「要画到地图上的标志」
func has_landmark_color(node_name: String) -> bool:
	for prefix: String in map_landmark_colors.keys():
		if node_name.begins_with(prefix):
			return true
	return false

## 取标志颜色（配合 has_landmark_color 使用）
func get_landmark_color(node_name: String) -> Color:
	for prefix: String in map_landmark_colors.keys():
		if node_name.begins_with(prefix):
			return map_landmark_colors[prefix]
	return Color(1, 1, 1, 1)

## 按房间 ID 取房间基础底色（前缀匹配）
func get_terrain_color(room_id: String) -> Color:
	for prefix: String in map_terrain_colors.keys():
		if room_id.begins_with(prefix):
			var base: Color = map_terrain_colors[prefix]
			base.a = map_room_fill_alpha
			return base
	var fallback: Color = map_default_terrain_color
	fallback.a = map_room_fill_alpha
	return fallback

## 房间实体地面的颜色（房间底色调暗，透明度不变）
func get_ground_color(room_id: String) -> Color:
	var base: Color = get_terrain_color(room_id)
	var ground: Color = base.darkened(1.0 - clampf(map_ground_brightness, 0.0, 1.0))
	ground.a = base.a
	return ground

## 按当前比例与留白计算整张生成贴图的画布尺寸（像素）
func compute_map_texture_size() -> Vector2i:
	var canvas: Vector2 = get_map_canvas_size()
	return Vector2i(maxi(int(ceilf(canvas.x)), 1), maxi(int(ceilf(canvas.y)), 1))

## 重算原点并同步 map_texture_size
## 生成贴图前必须调一次：原点 / 比例 / 画布尺寸三者必须自洽，否则整张图会错位。
func sync_generated_canvas() -> void:
	refresh_map_world_origin()
	map_texture_size = compute_map_texture_size()

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

## 世界坐标 → 地图纹理像素坐标
func world_to_map(world_pos: Vector2) -> Vector2:
	return (world_pos - map_world_origin) / world_units_per_map_pixel

## 地图纹理像素坐标 → 世界坐标
func map_to_world(map_pos: Vector2) -> Vector2:
	return map_pos * world_units_per_map_pixel + map_world_origin

## 全部已记录房间（含各自边界）在世界空间中的包围盒
func get_world_bounds() -> Rect2:
	var result := Rect2()
	var has_any := false
	for room_id in room_bounds_rects.keys():
		var rect: Rect2 = get_room_world_rect(str(room_id))
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue
		result = rect if not has_any else result.merge(rect)
		has_any = true
	return result

## 按当前配置「建议」的地图画布尺寸（像素），仅供美术参考。
## * 居中模式：画布就是纹理本身 → 返回 map_texture_size。
## * 自动模式：包围盒 + map_padding_world 留白。
## 运行时按 world_units_per_map_pixel 直接映射纹理，纹理比建议尺寸大也不会有问题
## （多出来的部分就是世界外围的留白）。
func get_map_canvas_size() -> Vector2:
	if center_texture_on_world_origin:
		return Vector2(float(map_texture_size.x), float(map_texture_size.y))
	var bounds: Rect2 = get_world_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return Vector2.ZERO
	var ratio: float = maxf(world_units_per_map_pixel, 1.0)
	var padded_bottom_right: Vector2 = bounds.position + bounds.size + Vector2(map_padding_world, map_padding_world)
	return Vector2(
		ceilf((padded_bottom_right.x - map_world_origin.x) / ratio),
		ceilf((padded_bottom_right.y - map_world_origin.y) / ratio)
	)

## 居中模式下，为了覆盖全部房间所需的最小纹理尺寸（美术参考）
## 因为纹理中心固定在原点，所以左右各需要「最远的那个房间」到原点的距离。
func get_required_texture_size_centered() -> Vector2i:
	if not center_texture_on_world_origin:
		return Vector2i.ZERO
	var bounds: Rect2 = get_world_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return Vector2i.ZERO
	var ratio: float = maxf(world_units_per_map_pixel, 1.0)
	var half_width: float = maxf(absf(bounds.position.x), absf(bounds.end.x)) / ratio
	var half_height: float = maxf(absf(bounds.position.y), absf(bounds.end.y)) / ratio
	return Vector2i(int(ceilf(half_width * 2.0)), int(ceilf(half_height * 2.0)))

## 当前纹理尺寸是否足以覆盖全部房间（居中模式专用）
func is_texture_size_sufficient() -> bool:
	var required: Vector2i = get_required_texture_size_centered()
	if required == Vector2i.ZERO:
		return true
	return map_texture_size.x >= required.x and map_texture_size.y >= required.y

## 房间在地图纹理坐标系中的矩形
func get_room_map_rect(room_id: String) -> Rect2:
	var world_rect: Rect2 = get_room_map_region_world(room_id)
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return Rect2()
	return Rect2(world_to_map(world_rect.position), world_rect.size / world_units_per_map_pixel)

## 按当前配置重算地图画布原点
## * 居中模式：纹理正中心 = 世界原点（推荐，与美术约定一致）。
## * 自动模式：全部房间包围盒左上角再向外预留 map_padding_world，并吸附到纹理像素。
func refresh_map_world_origin() -> void:
	var ratio: float = maxf(world_units_per_map_pixel, 1.0)
	if center_texture_on_world_origin:
		var half_size := Vector2(float(map_texture_size.x), float(map_texture_size.y)) * 0.5
		map_world_origin = -half_size * ratio
		return
	var bounds: Rect2 = get_world_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	var padded: Vector2 = bounds.position - Vector2(map_padding_world, map_padding_world)
	map_world_origin = Vector2(floorf(padded.x / ratio) * ratio, floorf(padded.y / ratio) * ratio)
