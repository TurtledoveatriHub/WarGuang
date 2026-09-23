extends CanvasLayer

@onready var message_label = $Background/Message
@onready var confirm_button = $Background/ButtonContainer/ConfirmButton
@onready var cancel_button = $Background/ButtonContainer/CancelButton

var confirm_callback: Callable

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
	queue_free()

func _on_cancel_pressed():
	queue_free()

# 添加ESC键处理函数
func setup_esc_close():
	set_process_input(true)

func _input(event):
	if event.is_action_pressed("ui_cancel"):
		_on_cancel_pressed()
		get_viewport().set_input_as_handled()  # 阻止事件传播
