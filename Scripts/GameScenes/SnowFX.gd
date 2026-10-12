extends Node2D
class_name SnowFX
## 房间下雪特效（两层视差雪花，世界空间）。
##
## 用法：把本节点放到**需要下雪的房间场景**里（作为房间根节点的直接子节点即可），
## 它自己会判断「现在是不是轮到本房间」，只在自己房间被加载时下雪、离开时淡出停掉。
##
## ★ 为什么是世界空间，而不是屏幕空间（本项目踩过的坑）：
##   * 雪放在屏幕空间（CanvasLayer）时，整片雪会「粘在相机上」—— 相机一移动，
##     连已经落到半空的雪花都跟着一起平移，看起来像贴在镜头上；
##   * 本脚本的做法：发射器（本节点）每帧跟到「相机视野正上方」，保证雪总是从画面上方生成；
##     而粒子用 local_coords = false 发到世界空间，所以**已经生成的雪花不再跟着相机走**，
##     相机会自然地从它们中间穿过去 —— 于「生成位置跟随相机」与「已生成的雪花固定在房里」兼得。
##   * 开关的唯一正确判据是「当前房间」——监听 RoomManager.room_loaded，
##     比对 room_id 与父节点名（房间场景根节点名就是房间 ID，如 SnowMountain1）；
##   * 房间被卸载/切走后必须停粒子（可见性 + emitting 一起关），否则每个雪房间都会留一份常驻粒子。
##
## 节点自动创建，不需要在场景里摆粒子节点；想调节只在 Inspector 里改导出参数即可。

## ★ 粒子参数（数量 / 速度 / 缩放 / 透明度 / 发射盒）全部写在其子节点 FarSnow / NearSnow 上，
##   直接在编辑器改、编辑器里就能实时看到效果 —— 本脚本只负责「什么时候下雪」与「发射器跟相机走」。

@export_category("整体")
## 本房间的雪显隐过渡时间（秒）
@export var fade_duration: float = 0.6
## 是否受游戏暂停影响（false = 暂停时雪照样下）
@export var pause_aware: bool = true

@export_category("发射器跟随相机")
## 发射带位于画面上边缘之上多少**屏幕像素**（与世界缩放无关，不同缩放下手感一致）
@export var screen_top_margin: float = 32.0
## 世界绘制层级：必须高于房间瓦片（部分瓦片层用到 20）与玩家节点，且低于所有 UI
@export var snow_z_index: int = 100

## 远景粒子（小、淡、慢；参数在节点上）
@onready var far_particles: CPUParticles2D = get_node_or_null("FarSnow") as CPUParticles2D
## 近景粒子（大、亮、快；参数在节点上）
@onready var near_particles: CPUParticles2D = get_node_or_null("NearSnow") as CPUParticles2D

## 本节点所属房间的 ID（取父节点名，如 SnowMountain1）
var _room_id: String = ""
## 当前是否应该在雪（由 room_loaded 决定）
var _should_snow: bool = false
## 显隐过渡 Tween
var _fade_tween: Tween = null


## 初始化：确定所属房间、连接房间切换信号并同步一次当前状态。
func _ready() -> void:
	# 世界空间绘制层级：高过房间瓦片与玩家，低于 UI
	z_index = snow_z_index
	_room_id = _resolve_room_id()
	if not pause_aware:
		if far_particles != null:
			far_particles.process_mode = Node.PROCESS_MODE_ALWAYS
		if near_particles != null:
			near_particles.process_mode = Node.PROCESS_MODE_ALWAYS
	_apply_visible_immediate(false)
	var room_manager: Node = get_node_or_null("/root/RoomManager")
	if room_manager != null and room_manager.has_signal("room_loaded"):
		room_manager.room_loaded.connect(_on_room_loaded)
		# 场景可能是在房间已经加载完之后才实例化的：主动同步一次
		_on_room_loaded(str(room_manager.get("current_room")), "")


## 每帧把发射器搬到相机视野正上方（只在应该下雪时做，避免无谓运算）。
func _process(_delta: float) -> void:
	_update_emitter_follow_camera()


## 把发射器摆到「相机视野正上方」，并抵消相机缩放。
## 缩放说明：粒子参数是按屏幕像素调的，而这里是世界空间；把本节点缩放设成 1/zoom 之后，
## 粒子在世界里的大小 × 缩放 = 屏幕上的大小，与原来屏幕空间的表现完全一致；
## 发射盒（子节点的 emission_rect_extents）也随之内缩，仍正好覆盖整个可视宽度。
func _update_emitter_follow_camera() -> void:
	if not _should_snow:
		return
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return
	var camera: Camera2D = viewport.get_camera_2d()
	if camera == null:
		return
	var zoom: float = maxf(maxf(camera.zoom.x, camera.zoom.y), 0.01)
	var visible_size: Vector2 = viewport.get_visible_rect().size
	scale = Vector2.ONE / zoom
	global_position = camera.global_position + Vector2(0.0, (-visible_size.y * 0.5 - screen_top_margin) / zoom)


## 取所属房间 ID：房间场景的根节点名就是房间 ID（如 SnowMountain1）
func _resolve_room_id() -> String:
	var parent: Node = get_parent()
	if parent != null:
		return str(parent.name)
	return ""


## 房间切换：只有「当前房间 == 本节点所属房间」时才下雪
func _on_room_loaded(room_id: String, _previous_room: String = "") -> void:
	_should_snow = room_id != "" and room_id == _room_id
	if _should_snow:
		_apply_visible_with_fade(true)
	else:
		_apply_visible_with_fade(false)


## 淡入 / 淡出：淡出结束后真的停掉粒子（省性能）
func _apply_visible_with_fade(snowing: bool) -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	if snowing:
		# 先就位再开火：否则第一批雪花会生成在房间原点（画面外），要等一个生命周期才补上
		_update_emitter_follow_camera()
		_set_emitting(true)
	var target_alpha: float = 1.0 if snowing else 0.0
	if fade_duration <= 0.0:
		_apply_alpha(target_alpha)
		_set_emitting(snowing)
		return
	_fade_tween = create_tween()
	_fade_tween.set_parallel(true)
	if far_particles != null:
		_fade_tween.tween_property(far_particles, "modulate:a", target_alpha, fade_duration)
	if near_particles != null:
		_fade_tween.tween_property(near_particles, "modulate:a", target_alpha, fade_duration)
	_fade_tween.chain().tween_callback(_on_fade_finished.bind(snowing))


## 淡出结束 → 停粒子；淡入结束 → 保持发射
func _on_fade_finished(snowing: bool) -> void:
	_set_emitting(snowing)


## 立即设置可见度（入场用，不播动画）
func _apply_visible_immediate(snowing: bool) -> void:
	_set_emitting(snowing)
	_apply_alpha(1.0 if snowing else 0.0)


## 设置两层粒子的 alpha
func _apply_alpha(alpha: float) -> void:
	if far_particles != null:
		far_particles.modulate = Color(1.0, 1.0, 1.0, alpha)
	if near_particles != null:
		near_particles.modulate = Color(1.0, 1.0, 1.0, alpha)


## 开关粒子的发射（关的时候连可见性一起关，避免空转）
func _set_emitting(enabled: bool) -> void:
	for particles: CPUParticles2D in [far_particles, near_particles]:
		if particles == null:
			continue
		particles.emitting = enabled
		particles.visible = enabled


## 外部查询：本房间现在是否应该在雪
func is_snowing() -> bool:
	return _should_snow
