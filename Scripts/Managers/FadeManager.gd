extends CanvasLayer

@onready var fade_rect = $ColorRect

@export_category("UI 场景切换参数（普通）")
## 普通 UI 切场：淡出时长（秒）
@export var ui_switch_fade_out_duration: float = 0.4
## 普通 UI 切场：全黑保持时长（秒）
@export var ui_switch_black_hold_duration: float = 0.2
## 普通 UI 切场：淡入时长（秒）
@export var ui_switch_fade_in_duration: float = 0.2

@export_category("UI 场景切换参数（SaveSelect 进入游戏）")
## SaveSelect -> Game：淡出时长（秒）
## 注意：实际使用 FadeManager.force_black() 瞬间全黑（因切场时场景正在加载，fade_out 会被截断）
@export var ui_save_to_game_fade_out_duration: float = 0.2
## SaveSelect -> Game：全黑保持时长（秒）
@export var ui_save_to_game_black_hold_duration: float = 1.8
## SaveSelect -> Game：淡入时长（秒）
@export var ui_save_to_game_fade_in_duration: float = 0.6

## ── 注意 ──
## 所有 UI 页面内过渡（Title→Settings 等非切场覆盖层）统一使用上方
## "UI 场景切换参数（普通）"组的 fade_out/black_hold/fade_in 值。
## 不再单独设 "UI 页面内过渡（非切场）"参数组，所有 UI 过渡参数集中管理。

signal fade_out_completed
signal fade_in_completed

var _fade_tween: Tween = null
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

func fade_out(duration: float):
	var safe_duration: float = clampf(duration, 0.0, 30.0)
	_stop_active_fade_tween()
	fade_rect.visible = true
	
	_fade_tween = create_tween()
	_fade_tween.tween_property(fade_rect, "color", Color(0.0, 0.0, 0.0, 1.0), safe_duration)
	
	await _fade_tween.finished
	fade_out_completed.emit()

func fade_in(duration: float):
	if has_black_hold():
		force_black()
		fade_in_completed.emit()
		return
	var safe_duration: float = clampf(duration, 0.0, 30.0)
	_stop_active_fade_tween()
	
	_fade_tween = create_tween()
	_fade_tween.tween_property(fade_rect, "color", Color(0, 0, 0, 0), safe_duration)
	
	await _fade_tween.finished
	fade_rect.visible = false
	fade_in_completed.emit()

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
