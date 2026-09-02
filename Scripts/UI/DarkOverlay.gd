extends CanvasLayer

@onready var color_rect: ColorRect = $ColorRect

## 遮罩的透明度（0-1）
@export var overlay_alpha: float = 0.7
var _overlay_request_count: int = 0

func _ready():
	# 设置层级在对话框之上，设置界面之下
	layer = 95
	
	# 初始隐藏
	visible = false
	
	# 设置 ColorRect 全屏
	if color_rect:
		color_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		color_rect.color = Color(0, 0, 0, overlay_alpha)
	_apply_overlay_state()

func set_overlay_alpha(alpha_value: float) -> void:
	overlay_alpha = clampf(alpha_value, 0.0, 1.0)
	if color_rect:
		color_rect.color = Color(0, 0, 0, overlay_alpha)

func set_overlay_state(should_show: bool, force_reset: bool = false) -> void:
	if force_reset:
		_overlay_request_count = 1 if should_show else 0
	elif should_show:
		# 关键修正：这个遮罩必须是单一开关状态，不能用递增计数叠加。
		# GameSettingScene 与 SettingsScene 之间反复切换时，计数会越来越大，
		# 最终出现多层暗化，并且只消失一层，剩下的会永久残留。
		_overlay_request_count = 1
	else:
		_overlay_request_count = 0
	_apply_overlay_state()

func _apply_overlay_state() -> void:
	visible = _overlay_request_count > 0
	if color_rect:
		color_rect.color = Color(0, 0, 0, overlay_alpha)

## 显示遮罩
func show_overlay():
	set_overlay_state(true)

## 隐藏遮罩
func hide_overlay():
	set_overlay_state(false)

func reset_overlay():
	_overlay_request_count = 0
	_apply_overlay_state()
