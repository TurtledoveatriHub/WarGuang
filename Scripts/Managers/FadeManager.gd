extends CanvasLayer

@onready var fade_rect = $ColorRect

@export_category("UI 场景切换参数（普通）")
## 普通 UI 切场：淡出时长（秒）
@export var ui_switch_fade_out_duration: float = 0.3
## 普通 UI 切场：全黑保持时长（秒）
@export var ui_switch_black_hold_duration: float = 0.2
## 普通 UI 切场：淡入时长（秒）
@export var ui_switch_fade_in_duration: float = 0.2

@export_category("UI 场景切换参数（SaveSelect 进入游戏）")
## SaveSelect -> Game：淡出时长（秒）（实际是淡入。）
@export var ui_save_to_game_fade_out_duration: float = 0.8
## SaveSelect -> Game：全黑保持时长（秒）
@export var ui_save_to_game_black_hold_duration: float = 0.6
## SaveSelect -> Game：淡入时长（秒）（实际是淡出。）
@export var ui_save_to_game_fade_in_duration: float = 0.6

## ── 注意 ──
## 所有 UI 页面内过渡（Title→Settings 等非切场覆盖层）统一使用上方
## "UI 场景切换参数（普通）"组的 fade_out/black_hold/fade_in 值。
## 不再单独设 "UI 页面内过渡（非切场）"参数组，所有 UI 过渡参数集中管理。

signal fade_out_completed
signal fade_in_completed

var _fade_tween: Tween = null
## 淡入/淡出的代次号：开始新的淡入淡出（或 force_black）时自增，
## 让「过期的」淡入淡出结束时不再改画面状态。
var _fade_generation: int = 0
var _black_hold_tags: Dictionary = {}

func _ready():
	# 设置整个CanvasLayer的暂停模式
	# 在Godot 4.5.1中，正确的常量名是PROCESS_MODE_ALWAYS
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	fade_rect.size = get_viewport().size
	fade_rect.color = Color(0, 0, 0, 0)
	fade_rect.visible = false
	layer = 1000
	fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

## 等待一律用「时长」而不是 await Tween.finished：
## 本管理器在开始新的淡入/淡出（或 force_black）时会 kill 掉上一个 Tween，
## 而被 kill 的 Tween 永远不会发 finished —— 任何 await 它的调用者（例如整条场景切换流程）
## 会永久卡住，表现就是「切到标题后整页卡死、按钮全不可点」。
func fade_out(duration: float):
	var safe_duration: float = clampf(duration, 0.0, 30.0)
	_stop_active_fade_tween()
	var generation: int = _fade_generation
	fade_rect.visible = true
	
	_fade_tween = create_tween()
	_fade_tween.tween_property(fade_rect, "color", Color(0.0, 0.0, 0.0, 1.0), safe_duration)
	
	await _wait_fade(safe_duration)
	if generation != _fade_generation:
		return
	fade_rect.color = Color(0.0, 0.0, 0.0, 1.0)
	fade_rect.visible = true
	fade_out_completed.emit()

func fade_in(duration: float):
	if has_black_hold():
		force_black()
		fade_in_completed.emit()
		return
	var safe_duration: float = clampf(duration, 0.0, 30.0)
	_stop_active_fade_tween()
	var generation: int = _fade_generation
	
	_fade_tween = create_tween()
	_fade_tween.tween_property(fade_rect, "color", Color(0, 0, 0, 0), safe_duration)
	
	await _wait_fade(safe_duration)
	if generation != _fade_generation:
		return
	fade_rect.color = Color(0, 0, 0, 0)
	fade_rect.visible = false
	fade_in_completed.emit()


## 等待一段时长（不依赖 Tween 信号）。
func _wait_fade(seconds: float) -> void:
	if seconds <= 0.0:
		return
	await get_tree().create_timer(seconds).timeout

func force_fade_in():
	if has_black_hold():
		force_black()
		return
	_stop_active_fade_tween()
	fade_rect.color = Color(0, 0, 0, 0)
	fade_rect.visible = false

func force_black():
	_stop_active_fade_tween()
	fade_rect.visible = true
	fade_rect.color = Color(0, 0, 0, 1)

func _stop_active_fade_tween() -> void:
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null
	# 代次号自增：正在等待中的淡入/淡出会发现自己已过期，不再改画面。
	_fade_generation += 1

func get_black_alpha() -> float:
	if not is_instance_valid(fade_rect):
		return 0.0
	return clampf(fade_rect.color.a, 0.0, 1.0)

func is_fully_black(threshold: float = 0.995) -> bool:
	if not is_instance_valid(fade_rect):
		return false
	return fade_rect.visible and get_black_alpha() >= clampf(threshold, 0.0, 1.0)

func hold_black(tag: String) -> void:
	var key: String = tag.strip_edges()
	if key == "":
		key = "default"
	_black_hold_tags[key] = true
	force_black()

func release_black_hold(tag: String) -> void:
	var key: String = tag.strip_edges()
	if key == "":
		key = "default"
	if _black_hold_tags.has(key):
		_black_hold_tags.erase(key)

func has_black_hold() -> bool:
	return not _black_hold_tags.is_empty()

## 清空所有黑幕锁（保留当前黑屏状态）。
## 用于场景切换等场景，确保 fade_in 不会被残留黑幕锁跳过。
func clear_black_holds() -> void:
	_black_hold_tags.clear()
