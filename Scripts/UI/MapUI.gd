extends CanvasLayer

## 地图界面（对标《空洞骑士》）
##
## ── 场景结构（全部可在编辑器里直接拖拽调整位置与大小）──────────────
##   MapUI (CanvasLayer)
##   ├─ Background        全屏黑幕（暗化程度由 DarkOverlay 统一规定）
##   ├─ ContentRoot       动效总线驱动的整体（淡入 + 轻微缩放回弹）
##   │   ├─ LegendSprite  图例（纯美术节点，脚本完全不碰）
##   │   ├─ MapWindow     ★观察窗口：位置/尺寸在这里调；clip_contents 保证内容不溢出
##   │   │   ├─ Backdrop     窗口黑底（anchors 铺满整个窗口）
##   │   │   ├─ MapContainer 运行时滚动 / 缩放
##   │   │   │   ├─ MapSprite      地图整图（代码生成，不要手挂贴图）
##   │   │   │   └─ QuestMarkerLayer 任务标记层（动态节点，不吃战争迷雾）
##   │   │   └─ PlayerIcon   玩家图标（钉在玩家所在的地图位置上）
##   │   └─ FrameSprite   装饰边框（纯美术节点，脚本完全不碰）
##   └─ UIFxDirector      开合动画总线
##
## ── 地图贴图是代码生成的 ────────────────────
##   * 底色块 / 实体地面 / 特殊标志 / 门连线全部由 MapManager 画进一张 Image，
##     再当普通贴图贴到 MapSprite 上。手绘整图已彻底废弃（没有任何美术回退）。
##   * 本脚本只负责「贴图贴上 + 对准玩家 + 缩放平移 + 吃战争迷雾」。
##
## ── 显示模型（对标《空洞骑士》/《泰拉瑞亚》）────
##   * 观察窗口大小恒定不动；地图**不会**每帧跟着玩家重算。
##   * 打开地图时只算一次：把视野对准玩家，然后把玩家图标**钉在玩家所在的地图位置上**。
##   * 玩家操作不被锁住；交互键 U 在开图期间被 MapManager 从 InputMap 里摘掉，
##     避免看地图时误触发 NPC / 存档点。受伤会自动关掉地图。
##   * 滚轮缩放（以窗口中心为锚点），鼠标左键拖拽平移，平移范围受限。
##
## ── 战争迷雾 ──────────────────────────────────────────────
##   * 未探索处纯黑，已探索处显示地图；边界用 step() 取硬边，完全没有模糊过渡。
##   * RADIUS 模式（默认，渐进揭露）：玩家走到哪亮到哪，绝不一进房间就显示整间房。
##     本模式需要每帧工作（_process 持续跑）。
##   * ROOM 模式：一进房间整块点亮（空洞骑士式）；本模式地图就绪后 _process 会彻底关掉。
##   * 两种模式下，未进入过的房间无论玩家靠多近都不会被点亮。

## 战争迷雾的揭示方式
## ★ 顺序不可改：场景文件里存的是整数，0=ROOM、1=RADIUS。改动顺序会让已保存的场景语义翻转。
enum FogRevealMode {
	ROOM,    ## 进入过的房间整块点亮（空洞骑士式：边界锐利、一眼看清地形）
	RADIUS,  ## 渐进揭露：玩家走到哪亮到哪（默认）
}

## 地图渲染着色器路径（战争迷雾）
const MAP_SHADER_PATH := "res://Assets/Shaders/MapReveal.gdshader"

## 覆盖层暗化规范（黑幕 alpha / 世界亮度 / 黑幕过渡时长）—— 全项目唯一来源
const OverlaySpec := preload("res://Scripts/UI/DarkOverlay.gd")

# ════════════════════════════════════════════════════════════
# 节点引用
# ════════════════════════════════════════════════════════════

## 全屏黑幕
@onready var background: ColorRect = $Background
## 整体内容根（动效总线的缩放目标，pivot 设为画面中心 → 从中心展开）
@onready var content_root: Control = $ContentRoot
## 装饰边框（纯美术，脚本不碰它的贴图/位置/缩放）
@onready var frame_sprite: Sprite2D = $ContentRoot/FrameSprite
## 图例（纯美术，脚本不碰它）
@onready var legend_sprite: Sprite2D = $ContentRoot/LegendSprite
## 观察窗口：地图只在这块矩形内出现
@onready var map_window: Control = $ContentRoot/MapWindow
## 地图内容容器（运行时滚动 / 缩放）
@onready var map_container: Node2D = $ContentRoot/MapWindow/MapContainer
## 地图整图精灵（贴图由 MapManager 代码生成，本脚本只负责贴上去）
@onready var map_sprite: Sprite2D = $ContentRoot/MapWindow/MapContainer/MapSprite
## 地标层（已废弃 —— 存档点 / 传送阵改由 MapManager 在贴图上打像素点，不再需要单独贴图层）
## 任务标记层（触发型任务用；不吃战争迷雾，永远可见）
@onready var quest_layer: Node2D = $ContentRoot/MapWindow/MapContainer/QuestMarkerLayer
## 玩家图标（地图上的一个点：位置 = 玩家在地图纹理上的位置）
@onready var player_icon: Sprite2D = $ContentRoot/MapWindow/MapContainer/PlayerIcon
## 动效总线（开合动画由它驱动）
@onready var fx_director: Node = $UIFxDirector

# ════════════════════════════════════════════════════════════
# 导出配置
# ════════════════════════════════════════════════════════════

@export_category("缩放")
## 打开地图时的基础缩放倍率（在「刚好铺满窗口」的下限之上再乘）：2.0 = 默认放大两倍
@export_range(0.1, 8.0, 0.05) var open_zoom: float = 2.0
## 滚轮能缩到的最小倍率
@export_range(0.05, 8.0, 0.05) var min_zoom: float = 0.25
## 滚轮能放到的最大倍率
@export_range(0.5, 16.0, 0.25) var max_zoom: float = 8.0
## 每一格滚轮的缩放倍率
@export_range(1.01, 2.0, 0.01) var zoom_step: float = 1.25

@export_category("地图坐标校准")
## 临时覆盖 RoomLayoutData.world_units_per_map_pixel（> 0 时生效，0 = 用数据文件里的值）。
## 用法：打开地图 + 打开「粗糙地图」，拖这个数字直到轮廓框正好套住美术画的房间，
## 再把最终值抄进 Assets/Configs/RoomLayoutData.tres。
## 公式：比例 = 房间的世界尺寸 ÷ 该房间在纹理上量到的像素尺寸。
@export var world_units_per_map_pixel_override: float = 0.0

@export_category("战争迷雾")
## 是否启用战争迷雾（关闭则整张地图直接可见）
@export var enable_fog_of_war: bool = true
## 揭示方式：RADIUS = 渐进揭露（走到哪亮到哪，默认）；ROOM = 进入过的房间整块点亮
@export var fog_reveal_mode: FogRevealMode = FogRevealMode.RADIUS
## RADIUS 模式下的揭示半径（世界像素）
@export var reveal_radius_world: float = 540.0
## RADIUS 模式下玩家移动多少世界像素后重新揭示一次
@export var reveal_step_world: float = 20.0

# ════════════════════════════════════════════════════════════
# 运行时状态
# ════════════════════════════════════════════════════════════

## 地图是否处于打开状态
var is_open: bool = false
## 地图精灵的材质（战争迷雾）
var _map_material: ShaderMaterial = null
## 玩家图标材质（不吃迷雾 —— 图标永远要可见）
var _icon_material: ShaderMaterial = null
## 地图是否已经准备好（贴图 + 迷雾遮罩都已就绪）—— 没就绪时 _process 会重试
var _map_ready: bool = false
## 当前视野缩放倍率（在 MapSprite 设定大小的基础上再乘）
var _view_zoom: float = 1.0
## 是否正在用鼠标左键拖拽平移地图
var _pan_dragging: bool = false
## 触屏捏合缩放：当前按在屏幕上的手指位置（index → 位置）。
var _active_touches: Dictionary = {}
## 上一帧两根手指之间的距离，用于算缩放倍率。
var _pinch_last_distance: float = 0.0
## 缓存的玩家节点引用（避免每帧做 get_first_node_in_group 查询）
var _player_ref: Node2D = null
## 迷雾初始化失败时的重试倒计时（秒），避免每帧重复尝试
var _reveal_retry_timer: float = 0.0
## 暗化前的全局亮度色（关闭时还原）
var _original_modulate: Color = Color(1, 1, 1, 1)
## 被本界面调暗的全局 CanvasModulate
var _canvas_modulate: CanvasModulate = null
## 入场动画兜底计时器（补间异常时把内容拉回基准状态）
var _open_fallback_timer: SceneTreeTimer = null
## 退场动画兜底计时器（补间异常时也要完成关闭）
var _close_fallback_timer: SceneTreeTimer = null


# ════════════════════════════════════════════════════════════
# 生命周期
# ════════════════════════════════════════════════════════════

func _ready() -> void:
	layer = 98
	visible = false
	# 地图在游戏进行中打开（传送面板还会暂停游戏），必须 ALWAYS 才会推进动画与输入。
	process_mode = Node.PROCESS_MODE_ALWAYS
	background.color = Color(0, 0, 0, 0)
	content_root.visible = false
	# 窗口必须裁掉溢出内容，否则地图会跑到窗口外面去
	map_window.clip_contents = true
	map_window.resized.connect(_on_map_window_resized)
	_setup_materials()
	_push_reveal_config()
	_update_process_state()
	# 任务标记增删时重建标记层（不是每帧）
	if MapManager != null:
		MapManager.markers_changed.connect(_refresh_quest_markers)
	# 布局数据在 Autoload 初始化阶段可能尚未就绪，延后一帧再准备地图
	call_deferred("_refresh_map")


## 创建并挂上材质：地图精灵与地标层吃战争迷雾，玩家图标不吃迷雾
func _setup_materials() -> void:
	var shader: Shader = load(MAP_SHADER_PATH)
	if shader == null:
		push_error("MapUI: 找不到地图着色器 " + MAP_SHADER_PATH)
		return
	_map_material = _make_map_material(shader)
	_icon_material = _make_map_material(shader)
	map_sprite.material = _map_material
	if player_icon != null:
		player_icon.material = _icon_material


## 按地图着色器新建一份材质（默认不开迷雾，由 _sync_*_material 决定）
func _make_map_material(shader: Shader) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("use_reveal_mask", false)
	material.set_shader_parameter("use_clip", false)
	return material


## 窗口尺寸变化时重新对准玩家（窗口中心变了，视野要跟着重算）
func _on_map_window_resized() -> void:
	_sync_view()


## 决定是否让 _process 继续跑。
## ROOM 模式且地图已就绪 → 彻底关掉，整个游戏过程零每帧开销；
## RADIUS 模式或地图还没准备好 → 才需要跑。
func _update_process_state() -> void:
	set_process(not _map_ready or is_open or (enable_fog_of_war and fog_reveal_mode == FogRevealMode.RADIUS))


## 取得玩家节点（带缓存，避免每次组查询）
func _get_player() -> Node2D:
	if _player_ref != null and is_instance_valid(_player_ref) and _player_ref.is_inside_tree():
		return _player_ref
	var found: Node = get_tree().get_first_node_in_group("player")
	_player_ref = found as Node2D
	return _player_ref


## 把战争迷雾参数下发给 MapManager（揭示逻辑由 MapUI 每帧驱动）
func _push_reveal_config() -> void:
	if MapManager == null:
		return
	MapManager.reveal_radius_world = reveal_radius_world
	MapManager.reveal_step_world = maxf(reveal_step_world, 1.0)
	# ROOM 模式才允许「一进房间整块点亮」；RADIUS（默认）必须是纯渐进揭露
	MapManager.room_level_reveal = fog_reveal_mode == FogRevealMode.ROOM


## 取得权威布局数据
func _layout() -> RoomLayoutData:
	if MapManager == null:
		return null
	return MapManager.get_layout_data()


## 世界亮度乘法系数（全项目统一来源：DarkOverlay）
func _world_darken() -> float:
	return OverlaySpec.WORLD_DARKEN_MULTIPLIER


## 黑幕渐变：打开时立即开始渐暗、关闭时立即开始渐亮（时长全项目统一）
func _fade_overlay(target_alpha: float) -> void:
	OverlaySpec.fade_rect_alpha(background, target_alpha, self)


# ════════════════════════════════════════════════════════════
# 地图准备
# ════════════════════════════════════════════════════════════

## 准备地图贴图、已探索遮罩
func _refresh_map() -> void:
	var layout: RoomLayoutData = _layout()
	if layout == null:
		return
	# 比例校准（Inspector 里的临时覆盖，> 0 才生效）。必须放在取贴图之前 ——
	# 整张地图是按比例生成与换算的，改比例等于整张重画。
	if world_units_per_map_pixel_override > 0.0:
		layout.world_units_per_map_pixel = world_units_per_map_pixel_override
	var texture: Texture2D = MapManager.get_map_texture() if MapManager != null else null
	if texture == null:
		return
	map_sprite.texture = texture
	var texture_size := Vector2i(texture.get_size())
	# 贴图尺寸本来就是从布局算出来的，这里只做一次保险的对齐
	if layout.map_texture_size != texture_size:
		layout.map_texture_size = texture_size
	# 已探索遮罩必须与地图纹理逐像素对应
	MapManager.ensure_reveal_mask(texture_size)
	_sync_map_material()
	# 按「已到达过的房间」把遮罩重描一遍（仅 ROOM 模式；RADIUS 模式内部直接 return）
	MapManager.reveal_visited_rooms()
	_refresh_quest_markers()
	_map_ready = true
	_update_process_state()
	# 贴图就绪后才能算「纹理像素 → 内容像素」，所以对准视野放在这里
	_sync_view()


## 把遮罩纹理挂上地图材质
func _sync_map_material() -> void:
	if _map_material == null:
		return
	var reveal_texture: Texture2D = MapManager.get_reveal_texture() if MapManager != null else null
	_map_material.set_shader_parameter("reveal_mask", reveal_texture)
	_map_material.set_shader_parameter("use_reveal_mask", enable_fog_of_war and reveal_texture != null)



# ════════════════════════════════════════════════════════════
# 视野换算（核心）
# ════════════════════════════════════════════════════════════

## 窗口中心（窗口局部坐标）
func _window_center() -> Vector2:
	return Vector2(map_window.size) * 0.5


## 玩家在地图纹理坐标系中的位置；没有玩家时取世界包围盒中心
func _focus_map_position() -> Vector2:
	var layout: RoomLayoutData = _layout()
	if layout == null:
		return Vector2.ZERO
	var player: Node2D = _get_player()
	if player != null:
		return layout.world_to_map(player.global_position)
	var bounds: Rect2 = layout.get_world_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return Vector2.ZERO
	return layout.world_to_map(bounds.get_center())


## 把「地图纹理坐标」换算成「地图内容坐标」（也就是 MapContainer 的局部坐标）。
## 会正确考虑 MapSprite 的 centered / position / scale：
## 所以你在编辑器里拖动、缩放、切换 centered 都不会让地图与玩家图标错位。
## 之所以要经过 MapSprite 自己的变换：拖动 MapSprite 就等于微调整图对齐。
func map_to_content(map_pos: Vector2) -> Vector2:
	if map_sprite == null:
		return map_pos
	var sprite_scale: Vector2 = map_sprite.scale
	var sprite_origin: Vector2 = map_sprite.position
	if map_sprite.centered and map_sprite.texture != null:
		# centered 时 position 是「贴图中心」，要减去半个尺寸才是左上角
		sprite_origin -= Vector2(map_sprite.texture.get_size()) * 0.5 * sprite_scale
	return sprite_origin + map_pos * sprite_scale


## 地图内容（纹理 × MapSprite.scale）在缩放 1.0 时的像素尺寸
func _content_size() -> Vector2:
	if map_sprite == null or map_sprite.texture == null:
		return Vector2.ZERO
	return Vector2(map_sprite.texture.get_size()) * map_sprite.scale


## 允许的最小缩放：地图**刚好铺满显示窗口**的倍率。
## 缩到这个值时窗口被地图完全填满，再缩小就会出现空白 —— 所以它就是缩放下限。
func _min_allowed_zoom() -> float:
	var content: Vector2 = _content_size()
	var win: Vector2 = map_window.size if map_window != null else Vector2.ZERO
	if content.x <= 0.0 or content.y <= 0.0 or win.x <= 0.0 or win.y <= 0.0:
		return min_zoom
	return maxf(min_zoom, maxf(win.x / content.x, win.y / content.y))


## 把地图平移限制在合法范围内：
##   地图比窗口大 → 窗口必须始终落在地图内（四条边都不会露出窗口外的空白）；
##   地图比窗口小 → 居中（正常情况下不会发生，因为缩放下限就是「刚好铺满」）。
func _clamp_pan() -> void:
	if map_container == null or map_window == null or map_sprite == null:
		return
	var content: Vector2 = _content_size()
	if content.x <= 0.0 or content.y <= 0.0:
		return
	var win: Vector2 = map_window.size
	# 地图内容左上角在 MapContainer 局部坐标系里的位置（只跟 MapSprite 的位姿有关）
	var origin: Vector2 = map_to_content(Vector2.ZERO)
	var scaled: Vector2 = content * _view_zoom
	var pos: Vector2 = map_container.position
	if scaled.x >= win.x:
		pos.x = clampf(pos.x, win.x - (origin.x + content.x) * _view_zoom, -origin.x * _view_zoom)
	else:
		pos.x = (win.x - scaled.x) * 0.5 - origin.x * _view_zoom
	if scaled.y >= win.y:
		pos.y = clampf(pos.y, win.y - (origin.y + content.y) * _view_zoom, -origin.y * _view_zoom)
	else:
		pos.y = (win.y - scaled.y) * 0.5 - origin.y * _view_zoom
	map_container.position = pos


## 把视野对准玩家（**只在打开地图时 / 窗口尺寸变化时**调用）。
## 之后地图视图不再动 —— 玩家自己跑动时只有图标跟着走。
func _sync_view() -> void:
	if map_container == null or map_window == null or MapManager == null:
		return
	if map_sprite == null or map_sprite.texture == null:
		return
	map_container.scale = Vector2(_view_zoom, _view_zoom)
	var focus: Vector2 = map_to_content(_focus_map_position())
	map_container.position = _window_center() - focus * _view_zoom
	# 对准玩家后立即限制范围，避免玩家靠边时地图边缘跑进窗口
	_clamp_pan()
	_update_player_icon()


## 玩家图标就钉在玩家所在的地图位置上（不是固定 UI）。
## 地图视图不动，所以玩家跑动时图标会在地图上移动 —— 空洞骑士就是这么做的。
func _update_player_icon() -> void:
	if player_icon == null or map_sprite == null or map_sprite.texture == null:
		return
	player_icon.position = map_to_content(_focus_map_position())
	player_icon.visible = true


## 滚轮缩放：以**窗口中心**为锚点（缩放前后窗口中心对应的地图内容点不变）。
## 缩放下限不是 min_zoom，而是「地图刚好铺满窗口」的倍率（见 _min_allowed_zoom）。
func _apply_zoom(factor: float) -> void:
	if map_container == null:
		return
	var new_zoom: float = clampf(_view_zoom * factor, _min_allowed_zoom(), max_zoom)
	if is_equal_approx(new_zoom, _view_zoom):
		return
	var anchor: Vector2 = (_window_center() - map_container.position) / _view_zoom
	_view_zoom = new_zoom
	map_container.scale = Vector2(_view_zoom, _view_zoom)
	map_container.position = _window_center() - anchor * _view_zoom
	_clamp_pan()
	_update_player_icon()


## 重建任务标记层（只在标记增删时调一次，后面只需位置换算）
func _refresh_quest_markers() -> void:
	if quest_layer == null:
		return
	for child in quest_layer.get_children():
		child.queue_free()
	if MapManager == null:
		return
	var layout: RoomLayoutData = _layout()
	if layout == null or map_sprite == null or map_sprite.texture == null:
		return
	var markers: Dictionary = MapManager.get_markers()
	for marker_id in markers.keys():
		var entry: Dictionary = markers[marker_id]
		var icon: Texture2D = entry.get("icon", null)
		if icon == null:
			continue
		var marker := Sprite2D.new()
		marker.name = str(marker_id)
		marker.texture = icon
		marker.position = map_to_content(layout.world_to_map(entry.get("world_pos", Vector2.ZERO)))
		quest_layer.add_child(marker)


# ════════════════════════════════════════════════════════════
# 战争迷雾
# ════════════════════════════════════════════════════════════

## RADIUS 模式专用：持续揭示玩家周围（只在「玩家当前所在房间」范围内画圆）
## ROOM 模式不需要它 —— 进房间时 MapManager.mark_room_visited 就已经把整块点亮了。
func _update_reveal_radius() -> void:
	if MapManager == null or MapManager.get_reveal_texture() == null:
		return
	var room_id: String = RoomManager.current_room if RoomManager != null else ""
	if room_id == "" or not MapManager.is_room_visited(room_id):
		return
	var layout: RoomLayoutData = _layout()
	if layout == null:
		return
	var player: Node2D = _get_player()
	if player == null:
		return
	# 揭示范围**严格限制在玩家当前所在房间的 room_bounds 内**：
	# 不能向外扩 —— 那会把隔壁「从未进入过」的房间的迷雾也揭开（即使它还没被画进贴图）。
	# 门连线现在只认「真的走过」，不再依赖遮罩，所以也不需要向外扩。
	MapManager.reveal_for_player(player.global_position, layout.get_room_map_region_world(room_id))


# ════════════════════════════════════════════════════════════
# 打开 / 关闭
# ════════════════════════════════════════════════════════════

func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	content_root.visible = true
	content_root.modulate = Color(1, 1, 1, 1)
	# 黑幕从全透明开始，立即开始渐暗（约 0.5 秒），避免整块黑“啵”地一下盖上来
	background.color = Color(0, 0, 0, 0)
	_fade_overlay(OverlaySpec.OVERLAY_ALPHA)
	_adjust_lighting()
	# 揭露模式可能刚在 Inspector 里改过，每次开图都重新下发给 MapManager
	_push_reveal_config()
	_view_zoom = clampf(open_zoom, _min_allowed_zoom(), max_zoom)
	# 开图期间需要每帧把玩家图标移到玩家当前的地图位置上（玩家可以边跑边看地图）
	_update_process_state()
	# _refresh_map() 里会做一次 _sync_view()：把视野对准玩家，并把玩家图标钉在玩家的地图位置上
	_refresh_map()
	_play_fx_enter()


func close() -> void:
	if not is_open:
		# 防御：若历史状态残留了可见地图，强制清理
		if visible:
			_apply_closed_state()
		return
	is_open = false
	# 立即恢复全局亮度，绝不依赖退场动画 —— 杜绝「关图后仍暗」残留。
	_restore_lighting()
	# 点了关闭就立即开始渐亮（约 0.5 秒）
	_fade_overlay(0.0)
	_play_fx_exit()


## 入场动画：交给 UIFxDirector；另设兜底计时器，补间异常时把内容拉回基准状态
func _play_fx_enter() -> void:
	if fx_director == null:
		return
	fx_director.call("play_enter")
	var duration: float = float(fx_director.call("estimate_duration", "enter"))
	_open_fallback_timer = get_tree().create_timer(duration + 0.2)
	_open_fallback_timer.timeout.connect(_fx_open_fallback)


## 入场兜底：仍在打开状态时，把内容恢复到基准可见状态
func _fx_open_fallback() -> void:
	if is_open and fx_director != null:
		fx_director.call("reset_state")


## 退场动画：交给 UIFxDirector；结束时（或兜底超时）执行关闭收尾
## 收尾必须等【内容退场】与【黑幕渐亮】都完成，否则黑幕会被瞬间切掉、看不到渐亮过程。
func _play_fx_exit() -> void:
	var fx_duration: float = 0.0
	if fx_director != null:
		fx_director.call("play_exit")
		fx_duration = float(fx_director.call("estimate_duration", "exit"))
	var total: float = maxf(fx_duration, OverlaySpec.OVERLAY_FADE_DURATION) + 0.2
	_close_fallback_timer = get_tree().create_timer(total)
	_close_fallback_timer.timeout.connect(_apply_closed_state)


## 关闭收尾：确保地图完全隐藏
func _apply_closed_state() -> void:
	if is_open:
		return
	content_root.visible = false
	background.color = Color(0, 0, 0, 0)
	visible = false
	_update_process_state()


func _exit_tree() -> void:
	# 兜底：任何异常路径下都要恢复全局亮度
	_restore_lighting()


# ════════════════════════════════════════════════════════════
# 暗化（数值统一由 DarkOverlay 规定，与传送面板 / 设置界面保持一致）
# ════════════════════════════════════════════════════════════

func _adjust_lighting() -> void:
	if RoomManager == null or RoomManager.global_canvas_modulate == null:
		return
	_canvas_modulate = RoomManager.global_canvas_modulate
	_original_modulate = _canvas_modulate.color
	var factor: float = _world_darken()
	_canvas_modulate.color = Color(
		_original_modulate.r * factor,
		_original_modulate.g * factor,
		_original_modulate.b * factor,
		1.0
	)


func _restore_lighting() -> void:
	if _canvas_modulate != null and is_instance_valid(_canvas_modulate):
		_canvas_modulate.color = _original_modulate


# ════════════════════════════════════════════════════════════
# 输入
# ════════════════════════════════════════════════════════════

## 地图界面作为模态覆盖层：打开期间接受关闭键、滚轮/双指缩放、单指（或鼠标左键）拖拽平移。
## 平移范围由 _clamp_pan() 限制：窗口永远不会跑出地图；缩到最小时地图刚好铺满窗口，也就无法再平移。
## 交互键 U 不在这里处理 —— MapManager 在开图期间直接把 interactive 的按键事件摘掉了。
func _input(event: InputEvent) -> void:
	if not is_open or not visible:
		return
	# 关闭键：Esc 或 Tab（map 动作）
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("map"):
		if MapManager != null:
			MapManager.close_map()
		get_viewport().set_input_as_handled()
		return
	# ── 触屏捏合缩放 ──────────────────────────────────────
	# Godot 在 Android 上不会发 MagnifyGesture，所以自己用两指距离比算缩放。
	if event is InputEventScreenTouch:
		var touch: InputEventScreenTouch = event
		if touch.pressed:
			_active_touches[touch.index] = touch.position
		else:
			_active_touches.erase(touch.index)
		_pinch_last_distance = _pinch_distance()
		return
	if event is InputEventScreenDrag:
		var touch_drag: InputEventScreenDrag = event
		if not _active_touches.has(touch_drag.index):
			return
		_active_touches[touch_drag.index] = touch_drag.position
		if _active_touches.size() < 2:
			return
		var distance: float = _pinch_distance()
		if _pinch_last_distance > 1.0 and distance > 1.0:
			_apply_zoom(distance / _pinch_last_distance)
		_pinch_last_distance = distance
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		# 双指捏合期间禁掉单指平移（触摸会被引擎同时合成为鼠标事件，否则会边缩放边跑）
		if _active_touches.size() >= 2:
			return
		# 按住鼠标左键拖动 = 平移地图（松开即停）
		if event.button_index == MOUSE_BUTTON_LEFT:
			_pan_dragging = event.pressed
			get_viewport().set_input_as_handled()
			return
		# 滚轮缩放
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_apply_zoom(zoom_step)
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_apply_zoom(1.0 / zoom_step)
				get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and _pan_dragging and map_container != null:
		if _active_touches.size() >= 2:
			return
		map_container.position += event.relative
		_clamp_pan()
		get_viewport().set_input_as_handled()


## 当前两根手指之间的距离（不足两指时返回 0）。
func _pinch_distance() -> float:
	if _active_touches.size() != 2:
		return 0.0
	var points: Array = _active_touches.values()
	return (points[0] as Vector2).distance_to(points[1] as Vector2)


## 每帧工作只在「确实需要」时才跑，否则 _process 会被彻底关掉（零开销）：
##   * 地图还没准备好（贴图 / 迷雾遮罩未就绪）→ 重试
##   * 地图正开着 → 把玩家图标移到玩家当前的地图位置上（只动图标，不动视图）
##   * RADIUS 模式 → 持续探路
## 关图 + ROOM 模式 + 地图已就绪时，本函数永远不会被调用。
func _process(delta: float) -> void:
	if not _map_ready:
		_reveal_retry_timer -= delta
		if _reveal_retry_timer <= 0.0:
			_reveal_retry_timer = 1.0
			_refresh_map()
		return
	if is_open:
		_update_player_icon()
	if enable_fog_of_war and fog_reveal_mode == FogRevealMode.RADIUS:
		_update_reveal_radius()
