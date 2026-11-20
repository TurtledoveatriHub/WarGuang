class_name UIPopupPanel
extends CanvasLayer
## 标题页上的「信息弹窗」基类（关于作者 / 游戏公告 / 游戏成就）。
##
## 与删除确认弹窗同一套观感与交互，把重复的部分收在一处：
##   * 打开：显示全局遮罩（暗化背景）+ 面板入场动画（由本场景的 UIFxDirector 驱动）
##   * 关闭：ContinueButton 或 ESC 都可以，**先播退场动画，播完再 queue_free**
##
## 宿主页面（TitleScene）的「完全无视」由调用方负责 —— 打开时调 set_overlay_active(true)
## 把标题页整层失活（按钮禁用 = 点不动、也不再播悬停动画）。本类只管自己。

## 关闭按钮路径（默认 ContinueButton）。
@export var close_button_path: NodePath = ^"ContinueButton"
## ESC 是否关闭本弹窗。
@export var esc_closes: bool = true

var _fx_bus: Node = null
var _closing: bool = false


func _ready() -> void:
	set_process_input(true)
	_fx_bus = get_node_or_null("UIFxDirector")
	var close_button: Node = get_node_or_null(close_button_path)
	if close_button is BaseButton:
		(close_button as BaseButton).pressed.connect(close)
	# 面板是运行时 add_child() 上来的，没人替它播入场 → 这里显式触发一次。
	if _fx_bus != null:
		_fx_bus.call_deferred("play_enter")
	# 背景暗化：与游戏内设置面板同款（全局只有一层遮罩，不做计数叠加）。
	if DarkOverlay and is_instance_valid(DarkOverlay):
		DarkOverlay.reset_overlay()
		DarkOverlay.show_overlay()


func _input(event: InputEvent) -> void:
	if not esc_closes or _closing:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()


## 关闭弹窗：先播退场动画，播完再销毁。
## 退场时长用总线自己的估算值（已含各按钮组件的错开时长）；
## **不 await Tween 信号** —— Tween 被 kill 时不会发 finished，等信号会直接卡死。
func close() -> void:
	if _closing:
		return
	_closing = true
	var seconds: float = 0.0
	if _fx_bus != null and is_instance_valid(_fx_bus):
		seconds = float(_fx_bus.call("estimate_duration", "exit"))
		_fx_bus.call("play_exit")
	if DarkOverlay and is_instance_valid(DarkOverlay):
		DarkOverlay.reset_overlay()
		DarkOverlay.hide_overlay()
	if seconds > 0.0:
		await get_tree().create_timer(seconds).timeout
	queue_free()
