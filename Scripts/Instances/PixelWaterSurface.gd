@tool
extends Area2D
class_name PixelWaterSurface

## 像素风水面（瓦片贴图版，对标蔚蓝）
##
## ★ 结构（全部在场景里看得见、可编辑，没有任何自定义着色器）：
##   WaterVisuals/WaterBody        水体：body_texture 横向平铺，纵向把「浅 → 深」色阶拉伸到整个水深
##   WaterVisuals/WaterSurfaceFar  远层水线：同一张条带贴图，滚动更慢、位置更低、半透明 → 层次感
##   WaterVisuals/WaterSurface     近层水线：surface_texture 贴在水面线上，横向滚动 = 波动
##   WaterVisuals/Splash           入水水花（一次性粒子）
##   CollisionShape2D              水面范围（由 water_width / water_depth 自动同步）
##   SplashSound                   入水音效（AudioStreamPlayer2D，记得给它指定 stream）
##
## ★ 尺寸怎么调：改 **water_width / water_depth**（导出参数），不要用 scale。
##   scale 会把贴图一起拉伸；改尺寸则按「1 纹素 = 1 像素」重新拼接瓦片。
##
## ★ 贴图替换：选中 WaterBody / WaterSurface / WaterSurfaceFar 换 texture 即可，
##   只要**能横向平铺**就不用改代码（生成器：tools/generate_water_textures.gd）。
##
## ★ 物理与判定：水中重力/速度乘数、浸没比例判定、入水音效与水花、入水刷新二段跳/冲刺。

## 开启动画所需的最低特效等级（Global.EffectLevel：低=0 / 中=1 / 高=2 / 超高=3）
const ANIMATED_MIN_LEVEL: int = 1

@export_category("尺寸（改这里，不要用 scale）")
## 水面宽度（像素）。贴图会按瓦片左右拼接，不会被拉伸
@export var water_width: float = 160.0:
	set(value):
		water_width = maxf(value, 8.0)
		_apply_size()
## 水面高度（像素）。决定水体范围与「浅 → 深」色阶的拉伸高度
@export var water_depth: float = 160.0:
	set(value):
		water_depth = maxf(value, 8.0)
		_apply_size()

@export_category("水面")
## 水面线相对水面顶部的偏移（正数 = 下移；一般保持 0）
@export var surface_offset_y: float = 0.0
## 近层水线横向滚动速度（像素/秒；0 = 静止）
@export var surface_scroll_speed: float = 6.0
## 远层水线速度比例（0 = 不要远层；1 = 与近层同速）
@export var far_layer_speed_ratio: float = 0.45
## 远层水线相对水面线的下移量（像素）
@export var far_layer_offset_y: float = 3.0
## 水体精灵相对水面线的纵向偏移（像素；正数 = 往下）。
## 水面条带高度是 6px，所以 0~5 之间都不会露缝，想微调水体位置就改它
@export var body_offset_y: float = 0.0
## 水体横向滚动速度（像素/秒；0 = 静止）
@export var body_scroll_speed: float = 0.0
## 水位上下呼吸幅度（像素；1 = 一个像素的起伏）
@export var bob_amplitude: float = 1.0
## 水位呼吸速度（弧度/秒）
@export var bob_speed: float = 1.2

@export_category("物理效果设置")
## 水中水平速度乘数
@export var water_horizontal_multiplier: float = 0.5
## 水中垂直速度乘数
@export var water_vertical_multiplier: float = 0.3
## 水中重力乘数
@export var water_gravity_multiplier: float = 0.6
## 水中最大下落速度乘数
@export var water_max_fall_multiplier: float = 0.3
## 水中加速度乘数
@export var water_acceleration_multiplier: float = 0.5

@export_category("水中下潜（按住下方向键）")
## 按住下方向键时，水中「最大下落速度乘数」过渡到的目标值
## （大于 water_max_fall_multiplier = 下潜更快；小于 = 下潜更慢）
@export var water_down_max_fall_multiplier: float = 0.8
## 该过渡的速度（乘数单位/秒，越大越快）
## ★ 用「每秒变化量」而不是固定过渡时间：按住/松开反复切换时不会出现跳变或回弹
@export var water_max_fall_transition_speed: float = 1.5

@export_category("浸入判定")
## 浸入比例阈值（0.8 = 物体 80% 体积浸入才判定为完全浸没）
@export var submersion_threshold: float = 0.8

@export_category("音效 / 水花")
## 是否启用入水音效
@export var enable_sound: bool = true
## 是否启用入水水花
@export var enable_splash: bool = true

@export_category("性能 / 特效等级")
## 跟随 Global 的特效等级（低特效档 = 水面静止不动，省一点功耗）
@export var follow_effect_level: bool = true

## 碰撞形状节点（水面范围，尺寸由 water_width / water_depth 同步）
@onready var collision_shape_node: CollisionShape2D = $CollisionShape2D
## 水体精灵
@onready var body_sprite: Sprite2D = get_node_or_null("WaterVisuals/WaterBody") as Sprite2D
## 近层水线精灵
@onready var surface_sprite: Sprite2D = get_node_or_null("WaterVisuals/WaterSurface") as Sprite2D
## 远层水线精灵（可选）
@onready var far_sprite: Sprite2D = get_node_or_null("WaterVisuals/WaterSurfaceFar") as Sprite2D
## 入水水花粒子（可选）
@onready var splash_particles: GPUParticles2D = get_node_or_null("WaterVisuals/Splash") as GPUParticles2D
## 入水音效
@onready var sound_player: AudioStreamPlayer2D = get_node_or_null("SplashSound") as AudioStreamPlayer2D

## 水面范围（= water_width × water_depth，不含节点缩放）
var _rect_size: Vector2 = Vector2.ZERO
## 水面线的局部 y（= 顶点 + surface_offset_y）
var _surface_y: float = 0.0
## 时钟（秒）
var _time: float = 0.0
## 近层水线累计横向滚动（像素）
var _surface_scroll: float = 0.0
## 水体累计横向滚动（像素）
var _body_scroll: float = 0.0
## 是否播放动画（低特效档关闭）
var _animate: bool = true
## 当前实际生效的水中最大下落速度乘数（在「默认 ↔ 按住下键」之间过渡）
var _current_max_fall_mul: float = 0.3
## 水中物体（物体 → true）
var _objects_in_water: Dictionary = {}
## 已经刷新过能力的水中物体（单次触碰只刷新一次）
var _refreshed_objects: Array = []
## 是否已连上 Global 的特效等级信号（退出时据此决定要不要断开）
var _effect_level_connected: bool = false
## 是否已经报过「贴图缺失」（只报一次，避免刷屏）
var _texture_warning_reported: bool = false

## 初始化：摆好水面瓦片、按特效等级决定是否播放动画
func _ready() -> void:
	## 加入组：便于运行时/调试工具直接抓到这个水面（例：实时调参、截图核对）
	add_to_group("water_surface")
	_ensure_widgets()
	_apply_size()
	_current_max_fall_mul = water_max_fall_multiplier
	_apply_quality_level(_read_effect_level())
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	## ★ 用字符串形式 connect：编辑器 / 导入扫描时 autoload 可能只是裸 Node，
	##   直接点 Global.effect_level_changed 会报 "Invalid access to property or key ..."。
	if Global != null and Global.has_signal("effect_level_changed"):
		Global.connect("effect_level_changed", Callable(self, "_apply_quality_level"))
		_effect_level_connected = true

## 物理帧：推进时钟与滚动，刷新滚动量与水中物体
func _physics_process(delta: float) -> void:
	if _animate:
		_time += delta
		_surface_scroll += surface_scroll_speed * delta
		_body_scroll += body_scroll_speed * delta
	_apply_scroll()
	_update_objects(delta)

## 统一初始化三个精灵的显示方式（横向平铺 + 左上角定位）
func _ensure_widgets() -> void:
	for sprite in [body_sprite, surface_sprite, far_sprite]:
		if sprite == null:
			continue
		sprite.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		sprite.centered = false
	if far_sprite != null and far_layer_speed_ratio <= 0.0:
		far_sprite.visible = false
	if splash_particles != null:
		## 水花只在入水时手动触发
		splash_particles.emitting = false

## 读取 Global 的当前特效等级（用 get() 避免 autoload 未就绪时报错）
func _read_effect_level() -> int:
	if Global == null:
		return ANIMATED_MIN_LEVEL
	var value: Variant = Global.get("effect_level")
	if value == null:
		return ANIMATED_MIN_LEVEL
	return int(value)

## 应用特效等级（Global.EffectLevel：低 / 中 / 高 / 超高）
## 低档 = 水面完全静止（不滚动、不呼吸），省一点功耗
func _apply_quality_level(level: int) -> void:
	_animate = (not follow_effect_level) or level >= ANIMATED_MIN_LEVEL
	_apply_scroll()

## 按 water_width / water_depth 重新摆放瓦片、同步碰撞框
func _apply_size() -> void:
	if not is_inside_tree() or surface_sprite == null:
		return
	_rect_size = Vector2(maxf(water_width, 8.0), maxf(water_depth, 8.0))
	_surface_y = -_rect_size.y * 0.5 + surface_offset_y
	_sync_collision_shape()
	var left: float = -_rect_size.x * 0.5
	## 水体：从水面线往下，纵向把色阶拉伸到整个水深（不会重复出现浅色带）
	if body_sprite != null:
		var depth: float = _rect_size.y * 0.5 - _surface_y
		body_sprite.position = Vector2(left, _surface_y + body_offset_y)
		body_sprite.scale = Vector2(1.0, maxf(depth, 1.0) / maxf(_sprite_texture_height(body_sprite, 64.0), 1.0))
	if surface_sprite.texture == null or (body_sprite != null and body_sprite.texture == null):
		_report_texture_warning()
	_apply_scroll()

## 把 CollisionShape2D 的尺寸同步成 water_width × water_depth
## ★ 只在尺寸不一致时才 duplicate 一份自己的形状：
##   形状子资源在场景里是共享的，直接改会污染其它实例。
func _sync_collision_shape() -> void:
	if collision_shape_node == null:
		return
	var shape_res: RectangleShape2D = collision_shape_node.shape as RectangleShape2D
	if shape_res == null:
		push_error("PixelWaterSurface: 需要 RectangleShape2D 作为水面范围，节点=" + str(get_path()))
		return
	if shape_res.size == _rect_size:
		return
	var own: RectangleShape2D = shape_res.duplicate() as RectangleShape2D
	own.size = _rect_size
	collision_shape_node.shape = own

## 把滚动量与水位呼吸写进 region_rect / 位置
func _apply_scroll() -> void:
	var scroll_s: float = _surface_scroll if _animate else 0.0
	var scroll_b: float = _body_scroll if _animate else 0.0
	var bob: float = 0.0
	if _animate and bob_amplitude > 0.0:
		## 量化到整数像素：像素风里水位就该是「一像素一像素」地呼吸
		bob = roundf(sin(_time * bob_speed) * bob_amplitude)
	var left: float = -_rect_size.x * 0.5
	if body_sprite != null:
		body_sprite.region_rect = Rect2(scroll_b, 0.0, _rect_size.x, _sprite_texture_height(body_sprite, 64.0))
	if far_sprite != null and far_sprite.visible:
		## 远层：更慢 + 更低 + 半透明 → 读起来像后面还有一层水线
		far_sprite.region_rect = Rect2(scroll_s * far_layer_speed_ratio, 0.0, _rect_size.x, _sprite_texture_height(far_sprite, 6.0))
		far_sprite.position = Vector2(left, _surface_y + far_layer_offset_y + bob)
	if surface_sprite != null:
		surface_sprite.region_rect = Rect2(scroll_s, 0.0, _rect_size.x, _sprite_texture_height(surface_sprite, 6.0))
		surface_sprite.position = Vector2(left, _surface_y + bob)

## 读精灵上贴图的高度（0 = 没贴图）
func _sprite_texture_height(sprite: Sprite2D, fallback: float) -> float:
	if sprite == null or sprite.texture == null:
		return fallback
	return maxf(float(sprite.texture.get_height()), 1.0)

## 贴图缺失只报一次（不静默兜底：缺图就是缺图）
func _report_texture_warning() -> void:
	if _texture_warning_reported:
		return
	_texture_warning_reported = true
	push_warning("PixelWaterSurface: WaterSurface / WaterBody 上还没放贴图（节点=" + str(get_path()) + "），水面会是空白的。")

## 逐帧更新水中物体：上报浸没状态 + 推进「按住下键」的下潜过渡
func _update_objects(delta: float) -> void:
	for obj in _objects_in_water.keys():
		if not is_instance_valid(obj):
			_objects_in_water.erase(obj)
			_refreshed_objects.erase(obj)
			continue
		## 上报「是否浸没」：气泡消耗与溺水伤害都在 PlayerBreathService 里统一处理
		if obj.has_method("set_submerged_in_water"):
			obj.set_submerged_in_water(is_fully_submerged(obj))
		if obj.is_in_group("player"):
			_update_player_sink(obj, delta)

## 玩家按住下方向键时，把「最大下落乘数」平稳过渡到更快的值；松开再过渡回来
## ★ 过渡量 = 速度 × delta，所以中途反复按下/松开也不会跳变
func _update_player_sink(player: Node, delta: float) -> void:
	var target: float = water_down_max_fall_multiplier if _is_down_pressed(player) else water_max_fall_multiplier
	_current_max_fall_mul = move_toward(_current_max_fall_mul, target, water_max_fall_transition_speed * delta)
	_apply_player_multipliers(player)

## 玩家是否正按住下方向键（操作锁定时不算）
func _is_down_pressed(player: Node) -> bool:
	if player.get("is_control_locked") == true:
		return false
	return Input.is_action_pressed("down")

## 把当前的水中乘数写给玩家
func _apply_player_multipliers(player: Node) -> void:
	if not player.has_method("set_environment_multipliers"):
		return
	player.set_environment_multipliers(
		water_horizontal_multiplier,
		water_vertical_multiplier,
		water_gravity_multiplier,
		_current_max_fall_mul,
		water_acceleration_multiplier
	)

## 处理物体进入水面
func _on_body_entered(body: Node2D) -> void:
	if not is_water_interactive(body):
		return
	_objects_in_water[body] = true
	## 入水瞬间刷新二段跳与冲刺（单次触碰只刷新一次）
	if not _refreshed_objects.has(body):
		refresh_water_abilities_for(body)
		_refreshed_objects.append(body)
	## 上报给玩家的水下呼吸系统（气泡与溺水伤害由 PlayerBreathService 统一处理）
	if body.has_method("set_in_water"):
		body.set_in_water(true)
	_play_entry_effects(body)
	apply_water_environment(body)

## 入水表现：水花 + 音效
func _play_entry_effects(body: Node2D) -> void:
	if enable_splash and splash_particles != null:
		## 水花从「入水点正上方的那段水面线」喷出来
		splash_particles.global_position = Vector2(body.global_position.x, global_position.y + _surface_y)
		splash_particles.restart()
		splash_particles.emitting = true
	if enable_sound and sound_player != null and sound_player.stream != null:
		sound_player.play()

## 处理物体离开水面
func _on_body_exited(body: Node2D) -> void:
	if not _objects_in_water.has(body):
		return
	_objects_in_water.erase(body)
	clear_water_environment(body)
	if body.has_method("set_in_water"):
		body.set_in_water(false)
	_refreshed_objects.erase(body)

## 应用水的环境效果（重力 / 速度乘数）
func apply_water_environment(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return
	## 每次入水都从「默认最大下落乘数」重新开始，避免上一次按着下键的残留
	_current_max_fall_mul = water_max_fall_multiplier
	_apply_player_multipliers(body)

## 清除水的环境效果
func clear_water_environment(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return
	_current_max_fall_mul = water_max_fall_multiplier
	if body.has_method("set_environment_multipliers"):
		body.set_environment_multipliers(1.0, 1.0, 1.0, 1.0, 1.0)

## 是否可与水面互动（需要有碰撞形状）
func is_water_interactive(body: Node2D) -> bool:
	return body != null and body.get_node_or_null("CollisionShape2D") != null

## 刷新水中能力（跳跃 / 冲刺）
func refresh_water_abilities_for(body: Node2D) -> void:
	if body.has_method("refresh_jump"):
		body.refresh_jump()
	if body.has_method("refresh_dash"):
		body.refresh_dash()
	## 与旧版一致：入水后允许再次使用二段跳，并禁止滑翔
	if body is CharacterBody2D:
		body.jump_count = 0
		body.has_double_jumped = false
		body.can_double_jump = true
		body.is_double_jump_holding = false
		body.can_glide = false

## 检查物体是否达到「完全浸没」阈值（用矩形重叠比例判定）
func is_fully_submerged(body: Node2D) -> bool:
	if _rect_size == Vector2.ZERO:
		return false
	## 世界矩形 = 局部尺寸 × 节点缩放
	var world_size: Vector2 = _rect_size * scale.abs()
	var water_rect: Rect2 = Rect2(global_position - world_size * 0.5, world_size)
	var player_collision: Node = body.get_node_or_null("CollisionShape2D")
	if player_collision == null or not (player_collision is CollisionShape2D):
		return false
	var shape: Shape2D = (player_collision as CollisionShape2D).shape
	if shape == null:
		return false
	var player_rect: Rect2 = Rect2()
	if shape is RectangleShape2D:
		var half_size: Vector2 = (shape as RectangleShape2D).size * 0.5
		player_rect = Rect2(body.global_position - half_size, (shape as RectangleShape2D).size)
	elif shape is CircleShape2D:
		var radius: float = (shape as CircleShape2D).radius
		player_rect = Rect2(body.global_position - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0))
	else:
		return false
	var overlap: Rect2 = player_rect.intersection(water_rect)
	if overlap.size.x <= 0.0 or overlap.size.y <= 0.0:
		return false
	var player_area: float = player_rect.size.x * player_rect.size.y
	if player_area <= 0.0:
		return false
	var ratio: float = (overlap.size.x * overlap.size.y) / player_area
	return ratio >= submersion_threshold

## 退出场景时断开特效等级信号
func _exit_tree() -> void:
	if not _effect_level_connected or Global == null:
		return
	if Global.has_signal("effect_level_changed"):
		Global.disconnect("effect_level_changed", Callable(self, "_apply_quality_level"))
	_effect_level_connected = false
