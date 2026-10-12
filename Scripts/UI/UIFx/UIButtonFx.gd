class_name UIButtonFx
extends TextureButton
## UI 按钮动效组件（三层架构中的「组件层」）。
##
## 挂在任意 TextureButton 上即可获得：
##   * 悬停（mouse_entered）：弹性缩放（回弹）+ 仅进入瞬间随机一次的微小旋转 + 文本轻微提亮 + 悬停音效
##   * 移出（mouse_exited）：平滑复位（无回弹）
##   * 按下（button_down）：按下音效（按下即响，比「松开才响」更跟手）
##   * 入场 / 退场：从下方上浮 + 轻 overshoot 缩放 + 淡入（由 UIFxDirector 调度，可错开时序）
##
## 设计约束：
##   * 悬停只写 `scale` / `rotation` / 子节点 Label.modulate；
##     入场退场写 `scale` / `modulate.a` / 位置漂移。两者**时间上互斥**：
##     入场退场进行中（_transition_active）或按钮 disabled 时，悬停与音效被完全忽略。
##   * 同一通道同一时刻只允许一个 Tween，新动画启动时旧动画被 kill，绝不叠加。
##   * 只关心「自己要怎么动 / 自己该响什么」，不处理点击业务、不管理其它节点。
##   * 位置漂移不直接 tween `position`（容器排版会覆盖它），而是 tween 一个进度值
##     再换算成 `position`，并在容器重排时自动重新叠加偏移。
##   * **不修改 texture_filter 的采样方式**：像素画工程全程 Nearest。
##     非 90° 旋转在 Nearest 下必然重采样（像素错位），这是几何事实，
##     用「动画期间临时切 Linear」只能掩盖且会让像素糊掉，因此不采用。

@export_category("悬停 · 缩放")
## 悬停目标缩放倍率（相对按钮自身基准 scale）。1.02 ~ 1.06 之间比较克制。
@export_range(1.0, 1.2, 0.005) var hover_scale_multiplier: float = 1.06
## 悬停放大时长（秒）。弹性回弹由 TRANS_ELASTIC 提供。
@export_range(0.05, 1.0, 0.01) var hover_enter_duration: float = 0.16
## 移出复位时长（秒）。
@export_range(0.05, 1.0, 0.01) var hover_exit_duration: float = 0.12

@export_category("悬停 · 旋转（默认关闭）")
## 随机旋转上限（度）。**默认 0（关闭）**：Nearest 采样下非 90° 旋转必然重采样，
## 表现为「像素被重新排列」，且无法用过滤方式消除（切 Linear 会把像素弄糊，已否决）。
## 单个按钮确实想要倾斜感时，建议改用「贴图级倾斜」（另做一张倾斜版贴图），而不是改这个值。
@export_range(0.0, 10.0, 0.1) var hover_rotate_degrees: float = 0.0
## 长按钮判定：屏幕最长边超过该值即视为「长按钮」。
@export_range(20.0, 2000.0, 1.0) var long_button_min_side: float = 200.0
## 长按钮判定：屏幕宽高比超过该值即视为「长按钮」。
@export_range(1.0, 10.0, 0.1) var long_button_aspect_threshold: float = 2.0
## 长按钮使用的随机旋转上限（度）。
@export_range(0.0, 10.0, 0.1) var long_button_rotate_degrees: float = 0.0

@export_category("悬停 · 像素位移")
## 悬停时的整体位移（像素）。**只取整像素**，因此不会引入任何重采样，像素画安全。
## 例：(0, -2) = 向上抬 2 像素，模拟「抬起来」的手感。
@export var hover_offset: Vector2 = Vector2(0.0, -4.0)
## 位移时长（秒）。
@export_range(0.02, 1.0, 0.01) var hover_offset_duration: float = 0.16

@export_category("悬停 · 文本提亮")
## 文本子节点提亮倍率（modulate 乘算，>1 即提亮）。1.0 = 不提亮。
@export_range(1.0, 2.0, 0.01) var label_brightness: float = 1.2
## 文本提亮/回落时长（秒）。
@export_range(0.02, 1.0, 0.01) var label_brightness_duration: float = 0.12

@export_category("入场 / 退场")
## 入场时长（秒）。
@export_range(0.05, 2.0, 0.01) var enter_duration: float = 0.32
## 入场起始位置相对基准位置的漂移（像素）。
@export var enter_drift_distance: Vector2 = Vector2(0.0, 16.0)
## 入场起始的额外放大倍率（配合 TRANS_BACK 形成轻 overshoot）。
@export_range(1.0, 1.5, 0.005) var enter_overshoot_scale: float = 1.08
## 退场时长（秒）。
@export_range(0.05, 2.0, 0.01) var exit_duration: float = 0.32
## 退场结束位置相对基准位置的漂移（像素）。
@export var exit_drift_distance: Vector2 = Vector2(0.0, 16.0)
## 入场淡化占 enter_duration 的比例（1.0 = 全程线性淡入；
## 0.5 = 前一半完成 透明→不透明，后一半保持不透明，让位移/缩放看得更清）。
@export_range(0.05, 1.0, 0.01) var enter_fade_ratio: float = 0.1
## 退场淡化占 exit_duration 的比例（1.0 = 全程线性淡出；
## 0.5 = 后半段才开始淡出，先看得见地沉下去再消失）。
@export_range(0.05, 1.0, 0.01) var exit_fade_ratio: float = 0.2

@export_category("音效")
## 是否启用本组件的悬停 / 按下音效。
@export var enable_sfx: bool = true
## 悬停音效。
@export var hover_sfx_stream: AudioStream = preload("res://Assets/Audios/SFX/Box/短促挥舞.wav")
## 按下音效。
@export var press_sfx_stream: AudioStream = preload("res://Assets/Audios/SFX/UI/鼠标点击.wav")

@export_category("退场")
## 退场前是否先把「悬停/按下」的像素位移与缩放按「鼠标移出」的方式平滑收回去。
## 背景：点击按钮切场景时，鼠标往往还按在按钮上（mouse_exited 不会触发），
## 若直接归位会看到「位移瞬间弹回 → 再下移退场」的抽动。
@export var release_hover_before_exit: bool = true

@export_category("通用")
## 是否接受 UIFxDirector（动效总线）的入场/退场调度。
## 关闭后：本按钮不再自己入场/退场，完全跟着父节点走（
## 适用于「按钮的父节点已经参与了 UITransitionAnimator」这种双重演出场景）。
@export var fx_managed: bool = true
## 像素画工程：强制最近邻采样，避免静止时像素块被插值糊掉。
@export var force_nearest_filter: bool = true

## 基准缩放（按钮在场景里的原始 scale，可能是 2 / 2.5 / 3 / 4）。
var _base_scale: Vector2 = Vector2.ONE
## 基准旋转（弧度）。
var _base_rotation: float = 0.0
## 基准 modulate。
var _base_modulate: Color = Color.WHITE
## 基准位置（= 排版位置）。**只由 _cache_base 与容器重排事件写入**，
## 绝不被漂移写回，否则基准会被污染（标题→设置→返回 按钮整体下移的根因）。
var _base_position: Vector2 = Vector2.ZERO

## 文本子节点（直接子节点里名为 Label，或第一个 Label）。
var _label: Label = null
## 文本基准颜色。
var _label_base_color: Color = Color.WHITE

## 悬停通道 Tween。
var _hover_tween: Tween = null
## 入场/退场通道 Tween。
var _trans_tween: Tween = null
## 入场/退场进行中：期间忽略悬停与移出。
var _transition_active: bool = false
## 鼠标是否停在按钮上。
var _hovering: bool = false
## 是否长期保持「悬停 / 按下」视觉（选中的分类按钮等）。
var locked_visual: bool = false
## 入场动画结束时鼠标已在按钮上、但页面还锁着输入 → 等解锁那一帧再补悬停。
var _pending_hover_sync: bool = false
## 位置漂移进度：0 = 完全偏移，1 = 归位。
var _drift_progress: float = 1.0
## 当前漂移向量（单位距离 × 方向）。
var _drift_offset: Vector2 = Vector2.ZERO
## 当前悬停位移（会被取整到整数像素后参与 position 计算）。
var _hover_offset_current: Vector2 = Vector2.ZERO
## 本次退场“悬停回收阶段”占用的时长（供调度层估算总时长；play_exit 时写入）。
var _exit_release_duration: float = 0.0
## 父节点是容器时，容器重排会覆盖 position，需要重新叠加漂移。
var _parent_container: Container = null


func _ready() -> void:
	if force_nearest_filter:
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_cache_base()
	_label = _find_label()
	if _label != null:
		_label_base_color = _label.modulate

	if not mouse_entered.is_connected(_on_mouse_entered):
		mouse_entered.connect(_on_mouse_entered)
	if not mouse_exited.is_connected(_on_mouse_exited):
		mouse_exited.connect(_on_mouse_exited)
	if not button_down.is_connected(_on_button_down):
		button_down.connect(_on_button_down)

	var parent_node: Node = get_parent()
	if parent_node is Container:
		_parent_container = parent_node as Container
		if not _parent_container.sort_children.is_connected(_on_parent_sorted):
			_parent_container.sort_children.connect(_on_parent_sorted)

	set_process(false)


## 只把按钮摆到「入场起始态」并声明过渡中，**不播动画**。
## 用途：页面级流程在黑屏期间先摆好位姿，等黑屏过渡结束再 `play_enter()`，
## 这样入场动画不会被黑屏/淡入盖掉（否则玩家只会看到动画的尾巴）。
func prepare_enter() -> void:
	_kill_transition_tween()
	_apply_enter_start_state()


## 入场起始态：漂移 + overshoot 放大 + 全透明（供 play_enter / prepare_enter 复用）。
func _apply_enter_start_state() -> void:
	# 先把上一次的残留（尤其是退场留下的漂移）清干净，保证每次入场都从同一基准出发。
	_settle_to_base()
	_exit_release_duration = 0.0
	_transition_active = true
	set_process(false)
	_hovering = false
	_drift_offset = enter_drift_distance
	_drift_progress = 0.0
	scale = _base_scale * enter_overshoot_scale
	modulate = Color(_base_modulate.r, _base_modulate.g, _base_modulate.b, 0.0)
	rotation = _base_rotation
	_apply_position_offset()


## 对外统一接口：播放入场动画（可被 UIFxDirector 错开延迟调用）。协程，调用方需 await。
func play_enter(delay: float = 0.0) -> void:
	_kill_transition_tween()
	_apply_enter_start_state()

	if delay > 0.0:
		await get_tree().create_timer(delay, true, false, false).timeout
		if not is_inside_tree():
			return

	var fade_duration: float = maxf(0.01, enter_duration * enter_fade_ratio)
	_trans_tween = create_tween()
	_trans_tween.set_parallel(true)
	_trans_tween.tween_property(self, "scale", _base_scale, enter_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# 淡化只占时长的一部分（默认前 50%），位移/缩放继续走完
	_trans_tween.tween_property(self, "modulate:a", _base_modulate.a, fade_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_trans_tween.tween_method(_set_drift_progress, 0.0, 1.0, enter_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await _trans_tween.finished

	_transition_active = false
	_settle_to_base()
	# 入场动画结束时要把视觉状态重新对齐一次（因为 _settle_to_base 会把缩放/位移复位）：
	#   * locked_visual（正在展示的分类按钮）：恢复「按下态」的缩放与位移；
	#   * 否则按「鼠标是否真的在按钮上」补一次悬停 —— 入场期间 mouse_entered 会被忽略，
	#     不补的话就会出现「贴图已经变成 hover、但没有缩放/位移」的错位状态。
	if locked_visual:
		_apply_hover_visual()
	else:
		_sync_hover_state()


## 对外统一接口：播放退场动画（可被 UIFxDirector 错开延迟调用）。协程，调用方需 await。
##
## 两阶段：
##   ① 悬停回收：若按钮此刻还停在悬停/按下状态，先用与「鼠标移出」完全相同的通道
##      把像素位移 / 缩放 / 文本提亮收回去（`_end_hover()`），不瞬间归位。
##   ② 退场：从已归位的基准出发做下沉 + 淡出。
## 总时长会通过 `get_fx_duration("exit")` 如实上报，调度层据此等待，不会提前切场。
func play_exit(delay: float = 0.0) -> void:
	_kill_transition_tween()

	# ① 悬停回收阶段
	var release_duration: float = 0.0
	if release_hover_before_exit and _needs_hover_release():
		release_duration = maxf(hover_exit_duration, 0.0)
		_hovering = false
		set_process(false)
		# 复用「鼠标移出」通道：位移→0、缩放→基准、文本→基准色，全程平滑。
		_end_hover()
	else:
		_settle_to_base()
	_exit_release_duration = release_duration
	_transition_active = true

	if delay > 0.0:
		await get_tree().create_timer(delay, true, false, false).timeout
		if not is_inside_tree():
			return
	if release_duration > 0.0:
		await get_tree().create_timer(release_duration, true, false, false).timeout
		if not is_inside_tree():
			return

	# ② 真正的退场（此刻已彻底归位）
	_settle_to_base()
	_drift_offset = exit_drift_distance
	_drift_progress = 1.0
	var fade_out_duration: float = maxf(0.01, exit_duration * exit_fade_ratio)
	_trans_tween = create_tween()
	_trans_tween.set_parallel(true)
	_trans_tween.tween_property(self, "scale", _base_scale * 0.92, exit_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	# 淡化贴到结尾（默认最后 50% 才淡出）：先看得见地沉下去，再消失
	_trans_tween.tween_property(self, "modulate:a", 0.0, fade_out_duration) \
		.set_delay(maxf(0.0, exit_duration - fade_out_duration)) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_trans_tween.tween_method(_set_drift_progress, 1.0, 0.0, exit_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await _trans_tween.finished

	_transition_active = false
	# 退场结束时按钮已完全透明（modulate.a = 0），此时把漂移归零、位置写回基准，
	# 让组件回到「已归位」状态，下一次 play_enter 才能拿到正确的排版基准。
	_drift_offset = Vector2.ZERO
	_drift_progress = 1.0
	_hover_offset_current = Vector2.ZERO
	position = _base_position


## 退场前是否需要先回收悬停状态（鼠标还按在按钮上 / 位移/缩放尚未归位）。
func _needs_hover_release() -> bool:
	if _hovering:
		return true
	if _hover_offset_current != Vector2.ZERO:
		return true
	if _hover_tween != null and _hover_tween.is_valid():
		return true
	return false


## 入场/退场动画时长（供调度层计算整体时长）。
## 退场时长含「悬停回收阶段」，否则调度层会以为已经播完而提前切场。
func get_fx_duration(kind: String = "enter") -> float:
	if kind == "enter":
		return enter_duration
	return _exit_release_duration + exit_duration


## 立刻回到基准状态并清掉所有动画（场景要隐藏/重排时可手动调用）。
func settle_now() -> void:
	_kill_transition_tween()
	_transition_active = false
	set_process(false)
	_hovering = false
	_settle_to_base()


## 供外部（如面板级整体动画）显式声明「现在处于过渡中，请忽略悬停」。
func set_transition_blocked(blocked: bool) -> void:
	if blocked == _transition_active:
		return
	if blocked:
		_transition_active = true
		_kill_hover_tween()
		_settle_to_base()
		set_process(false)
	else:
		_transition_active = false


func is_transition_active() -> bool:
	return _transition_active


## 调试 / 自动化 QA 用：返回当前动效状态快照。
func get_debug_state() -> Dictionary:
	return {
		"base_scale": _base_scale,
		"scale": scale,
		"base_rotation_deg": rad_to_deg(_base_rotation),
		"rotation_deg": rad_to_deg(rotation),
		"base_position": _base_position,
		"position": position,
		"drift_progress": _drift_progress,
		"hover_offset": _hover_offset_current,
		"modulate_a": modulate.a,
		"transition_active": _transition_active,
		"hovering": _hovering,
		"disabled": disabled,
		"size": size,
		"label_text": _label.text if _label != null and is_instance_valid(_label) else "",
		"label_color": _label.modulate if _label != null and is_instance_valid(_label) else Color.WHITE,
	}


func _cache_base() -> void:
	_base_scale = scale
	_base_rotation = rotation
	_base_modulate = modulate
	_base_position = position


func _find_label() -> Label:
	var direct: Node = get_node_or_null("Label")
	if direct is Label:
		return direct as Label
	for child in get_children():
		if child is Label:
			return child as Label
	return null


## 文本字号自适应已移除：Label 的字体/字号完全由场景与 Theme / LabelSettings 决定，
## 组件不再做任何 font / font_size 覆盖，避免编辑器设置与运行时不一致。


## 容器重排会直接覆盖 position；容器写回的 position 就是「排版基准」，
## 因此先刷新基准、再把当前偏移叠加回去（否则动画中途偏移会被容器抹掉）。
func _on_parent_sorted() -> void:
	_base_position = position
	if _drift_progress < 1.0 or _hover_offset_current != Vector2.ZERO:
		_apply_position_offset()


func _set_drift_progress(value: float) -> void:
	_drift_progress = value
	_apply_position_offset()


func _set_hover_offset(value: Vector2) -> void:
	_hover_offset_current = value
	_apply_position_offset()


## 把「入场/退场漂移」与「悬停位移」合并成唯一的 position 写入点。
## 结果取整到整数像素：像素画工程下亚像素平移会造成亚像素采样和抖动。
func _apply_position_offset() -> void:
	var offset: Vector2 = _drift_offset * (1.0 - _drift_progress) + _hover_offset_current
	position = _base_position + offset.round()


func _settle_to_base() -> void:
	_kill_hover_tween()
	scale = _base_scale
	rotation = _base_rotation
	if _label != null and is_instance_valid(_label):
		_label.modulate = _label_base_color
	_drift_offset = Vector2.ZERO
	_drift_progress = 1.0
	_hover_offset_current = Vector2.ZERO
	position = _base_position
	modulate = _base_modulate


func _on_mouse_entered() -> void:
	if locked_visual or _transition_active or disabled or not is_inside_tree():
		return
	_play_hover_sfx()
	_apply_hover_visual()


## 让按钮长期停留在「悬停 / 按下」的视觉状态（缩放 + 像素位移 + 文本提亮）。
## 典型用法：设置界面里「正在展示」的那个分类按钮 —— 除了按下态贴图，
## 还要保持按下时的大小与位移；切换到其它分类时传 false 恢复原状。
func set_locked_visual(enabled: bool) -> void:
	if locked_visual == enabled:
		return
	locked_visual = enabled
	if enabled:
		if not _transition_active and is_inside_tree():
			_apply_hover_visual()
	else:
		_hovering = false
		set_process(false)
		_end_hover()


## 让「视觉状态」与「鼠标是否真的在按钮上」对齐（入场结束时调用）。
func _sync_hover_state() -> void:
	if locked_visual:
		return
	# 入场动画结束时页面往往还锁着输入：按钮可能是 disabled，
	# 也可能被页面改成 mouse_filter = IGNORE（例如设置页的分类按钮）。
	# 这种状态下判定悬停必然失败，改为交给 _process 在「真正可悬停」的那一帧补上 ——
	# 否则就会出现「贴图已是 hover、但没有缩放/位移」（TitleScene）
	# 或「完全无视鼠标」（SettingsScene）这类错位。
	if not _can_receive_hover():
		_pending_hover_sync = true
		set_process(true)
		return
	_pending_hover_sync = false
	if _is_mouse_over():
		if not _hovering:
			_on_mouse_entered()
	elif _hovering:
		_on_mouse_exited()


## 当前是否「真的能收到悬停」（disabled / mouse_filter=IGNORE / 不可见 时收不到）。
func _can_receive_hover() -> bool:
	if disabled or not is_visible_in_tree():
		return false
	return mouse_filter != Control.MOUSE_FILTER_IGNORE


## 鼠标当前是否停在本按钮上（入场/移出信号被忽略时用它兜底）。
func _is_mouse_over() -> bool:
	return _can_receive_hover() and get_global_rect().has_point(get_global_mouse_position())


## 应用「悬停 / 按下」视觉（缩放 + 像素位移 + 旋转 + 文本提亮）。
func _apply_hover_visual() -> void:
	_hovering = true
	set_process(true)
	_kill_hover_tween()

	var target_scale: Vector2 = _base_scale * hover_scale_multiplier
	var target_rotation: float = _base_rotation + deg_to_rad(_roll_hover_angle())

	_hover_tween = create_tween()
	_hover_tween.set_parallel(true)
	# 弹性回弹：先冲过目标再弹回稳定。
	_hover_tween.tween_property(self, "scale", target_scale, hover_enter_duration) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	# 像素位移：拿位置取整到整像素，不引入任何重采样（像素画安全的“抬起来”手感）。
	_hover_tween.tween_method(_set_hover_offset, _hover_offset_current, hover_offset, hover_offset_duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# 旋转默认关闭（hover_rotate_degrees = 0 时本通道实质为空操作）。
	# 旋转只在此刻随机一次，鼠标停在按钮上不会再抖。
	_hover_tween.tween_property(self, "rotation", target_rotation, hover_enter_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if _label != null and is_instance_valid(_label):
		_hover_tween.tween_property(_label, "modulate", _brightened_label_color(), label_brightness_duration) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _on_mouse_exited() -> void:
	if locked_visual:
		return
	if not _hovering:
		return
	_hovering = false
	set_process(false)
	_end_hover()


## 悬停期间每帧检查：按钮被 disabled（场景锁定输入 / 面板开始整体动画）时立即归位，
## 避免本组件的 Tween 与场景级 Tween 同时写 scale 造成抖动；
## 同时负责「解锁那一帧」补上入场结束时应有的悬停表现。
func _process(_delta: float) -> void:
	if _hovering and disabled:
		_hovering = false
		_end_hover()
		if not _pending_hover_sync:
			set_process(false)
		return
	if _pending_hover_sync and _can_receive_hover():
		_pending_hover_sync = false
		_sync_hover_state()
		if not _hovering:
			set_process(false)


func _end_hover() -> void:
	_kill_hover_tween()
	_hover_tween = create_tween()
	_hover_tween.set_parallel(true)
	_hover_tween.tween_property(self, "scale", _base_scale, hover_exit_duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_hover_tween.tween_method(_set_hover_offset, _hover_offset_current, Vector2.ZERO, hover_offset_duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_hover_tween.tween_property(self, "rotation", _base_rotation, hover_exit_duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	if _label != null and is_instance_valid(_label):
		_hover_tween.tween_property(_label, "modulate", _label_base_color, hover_exit_duration) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## 按下瞬间播放点击音效（按下即响，比在业务层 on_pressed 里播更跟手、
## 也让所有按钮的音效来源统一到组件层）。
func _on_button_down() -> void:
	if not enable_sfx:
		return
	if not is_inside_tree():
		return
	AudioManager.play_button_click_sfx(press_sfx_stream)


func _play_hover_sfx() -> void:
	if not enable_sfx:
		return
	AudioManager.play_button_hover_sfx(hover_sfx_stream)


## 按按钮屏幕尺寸（size × scale）决定本次悬停的随机旋转上限。
func _roll_hover_angle() -> float:
	var on_screen: Vector2 = Vector2(absf(size.x * _base_scale.x), absf(size.y * _base_scale.y))
	var limit: float = hover_rotate_degrees
	if on_screen.x > 0.0 and on_screen.y > 0.0:
		var longest: float = maxf(on_screen.x, on_screen.y)
		var aspect: float = maxf(on_screen.x, on_screen.y) / maxf(1.0, minf(on_screen.x, on_screen.y))
		if longest >= long_button_min_side or aspect >= long_button_aspect_threshold:
			limit = long_button_rotate_degrees
	if limit <= 0.0:
		return 0.0
	return randf_range(-limit, limit)


func _brightened_label_color() -> Color:
	return Color(
		_label_base_color.r * label_brightness,
		_label_base_color.g * label_brightness,
		_label_base_color.b * label_brightness,
		_label_base_color.a
	)


func _kill_hover_tween() -> void:
	if _hover_tween != null and _hover_tween.is_valid():
		_hover_tween.kill()
	_hover_tween = null


func _kill_transition_tween() -> void:
	if _trans_tween != null and _trans_tween.is_valid():
		_trans_tween.kill()
	_trans_tween = null
