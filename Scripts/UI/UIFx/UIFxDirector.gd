class_name UIFxDirector
extends Node
## UI 动效总线（UI 架构重做第 2 层：表现层调度）。
##
## 它把原先互不相干的三套机制收敛成**一条总线 + 一个状态**：
##   * 过渡轨道：`UITransitionAnimator`（页面整体 / 标题的开合）—— 鸭子类型发现，不依赖具体类
##   * 循环轨道：`UILoopAnimator`（常态循环动画，进入即开始、退场即结束，不参与等待）
##   * 组件轨道：任何具备 `play_enter` / `play_exit` / `get_fx_duration` 的节点（按钮等），按树序错开
##
## 对外只有三件事：
##     play_enter() / play_exit()   触发（**纯同步**，不阻塞、可直接 call()）
##     is_busy()                    还在播吗（业务层轮询它）
##
## ── 为什么用「截止时间戳」而不是计数 + 信号 ────────────────
## Godot 4 中 `obj.call("coro")` 不返回可等待对象；而 `play_enter()` 可能在调用方
## 开始等待之前就已经播完并发出信号，`await` 信号会永远等不到 → 死锁
## （曾导致输入锁永不解除、按钮永久点不动）。
## 现在：触发时按各组件的声明时长算出总时长并写下一个截止时间戳，busy 完全由时间决定，
## **既没有需要配对的计数器（不会涓漏），也没有可能已经发生过的信号（不会死锁）**。

@export_category("错开时序")
## 相邻组件之间的错开间隔（秒）。0 = 全部同时播放。
@export_range(0.0, 0.5, 0.005) var stagger_delay: float = 0.05
## 入场：第一个组件之前的额外延迟（秒）。
@export_range(0.0, 2.0, 0.01) var enter_first_delay: float = 0.1
## 退场：第一个（倒序后最先播放的）组件之前的额外延迟（秒）。
@export_range(0.0, 2.0, 0.01) var exit_first_delay: float = 0.0
## 过渡轨道（UITransitionAnimator）的入场额外延迟（秒）。
## 用它做层次感：例如过渡 0.0、组件 enter_first_delay 0.15 →「背景/标题先动、按钮随后」。
@export_range(0.0, 2.0, 0.01) var transition_enter_delay: float = 0.15
## 过渡轨道的退场额外延迟（秒）。
@export_range(0.0, 2.0, 0.01) var transition_exit_delay: float = 0.0

@export_category("轨道开关")
## 驱动组件轨道（按钮等）。
@export var drive_components: bool = true
## 驱动过渡轨道（本页面的 UITransitionAnimator）。
@export var drive_transition: bool = true
## 驱动循环轨道（本页面的 UILoopAnimator）。
@export var drive_loop: bool = true

@export_category("收集规则")
## 只处理 is_visible_in_tree() 为 true 的组件：隐藏页面里的按钮不参与错开。
@export var only_visible_components: bool = true
## 是否打印调度信息（排查时序问题时打开）。
@export var debug_log: bool = false

# ════════════════════════════════════════════════════════════
# 过渡轨道（原本的 UITransitionAnimator，现已并入总线）
# ════════════════════════════════════════════════════════════
# 「哪些节点参与页面整体开合」现在只在本节点上配置一处，不再有两份目标列表。
# 兼容：若场景里还留着旧的 UITransitionAnimator 节点，仍然优先交给它驱动。

@export_category("过渡轨道（页面整体开合）")
## 参与过渡动画的节点路径（相对本节点，例如 "../Background"）。只接受 CanvasItem。
@export var target_paths: Array[NodePath] = []
## 漂移距离（像素，Vector2）。例如 (0, -12) = 入场从上方归位、退场收向上方；(-48, 0) = 左右漂移。
@export var drift_distance: Vector2 = Vector2(0.0, 12.0)
## 入场动画总时长（秒）。
@export var enter_duration: float = 0.8
## 退场动画总时长（秒）。
@export var exit_duration: float = 0.6
## 入场：从 0 放大到峰值阶段的占比（与 exit_peak_phase_ratio 对称）。
@export_range(0.1, 0.8, 0.05) var enter_peak_phase_ratio: float = 0.2
## 入场峰值停顿时长（秒）。
@export var enter_peak_hold_duration: float = 0.28
## 退场：放大到峰值阶段的占比。
@export_range(0.1, 0.8, 0.05) var exit_peak_phase_ratio: float = 0.2
## 退场峰值停顿时长（秒）。
@export var exit_peak_hold_duration: float = 0.24
## 放大峰值倍率。
@export var peak_scale_multiplier: float = 1.2
## 入场淡化占总时长的比例（从 0 开始：前 35% 内完成 透明→不透明）。
@export_range(0.05, 1.0, 0.01) var enter_fade_ratio: float = 0.35
## 退场淡化占总时长的比例（贴到结尾：最后 40% 才淡出）。
@export_range(0.05, 1.0, 0.01) var exit_fade_ratio: float = 0.4
## 没有任何人调用 play_enter() 时，_ready 后自动播一次入场。
## （独立 add_child() 的面板 —— 例如删除确认对话框 —— 需要开启）
@export var auto_enter_on_ready: bool = false

## 入场 / 退场的预计结束时间戳（毫秒）。
## busy 判定完全由「当前时间是否已超过截止时间」决定：
## 没有计数器、没有代次号，所以**不存在「批次被取代后计数涓漏导致 busy 永远为真」的可能**。
var _enter_deadline_ms: int = 0
var _exit_deadline_ms: int = 0
## 过渡目标（解析后的节点）及其编辑器基态。
var _targets: Array[CanvasItem] = []
var _init_modulates: Array[Color] = []
var _init_positions: Array[Vector2] = []
var _init_scales: Array[Vector2] = []
## 每个目标是否允许位移补间：父节点是 Container 时不允许
## （容器重排会覆盖 position，且 Godot 会对「向容器子节点写 position」报错）。
var _target_allows_drift: Array[bool] = []
## 位移/缩放 Tween 与淡化 Tween（分开，避免同一属性在一条 Tween 里重复补间）。
var _transition_tween: Tween = null
var _transition_fade_tween: Tween = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_cache_targets()
	_apply_transition_enter_start_state()
	if auto_enter_on_ready:
		call_deferred("play_enter")


## 入场是否仍在进行。
func is_enter_busy() -> bool:
	return Time.get_ticks_msec() < _enter_deadline_ms


## 退场是否仍在进行。
func is_exit_busy() -> bool:
	return Time.get_ticks_msec() < _exit_deadline_ms


## 任意方向是否仍在进行（业务层的统一等待入口）。
func is_busy() -> bool:
	return is_enter_busy() or is_exit_busy()


## 预计时长（秒）——供外部估算，不改变任何状态。
func estimate_duration(kind: String = "enter") -> float:
	return _compute_total(kind, collect_components())


## 播放本页所有轨道的入场动画。**同步返回**（不阻塞、可安全被 call()）。
func play_enter(root: Node = null) -> void:
	var comps: Array[Node] = []
	if drive_components:
		comps = collect_components(root)
	var total: float = _fire_components(comps, "enter")

	if drive_transition:
		total = maxf(total, _fire_transition(root, "enter"))

	if drive_loop:
		_play_loop(root, true)

	_enter_deadline_ms = _deadline_from(total)


## 播放本页所有轨道的退场动画（组件倒序）。**同步返回**。
func play_exit(root: Node = null) -> void:
	var comps: Array[Node] = []
	if drive_components:
		comps = collect_components(root)
	var total: float = _fire_components(comps, "exit")

	if drive_transition:
		total = maxf(total, _fire_transition(root, "exit"))

	if drive_loop:
		_play_loop(root, false)

	_exit_deadline_ms = _deadline_from(total)


## 只把本页所有轨道摆到「入场起始态」，**不播动画、不算 busy**。
## 用途：页面级流程在黑屏过渡期间先摆好位姿，等黑屏结束再 `play_enter()`，
## 保证入场动画完整可见（否则动画会被黑屏/淡入盖掉，玩家只看到尾巴）。
func prepare_enter(root: Node = null) -> void:
	if drive_components:
		for comp in collect_components(root):
			if comp.has_method("prepare_enter"):
				comp.call("prepare_enter")
	if drive_transition:
		prepare_enter_transition()
	_enter_deadline_ms = 0


## 立即把所有组件拉回基准状态（不做动画）。
func settle_all_now(root: Node = null) -> void:
	for comp in collect_components(root):
		if comp.has_method("settle_now"):
			comp.call("settle_now")


## 收集场景根子树下所有具备动效能力的组件（节点树前序，顺序稳定）。
func collect_components(root: Node = null) -> Array[Node]:
	var found: Array[Node] = []
	var actual_root: Node = root if root != null else get_parent()
	if actual_root == null:
		return found
	_collect_recursive(actual_root, found)
	# 互斥：同一个节点不能同时被「过渡轨道」和「组件轨道」驱动 ——
	# 两套 Tween 同时写 scale/position/modulate 会互相覆盖（表现为抖动、位移叠加）。
	# 这类节点默认交给过渡轨道，从组件列表里移除。
	for t in _targets:
		if found.has(t):
			found.erase(t)
			if debug_log:
				print("[UIFxDirector] 跳过同时参与过渡轨道的组件：%s" % t.name)
	return found


## 本页面内的常态循环动画器（递归扫描、不依赖节点名）。
func find_loop_animators(root: Node = null) -> Array[Node]:
	var actual_root: Node = root if root != null else get_parent()
	var found: Array[Node] = []
	if actual_root == null:
		return found
	_collect_loop_animators(actual_root, found)
	return found


# ──────────────── 过渡轨道：对外接口 ────────────────

## 只把过渡目标摆到「入场起始态」，不播动画（页面级流程在黑屏期间调用）。
func prepare_enter_transition() -> void:
	_stop_transition_tweens()
	_apply_transition_enter_start_state()


## 当前参与过渡的目标（供 collect_components 做互斥判断）。
func get_transition_targets() -> Array[CanvasItem]:
	return _targets


## 是否至少有一个有效过渡目标。
func has_targets() -> bool:
	return not _targets.is_empty()


## 重新解析目标并刷新基态缓存（目标节点被替换/改动后调用）。
func refresh_targets() -> void:
	_cache_targets()


## 还原到缓存的编辑器基态（不做动画）。
func reset_state() -> void:
	_stop_transition_tweens()
	for i in _targets.size():
		_targets[i].modulate = _init_modulates[i]
		_targets[i].position = _init_positions[i]
		_targets[i].scale = _init_scales[i]


## 播放入场过渡（协程）。
func play_enter_transition(delay: float = 0.0) -> void:
	if _targets.is_empty():
		return
	_stop_transition_tweens()
	_apply_transition_enter_start_state()
	if delay > 0.0:
		await get_tree().create_timer(delay, true, false, false).timeout
		if not is_inside_tree():
			return
	var peak_duration: float = maxf(0.01, enter_duration * enter_peak_phase_ratio)
	var hold_duration: float = minf(maxf(0.0, enter_peak_hold_duration), maxf(0.0, enter_duration - peak_duration - 0.01))
	var settle_duration: float = maxf(0.01, enter_duration - peak_duration - hold_duration)
	# 淡化：单独一条 Tween，只占总时长的 enter_fade_ratio（默认在开头 35% 内完成）
	_transition_fade_tween = create_tween()
	_transition_fade_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var fade_duration: float = _fade_duration(enter_duration, enter_fade_ratio)
	for i in _targets.size():
		_transition_fade_tween.parallel().tween_property(_targets[i], "modulate:a", _init_modulates[i].a, fade_duration)
	# 缩放/位移：与退场严格相反 —— 0 → 峰值 → 停顿 → 基准
	_transition_tween = create_tween()
	_transition_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	for i in _targets.size():
		_transition_tween.parallel().tween_property(_targets[i], "scale", _init_scales[i] * peak_scale_multiplier, peak_duration)
	if hold_duration > 0.0:
		_transition_tween.chain().tween_interval(hold_duration)
	_transition_tween.chain()
	for i in _targets.size():
		var target: CanvasItem = _targets[i]
		_transition_tween.parallel().tween_property(target, "scale", _init_scales[i], settle_duration)
		if _target_allows_drift[i]:
			_transition_tween.parallel().tween_property(target, "position", _init_positions[i], settle_duration)
	await _transition_tween.finished


## 播放退场过渡（协程）。
func play_exit_transition(delay: float = 0.0) -> void:
	if _targets.is_empty():
		return
	_stop_transition_tweens()
	if delay > 0.0:
		await get_tree().create_timer(delay, true, false, false).timeout
		if not is_inside_tree():
			return
	var peak_duration: float = maxf(0.01, exit_duration * exit_peak_phase_ratio)
	var hold_duration: float = minf(maxf(0.0, exit_peak_hold_duration), maxf(0.0, exit_duration - peak_duration - 0.01))
	var vanish_duration: float = maxf(0.01, exit_duration - peak_duration - hold_duration)
	# 淡化：贴到结尾
	var fade_duration: float = _fade_duration(exit_duration, exit_fade_ratio)
	_transition_fade_tween = create_tween()
	_transition_fade_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	for i in _targets.size():
		_transition_fade_tween.parallel().tween_property(_targets[i], "modulate:a", 0.0, fade_duration) \
			.set_delay(maxf(0.0, exit_duration - fade_duration))
	# 缩放/位移：放大 → 停顿 → 收走
	_transition_tween = create_tween()
	_transition_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	for i in _targets.size():
		_transition_tween.parallel().tween_property(_targets[i], "scale", _init_scales[i] * peak_scale_multiplier, peak_duration)
	if hold_duration > 0.0:
		_transition_tween.chain().tween_interval(hold_duration)
	_transition_tween.chain()
	for i in _targets.size():
		var target: CanvasItem = _targets[i]
		if _target_allows_drift[i]:
			_transition_tween.parallel().tween_property(target, "position", _init_positions[i] + drift_distance, vanish_duration)
		_transition_tween.parallel().tween_property(target, "scale", Vector2.ZERO, vanish_duration)
	await _transition_tween.finished


# ──────────────── 过渡轨道：内部 ────────────────

## 让单个节点单独播一次入场（不改动其它目标，也不影响 total 计时）。
## 用途：某些节点是「需要时才出现」的 —— 例如对话的选项菜单不能跟整页入场一起播，
## 在它出现的那一刻调这个即可。
func play_single_enter(target: CanvasItem, duration: float = -1.0) -> void:
	if target == null or not is_instance_valid(target):
		return
	var total: float = duration if duration > 0.0 else enter_duration
	var base_modulate: Color = target.modulate
	var base_scale: Vector2 = target.scale
	var base_pos: Vector2 = target.position
	var allow_drift: bool = not (target is Control and target.get_parent() is Container)
	target.modulate = Color(base_modulate.r, base_modulate.g, base_modulate.b, 0.0)
	target.scale = Vector2.ZERO
	if allow_drift:
		target.position = base_pos + drift_distance
	var peak_duration: float = maxf(0.01, total * enter_peak_phase_ratio)
	var hold_duration: float = minf(maxf(0.0, enter_peak_hold_duration), maxf(0.0, total - peak_duration - 0.01))
	var settle_duration: float = maxf(0.01, total - peak_duration - hold_duration)
	var fade_duration: float = _fade_duration(total, enter_fade_ratio)
	var fade: Tween = create_tween()
	fade.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	fade.tween_property(target, "modulate:a", base_modulate.a, fade_duration)
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(target, "scale", base_scale * peak_scale_multiplier, peak_duration)
	if hold_duration > 0.0:
		tween.tween_interval(hold_duration)
	tween.tween_property(target, "scale", base_scale, settle_duration)
	if allow_drift:
		tween.parallel().tween_property(target, "position", base_pos, settle_duration)


## 把「占总时长比例」换算成秒（至少一帧）。
func _fade_duration(total_duration: float, ratio: float) -> float:
	return clampf(total_duration * ratio, 0.01, maxf(total_duration, 0.01))


func _stop_transition_tweens() -> void:
	if _transition_tween != null and _transition_tween.is_valid():
		_transition_tween.kill()
	_transition_tween = null
	if _transition_fade_tween != null and _transition_fade_tween.is_valid():
		_transition_fade_tween.kill()
	_transition_fade_tween = null


func _apply_transition_enter_start_state() -> void:
	for i in _targets.size():
		var target: CanvasItem = _targets[i]
		var base_color: Color = _init_modulates[i]
		target.modulate = Color(base_color.r, base_color.g, base_color.b, 0.0)
		if _target_allows_drift[i]:
			target.position = _init_positions[i] + drift_distance
		# 入场从「零缩放」长到峰值（与退场严格对称）
		target.scale = Vector2.ZERO


func _cache_targets() -> void:
	_targets.clear()
	_init_modulates.clear()
	_init_positions.clear()
	_init_scales.clear()
	for path in target_paths:
		var target: CanvasItem = _resolve_target(path)
		if target == null:
			continue
		_targets.append(target)
		_init_modulates.append(target.modulate)
		_init_positions.append(target.position)
		_init_scales.append(target.scale)
		# 父节点是 Container 的目标只做淡化/缩放：容器重排会覆盖 position，
		# 而且对容器子节点写 position 会被 Godot 直接报错。
		_target_allows_drift.append(not (target is Control and target.get_parent() is Container))


func _resolve_target(path: NodePath) -> CanvasItem:
	if path.is_empty():
		return null
	var node: Node = get_node_or_null(path)
	if node != null and node is CanvasItem:
		return node as CanvasItem
	return null


# ──────────────────────────── 内部 ────────────────────────────

func _fire_components(comps: Array[Node], kind: String) -> float:
	if comps.is_empty():
		return 0.0
	var stagger: float = maxf(stagger_delay, 0.0)
	var first_delay: float = enter_first_delay if kind == "enter" else exit_first_delay
	# 入场正序、退场倒序。
	var ordered: Array[Node] = []
	ordered.append_array(comps)
	if kind == "exit":
		ordered.reverse()
	var total: float = 0.0
	for i in ordered.size():
		var comp: Node = ordered[i]
		var delay: float = first_delay + float(i) * stagger
		comp.call("play_enter" if kind == "enter" else "play_exit", delay)
		var comp_duration: float = 0.0
		if comp.has_method("get_fx_duration"):
			comp_duration = float(comp.call("get_fx_duration", kind))
		if debug_log:
			print("    · %s 延时 %.3fs 时长 %.3fs" % [comp.name, delay, comp_duration])
		total = maxf(total, delay + comp_duration)
	if debug_log:
		print("[UIFxDirector] %s：%d 个组件，总时长 %.3fs" % [kind, ordered.size(), total])
	return total


## 触发过渡轨道并返回它的时长。
## 不 await Tween.finished：被 kill 的 Tween 不发 finished，中途一旦有人 reset_state()
## 就会永久卡住（这正是过去「按钮点不动」的根因之一）。
func _fire_transition(_root: Node, kind: String) -> float:
	if _targets.is_empty():
		return 0.0
	var delay: float = transition_enter_delay if kind == "enter" else transition_exit_delay
	if kind == "enter":
		play_enter_transition(delay)
	else:
		play_exit_transition(delay)
	var duration: float = enter_duration if kind == "enter" else exit_duration
	if debug_log:
		print("[UIFxDirector] 过渡轨道 %s：%d 个目标，延时 %.3fs 时长 %.3fs" % [kind, _targets.size(), delay, duration])
	return delay + duration


func _play_loop(root: Node, forward: bool) -> void:
	for animator in find_loop_animators(root):
		if animator.has_method("play_enter") and animator.has_method("play_exit"):
			animator.call("play_enter" if forward else "play_exit")


## 把时长换算成截止时间戳（毫秒）。至少保留一帧，避免「一帧都还没渲染就宣告播完」。
func _deadline_from(seconds: float) -> int:
	var ms: int = int(ceil(maxf(seconds, 0.0) * 1000.0))
	return Time.get_ticks_msec() + maxi(ms, 16)


func _compute_total(kind: String, comps: Array[Node]) -> float:
	var stagger: float = maxf(stagger_delay, 0.0)
	var first_delay: float = enter_first_delay if kind == "enter" else exit_first_delay
	var longest: float = 0.0
	for i in comps.size():
		var comp: Node = comps[i]
		var duration: float = 0.0
		if comp.has_method("get_fx_duration"):
			duration = float(comp.call("get_fx_duration", kind))
		longest = maxf(longest, first_delay + float(i) * stagger + duration)
	if drive_transition and not _targets.is_empty():
		var own: float = enter_duration if kind == "enter" else exit_duration
		var own_delay: float = transition_enter_delay if kind == "enter" else transition_exit_delay
		longest = maxf(longest, own + own_delay)
	return longest


func _collect_recursive(node: Node, acc: Array[Node]) -> void:
	for child in node.get_children():
		if child == self:
			continue
		if _is_fx_component(child):
			if not only_visible_components or child.is_visible_in_tree():
				acc.append(child)
		_collect_recursive(child, acc)


func _collect_loop_animators(node: Node, acc: Array[Node]) -> void:
	for child in node.get_children():
		if child == self:
			continue
		var script_ref: Script = child.get_script()
		if child is AnimatedSprite2D and script_ref != null and str(script_ref.resource_path).ends_with("UILoopAnimator.gd"):
			acc.append(child)
		_collect_loop_animators(child, acc)


func _is_fx_component(node: Node) -> bool:
	if not (node.has_method("play_enter") and node.has_method("play_exit") and node.has_method("get_fx_duration")):
		return false
	# 组件可以自己声明「不要被总线驱动」（例如它的父节点已经参与了过渡动画）
	var managed: Variant = node.get("fx_managed")
	if managed != null and not bool(managed):
		return false
	return true
