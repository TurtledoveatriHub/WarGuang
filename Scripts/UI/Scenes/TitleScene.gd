extends UIScene  # UI 页面统一基类（生命周期 / 输入锁 / 动效总线）

## 设置界面场景（在 Inspector 中拖拽 SettingsScene.tscn）
@export var settings_scene_resource: PackedScene
## 三个信息弹窗（在 Inspector 中拖拽对应 .tscn）
@export var about_author_scene: PackedScene
@export var update_notes_scene: PackedScene
@export var achievement_scene: PackedScene
## 标题画面 BGM 名称（对应 AudioManager.bgm_paths 的键，默认 "BGM0" = 探险.ogg）。
## 注意：不要在场景里直接把音频资源拖成 @export AudioStream——
## 那样 .ogg 会被烘进 .tscn 的资源表，场景存活期间一直被强引用，
## 退出时引擎会报 "ObjectDB instances leaked at exit / resources still in use"。
@export var title_bgm_name: String = "BGM0"


@onready var start_button = $StartButton
@onready var settings_button = $SettingsButton
@onready var quit_button = $QuitButton
@onready var ach_button: TextureButton = $ACHButton
@onready var about_author_button: TextureButton = $AboutAuthor
@onready var update_notes_button: TextureButton = $UpdateNotes
## 当前打开的弹窗（同一时刻只允许一个）
var _active_popup: Node = null
## 过渡轨道已并入 UIFxDirector（动效总线）：这里保留旧名字指向总线，业务代码无需改动。
@onready var ui_transition_animator: Node = _get_fx_bus()
@onready var title_sprite_a: Sprite2D = $Title
@onready var title_sprite_b: Sprite2D = get_node_or_null("TitleB")
@onready var title_click_area_a: BaseButton = get_node_or_null("TitleClickAreaA")
@onready var title_click_area_b: BaseButton = get_node_or_null("TitleClickAreaB")

## 当前标题点击计数
var _title_click_count: int = 0
## 标题是否正在抖动
var _title_shaking: bool = false
## 标题A初始位置
var _title_a_base_position: Vector2 = Vector2.ZERO
## 标题A初始缩放
var _title_a_base_scale: Vector2 = Vector2.ONE
## 标题B初始位置
var _title_b_base_position: Vector2 = Vector2.ZERO
## 标题B初始缩放
var _title_b_base_scale: Vector2 = Vector2.ONE

enum TitleVariant {
	A,
	B
}

const TITLE_UI_STATE_PATH: String = "user://ui_state.cfg"
const TITLE_UI_STATE_SECTION: String = "title_scene"
const TITLE_UI_STATE_KEY: String = "active_variant"

var _active_title_variant: int = TitleVariant.A

@export_category("标题可点击区域互动")
@export var title_shake_duration: float = 0.5
@export var title_shake_strength: float = 7.0
@export var title_shake_interval: float = 0.03

@export_category("退出游戏")
## 点击退出后渐入黑屏的时长（秒），然后退出游戏。
@export var quit_fade_out_duration: float = 1.0

## 初始化标题场景
func _ready():
	start_button.pressed.connect(_on_start_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	ach_button.pressed.connect(_on_achievement_button_pressed)
	about_author_button.pressed.connect(_on_about_author_button_pressed)
	update_notes_button.pressed.connect(_on_update_notes_button_pressed)
	if title_click_area_a:
		title_click_area_a.pressed.connect(_on_title_area_a_pressed)
	if title_click_area_b:
		title_click_area_b.pressed.connect(_on_title_area_b_pressed)
	# 先把动画器还原到编辑器基态，再记录标题A/B初始位姿，避免拿到入场偏移后的错误基准。
	if ui_transition_animator:
		ui_transition_animator.reset_state()
	if title_sprite_a:
		_title_a_base_position = title_sprite_a.position
		_title_a_base_scale = title_sprite_a.scale
	if title_sprite_b:
		_title_b_base_position = title_sprite_b.position
		_title_b_base_scale = title_sprite_b.scale
	_load_title_variant_state()
	_apply_title_variant_state(false)

	## 若开场过场动画正在播放，先把「入场演出的主角」隐藏起来：
	## UITransitionAnimator 的目标 + 所有 UILoopAnimator + 所有按钮动效组件。
	## Background / 光源 / CanvasModulate 等背景元素**保持可见**（可提前显示）。
	## 等 intro 播完的同一时刻再显形并开始入场演出（见 _begin_enter_sequence）。
	var boot_waiting: bool = _is_boot_cutscene_playing()
	if boot_waiting:
		_hide_enter_showcase()

	set_input_locked(true)
	if ui_transition_animator:
		ui_transition_animator.reset_state()
	# 开场过场还在播 → 等它播完再入场；否则若不是黑屏（编辑器直接运行该场景）就立即入场。
	# 黑屏场景切换时，由 SceneManager / UIRouter 在黑屏下显式调用 ui_enter()。
	if boot_waiting:
		call_deferred("_begin_enter_sequence")
	else:
		auto_enter_unless_black()
	
	## 播放 UI BGM：按名称交给 AudioManager 运行时加载，避免音频资源被烘进场景。
	if title_bgm_name != "":
		AudioManager.play_bgm(title_bgm_name)
	
	## 修改：调用 LightingManager 的统一函数
	LightingManager.setup_ui_breathing_effect(self)


## 开始本场景的入场演出。
## 若开场过场动画（BootCutscene）正在播放，则等它播完（intro_finished）再开始，
## 从而保证：开场动画 → 本场景显形 + 入场演出 → 覆盖层淡出，顺序正确且不阻塞 _ready。
func _begin_enter_sequence() -> void:
	var boot: Node = get_node_or_null("/root/BootCutscene")
	if boot != null and boot.has_method("is_playing") and boot.has_method("is_intro_finished"):
		var playing: bool = bool(boot.call("is_playing"))
		var intro_done: bool = bool(boot.call("is_intro_finished"))
		if playing and not intro_done:
			# 直接 await 信号本体（Godot 4 中调用协程函数不会返回可 await 的对象）。
			var intro_signal: Variant = boot.get("intro_finished")
			if intro_signal is Signal:
				await intro_signal
	# 显形与入场演出同一时刻发生，避免“先出现、后播动画”的脱节感。
	_restore_enter_showcase()
	await ui_enter()


## 开场过场动画是否正在播放（含淡出阶段）。
func _is_boot_cutscene_playing() -> bool:
	var boot: Node = get_node_or_null("/root/BootCutscene")
	if boot == null or not boot.has_method("is_playing"):
		return false
	return bool(boot.call("is_playing"))


## 处理开始按钮按下
func _on_start_button_pressed():
	if is_input_locked():
		return
	_reset_title_click_state()
	LightingManager.stop_all_light_effects()
	# 退场动画 / 黑屏 / 换场景 / 新页入场的顺序只在 UIRouter 里定义一处。
	await UIRouter.goto_scene(ScenePaths.UI_SAVE_SELECT)

## 处理设置按钮按下（以覆盖层方式打开设置界面）
func _on_settings_button_pressed():
	if is_input_locked():
		return
	_reset_title_click_state()
	if not settings_scene_resource:
		push_error("TitleScene: settings_scene_resource 未配置！请在 Inspector 中拖拽 SettingsScene.tscn")
		return
	var settings_page: Node = settings_scene_resource.instantiate()
	await UIRouter.open_overlay(settings_page, self)

## 处理退出按钮按下
func _on_quit_button_pressed():
	if is_input_locked():
		return
	_reset_title_click_state()
	# 黑屏过渡在点击瞬间立即开始，与退场动画并行推进，不等退场动画播完。
	UIRouter.quit_game(quit_fade_out_duration)

## 覆盖基类：把锁定状态应用到本页面的按钮上。
## （事件吞噬、覆盖层穿透、解锁时机都由基类统一处理）
func _on_input_lock_applied(locked: bool) -> void:
	start_button.disabled = locked
	settings_button.disabled = locked
	quit_button.disabled = locked
	# 两个角落里的小按钮与成就按钮也一起失活：
	# 弹窗打开期间它们不仅点不动，也不再播悬停动画（UIButtonFx 会忽略 disabled 按钮的悬停）。
	ach_button.disabled = locked
	about_author_button.disabled = locked
	update_notes_button.disabled = locked


## ------------------------------------------------------------------
## 信息弹窗（关于作者 / 游戏公告 / 游戏成就）
## ------------------------------------------------------------------

func _on_about_author_button_pressed() -> void:
	_open_popup(about_author_scene, "AboutAuthor")


func _on_update_notes_button_pressed() -> void:
	_open_popup(update_notes_scene, "UpdateNotes")


func _on_achievement_button_pressed() -> void:
	_open_popup(achievement_scene, "AchievementScene")


## 打开一个信息弹窗。与「设置界面」不同：这三个弹窗**不换场景、也不播标题页的退场**，
## 只是叠一层遮罩 + 把标题页整层失活：
##   * set_overlay_active(true) → 本页按钮全部禁用：点不动、也不再播悬停动画；
##   * 因为 overlay_pass_through_input = true，本页不会吞事件，弹窗自己的 ContinueButton / ESC
##     才收得到（否则会出现「弹窗盖在上面但按钮点不动」）。
func _open_popup(scene: PackedScene, tag: String) -> void:
	if scene == null:
		push_error("TitleScene: %s 弹窗未配置！请在 Inspector 中拖拽对应的 .tscn" % tag)
		return
	if is_input_locked() or _active_popup != null or UIRouter.is_busy():
		return
	_reset_title_click_state()
	_active_popup = scene.instantiate()
	set_overlay_active(true)
	add_child(_active_popup)
	_active_popup.tree_exited.connect(_on_popup_closed)


## 弹窗自行销毁后（ContinueButton / ESC）解除失活，标题页重新可用。
func _on_popup_closed() -> void:
	_active_popup = null
	set_overlay_active(false)
	set_input_locked(false)

## 覆盖基类：本页面入场时的额外表现（灯光呼吸重建）。
## 注意：这里**不能 await 帧**，否则入场动画会晚一帧才开始，
## 表现为「标题/按钮先完整显示一帧，然后才突然插入场动画」。
func _on_page_enter() -> void:
	_reset_title_click_state()
	LightingManager.setup_ui_breathing_effect(self)

## 覆盖基类：本页面退场时的额外表现。
func _on_page_exit() -> void:
	LightingManager.stop_all_light_effects()


## ------------------------------------------------------------------
## 入场演出主角的隐藏 / 恢复（开场过场期间）
## ------------------------------------------------------------------

## 过场期间被主动隐藏的节点及其原始可见性。
var _enter_showcase_nodes: Array[CanvasItem] = []
var _enter_showcase_visibilities: Array[bool] = []

## 隐藏「入场演出主角」：动画器目标 + UILoopAnimator + 按钮动效组件。
func _hide_enter_showcase() -> void:
	_restore_enter_showcase()
	for target in _collect_enter_showcase():
		_enter_showcase_nodes.append(target)
		_enter_showcase_visibilities.append(target.visible)
		target.visible = false

## 恢复被隐藏过的节点（只还原我们改过的那几个，不碰本来就隐藏的节点如 TitleB）。
func _restore_enter_showcase() -> void:
	for i in _enter_showcase_nodes.size():
		var target: CanvasItem = _enter_showcase_nodes[i]
		if is_instance_valid(target):
			target.visible = _enter_showcase_visibilities[i]
	_enter_showcase_nodes.clear()
	_enter_showcase_visibilities.clear()

func _collect_enter_showcase() -> Array[CanvasItem]:
	var targets: Array[CanvasItem] = []
	# 动画器目标（Title / TitleB 都在列表里；哪个可见由变体状态决定）
	if ui_transition_animator:
		for p in ui_transition_animator.target_paths:
			if p.is_empty():
				continue
			var node: Node = ui_transition_animator.get_node_or_null(p)
			if node is CanvasItem and not targets.has(node):
				targets.append(node)
	for animator in get_ui_loop_animators():
		if animator is CanvasItem and not targets.has(animator):
			targets.append(animator)
	for component in get_fx_components():
		if component is CanvasItem and not targets.has(component):
			targets.append(component)
	return targets


## 处理标题A点击
func _on_title_area_a_pressed() -> void:
	if is_input_locked() or is_overlay_active() or _title_shaking:
		return
	if _active_title_variant != TitleVariant.A:
		return
	await _on_title_variant_click()

## 处理标题B点击
func _on_title_area_b_pressed() -> void:
	if is_input_locked() or is_overlay_active() or _title_shaking:
		return
	if _active_title_variant != TitleVariant.B:
		return
	await _on_title_variant_click()

## 处理标题点击计数
func _on_title_variant_click() -> void:
	var active_title: Sprite2D = title_sprite_a if _active_title_variant == TitleVariant.A else title_sprite_b
	await _play_title_shake(active_title)
	_title_click_count += 1
	if _title_click_count >= 3:
		_title_click_count = 0
		await _toggle_title_variant()

## 播放标题抖动反馈
func _play_title_shake(target: Sprite2D) -> void:
	if not target:
		return
	_title_shaking = true
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var base_position: Vector2 = target.position
	var elapsed: float = 0.0
	while elapsed < title_shake_duration:
		target.position = base_position + Vector2(
			rng.randf_range(-title_shake_strength, title_shake_strength),
			rng.randf_range(-title_shake_strength, title_shake_strength)
		)
		await get_tree().create_timer(title_shake_interval).timeout
		elapsed += title_shake_interval
	target.position = base_position
	_title_shaking = false

## 切换标题变体
func _toggle_title_variant() -> void:
	if _active_title_variant == TitleVariant.A:
		await _swap_title_variant(title_sprite_a, title_sprite_b)
		_active_title_variant = TitleVariant.B
	else:
		await _swap_title_variant(title_sprite_b, title_sprite_a)
		_active_title_variant = TitleVariant.A
	_save_title_variant_state()
	_apply_title_variant_state(false)

## 执行标题变体切换动画
func _swap_title_variant(from_sprite: Sprite2D, to_sprite: Sprite2D) -> void:
	if not from_sprite or not to_sprite:
		return
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(from_sprite, "scale:y", 0.05, 0.2)
	tween.tween_property(from_sprite, "modulate:a", 0.0, 0.1)
	await tween.finished
	from_sprite.visible = false

	to_sprite.visible = true
	var base_scale_b: Vector2 = _title_b_base_scale if to_sprite == title_sprite_b else _title_a_base_scale
	var base_position_b: Vector2 = _title_b_base_position if to_sprite == title_sprite_b else _title_a_base_position
	to_sprite.position = base_position_b
	to_sprite.scale = base_scale_b
	to_sprite.scale.y = 0.05
	to_sprite.modulate.a = 0.0
	var tween_b := create_tween()
	tween_b.set_trans(Tween.TRANS_CUBIC)
	tween_b.set_ease(Tween.EASE_OUT)
	tween_b.parallel().tween_property(to_sprite, "scale:y", base_scale_b.y, 0.22)
	tween_b.parallel().tween_property(to_sprite, "modulate:a", 1.0, 0.22)
	await tween_b.finished

## 应用当前标题变体状态
func _apply_title_variant_state(reset_counter: bool = true) -> void:
	if title_sprite_a:
		title_sprite_a.position = _title_a_base_position
		title_sprite_a.scale = _title_a_base_scale
		title_sprite_a.visible = _active_title_variant == TitleVariant.A
		title_sprite_a.modulate.a = 1.0
	if title_sprite_b:
		title_sprite_b.position = _title_b_base_position
		title_sprite_b.scale = _title_b_base_scale
		title_sprite_b.visible = _active_title_variant == TitleVariant.B
		title_sprite_b.modulate.a = 1.0
	if title_click_area_a:
		title_click_area_a.visible = _active_title_variant == TitleVariant.A
	if title_click_area_b:
		title_click_area_b.visible = _active_title_variant == TitleVariant.B
	if ui_transition_animator:
		ui_transition_animator.reset_state()
	if reset_counter:
		_title_click_count = 0

## 读取标题变体持久化状态
func _load_title_variant_state() -> void:
	var config := ConfigFile.new()
	var err := config.load(TITLE_UI_STATE_PATH)
	if err != OK:
		_active_title_variant = TitleVariant.A
		return
	_active_title_variant = int(config.get_value(TITLE_UI_STATE_SECTION, TITLE_UI_STATE_KEY, TitleVariant.A))

## 保存标题变体持久化状态
func _save_title_variant_state() -> void:
	var config := ConfigFile.new()
	config.load(TITLE_UI_STATE_PATH)
	config.set_value(TITLE_UI_STATE_SECTION, TITLE_UI_STATE_KEY, _active_title_variant)
	config.save(TITLE_UI_STATE_PATH)

## 重置标题点击状态（切场前后统一调用）
## 重置标题点击状态
func _reset_title_click_state() -> void:
	_title_click_count = 0
	_title_shaking = false

func _exit_tree():
	LightingManager.stop_all_light_effects()
