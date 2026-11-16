extends CanvasLayer
class_name PlayerUI

## ============================================
## PlayerUI - 玩家 UI 管理器
## ============================================

## 血量单位场景（在 Inspector 中拖拽 HealthUnit.tscn）
@export var health_unit_scene: PackedScene

## 气泡单位场景（在 Inspector 中拖拽 BubbleUnit.tscn）
@export var bubble_unit_scene: PackedScene


## 游戏设置场景（在 Inspector 中拖拽 GameSettingScene.tscn）
@export var game_setting_scene: PackedScene

var max_health: int = 3
var current_health: int = 3
var health_units: Array = []

## 信号定义
signal health_changed(new_health)
signal max_health_changed(new_max_health)
signal player_died()

## 节点引用
@onready var health_container = $HealthContainer
## 气泡行容器（场景里摆好的节点，对标 HealthContainer）
@onready var bubble_container = $BubbleContainer
@onready var coin_container = $CoinContainer
@onready var coin_label = $CoinContainer/CoinLabel
@onready var coin_change_label = $CoinContainer/CoinChangeLabel
@onready var game_setting_button = $PlayerIcon

## ── 水下气泡（气泡 / 溺水系统；结构完全对标 HealthContainer + HealthUnit） ──
## 水下渐晕复用受伤效果的着色器 → 观感一致、并且可以同时叠加
const VIGNETTE_SHADER_PATH: String = "res://Assets/Shaders/VignetteEffect.gdshader"
@export_category("水下气泡（对标 HealthContainer / HealthUnit）")
## 第 1 个气泡的 x / y（对标 health_unit_start_x / health_unit_y）
@export var bubble_unit_start_x: float = 0.0
@export var bubble_unit_y: float = 0.0
## 气泡横向间距（像素）
@export var bubble_unit_spacing: float = 40.0
## 气泡缩放（对标 HealthUnit 的 scale = Vector2(2, 2)）
@export var bubble_unit_scale: Vector2 = Vector2(2.0, 2.0)

@export_category("水下屏幕滤镜（复用受伤渐晕 shader，可叠加）")
## 水下渐晕颜色（alpha 越大边缘越浓）
@export var water_tint_color: Color = Color(0.08, 0.30, 0.70, 0.72)
## 水下渐晕基础强度（屏幕边缘浓度）
@export var water_vignette_intensity: float = 0.55
## 气泡快耗尽时的额外强度
@export var water_vignette_danger_extra: float = 0.45
## 渐晕内圈半径（越大中心越干净）
@export var water_vignette_inner_radius: float = 0.35
## 渐晕外圈半径
@export var water_vignette_outer_radius: float = 1.0
## 进水 / 出水时滤镜淡入淡出的时间（秒；0 = 瞬间开关，不推荐）
@export var water_tint_fade_time: float = 0.25
## 低气泡（只剩 1 个 / 已耗尽）时的提示音（留空 = 静音）
@export var bubble_warning_sound: AudioStream

## 气泡单位列表（对标 health_units）
var bubble_units: Array = []
## 上一次显示的气泡数量（用于判断哪个气泡刚被消耗 → 播破裂动画）
var _bubble_last_count: int = -1
## 运行时创建的水色滤镜
var _water_tint: ColorRect = null
## 水色滤镜的「目标强度」（由 set_water_tint 写入）
var _water_tint_target: float = 0.0
## 水色滤镜的「当前显示强度」（每帧向目标过渡，做出进出水过渡）
var _water_tint_current: float = 0.0
## 低气泡提示：呼吸缩放 Tween 与提示音播放器
var _bubble_pulse: Tween = null
var _warning_player: AudioStreamPlayer = null

## 游戏设置实例引用
var game_setting_instance: Node = null

## 血量布局参数
@export_category("血量 UI 布局设置")
## 血量单位之间的水平间距
@export var health_unit_spacing: float = 0.0
## 第一个血量单位的 X 坐标
@export var health_unit_start_x: float = 0.0
## 所有血量单位的 Y 坐标
@export var health_unit_y: float = 0.0

## 钱币动画设置
@export_category("钱币动画设置")
## 获得钱币后延迟多少秒开始递增
@export var coin_increment_delay: float = 1.5

## 钱币动画结束后等待多少秒开始淡出
@export var coin_hide_delay: float = 2.0
## 钱币淡入淡出动画的持续时间（秒）
@export var coin_fade_duration: float = 0.5
## 钱币动画变化间隔时间（≤10 个时的间隔）
@export var coin_change_interval_slow: float = 0.2
## 钱币动画变化间隔时间（≤100 个时的间隔）
@export var coin_change_interval_mod: float = 0.05
## 钱币动画变化间隔时间（>100 个时的间隔）
@export var coin_change_interval_fast: float = 0.02

## 钱币系统相关变量
var current_display_coins: int = 0
var coin_change_amount: int = 0
var coin_visible: bool = false
var coin_hide_timer: float = 0.0
var coin_tween: Tween
var coin_delay_timer: float = 0.0
var is_waiting_for_increment: bool = false
var is_increasing: bool = false
var is_animating: bool = false

func _ready():
	initialize_health_display()
	initialize_coin_display()
	add_to_group("player_ui")
	
	# 连接信号
	game_setting_button.pressed.connect(_open_game_setting_menu)
	Global.player_max_health_changed.connect(_on_global_max_health_changed)
	
	## 监听地图打开/关闭状态
	MapManager.map_visibility_changed.connect(_on_map_visibility_changed)
	Global.player_health_changed.connect(_on_global_health_changed)
	Global.coins_changed.connect(_on_coins_changed)
	Global.coins_changing.connect(_on_coins_changing)
	_setup_debug_full_map_button()

## ════ 临时调试：一键准备「完整地图」 ════
## 为什么放在 HUD 而不是地图场景：地图打开时再改贴图会瞬间变化、很突兀；
## 在 HUD 上先把全部房间烘焙进贴图 + 整块揭开会探索遮罩，之后开图就是完整的。
## 用完把这段 + 按钮一起删掉即可。
func _setup_debug_full_map_button() -> void:
	var button := Button.new()
	button.name = "DebugFullMapButton"
	button.text = "完整地图(临时)"
	button.focus_mode = Control.FOCUS_NONE
	button.size = Vector2(150, 38)
	button.pressed.connect(_on_debug_full_map_pressed)
	add_child(button)
	_place_debug_full_map_button()
	if get_viewport() != null and not get_viewport().size_changed.is_connected(_place_debug_full_map_button):
		get_viewport().size_changed.connect(_place_debug_full_map_button)

## 把按钮摆在右上角（窗口尺寸变化时也跟着走）
func _place_debug_full_map_button() -> void:
	var button: Button = get_node_or_null("DebugFullMapButton") as Button
	if button == null or get_viewport() == null:
		return
	var size: Vector2 = get_viewport().get_visible_rect().size
	button.position = Vector2(size.x - button.size.x - 12.0, 12.0)

## 按下：烘焙布局里全部房间 + 整块揭开遮罩（不污染存档的已探索记录）
func _on_debug_full_map_pressed() -> void:
	if MapManager == null:
		return
	if ScenePaths != null:
		for room_key in ScenePaths.ROOM_PATHS.keys():
			MapManager.bake_room_from_scene(str(room_key))
	if MapManager.has_method("reveal_all_mask"):
		MapManager.reveal_all_mask()
	# 完整地图也要把「应当出现的门连线」补上（门在房间内部的不算）
	if MapManager.has_method("set_draw_all_door_connectors"):
		MapManager.set_draw_all_door_connectors(true)

## 退场清理：设置面板实例是 add_child 到 /root 的，不属于本场景，异常路径下会残留，
## 这里统一清掉。
func _exit_tree() -> void:
	if is_instance_valid(game_setting_instance):
		game_setting_instance.queue_free()
	game_setting_instance = null

## 层级契约（别再加独立高层 CanvasLayer）：PlayerIcon 必须留在 PlayerUI 自己的
## CanvasLayer 里，它才能像 HealthContainer 一样被 DarkOverlay 的全屏黑幕（layer 95，
## alpha 0.7）压暗 —— 地图 / 传送面板 / 游戏内设置打开时都是这层在暗化背景。
## 曾经把图标挪到 layer 101（「比设置界面 100 还高」），后果：
##   1) 黑幕压暗不到它 → 只有图标是亮的；
##   2) SettingsScene 的全屏背景（layer 100）盖不住它 → 打开设置后图标不消失。
## 留在本层后：黑幕能暗化它、设置界面能盖住它；点击拦截靠已有的 set_icon_locked()。

func _process(_delta):
	# 处理钱币延迟递增
	if is_waiting_for_increment:
		coin_delay_timer += _delta
		if coin_delay_timer >= coin_increment_delay:
			is_waiting_for_increment = false
			coin_delay_timer = 0.0
			# 关键修复：调用 play_coin_animation()
			play_coin_animation()
	
	# 处理钱币自动隐藏
	if coin_visible and coin_change_amount == 0 and not is_waiting_for_increment:
		coin_hide_timer += _delta
		if coin_hide_timer >= coin_hide_delay:
			hide_coin_ui()
			coin_hide_timer = 0.0
	
	## 水下蓝滤镜：每帧向目标强度逼近（进水淡入 / 出水淡出）
	_update_water_tint(_delta)

# 血量显示初始化
func initialize_health_display():
	# 清除现有的血量单位
	for unit in health_units:
		if is_instance_valid(unit):
			unit.queue_free()
	health_units.clear()
	
	# 创建新的血量单位
	for i in range(max_health):
		var health_unit = health_unit_scene.instantiate()
		
		health_unit.position = Vector2(health_unit_start_x + (i * 0.5 * health_unit_spacing), health_unit_y)
		health_unit.scale = Vector2(2, 2)
		health_container.add_child(health_unit)
		health_units.append(health_unit)
		
		# 连接动画完成信号
		if health_unit.animated_sprite:
			health_unit.animated_sprite.animation_finished.connect(_on_health_unit_animation_finished.bind(health_unit))
	
	# 初始设置为满血
	current_health = max_health
	_apply_health_state_immediately()

func _on_health_unit_animation_finished(health_unit):
	match health_unit.animated_sprite.animation:
		"ADD":
			# ADD 动画完成后切换到 HAVE 状态
			health_unit.set_state(health_unit.HealthState.HAVE)
		"REDUCE":
			# REDUCE 动画完成后切换到 NULL 状态
			health_unit.set_state(HealthUnit.HealthState.NULL)

# 立即应用血量状态（不播放动画）
func _apply_health_state_immediately():
	# 应用每个血量单位的状态
	for i in range(health_units.size()):
		var health_unit = health_units[i]
		
		if not is_instance_valid(health_unit):
			continue
		
		# 修复：类型检查，确保是 HealthUnit
		if not health_unit.has_method("set_state"):
			continue
		
		if i < current_health:
			if current_health == 1 and i == 0:
				health_unit.set_state(HealthUnit.HealthState.LASTHAVE)
			else:
				health_unit.set_state(HealthUnit.HealthState.HAVE)
		else:
			health_unit.set_state(HealthUnit.HealthState.NULL)
	
	# 触发低血量视觉效果
	
# 统一的血量设置函数
func set_health_internal(new_health: int, play_animation: bool = true):
	var old_health = current_health
	current_health = clamp(new_health, 0, max_health)
	
	if play_animation and old_health != current_health:
		_play_health_animation_for_change(old_health, current_health)
	else:
		_apply_health_state_immediately()
	
	health_changed.emit(current_health)
	Global.player_current_health = current_health
	
	if current_health <= 0:
		player_died.emit()

# 播放血量变化动画（根据血量变化）
func _play_health_animation_for_change(old_health: int, new_health: int):
	# 计算变化的血量单位索引
	var start_index = min(old_health, new_health)
	var end_index = max(old_health, new_health)
	
	# 确定是增加还是减少
	var is_healing = new_health > old_health
	
	for i in range(start_index, end_index):
		if i < health_units.size():
			var health_unit = health_units[i]
			if is_instance_valid(health_unit):
				if is_healing:
					health_unit.set_state(HealthUnit.HealthState.ADD)
				else:
					health_unit.set_state(HealthUnit.HealthState.REDUCE)
	
	# 更新所有血量单位的最终状态
	await get_tree().create_timer(0.3).timeout
	_apply_health_state_immediately()

# 更新低血量视觉效果
func _update_low_health_effect():
	var player = get_tree().get_first_node_in_group("player")
	if player and player.has_method("update_low_health_effect"):
		player.update_low_health_effect()

# 公共接口函数
## 气泡显示初始化（对标 initialize_health_display）：
## BubbleContainer 是场景里摆好的节点，这里只按上限补齐气泡单位
func initialize_bubble_display(max_count: int) -> void:
	for unit in bubble_units:
		if is_instance_valid(unit):
			unit.queue_free()
	bubble_units.clear()
	for i in range(maxi(max_count, 0)):
		if bubble_unit_scene == null:
			push_error("PlayerUI: 还没有在检视面板里拖入 bubble_unit_scene（BubbleUnit.tscn）")
			break
		var bubble_unit = bubble_unit_scene.instantiate()
		bubble_unit.position = Vector2(bubble_unit_start_x + (i * 0.5 * bubble_unit_spacing), bubble_unit_y)
		bubble_unit.scale = bubble_unit_scale
		bubble_container.add_child(bubble_unit)
		bubble_units.append(bubble_unit)
	bubble_container.visible = false
	_bubble_last_count = -1

## 设置气泡显示：current < 0 = 隐藏整行（未完全浸没 / 已有水下呼吸）
## ★ 结构与 initialize_health_display() + _apply_health_state_immediately() 一致：
##   数量变了就重建单位，再按当前数量逐个套用状态。
func set_bubble_count(current: int, maximum: int) -> void:
	var max_count: int = maxi(maximum, 0)
	if current < 0 or max_count <= 0:
		bubble_container.visible = false
		_bubble_last_count = -1
		return
	if bubble_units.size() != max_count:
		initialize_bubble_display(max_count)
	bubble_container.visible = true
	## 判断哪个气泡刚刚被消耗（从有变无）→ 那个单位要播破裂动画
	var consumed_index: int = -1
	if _bubble_last_count >= 0 and current < _bubble_last_count:
		consumed_index = maxi(current, 0)
	_bubble_last_count = current
	for i in range(bubble_units.size()):
		var unit: Node = bubble_units[i]
		if not is_instance_valid(unit):
			continue
		if i < current:
			unit.show_full()
		elif i == consumed_index:
			unit.pop()
		else:
			unit.show_empty()
	## 只剩 1 个 / 已耗尽：整个气泡行做呼吸缩放 + 提示音
	_update_bubble_warning(current <= 1)

## 低气泡警告：气泡行做「呼吸」缩放，并播放一次提示音
func _update_bubble_warning(low: bool) -> void:
	if bubble_container == null or not is_instance_valid(bubble_container):
		return
	if not low:
		if _bubble_pulse != null and _bubble_pulse.is_valid():
			_bubble_pulse.kill()
		_bubble_pulse = null
		bubble_container.scale = Vector2.ONE
		return
	if _warning_player == null or not is_instance_valid(_warning_player):
		_warning_player = AudioStreamPlayer.new()
		_warning_player.name = "BubbleWarningSound"
		add_child(_warning_player)
	if _bubble_pulse == null or not _bubble_pulse.is_valid():
		_bubble_pulse = create_tween().set_loops()
		_bubble_pulse.tween_property(bubble_container, "scale", Vector2(1.06, 1.06), 0.4).set_trans(Tween.TRANS_SINE)
		_bubble_pulse.tween_property(bubble_container, "scale", Vector2(0.96, 0.96), 0.4).set_trans(Tween.TRANS_SINE)
	if bubble_warning_sound != null and not _warning_player.playing:
		_warning_player.stream = bubble_warning_sound
		_warning_player.play()

## 设置水下屏幕滤镜（渐晕）：strength = 是否在水下（0/1），danger = 气泡越少越大（0~1）
## ★ 这里只写「目标强度」，真正的淡入淡出在 _update_water_tint() 里做
func set_water_tint(strength: float, danger: float) -> void:
	_ensure_water_tint()
	if _water_tint == null:
		return
	var strength_clamped: float = clampf(strength, 0.0, 1.0)
	var danger_clamped: float = clampf(danger, 0.0, 1.0)
	_water_tint_target = clampf((water_vignette_intensity + water_vignette_danger_extra * danger_clamped) * strength_clamped, 0.0, 1.0)

## 每帧平滑逼近目标强度：进水淡入、出水淡出，气泡变少时也会慢慢加深
func _update_water_tint(delta: float) -> void:
	if _water_tint == null or not is_instance_valid(_water_tint):
		return
	if water_tint_fade_time <= 0.0:
		_water_tint_current = _water_tint_target
	else:
		_water_tint_current = move_toward(_water_tint_current, _water_tint_target, delta / water_tint_fade_time)
	_water_tint.visible = _water_tint_current > 0.001
	if not _water_tint.visible:
		return
	var mat: ShaderMaterial = _water_tint.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("intensity", clampf(_water_tint_current, 0.0, 1.0))
	mat.set_shader_parameter("color", water_tint_color)
	mat.set_shader_parameter("inner_radius", water_vignette_inner_radius)
	mat.set_shader_parameter("outer_radius", water_vignette_outer_radius)

## 创建全屏水色渐晕：与受伤的红色渐晕用**同一个 shader**（观感一致、可同时叠加）
func _ensure_water_tint() -> void:
	if _water_tint != null and is_instance_valid(_water_tint):
		return
	_water_tint = ColorRect.new()
	_water_tint.name = "WaterTint"
	_water_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat: ShaderMaterial = ShaderMaterial.new()
	if ResourceLoader.exists(VIGNETTE_SHADER_PATH):
		mat.shader = load(VIGNETTE_SHADER_PATH)
	_water_tint.material = mat
	add_child(_water_tint)
	## 压到最底层：盖住游戏画面，但不遮住血量/金币/气泡等 HUD
	move_child(_water_tint, 0)
	## ★ 用 anchors + offsets 一次性铺满视口（不要再单独 set size，会和 anchors 冲突）
	if _water_tint is Control:
		(_water_tint as Control).set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_water_tint.visible = false

func take_damage(damage: int = 1):
	if damage <= 0 or current_health <= 0:
		return
	
	set_health_internal(current_health - damage, true)
	
	# 关键修复：在血量变为 0 时立即触发低血量效果
	if current_health == 0:
		# 通过信号通知 Player 触发低血量效果
		var player = get_tree().get_first_node_in_group("player")
		if player and player.has_method("_trigger_low_health_effect"):
			player._trigger_low_health_effect()

func heal(heal_amount: int = 1):
	if heal_amount <= 0 or current_health >= max_health:
		return
	
	set_health_internal(current_health + heal_amount, true)

func set_health(new_health: int):
	set_health_internal(new_health, true)

func increase_max_health(amount: int = 1):
	if amount <= 0:
		return
	
	var old_max_health = max_health
	max_health += amount
	current_health += amount  # 增加上限时同时恢复血量
	Global.player_max_health = max_health
	Global.player_current_health = current_health
	
	# 重新创建血量显示
	initialize_health_display()
	
	# 关键修复：只为新增的血量单位播放 ADD 动画
	for i in range(old_max_health, max_health):
		if i < health_units.size():
			var health_unit = health_units[i]
			if is_instance_valid(health_unit):
				health_unit.set_state(HealthUnit.HealthState.ADD)
	
	# 发出信号
	max_health_changed.emit(max_health)
	health_changed.emit(current_health)
	Global.player_max_health_changed.emit(max_health)
	Global.player_health_changed.emit(current_health)

# 钱币系统相关函数
func initialize_coin_display():
	# 初始设置钱币显示
	current_display_coins = Global.player_coins
	coin_label.text = str(current_display_coins)
	coin_change_label.visible = false
	
	# 初始隐藏钱币 UI
	coin_container.modulate.a = 0.0
	coin_visible = false

func _on_coins_changed(new_amount: int):
	if not is_animating:
		var change = new_amount - current_display_coins
		if change > 0:
			coin_change_amount = change
			is_increasing = true
			play_coin_animation()
	else:
		var remaining = new_amount - current_display_coins
		if remaining > 0:
			coin_change_amount = remaining
			is_increasing = true
			coin_change_label.text = "+" + str(coin_change_amount)
			_restart_animation()
		else:
			coin_change_amount = -remaining
			is_increasing = false
			coin_change_label.text = "-" + str(coin_change_amount)
			_restart_animation()

# 处理钱币花费动画
func _on_coins_changing(_old_amount: int, new_amount: int, _duration: float):
	var decrease_amount = _old_amount - new_amount
	
	if decrease_amount > 0:
		if not is_animating:
			coin_change_amount = decrease_amount
			is_increasing = false
			play_coin_animation()
		else:
			var remaining = current_display_coins - new_amount
			if remaining > 0:
				coin_change_amount = remaining
				is_increasing = false
				coin_change_label.text = "-" + str(coin_change_amount)
				_restart_animation()
			else:
				coin_change_amount = -remaining
				is_increasing = true
				coin_change_label.text = "+" + str(coin_change_amount)
				_restart_animation()

func _restart_animation():
	# 停止当前动画
	if coin_tween:
		coin_tween.kill()
		coin_tween = null
	
	# 重新播放
	play_coin_animation()

func play_coin_animation():
	is_animating = true
	
	coin_hide_timer = 0.0
	show_coin_ui()
	
	if coin_container:
		coin_container.visible = true
		coin_container.modulate.a = 1.0
	if coin_label:
		coin_label.visible = true
	
	var amount = coin_change_amount
	if is_increasing:
		coin_change_label.text = "+" + str(amount)
	else:
		coin_change_label.text = "-" + str(amount)
	coin_change_label.visible = true
	
	if coin_tween:
		coin_tween.kill()
		coin_tween = null
	
	coin_tween = create_tween()
	coin_tween.set_parallel(false)
	
	for i in range(amount):
		var remaining = amount - i
		var current_interval = _get_coin_change_interval(remaining)
		
		coin_tween.tween_callback(func(): 
			if is_increasing:
				coin_change_amount -= 1
				current_display_coins += 1
			else:
				coin_change_amount -= 1
				current_display_coins -= 1
			
			if coin_change_amount > 0:
				if is_increasing:
					coin_change_label.text = "+" + str(coin_change_amount)
				else:
					coin_change_label.text = "-" + str(coin_change_amount)
			else:
				coin_change_label.visible = false
			
			coin_label.text = str(current_display_coins)
		)
		coin_tween.tween_interval(current_interval)
	
	coin_tween.tween_callback(func():
		is_animating = false
		
		coin_change_label.visible = false
		coin_hide_timer = 2.0
		
		if current_display_coins != Global.player_coins:
			print("警告：显示值", current_display_coins, "≠ 实际值", Global.player_coins)
			current_display_coins = Global.player_coins
			coin_label.text = str(current_display_coins)
	)

## 根据变化数量获取间隔时间（使用外部变量）
func _get_coin_change_interval(amount: int) -> float:
	if amount <= 10:
		return coin_change_interval_slow
	elif amount <= 100:
		return coin_change_interval_mod
	else:
		return coin_change_interval_fast

func update_coin_display():
	coin_label.text = str(current_display_coins)

func show_coin_ui():
	if coin_visible:
		return
	
	coin_visible = true
	coin_hide_timer = 0.0
	
	if coin_tween:
		coin_tween.kill()
	
	coin_tween = create_tween()
	coin_tween.tween_property(coin_container, "modulate:a", 1.0, coin_fade_duration)

func hide_coin_ui():
	if not coin_visible:
		return
	
	coin_visible = false
	
	if coin_tween:
		coin_tween.kill()
	
	coin_tween = create_tween()
	coin_tween.tween_property(coin_container, "modulate:a", 0.0, coin_fade_duration)

# 游戏设置相关函数
func _on_game_setting_button_pressed():
	# 点击音效由 UIButtonFx 组件层在 button_down 时统一播放
	
	_open_game_setting_menu()

func _open_game_setting_menu():
	if game_setting_instance != null:
		return
	# 切场过渡期间（例如从存档进入游戏的黑屏/淡入阶段）不打开设置面板：
	# 此时 SceneManager 的切场锁尚未释放，面板里的「返回主菜单」会被拒绝，
	# 表现为「面板能打开、但按钮点了没反应」。直接不让打开，语义更干净。
	if SceneManager and SceneManager.has_method("is_scene_switch_in_progress") and SceneManager.is_scene_switch_in_progress():
		return
	
	if not game_setting_scene:
		push_error("PlayerUI: game_setting_scene 未配置！请在 Inspector 中拖拽 GameSettingScene.tscn")
		return
	
	game_setting_instance = game_setting_scene.instantiate()
	
	if game_setting_instance.has_signal("menu_closed"):
		game_setting_instance.menu_closed.connect(_on_game_setting_closed)
	
	# 设置面板打开期间：图标不隐藏，保持按下外观并禁止再按（按需求）。
	set_icon_locked(true)
	
	# 确保游戏暂停 - 关键修复
	get_tree().paused = true
	get_tree().root.add_child(game_setting_instance)

func _on_game_setting_closed():
	game_setting_instance = null
	set_icon_locked(false)


## 图标按钮（PlayerIcon）的锁定状态：地图 / 传送面板 / 游戏内设置打开期间，
## 图标**保持显示**并保持按下外观，但不能再按（避免重复触发同一个面板）。
func set_icon_locked(locked: bool) -> void:
	if not game_setting_button:
		return
	game_setting_button.toggle_mode = true
	game_setting_button.button_pressed = locked
	game_setting_button.disabled = locked

func _input(event):
	## Tab：有地图能力且设置未打开时切换地图（优先处理，避免与 Esc 互斥）
	if event.is_action_pressed("map"):
		if game_setting_instance != null:
			return
		if Global.unlocked_abilities.get("map", false) and MapManager:
			MapManager.toggle_map()
		get_viewport().set_input_as_handled()
		return
	## Esc：地图打开时关闭地图，否则打开设置
	if event.is_action_pressed("ui_cancel"):
		if MapManager and MapManager.is_map_open:
			MapManager.close_map()
			get_viewport().set_input_as_handled()
			return
		if game_setting_instance == null:
			_open_game_setting_menu()

func _on_map_visibility_changed(map_visible: bool) -> void:
	## 地图打开时锁定图标（不隐藏）：保持按下外观，并禁止再次按下
	set_icon_locked(map_visible)

# 全局数据更新
func _on_global_max_health_changed(new_max_health: int):
	if new_max_health != max_health:
		max_health = new_max_health
		current_health = min(current_health, max_health)
		initialize_health_display()

func _on_global_health_changed(new_health: int):
	if new_health != current_health:
		# 使用动画方式更新血量，确保播放 ADD 动画
		set_health_internal(new_health, true)
		
		# 关键修复：通知 Player 更新低血量效果
		var player = get_tree().get_first_node_in_group("player")
		if player and player.has_method("update_low_health_effect"):
			player.update_low_health_effect()

# 公共方法
func get_health() -> int:
	return current_health

func set_max_health(new_max_health: int):
	max_health = new_max_health
	current_health = min(current_health, max_health)
	max_health_changed.emit(max_health)
	initialize_health_display()
	Global.player_max_health = max_health
	Global.player_current_health = current_health

## 隐藏 UI（保留设置按钮和钱币）
func hide_ui_except_settings():
	health_container.visible = false
	coin_container.visible = false

## 带淡出效果隐藏 UI（忽略钱币，因为挑战开始时钱币已经是隐藏的）
func fade_out_ui_no_coin(duration: float):
	var tween = create_tween()
	tween.tween_property(health_container, "modulate:a", 0.0, duration)
	tween.tween_callback(func():
		health_container.visible = false
	)

## 显示 UI
func show_ui():
	health_container.visible = true
	coin_container.visible = true
	health_container.modulate.a = 1.0
	coin_container.modulate.a = 1.0

## 带淡入效果显示 UI（忽略钱币，因为挑战结束时钱币不需要自动显示）
func fade_in_ui_no_coin(_duration: float):
	health_container.visible = true
	health_container.modulate.a = 1.0
	# 注意：不显示 coin_container，保持隐藏状态
