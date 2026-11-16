# ★ 不要给本脚本（及其子类）加 @tool：编辑器里每帧跑脚本会覆写节点的
#   position / lifetime / 材质参数，导致「参数改了保存又变回去」。
#   区域只需要在运行时工作，编辑器里能改参数比实时预览更重要。
extends Area2D
class_name EnvironmentZoneBase

## 环境区域基类（EnvironmentZone / UpdraftZone 共用）
##
## 负责三件事：
##  1. 区域范围：从自己的 CollisionShape2D 取局部矩形，并按当前全局变换换算世界矩形（不用进出信号）。
##  2. 影响强度：地面/空中系数 × 效果变化系数（**可以是负数**）。
##  3. 效果变化（两个子类共用同一套参数）：
##       - 时间循环：在「variation_amplitude 端点」与「100% 端点」之间往复；
##         每个端点先「持续」variation_hold_time，再用正弦过渡 variation_transition_time 秒切换到另一端点。
##       - 开关控制：接受 Switch 实例（与机关门 MechanismObject 同逻辑：state_changed + is_on()）；
##         开关关闭 = 100%（按参数原样），开关激活 = variation_amplitude，切换过程同样走正弦过渡。
##
## ★ variation_amplitude 的含义（归一化端点值）：
##     1.0  = 完全没有变化（效果恒为 100%）
##     0.0  = 在 0% ~ 100% 之间变化
##    -1.0  = 在 -100% ~ 100% 之间变化（**负值 = 与设置的效果方向相反**）
##     其他值同理外推（例如 -2.0 → -200% ~ 100%，即反向且力度加倍）
##
## ★ 只在运行时工作（不加 @tool）：编辑器里能自由改参数比实时预览更重要。
##
## 子类需要实现：_get_zone_group / _get_zone_label / _is_effect_enabled /
##              _get_base_strength / _get_visual_direction（可选 _is_player_eligible / _zone_ready）。

## 效果变化方式
enum VariationMode {
	TIME_LOOP,   ## 时间循环：在 variation_amplitude 与 100% 两个端点之间往复
	SWITCH,      ## 开关控制：由 Switch 实例把效果从 100% 切到 variation_amplitude
}

@export_category("环境区")
## 是否启用本区域（关闭后完全不参与计算，便于临时对比调试）
@export var zone_enabled: bool = true

@export_category("影响强度")
## 地面上的影响强度（0 = 地面完全不受影响，1 = 与空中相同；地面摩擦更稳时可调小）
@export var ground_scale: float = 1.0
## 空中的影响强度（0~1）
@export var air_scale: float = 1.0

@export_category("效果变化（可选）")
## 是否启用效果变化：关闭 = 所有效果参数恒定 100%
@export var variation_enabled: bool = false
## 变化方式：时间循环（按时间往复）/ 开关控制（由 Switch 实例切换）
@export_enum("时间循环", "开关控制") var variation_mode: int = VariationMode.TIME_LOOP
## 变化的「端点」值（1.0 = 完全不变；0.0 = 0%~100%；-1.0 = -100%~100%，负值即反向；如 -2.0 = -200%~100%）
@export var variation_amplitude: float = 1.0
## 【时间循环】两个端点各自持续的时间（秒）
@export var variation_hold_time: float = 1.5
## 【两种模式通用】端点之间的正弦过渡时长（秒）
@export var variation_transition_time: float = 0.6
## 【时间循环】起始相位（0~1；摆多个区域时可以错开节奏）
@export var variation_phase: float = 0.0
## 【开关控制】驱动本区域的开关（可拖拽多个 Switch，与机关门逻辑一致）
@export var switches: Array[NodePath] = []
## 【开关控制】true = 全部开关都激活才切换；false = 任一开关激活即切换
@export var all_active_required: bool = true

## 碰撞形状节点（= 区域范围）
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

## 形状报错只报一次（否则编辑器里每帧刷屏）
var _shape_error_reported: bool = false
## 开关控制模式：当前过渡进度（0 = 未激活端，1 = 激活端）
var _switch_progress: float = 0.0
## 开关控制模式：过渡目标进度（0 或 1）
var _switch_target: float = 0.0

## 初始化：登记组、缓存矩形、连接开关，并调用子类的 _zone_ready()
func _ready() -> void:
	var group_name: String = _get_zone_group()
	if group_name != "":
		add_to_group(group_name)
	_connect_switches()
	_sync_switch_immediate()
	set_process(variation_enabled and variation_mode == VariationMode.SWITCH)
	_zone_ready()

## 开关控制模式：每帧让过渡进度逼近目标（正弦缓动在 get_variation_scale() 里应用）
func _process(delta: float) -> void:
	if not variation_enabled or variation_mode != VariationMode.SWITCH:
		return
	_switch_target = 1.0 if _evaluate_switches() else 0.0
	var step: float = delta / maxf(variation_transition_time, 0.001)
	_switch_progress = move_toward(_switch_progress, _switch_target, step)

## 连接开关信号（与机关门 MechanismObject 一致：state_changed 信号 + is_on() 查询）
func _connect_switches() -> void:
	for path in switches:
		var sw: Node = get_node_or_null(path)
		if sw == null or not sw.has_signal("state_changed"):
			continue
		var handler: Callable = Callable(self, "_on_switch_state_changed")
		if not sw.is_connected("state_changed", handler):
			sw.state_changed.connect(handler)

## 开关状态变化：只更新目标进度，实际过渡由 _process 推进
func _on_switch_state_changed(_is_on: bool) -> void:
	_switch_target = 1.0 if _evaluate_switches() else 0.0

## 初始化时直接对齐到开关当前状态（不做过渡动画）
func _sync_switch_immediate() -> void:
	_switch_progress = 1.0 if _evaluate_switches() else 0.0
	_switch_target = _switch_progress

## 评估所有开关：全部激活 / 任一激活
func _evaluate_switches() -> bool:
	if switches.is_empty():
		return false
	var active_count: int = 0
	var total: int = 0
	for path in switches:
		var sw: Node = get_node_or_null(path)
		if sw == null or not sw.has_method("is_on"):
			continue
		total += 1
		if bool(sw.is_on()):
			active_count += 1
	if total == 0:
		return false
	if all_active_required:
		return active_count >= total
	return active_count > 0

## 当前「效果变化」的强度系数：
## 1.0 = 完全按参数原样；0.0 = 效果消失；负值 = 与设置的效果方向相反（-1.0 = 完全反向）
func get_variation_scale() -> float:
	if not variation_enabled:
		return 1.0
	if variation_mode == VariationMode.SWITCH:
		## 未激活端 = 100%（按参数原样）；激活端 = variation_amplitude
		var eased: float = (1.0 - cos(clampf(_switch_progress, 0.0, 1.0) * PI)) * 0.5
		return lerpf(1.0, variation_amplitude, eased)
	## 时间循环：低端持续 → 正弦过渡 → 100% 端持续 → 正弦过渡回低端
	var hold: float = maxf(variation_hold_time, 0.0)
	var transition: float = maxf(variation_transition_time, 0.001)
	var cycle: float = hold * 2.0 + transition * 2.0
	var elapsed: float = fposmod(float(Time.get_ticks_msec()) / 1000.0 + variation_phase * cycle, cycle)
	if elapsed < hold:
		return variation_amplitude
	if elapsed < hold + transition:
		var k_up: float = (elapsed - hold) / transition
		return lerpf(variation_amplitude, 1.0, (1.0 - cos(k_up * PI)) * 0.5)
	if elapsed < hold * 2.0 + transition:
		return 1.0
	var k_down: float = (elapsed - hold * 2.0 - transition) / transition
	return lerpf(1.0, variation_amplitude, (1.0 - cos(k_down * PI)) * 0.5)

## 区域的世界矩形（每次调用都按当前形状与变换重算 —— 编辑器里改尺寸 / 挪动也能立刻生效）
func get_zone_world_rect() -> Rect2:
	var rect_local: Rect2 = _compute_zone_local_rect()
	if not rect_local.has_area():
		return Rect2()
	var p1: Vector2 = to_global(rect_local.position)
	var p2: Vector2 = to_global(rect_local.end)
	return Rect2(
		Vector2(minf(p1.x, p2.x), minf(p1.y, p2.y)),
		Vector2(absf(p2.x - p1.x), absf(p2.y - p1.y))
	)

## 形状配置异常时只报一次错（与“不做兜底猜测”的约定一致）
func _report_shape_error(message: String) -> void:
	if _shape_error_reported:
		return
	_shape_error_reported = true
	push_error(message)

## 计算区域的局部矩形；形状缺失 / 类型不支持时 push_error 并返回空矩形
func _compute_zone_local_rect() -> Rect2:
	var label: String = _get_zone_label()
	if collision_shape == null:
		_report_shape_error(label + ": 缺少 CollisionShape2D（区域范围），节点=" + str(get_path()))
		return Rect2()
	var shape: Shape2D = collision_shape.shape
	if shape == null:
		_report_shape_error(label + ": CollisionShape2D 没设 shape（区域范围），节点=" + str(get_path()))
		return Rect2()
	var scale_factor: Vector2 = Vector2(maxf(absf(collision_shape.scale.x), 0.001), maxf(absf(collision_shape.scale.y), 0.001))
	var size: Vector2 = Vector2.ZERO
	if shape is RectangleShape2D:
		size = (shape as RectangleShape2D).size * scale_factor
	elif shape is CircleShape2D:
		var radius: float = (shape as CircleShape2D).radius * maxf(scale_factor.x, scale_factor.y)
		size = Vector2(radius * 2.0, radius * 2.0)
	else:
		_report_shape_error(label + ": 区域范围只支持 RectangleShape2D / CircleShape2D，当前=" + shape.get_class() + "，节点=" + str(get_path()))
		return Rect2()
	var center: Vector2 = collision_shape.position
	return Rect2(center - size * 0.5, size)

## 计算本区域对玩家当前的影响强度（**可为负**：负值 = 与设置的效果方向相反）
## = 地面 / 空中系数 × 效果变化系数
func compute_influence(player: Node) -> float:
	if not zone_enabled or player == null:
		return 0.0
	if not _is_player_eligible(player):
		return 0.0
	var rect: Rect2 = get_zone_world_rect()
	if not rect.has_area() or not rect.has_point(player.global_position):
		return 0.0
	## 地面 / 空中系数
	var surface_scale: float = air_scale
	if player.is_on_floor():
		surface_scale = ground_scale
	var influence: float = clampf(surface_scale, 0.0, 1.0)
	return clampf(influence * get_variation_scale(), -2.0, 2.0)

## 供可视化使用的「100% 基准强度」（用于把当前强度换算成粒子数量比例）
func get_visual_base_strength() -> float:
	return _get_base_strength()

## 表现状态：强度可能为负（效果反向），此时方向也一并翻转，粒子会朝反方向吹
func get_visual_state() -> Dictionary:
	var scale_factor: float = get_variation_scale()
	var direction: Vector2 = _get_visual_direction()
	if scale_factor < 0.0:
		direction = -direction
	var active: bool = zone_enabled and _is_effect_enabled() and not is_zero_approx(scale_factor)
	return {
		"enabled": active,
		"direction": direction,
		"strength": _get_base_strength() * scale_factor,
	}

## ── 子类实现 ────────────────────────────────────────────────
## 区域所属组名（服务按组遍历）
func _get_zone_group() -> String:
	return ""

## 报错信息里使用的名字
func _get_zone_label() -> String:
	return "EnvironmentZoneBase"

## 子类自己的初始化（在基类 _ready 之后调用）
func _zone_ready() -> void:
	pass

## 玩家是否满足本区域的前置条件（例：上升气流要求处于滑翔状态）
func _is_player_eligible(_player: Node) -> bool:
	return true

## 本区域是否具备可表现的效果（例：风场是否启用）
func _is_effect_enabled() -> bool:
	return true

## 基准强度（100% 时的强度数值，用于可视化换算）
func _get_base_strength() -> float:
	return 0.0

## 表现方向（效果变化为负时由基类自动翻转）
func _get_visual_direction() -> Vector2:
	return Vector2.RIGHT
