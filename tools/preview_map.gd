extends SceneTree

## 临时预览工具（验证用，用完即删）：
## 启动 MainGameScene → 标记一批房间已探索 → 打开地图 → 分阶段连拍证据图 → 退出。
## 用法：godot --path <proj> --script res://tools/preview_map.gd

## 要预览的场景
const SCENE_PATH := "res://Scenes/GameScenes/MainGameScene.tscn"
## 进入游戏后先等多少帧
const WAIT_FRAMES_WARMUP := 200
## 每个阶段之间等多少帧
const WAIT_FRAMES_STEP := 120
## 为了看清渲染效果，预览时假装已经探索过这些房间
const PREVIEW_VISITED: Array[String] = [
	"GrassLand1", "GrassLand2", "GrassLand3", "GrassLand4", "GrassLand5",
	"GrassLand6", "GrassLand7", "GrassLand8", "GrassLand9", "GrassLand10",
	"Room1", "SnowMountain1", "SnowMountain2",
]

## 已过帧数
var _frames: int = 0
## 当前阶段
var _stage: int = 0
## 当前阶段开始的帧号
var _stage_start: int = 0

func _initialize() -> void:
	var packed: PackedScene = load(SCENE_PATH)
	if packed == null:
		print("[preview] 场景加载失败")
		quit()
		return
	root.add_child(packed.instantiate())
	print("[preview] MainGameScene 已加入场景树")

## 取视口图像
func _grab() -> Image:
	return root.get_texture().get_image()

## 存全屏图
func _save_full(image: Image, shot_name: String) -> void:
	var err: int = image.save_png("res://tmp_%s.png" % shot_name)
	print("[preview] 全屏图 tmp_%s.png（%dx%d，%s）" % [shot_name, image.get_width(), image.get_height(), error_string(err)])

## 裁出地图窗口区域另存
func _save_window(image: Image, shot_name: String) -> void:
	var map_ui: Node = root.get_node_or_null("MapUI")
	var window: Control = map_ui.get_node_or_null("ContentRoot/MapWindow") if map_ui != null else null
	if window == null:
		print("[preview] 找不到 MapWindow")
		return
	var rect := Rect2i(Vector2i(window.position), Vector2i(window.size))
	var region: Image = image.get_region(rect)
	var err: int = region.save_png("res://tmp_%s.png" % shot_name)
	print("[preview] 窗口图 tmp_%s.png（%dx%d，%s）" % [shot_name, region.get_width(), region.get_height(), error_string(err)])

## 打印地图视图关键数值
func _report_view() -> void:
	var map_ui: Node = root.get_node_or_null("MapUI")
	if map_ui == null:
		return
	var container: Node2D = map_ui.get_node_or_null("ContentRoot/MapWindow/MapContainer")
	var sprite: Sprite2D = map_ui.get_node_or_null("ContentRoot/MapWindow/MapContainer/MapSprite")
	var rough: Node2D = map_ui.get_node_or_null("ContentRoot/MapWindow/MapContainer/RoughMapLayer")
	var icon: Node2D = map_ui.get_node_or_null("ContentRoot/MapWindow/PlayerIcon")
	if container != null:
		print("[preview] container.position = %s｜scale = %s" % [str(container.position), str(container.scale)])
	if sprite != null:
		print("[preview] MapSprite.position = %s｜scale = %s｜贴图 = %s｜可见 = %s" % [
			str(sprite.position), str(sprite.scale),
			str(sprite.texture.get_size()) if sprite.texture != null else "无",
			str(sprite.visible)
		])
	if rough != null:
		var first: Node = rough.get_child(0) if rough.get_child_count() > 0 else null
		print("[preview] 粗糙地图轮廓数量 = %d｜首个宽度 = %s" % [
			rough.get_child_count(),
			str((first as Line2D).width) if first is Line2D else "无"
		])
	if icon != null:
		print("[preview] PlayerIcon.position = %s｜可见 = %s" % [str(icon.position), str(icon.visible)])

## 把迷雾遮罩导出成 PNG（放大 3 倍便于肉眼核对）
func _dump_mask() -> void:
	var map_manager: Node = root.get_node_or_null("MapManager")
	if map_manager == null:
		return
	var reveal: Texture2D = map_manager.call("get_reveal_texture")
	if reveal == null:
		print("[preview] 遮罩为空")
		return
	var image: Image = reveal.get_image()
	if image == null:
		print("[preview] 遮罩取不到图像")
		return
	var white: int = 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).r > 0.5:
				white += 1
	print("[preview] 遮罩 %dx%d，已点亮像素 = %d（占比 %.2f%%）" % [
		image.get_width(), image.get_height(), white,
		100.0 * float(white) / float(image.get_width() * image.get_height())
	])
	var scaled: Image = image.duplicate()
	scaled.resize(image.get_width() * 3, image.get_height() * 3, Image.INTERPOLATE_NEAREST)
	var err: int = scaled.save_png("res://tmp_mask.png")
	print("[preview] 遮罩图 tmp_mask.png（%s）" % error_string(err))

## 进入下一阶段
func _advance(stage: int) -> void:
	_stage = stage
	_stage_start = _frames
	print("[preview] ── 阶段 %d（帧 %d）──" % [stage, _frames])

func _process(_delta: float) -> bool:
	_frames += 1
	var map_ui: Node = root.get_node_or_null("MapUI")

	if _stage == 0 and _frames >= WAIT_FRAMES_WARMUP:
		var map_manager: Node = root.get_node_or_null("MapManager")
		if map_manager != null:
			for room_id: String in PREVIEW_VISITED:
				map_manager.call("mark_room_visited", room_id)
			map_manager.call("open_map")
			print("[preview] 已预置探索房间 %d 个并打开地图" % PREVIEW_VISITED.size())
		_dump_mask()
		_advance(1)
		return false

	if _stage == 1 and _frames - _stage_start >= WAIT_FRAMES_STEP:
		_report_view()
		var image: Image = _grab()
		if image != null:
			_save_full(image, "map_full")
			_save_window(image, "map_window_fog")
		_advance(2)
		return false

	if _stage == 2 and _frames - _stage_start >= WAIT_FRAMES_STEP:
		# 关掉迷雾，单独核对纹理映射
		if map_ui != null:
			map_ui.set("enable_fog_of_war", false)
			map_ui.call("_refresh_map")
			print("[preview] 已关闭战争迷雾")
		_advance(3)
		return false

	if _stage == 3 and _frames - _stage_start >= WAIT_FRAMES_STEP:
		var image: Image = _grab()
		if image != null:
			_save_window(image, "map_window_nofog")
		# 缩小到 0.5 倍，检查「窗口裁剪 + 黑底」是否生效（地图应缩成 256×144 居中，四周纯黑）
		if map_ui != null:
			map_ui.set("_view_zoom", 0.5)
			map_ui.call("_sync_view")
			print("[preview] 已把视野缩放到 0.5")
		_advance(4)
		return false

	if _stage == 4 and _frames - _stage_start >= WAIT_FRAMES_STEP:
		var image: Image = _grab()
		if image != null:
			_save_window(image, "map_window_zoomout")
		return true

	return false
