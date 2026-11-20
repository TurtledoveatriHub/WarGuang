# ★ 不加 @tool（理由见 EnvironmentZoneBase 顶部）：编辑器里跑脚本会覆写节点属性与
#   材质参数，导致「参数改了保存又变回去」。粒子预览不必实时。
extends GPUParticles2D
class_name EnvironmentZoneVisual

## 区域可视化（可选）：把父级区域（EnvironmentZone / UpdraftZone）的方向与强度映射成「气流条纹粒子」
##
## ★ 为什么放在区域场景内部、而不是单独做一个特效场景：
##   方向 / 强度 / 范围 / 变化节奏**全部来自区域自身**。分成两个场景会出现两份需要同步的参数，
##   复制、摆放、改尺寸时极容易漏改一半；做成区域的可选子节点后，区域就是一个完整单位，
##   开关也只有一个（visual_enabled）。
##
## ★ 表现方式的选择（参考空洞骑士 / 蔚蓝的做法）：
##   - 蔚蓝的风场是「大面积拉伸条纹 + 少量粒子」，条纹负责让人看懂风向与范围；
##   - 空洞骑士的上升气流 / 风区也是粒子系统（尘、叶、雪）配合区域，而不是逐帧美术动画。
##   所以这里用**条纹粒子**：竖向条纹贴图（场景里已指定 Assets/Textures/FX/wind_streak.tres）
##   并开启 particle_flag_align_y（贴图 Y 轴对齐速度方向）。
##
## ★ 材质与贴图都**直接放在区域场景里**（ParticleProcessMaterial + 条纹贴图），所以：
##   - 编辑器里不用运行游戏就能看到粒子，也不会再有「未指定 process_material」警告；
##   - 本脚本只负责「按区域状态驱动动态部分」：方向 / 速度 / 生命周期 / 颜色 / 数量比例 / 开关。
##   - 想改贴图形状或基础观感，直接在场景里改材质与贴图即可，不必动脚本。

@export_category("区域可视化")
## 是否启用可视化（关闭 = 完全不发射粒子）
@export var visual_enabled: bool = true
## 粒子速度 = 区域速度 × 该比例
@export var speed_ratio: float = 0.9
## 发射薄片在区域外多远处开始进入（0 = 与 CollisionShape2D 完全对齐）
@export var emit_margin: float = 0.0
## 条纹飞行距离 = 区域在流动方向上的长度 × 该比例（1.0 = 正好穿过整个区域）
@export var travel_ratio: float = 1.0
## 粒子寿命硬上限（秒）。★ 它同时也限定了「粒子最远能飞多远」= 基准速度 × 上限。
## 这里曾经写死 2.0 秒：默认 360×0.9 = 324 px/s，最多只能覆盖 648 px。
## 于是 SnowMountain6 那条 80×160 × scale(4,8) = 320×1280 px 的上升气流，
## 粒子飞到一半就到期消失 —— 玩家滑翔到上半段时风场「看起来没有了」。
## 现在寿命由「区域长度 ÷ 基准速度」直接算出，这个上限只用来兜极端情况。
const MAX_PARTICLE_LIFETIME: float = 30.0
## 风向翻转时最多等多久让旧粒子飞完（等太久等于风场停摆，宁可让极少数旧粒子提前翻向）
const MAX_DIRECTION_SWITCH_WAIT: float = 4.0
## 满强度参考值（用于把强度换算成 amount_ratio）
var _full_strength: float = 120.0
## 运行期构建的粒子材质
var _material: ParticleProcessMaterial = null
## 条纹需要飞行的距离（= 区域在流动方向上的长度）
var _travel_distance: float = 96.0
## 当前发射布局签名（只在区域**尺寸**变化时重置粒子，方向变化不重置）
var _layout_signature: String = ""
## 当前实际生效的表现方向（只有旧粒子全部飞完之后才会切换）
var _active_direction: Vector2 = Vector2.ZERO
## 待切换的目标方向（等旧粒子飞完再应用）
var _pending_direction: Vector2 = Vector2.ZERO
## 距离切换还需要的等待时间（秒）—— 等旧粒子自然飞完
var _switch_wait: float = 0.0

## 初始化：复制一份属于自己的粒子材质（子资源在实例间是共享的！），并铺设发射布局
func _ready() -> void:
	## ★★ 关键：场景里的 ParticleProcessMaterial 子资源在多个实例之间是**共享**的。
	##   不复制的话，两个 EnvironmentZone 会互相覆写方向 / 发射盒 / 速度
	##   （实测：EnvironmentZone2 的变化会把 EnvironmentZone 的粒子也带跑，范围也会错乱）。
	if process_material is ParticleProcessMaterial:
		_material = (process_material as ParticleProcessMaterial).duplicate() as ParticleProcessMaterial
	else:
		_material = ParticleProcessMaterial.new()
	process_material = _material
	## 只设「结构上必须」的两项，其余（缩放 / 颜色 / 抖动）全部交给场景里的材质
	_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_material.particle_flag_align_y = true
	_update_emission_layout(Vector2.RIGHT)
	_full_strength = _read_base_strength()
	amount_ratio = 0.0

## 每帧跟随区域状态：方向 / 速度 / 强度 / 开关
## ★ 方向切换是「两段式」的：
##   ① 需要反向时先**停止发射**，让已经发射的粒子按原方向自然飞完；
##   ② 等旧粒子全部消失（= 一倍生命周期）后，再把方向切到新方向并恢复发射。
##   为什么不直接改 direction：2D 粒子材质的 direction 一改，**已经飞在半路的粒子
##   也会跟着反向**，于是会看到粒子冲出 CollisionShape2D（之前就是这个坑）；
##   也不改 lifetime：改它会让已发射粒子的剩余寿命被拉长，同样会飘出区域。
func _process(delta: float) -> void:
	var state: Dictionary = _read_zone_state()
	## ★ 只在「可见」时才发射：房间被隐藏（切房间但没释放）时不再空转，省性能
	var active: bool = visual_enabled and bool(state.get("enabled", false)) and is_visible_in_tree()
	if not active:
		if emitting:
			emitting = false
		amount_ratio = 0.0
		_pending_direction = Vector2.ZERO
		_switch_wait = 0.0
		_active_direction = Vector2.ZERO
		return
	var direction: Vector2 = state.get("direction", Vector2.RIGHT)
	var strength: float = float(state.get("strength", 0.0))
	if direction == Vector2.ZERO or is_zero_approx(strength):
		if emitting:
			emitting = false
		amount_ratio = 0.0
		return
	if _active_direction == Vector2.ZERO:
		_apply_direction(direction)
	## 已经排队切换，但风向又转回来了：取消切换，继续用原方向发射
	if _pending_direction != Vector2.ZERO and direction.dot(_active_direction) > 0.0:
		_pending_direction = Vector2.ZERO
		_switch_wait = 0.0
	## 需要反向：停止发射，开始等旧粒子飞完
	if _pending_direction == Vector2.ZERO and direction.dot(_active_direction) < 0.0:
		_pending_direction = direction
		_switch_wait = minf(_current_lifetime(), MAX_DIRECTION_SWITCH_WAIT)
		if emitting:
			emitting = false
		amount_ratio = 0.0
	## 等待期间什么都不改（旧粒子正在按原方向飞完）
	if _pending_direction != Vector2.ZERO:
		_switch_wait = maxf(_switch_wait - delta, 0.0)
		if _switch_wait <= 0.0:
			_apply_direction(_pending_direction)
			_pending_direction = Vector2.ZERO
		return
	## —— 正常发射 ——
	var magnitude: float = absf(strength)
	_full_strength = _read_base_strength()
	## 发射布局（薄片位置 / 宽度 / 材质方向）跟随当前生效方向
	_update_emission_layout(_active_direction)
	var speed: float = maxf(magnitude * speed_ratio, 1.0)
	if _material != null:
		_material.initial_velocity_min = speed * 0.85
		_material.initial_velocity_max = speed * 1.15
	lifetime = _current_lifetime()
	amount_ratio = clampf(magnitude / maxf(_full_strength, 0.001), 0.02, 1.0)
	if not emitting:
		emitting = true

## 应用表现方向（挪发射薄片 + 写材质方向）
func _apply_direction(direction: Vector2) -> void:
	_active_direction = direction
	_update_emission_layout(direction)

## 粒子寿命：按「满强度速度」算，保证条纹正好在区域另一端消失
## ★ 不能按当前瞬时强度算：效果变化到接近 0 时速度极小，寿命会被拉成好几秒，
##   粒子就会飘出区域（实测“像寿命被翻倍了一样飞得很远”）。
## ★ 也不能再给寿命一个“够用就行”的小上限：寿命 = 覆盖距离 ÷ 速度，
##   上限一小，长区域的上半段就永远没有粒子（见 MAX_PARTICLE_LIFETIME 的说明）。
func _current_lifetime() -> float:
	var ref_speed: float = maxf(_full_strength * speed_ratio, 1.0)
	var distance: float = maxf(_travel_distance * travel_ratio, 0.0)
	return clampf(distance / ref_speed, 0.05, MAX_PARTICLE_LIFETIME)

## 读取区域的「100% 基准强度」（用于把当前强度折算成粒子数量比例）
func _read_base_strength() -> float:
	var zone: Node = get_parent()
	if zone != null and zone.has_method("get_visual_base_strength"):
		return maxf(float(zone.get_visual_base_strength()), 0.001)
	return maxf(_full_strength, 0.001)

## 重建发射布局（每帧按当前方向重算，但只在**区域尺寸变化**时才重置粒子）
## —— 粒子是贴着上游边缘的一张薄片，于是条纹从区域一端穿到另一端，
##    粒子场范围与 CollisionShape2D 完全一致（旧做法铺满整盒再飞一段 → 必然超出区域）。
## ★ 方向翻转只把薄片挪到另一侧：已经发射的粒子继续按原方向飞完，新粒子才用新方向。
func _update_emission_layout(direction: Vector2) -> void:
	var zone: Node = get_parent()
	if zone == null or _material == null:
		return
	var shape_node: CollisionShape2D = zone.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return
	var size: Vector2 = _shape_size(shape_node)
	if size == Vector2.ZERO:
		return
	var axis: Vector2 = direction if direction != Vector2.ZERO else Vector2.RIGHT
	axis = axis.normalized()
	## ★ 不旋转粒子节点：薄片用「轴对齐」表达上游边缘 ——
	##   横向风 → 竖直的一条薄片（贴左 / 右边缘）；竖直风 → 水平的一条（贴上 / 下边缘）。
	##   节点不旋转、方向只由材质的 direction 决定，行为最可预测。
	var slab_half: float = 2.0
	var horizontal_flow: bool = absf(axis.x) >= absf(axis.y)
	var slab_position: Vector2 = shape_node.position
	var extents: Vector3 = Vector3(slab_half, maxf(size.y * 0.5, 1.0), 1.0)
	if horizontal_flow:
		_travel_distance = maxf(size.x, 16.0)
		slab_position.x += (1.0 if axis.x < 0.0 else -1.0) * (_travel_distance * 0.5 - slab_half - emit_margin)
		extents = Vector3(slab_half, maxf(size.y * 0.5, 1.0), 1.0)
	else:
		_travel_distance = maxf(size.y, 16.0)
		slab_position.y += (1.0 if axis.y < 0.0 else -1.0) * (_travel_distance * 0.5 - slab_half - emit_margin)
		extents = Vector3(maxf(size.x * 0.5, 1.0), slab_half, 1.0)
	var signature: String = str(size)
	rotation = 0.0
	position = slab_position
	## ★★ 必须显式设置 visibility_rect：GPUParticles2D **只绘制落在这个矩形里的粒子**，
	##   默认值只有 200×200（且是节点局部坐标，会跟着节点缩放一起变）。
	##   区域一拉长，上半段的粒子就被整个裁掉 —— 表现就是「玩家还在风场里，粒子却凭空消失」。
	##   实测：160 高的区域只有 102 px 有粒子（64%），scale(4,8) 的 1280 高区域只有 816 px。
	##   这里让矩形覆盖整个区域再各留 128 px 余量（兜住 align_y 旋转后的条纹）。
	var rect_center: Vector2 = shape_node.position - position
	var margin: Vector2 = Vector2(128.0, 128.0)
	visibility_rect = Rect2(rect_center - size * 0.5 - margin, size + margin * 2.0)
	_material.emission_box_extents = extents
	_material.direction = Vector3(axis.x, axis.y, 0.0)
	## ★ 只有「区域尺寸」变了才重置：尺寸一变，旧粒子的飞行距离就不对了。
	##   方向翻转只是把上游边缘挪到另一侧，**不清空已有粒子** —— 已经发射的粒子继续
	##   按原方向飞完，新发射的粒子才用新方向，所以风向变化不会是“整片瞬间翻面”。
	if signature == _layout_signature:
		return
	_layout_signature = signature
	restart()

## 读取形状尺寸（含形状节点缩放）
func _shape_size(shape_node: CollisionShape2D) -> Vector2:
	if shape_node.shape is RectangleShape2D:
		return (shape_node.shape as RectangleShape2D).size * shape_node.scale.abs()
	if shape_node.shape is CircleShape2D:
		var radius: float = (shape_node.shape as CircleShape2D).radius * maxf(absf(shape_node.scale.x), absf(shape_node.scale.y))
		return Vector2(radius * 2.0, radius * 2.0)
	return Vector2.ZERO

## 读取父级区域的表现状态（父级需实现 get_visual_state()）
func _read_zone_state() -> Dictionary:
	var zone: Node = get_parent()
	if zone == null or not zone.has_method("get_visual_state"):
		return {"enabled": false, "direction": Vector2.ZERO, "strength": 0.0}
	return zone.get_visual_state()
