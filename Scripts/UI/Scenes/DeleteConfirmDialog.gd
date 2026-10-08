extends CanvasLayer

@onready var message_label = $Background/Message
@onready var confirm_button = $Background/ButtonContainer/ConfirmButton
@onready var cancel_button = $Background/ButtonContainer/CancelButton

var confirm_callback: Callable
## 已进入「退场动画 + 销毁」流程，防止重复触发。
var _closing: bool = false

func _ready():
	confirm_button.pressed.connect(_on_confirm_pressed)
	cancel_button.pressed.connect(_on_cancel_pressed)
	
	# 设置默认消息
	if message_label:
		message_label.text = "是否删除存档？"

	# 面板入场动画由动效总线（UIFxDirector）驱动 —— 节点在场景里，目标在 Inspector 里配。
	# 本面板是独立 add_child() 上来的（不是 UIScene、不经过 UIRouter），没人替它入场，
	# 所以必须在这里显式触发一次。
	$UIFxDirector.call_deferred("play_enter")

func _on_confirm_pressed():
	# 点击音效由 UIButtonFx 组件层在 button_down 时统一播放
	
	if confirm_callback:
		confirm_callback.call()
	close()

func _on_cancel_pressed():
	close()

## 关闭弹窗：**先播退场动画，播完再销毁**（否则面板是「啪一下直接消失」）。
## 退场时长用总线自己的估算值（已含按钮组件的错开时长）；
## 不 await Tween 信号 —— Tween 被 kill 时不会发 finished，等信号会直接卡死。
func close() -> void:
	if _closing:
		return
	_closing = true
	var seconds: float = 0.0
	var bus: Node = get_node_or_null("UIFxDirector")
	if bus != null:
		seconds = float(bus.call("estimate_duration", "exit"))
		bus.call("play_exit")
	if seconds > 0.0:
		await get_tree().create_timer(seconds).timeout
	queue_free()

# 添加ESC键处理函数
func setup_esc_close():
	set_process_input(true)

func _input(event):
	if event.is_action_pressed("ui_cancel"):
		_on_cancel_pressed()
		get_viewport().set_input_as_handled()  # 阻止事件传播
