# SettingsScene.gd
extends UIScene  # UI 页面统一基类（生命周期 / 输入锁 / 动效总线）

## 设置场景主脚本
## 节点引用
@onready var audio_button = $SettingsRoot/AudioButton          # 音量按钮
@onready var controls_button = $SettingsRoot/ControlsButton    # 按键映射按钮
@onready var graphics_button = $SettingsRoot/GraphicsButton    # 画面按钮
@onready var audio_page = $SettingsRoot/PagesRoot/AudioPage              # 音频页面
@onready var pc_controls_page = $SettingsRoot/PagesRoot/PCControlsPage    # PC控制页面
@onready var mobie_controls_page = get_node_or_null("SettingsRoot/PagesRoot/MobieControlsPage") # 移动端控制页面
@onready var graphics_page = get_node_or_null("SettingsRoot/PagesRoot/GraphicsPage") # 画面页面
@onready var effect_level_option: OptionButton = get_node_or_null("SettingsRoot/PagesRoot/GraphicsPage/EffectLevelContainer/EffectLevelOption")
@onready var close_button = $BackButton                        # 关闭按钮
## 过渡轨道已并入 UIFxDirector（动效总线）：这里保留旧名字指向总线，业务代码无需改动。
@onready var ui_transition_animator: Node = _get_fx_bus()

## 音量滑块引用（根据你的实际节点路径调整）
@onready var master_volume_slider = $SettingsRoot/PagesRoot/AudioPage/VolumeContainer/MasterVolumeLabel/MasterVolumeSlider
@onready var bgm_volume_slider = $SettingsRoot/PagesRoot/AudioPage/VolumeContainer/BGMVolumeLabel/BGMVolumeSlider
@onready var sfx_volume_slider = $SettingsRoot/PagesRoot/AudioPage/VolumeContainer/SFXVolumeLabel/SFXVolumeSlider
@onready var master_volume_label: Label = get_node_or_null("SettingsRoot/PagesRoot/AudioPage/VolumeContainer/MasterVolumeLabel")
@onready var bgm_volume_label: Label = get_node_or_null("SettingsRoot/PagesRoot/AudioPage/VolumeContainer/BGMVolumeLabel")
@onready var sfx_volume_label: Label = get_node_or_null("SettingsRoot/PagesRoot/AudioPage/VolumeContainer/SFXVolumeLabel")
## 常态 UI 循环动画由基类的动效总线统一驱动，本脚本不再自带收集与播放逻辑。

var esc_enabled: bool = false
## 当前展示的分类页（决定哪个按钮画 texture_pressed）。
var _category_active_page: String = "audio"
## 分类按钮当前是否可点（= 输入锁状态）。
var _category_buttons_interactive: bool = true

var _current_page_name: String = "audio"
var _page_switch_in_progress: bool = false

@export_category("Settings 页面内切换动画")
## 强制在 PC 端以移动端控制页面进行调试测试。
## 默认 false：PC 上显示 PCControlsPage；需要测试移动端页面时在 Inspector 勾选。
@export var force_mobile_controls_for_testing: bool = false
## 设置页面入场动画时长，单位：秒。
@export var page_enter_duration: float = 0.22
## 设置页面退场动画时长，单位：秒。
@export var page_exit_duration: float = 0.18
## 入场动画峰值缩放倍率。
@export var page_peak_scale_multiplier: float = 1.12
## 退场动画最小缩放倍率。
@export var page_exit_min_scale_multiplier: float = 0.02
## 页面缩放动画的轴心（PagesRoot 局部坐标，默认 = 屏幕中心）。
## Node2D 没有 pivot 属性（编辑器无法拖拽），这里用位置补偿等价实现“绕屏幕中心缩放”。
@export var page_scale_pivot: Vector2 = Vector2(640.0, 360.0)
## 页面动画起始位移量，单位：像素。
@export var page_drift_distance: float = 18.0

enum UiEffectLevel {
	LOW,
	MEDIUM,
	HIGH
}

var ui_effect_level: int = UiEffectLevel.MEDIUM
var _page_base_positions: Dictionary = {}
var _page_base_scales: Dictionary = {}
var _page_base_modulates: Dictionary = {}
var _settings_canvas_original_color: Color = Color(1.0, 1.0, 1.0, 1.0)
var _settings_canvas_modulate: CanvasModulate = null

func _connect_unique_signal(signal_ref: Signal, callable_ref: Callable) -> void:
	if signal_ref and not signal_ref.is_connected(callable_ref):
		signal_ref.connect(callable_ref)

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	# 本页面锁定输入时**不吞鼠标事件**：移动端布局编辑态下按钮仍需接收拖动。
	lock_swallows_mouse = false
	_settings_canvas_modulate = get_node_or_null("CanvasModulate") as CanvasModulate
	if _settings_canvas_modulate and is_instance_valid(_settings_canvas_modulate):
		_settings_canvas_original_color = _settings_canvas_modulate.color
	_connect_mobile_controls_signals()
	
	# 连接按钮信号
	_connect_unique_signal(audio_button.pressed, _on_audio_button_pressed)
	_connect_unique_signal(controls_button.pressed, _on_controls_button_pressed)
	_connect_unique_signal(graphics_button.pressed, _on_graphics_button_pressed)
	_connect_unique_signal(close_button.pressed, _on_close_button_pressed)
	
	# 连接音量滑块信号
	if master_volume_slider:
		_connect_unique_signal(master_volume_slider.value_changed, _on_master_volume_changed)
		_connect_unique_signal(master_volume_slider.drag_started, _on_volume_slider_drag_started)
	if bgm_volume_slider:
		_connect_unique_signal(bgm_volume_slider.value_changed, _on_bgm_volume_changed)
		_connect_unique_signal(bgm_volume_slider.drag_started, _on_volume_slider_drag_started)
	if sfx_volume_slider:
		_connect_unique_signal(sfx_volume_slider.value_changed, _on_sfx_volume_changed)
		_connect_unique_signal(sfx_volume_slider.drag_started, _on_volume_slider_drag_started)
	_cache_page_base_states()
	_set_only_page_visible("audio")
	_current_page_name = "audio"
	_set_category_button_state(_current_page_name)
	_populate_effect_level_options()
	if effect_level_option:
		_connect_unique_signal(effect_level_option.item_selected, _on_effect_level_selected)
	
	# 设置焦点：正在展示的分类按钮是不可聚焦的（focus_mode = NONE），必须跳过，
	# 否则引擎会打印 "This control can't grab focus"。
	_grab_initial_category_focus()
	
	# 同步滑块值与实际总线音量
	if master_volume_slider:
		master_volume_slider.value = AudioManager.get_bus_volume_percent("Master")
	if bgm_volume_slider:
		bgm_volume_slider.value = AudioManager.get_bus_volume_percent("BGM")
	if sfx_volume_slider:
		sfx_volume_slider.value = AudioManager.get_bus_volume_percent("SFX")
	_refresh_all_volume_labels()

	set_input_locked(true)
	if ui_transition_animator:
		ui_transition_animator.reset_state()
	# 黑屏场景切换时由 SceneManager / UIRouter 显式调用 ui_enter()；
	# 非黑屏（编辑器直接运行本场景）时自行入场；没有过渡动画器时同样走这条路。
	auto_enter_unless_black()

	# ESC冷却
	var esc_timer = Timer.new()
	esc_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	esc_timer.wait_time = 0.1
	esc_timer.one_shot = true
	esc_timer.autostart = true
	esc_timer.timeout.connect(func():
		esc_enabled = true
		if esc_timer.is_inside_tree():
			remove_child(esc_timer)
			esc_timer.queue_free()
	)
	add_child(esc_timer)

## 切换页面
func switch_to_page(page_name: String):
	await _switch_to_page(page_name, true)

func _switch_to_page(page_name: String, animated: bool = true) -> void:
	if page_name == _current_page_name:
		return
	var target_page: CanvasItem = _resolve_page(page_name)
	if target_page == null:
		return
	if _page_switch_in_progress:
		return

	var previous_page: CanvasItem = _resolve_page(_current_page_name)
	_page_switch_in_progress = true
	# 立即切「哪个分类被选中」的视觉状态（贴图 + 缩放/位移），不等页面切换动画播完 ——
	# 否则旧分类按钮会一直亮着，看着像点击没响应。
	_current_page_name = page_name
	_set_category_button_state(page_name)
	if previous_page and previous_page != target_page:
		if animated:
			await _play_page_exit(previous_page)
		previous_page.visible = false
		_restore_page_base_state(previous_page)

	target_page.visible = true
	if animated:
		await _play_page_enter(target_page)
	else:
		_restore_page_base_state(target_page)

	_page_switch_in_progress = false

func _is_mobile_platform() -> bool:
	return force_mobile_controls_for_testing or OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")

func _get_controls_page_name() -> String:
	return "mobie_controls" if _is_mobile_platform() else "pc_controls"

func _resolve_page(page_name: String) -> CanvasItem:
	match page_name:
		"audio":
			return audio_page
		"controls":
			return _resolve_page(_get_controls_page_name())
		"pc_controls":
			return pc_controls_page
		"mobile_controls", "mobie_controls":
			return mobie_controls_page
		"graphics":
			return graphics_page
		_:
			return null

func _cache_page_base_states() -> void:
	for page_name in ["audio", "pc_controls", "mobie_controls", "graphics"]:
		var page: CanvasItem = _resolve_page(page_name)
		if page:
			_page_base_positions[page_name] = page.position
			_page_base_scales[page_name] = page.scale
			_page_base_modulates[page_name] = page.modulate

func _restore_page_base_state(page: CanvasItem) -> void:
	var page_name := _name_by_page(page)
	if page_name == "":
		return
	page.position = _page_base_positions.get(page_name, page.position)
	page.scale = _page_base_scales.get(page_name, page.scale)
	page.modulate = _page_base_modulates.get(page_name, page.modulate)

## 计算“绕 page_scale_pivot 缩放 scale_factor 倍”时该页面应有的位置。
## 原理：绕点 C 缩放时，位置需同步补偿为 C + (base - C) * factor；
## 因为位置是该倍率的仿射函数，与缩放使用同一缓动即可保证全程绕 C 缩放。
func _pivot_scaled_position(base_position: Vector2, scale_factor: float, extra_offset: Vector2 = Vector2.ZERO) -> Vector2:
	return page_scale_pivot + (base_position - page_scale_pivot) * scale_factor + extra_offset

func _play_page_enter(page: CanvasItem) -> void:
	var page_name := _name_by_page(page)
	if page_name == "":
		return
	var base_position: Vector2 = _page_base_positions.get(page_name, page.position)
	var base_scale: Vector2 = _page_base_scales.get(page_name, page.scale)
	var base_modulate: Color = _page_base_modulates.get(page_name, page.modulate)
	# 起始态：放大 + 下移 + 全透明；缩放轴心 = page_scale_pivot（默认屏幕中心）。
	page.scale = base_scale * page_peak_scale_multiplier
	page.position = _pivot_scaled_position(base_position, page_peak_scale_multiplier, Vector2(0.0, page_drift_distance))
	page.modulate = Color(base_modulate.r, base_modulate.g, base_modulate.b, 0.0)
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(page, "position", base_position, page_enter_duration)
	tween.parallel().tween_property(page, "scale", base_scale, page_enter_duration)
	tween.parallel().tween_property(page, "modulate:a", base_modulate.a, page_enter_duration)
	await tween.finished

func _play_page_exit(page: CanvasItem) -> void:
	var page_name := _name_by_page(page)
	if page_name == "":
		return
	var base_position: Vector2 = _page_base_positions.get(page_name, page.position)
	var base_scale: Vector2 = _page_base_scales.get(page_name, page.scale)
	# 起始态：回到基态，保证从当前位置开始平滑推进。
	page.position = base_position
	page.scale = base_scale
	# 终态：缩小 + 下移 + 全透明；同样以 page_scale_pivot 为轴心。
	var target_position: Vector2 = _pivot_scaled_position(base_position, page_exit_min_scale_multiplier, Vector2(0.0, page_drift_distance))
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(page, "position", target_position, page_exit_duration)
	tween.parallel().tween_property(page, "scale", base_scale * page_exit_min_scale_multiplier, page_exit_duration)
	tween.parallel().tween_property(page, "modulate:a", 0.0, page_exit_duration)
	await tween.finished

func _name_by_page(page: CanvasItem) -> String:
	if page == audio_page:
		return "audio"
	if page == pc_controls_page:
		return "pc_controls"
	if page == mobie_controls_page:
		return "mobie_controls"
	if page == graphics_page:
		return "graphics"
	return ""

func _set_only_page_visible(active_page: String) -> void:
	for page_name in ["audio", "pc_controls", "mobie_controls", "graphics"]:
		var page: CanvasItem = _resolve_page(page_name)
		if page == null:
			continue
		page.visible = page_name == active_page

func _set_category_buttons_enabled(enabled: bool) -> void:
	_category_buttons_interactive = enabled
	_apply_category_buttons()

func _set_category_button_state(active_page: String) -> void:
	_category_active_page = active_page
	_apply_category_buttons()

## 把「当前展示哪一页」+「是否可点」应用到三个分类按钮上。
func _apply_category_buttons() -> void:
	_apply_category_button(audio_button, _category_active_page == "audio")
	_apply_category_button(controls_button, _category_active_page == "controls" or _category_active_page == "pc_controls" or _category_active_page == "mobie_controls" or _category_active_page == "mobile_controls")
	_apply_category_button(graphics_button, _category_active_page == "graphics")

## 正在展示的分类按钮用 **texture_pressed** 表现「已选中」，**不再用 disabled**
## （disabled 会画 texture_disabled，那不是我们要的「按下态」贴图）。
## TextureButton 只有在 toggle_mode + button_pressed 时才画 texture_pressed，
## 所以这里用「切换态 + 忽略鼠标」代替 disabled。
func _apply_category_button(button: TextureButton, active: bool) -> void:
	if button == null:
		return
	button.disabled = false
	button.toggle_mode = true
	button.button_pressed = active
	var interactive: bool = _category_buttons_interactive and not active
	button.mouse_filter = Control.MOUSE_FILTER_STOP if interactive else Control.MOUSE_FILTER_IGNORE
	button.focus_mode = Control.FOCUS_ALL if interactive else Control.FOCUS_NONE
	# 正在展示的那个按钮除了「按下态贴图」，还要保持按下时的大小缩放与位移；
	# 切换到其它分类时传 false，它会自行恢复原状。
	if button.has_method("set_locked_visual"):
		button.call("set_locked_visual", active)

## 覆盖基类：退出设置页时把分类按钮恢复成默认外观（默认贴图 + 缩放/位移复位）。
## 否则退场动画期间「正在展示」的那个按钮会一直是按下态，看着像没退干净。
func _on_page_exit() -> void:
	_release_category_visuals()


## 把三个分类按钮的「选中态」全部撤掉（贴图 + 缩放/位移）。
func _release_category_visuals() -> void:
	for button in [audio_button, controls_button, graphics_button]:
		if button == null:
			continue
		button.button_pressed = false
		if button.has_method("set_locked_visual"):
			button.call("set_locked_visual", false)


## 初始焦点：给第一个可交互的分类按钮（跳过当前展示的那一个）。
func _grab_initial_category_focus() -> void:
	if not is_inside_tree():
		return
	for button in [audio_button, controls_button, graphics_button]:
		if button is Control and button.focus_mode != Control.FOCUS_NONE and not button.disabled:
			button.grab_focus()
			return

func _populate_effect_level_options() -> void:
	if not effect_level_option:
		return
	effect_level_option.clear()
	effect_level_option.add_item("低", UiEffectLevel.LOW)
	effect_level_option.add_item("中", UiEffectLevel.MEDIUM)
	effect_level_option.add_item("高", UiEffectLevel.HIGH)
	effect_level_option.select(ui_effect_level)

func _on_effect_level_selected(index: int) -> void:
	ui_effect_level = index
	_apply_effect_level(ui_effect_level)

func _apply_effect_level(level: int) -> void:
	match level:
		UiEffectLevel.LOW:
			print("SettingsScene: 特效等级=低")
		UiEffectLevel.MEDIUM:
			print("SettingsScene: 特效等级=中")
		UiEffectLevel.HIGH:
			print("SettingsScene: 特效等级=高")

## 音频按钮按下
func _on_audio_button_pressed():
	if is_input_locked() or _page_switch_in_progress:
		return
	# 点击音效由 UIButtonFx 组件层在 button_down 时统一播放
	
	# 静默取消控制页面中的映射
	if pc_controls_page and pc_controls_page.has_method("cancel_current_mapping"):
		pc_controls_page.cancel_current_mapping()
	if mobie_controls_page and mobie_controls_page.has_method("cancel_current_mapping"):
		mobie_controls_page.cancel_current_mapping()
	
	await _switch_to_page("audio")

## 控制按钮按下
func _on_controls_button_pressed():
	if is_input_locked() or _page_switch_in_progress:
		return
	# 点击音效由 UIButtonFx 组件层在 button_down 时统一播放
	
	# 静默取消任何映射
	if pc_controls_page and pc_controls_page.has_method("cancel_current_mapping"):
		pc_controls_page.cancel_current_mapping()
	if mobie_controls_page and mobie_controls_page.has_method("cancel_current_mapping"):
		mobie_controls_page.cancel_current_mapping()
	
	var target_page_name := _get_controls_page_name()
	await _switch_to_page(target_page_name)

func _on_graphics_button_pressed():
	if is_input_locked() or _page_switch_in_progress:
		return
	# 点击音效由 UIButtonFx 组件层在 button_down 时统一播放
	if pc_controls_page and pc_controls_page.has_method("cancel_current_mapping"):
		pc_controls_page.cancel_current_mapping()
	if mobie_controls_page and mobie_controls_page.has_method("cancel_current_mapping"):
		mobie_controls_page.cancel_current_mapping()
	await _switch_to_page("graphics")

## 关闭按钮按下
func _on_close_button_pressed():
	if is_input_locked():
		return
	# 点击音效由 UIButtonFx 组件层在 button_down 时统一播放
	_close_settings()

## 覆盖基类：ESC 关闭（重新映射中不关闭）
func _on_ui_cancel() -> void:
	if not esc_enabled:
		return
	if InputMapManager.is_remapping():
		return
	_close_settings()

## 关闭设置场景
func _connect_mobile_controls_signals() -> void:
	if mobie_controls_page and is_instance_valid(mobie_controls_page):
		if mobie_controls_page.has_signal("layout_saved_and_closed"):
			mobie_controls_page.layout_saved_and_closed.connect(_on_mobile_controls_page_saved)

func _on_mobile_controls_page_saved() -> void:
	# 取消布局编辑时的场景暗化逻辑：只恢复交互锁定，不再操作全局亮度。
	set_input_locked(false)

func _close_settings():
	set_process_input(false)
	set_process_unhandled_input(false)

	if close_button:
		close_button.disabled = true

	# 取消任何正在进行的重新映射
	if InputMapManager:
		InputMapManager.cancel_remap()

	# SettingsScene 关闭时不得再操作父层 DarkOverlay：父场景的暗化状态由它自己控制。
	# 退场动画 / 淡出 / 释放 / 宿主页面重新入场 / 淡入 的顺序只在 UIRouter 里定义一处。
	# 若本页面不是被 UIRouter 打开的（例如编辑器里单独运行），则退场后直接释放自己。
	if UIRouter.has_overlay():
		await UIRouter.close_overlay()
	else:
		await ui_exit()
		queue_free()

## 音量控制函数
func _on_master_volume_changed(value: float):
	AudioManager.set_bus_volume_percent("Master", value)
	if master_volume_label:
		master_volume_label.text = "主  音 量：%d%%" % int(round(clampf(value, 0.0, 100.0)))

func _on_bgm_volume_changed(value: float):
	AudioManager.set_bus_volume_percent("BGM", value)
	if bgm_volume_label:
		bgm_volume_label.text = "背景音量：%d%%" % int(round(clampf(value, 0.0, 100.0)))

func _on_sfx_volume_changed(value: float):
	AudioManager.set_bus_volume_percent("SFX", value)
	if sfx_volume_label:
		sfx_volume_label.text = "音效音量：%d%%" % int(round(clampf(value, 0.0, 100.0)))


## 根据当前滑块值刷新三个音量标题的百分比显示。
func _refresh_all_volume_labels() -> void:
	if master_volume_label and master_volume_slider:
		master_volume_label.text = "主  音 量：%d%%" % int(round(clampf(master_volume_slider.value, 0.0, 100.0)))
	if bgm_volume_label and bgm_volume_slider:
		bgm_volume_label.text = "背景音量：%d%%" % int(round(clampf(bgm_volume_slider.value, 0.0, 100.0)))
	if sfx_volume_label and sfx_volume_slider:
		sfx_volume_label.text = "音效音量：%d%%" % int(round(clampf(sfx_volume_slider.value, 0.0, 100.0)))

## 音量滑块拖拽开始时播放点击音效
func _on_volume_slider_drag_started():
	AudioManager.play_button_click_sfx()

func _exit_tree():
	LightingManager.stop_all_light_effects()

## 覆盖基类：把输入锁应用到本页面的按钮上。
## 注意：本页面锁定输入时**不吞鼠标事件**（基类 lock_swallows_mouse 已设为 false），
## 因为移动端布局编辑态下仍需让按钮接收拖动事件。
func _on_input_lock_applied(locked: bool) -> void:
	if locked:
		_set_category_buttons_enabled(false)
		close_button.disabled = true
		return

	close_button.disabled = false
	_set_category_buttons_enabled(true)
	_set_category_button_state(_current_page_name)
	# 锁定期间分类按钮会被设成不可聚焦（引擎会顺手释放焦点），解锁后补一次初始焦点
	_grab_initial_category_focus()


## ---- 以下动效 / 等待 / 节点收集逻辑已全部上提到 UIScene / UIFxDirector，本文件不再重复实现 ----
