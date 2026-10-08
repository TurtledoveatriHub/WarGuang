extends CanvasLayer
class_name SnowFX
## 房间下雪特效（参考蔚蓝：两层视差雪花）。
##
## 用法：把本节点放到**需要下雪的房间场景**里（作为房间根节点的直接子节点即可），
## 它自己会判断「现在是不是轮到本房间」，只在自己房间被加载时下雪、离开时淡出停掉。
##
## 为什么这么控制（回答「何时开何时关」）：
##   * 雪是**屏幕空间**效果（雪花跟着相机走，不会在房间里“卡在墙上”），
##     所以它不该用房间里的世界坐标，而是覆盖整个视口；
##   * 开关的唯一正确判据是「当前房间」——监听 RoomManager.room_loaded，
##     比对 room_id 与父节点名（房间场景根节点名就是房间 ID，如 SnowMountain1）；
##   * 房间被卸载/切走后必须停粒子（可见性 + emitting 一起关），否则每个雪房间都会留一份常驻粒子。
##
## 节点自动创建，不需要在场景里摆粒子节点；想调节只在 Inspector 里改导出参数即可。

## ★ 粒子参数（数量 / 速度 / 缩放 / 透明度 / 发射盒）全部写在其子节点 FarSnow / NearSnow 上，
##   直接在编辑器改、编辑器里就能实时看到效果 —— 本脚本只负责「什么时候下雪」。
##
## 为什么这么控制（回答「何时开何时关」）：
##   * 雪是**屏幕空间**效果（雪花跟着相机走，不会在房间里“卡在墙上”），
##     所以它不该用房间里的世界坐标，而是覆盖整个视口；
##   * 开关的唯一正确判据是「当前房间」——监听 RoomManager.room_loaded，
##     比对 room_id 与父节点名（房间场景根节点名就是房间 ID，如 SnowMountain1）；
##   * 房间被卸载/切走后必须停粒子（可见性 + emitting 一起关），否则每个雪房间都会留一份常驻粒子。

@export_category("整体")
## 本房间的雪显隐过渡时间（秒）
@export var fade_duration: float = 0.6
## 是否受游戏暂停影响（false = 暂停时雪照样下）
@export var pause_aware: bool = true

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


func _ready() -> void:
	layer = 5
	# ★ follow_viewport_enabled 必须关：本节点是屏幕空间覆盖层，
	#   开着的话会被相机再乘一次变换，雪会跟着相机跑到画面外。
	follow_viewport_enabled = false
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
