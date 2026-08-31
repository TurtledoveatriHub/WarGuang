extends Node2D
class_name MobieControlsPage

## 移动端虚拟按键设置页
## 该页不负责运行时渲染逻辑；仅负责布局参数配置和 UI 说明
## 具体虚拟按键的实际创建/显示逻辑由游戏运行时控制器处理

@onready var layout_mode_option: OptionButton = $LayoutSettings/LayoutModeOption
@onready var dpad_center_x: SpinBox = $LayoutSettings/CenterRow/DpadCenterX
@onready var dpad_center_y: SpinBox = $LayoutSettings/CenterRow/DpadCenterY
@onready var dpad_spacing: SpinBox = $LayoutSettings/SpacingRow/DpadSpacing
@onready var dpad_size: SpinBox = $LayoutSettings/ButtonSizeRow/DpadButtonSize
@onready var jump_size: SpinBox = $LayoutSettings/ActionSizeRow/JumpSize
@onready var action_size: SpinBox = $LayoutSettings/ActionSizeRow/ActionSize
@onready var button_alpha: SpinBox = $LayoutSettings/AlphaRow/ButtonAlpha
@onready var pressed_alpha: SpinBox = $LayoutSettings/AlphaRow/PressedAlpha

var _mobile_controls_owner: Node = null

func _ready():
	_setup_mode_options()
	_connect_controls()
	_refresh_from_owner()

func _setup_mode_options():
	layout_mode_option.clear()
	layout_mode_option.add_item("十字键", 0)
	layout_mode_option.add_item("圆盘摇杆", 1)

func _connect_controls():
	layout_mode_option.item_selected.connect(_on_layout_mode_changed)
	for control in [dpad_center_x, dpad_center_y, dpad_spacing, dpad_size, jump_size, action_size, button_alpha, pressed_alpha]:
		if control and control.has_signal("value_changed"):
			control.value_changed.connect(_on_layout_value_changed)

func _on_layout_mode_changed(index: int) -> void:
	_apply_config_to_owner()

func _on_layout_value_changed(_value: float) -> void:
	_apply_config_to_owner()

func _find_mobile_controls_owner() -> Node:
	if _mobile_controls_owner and is_instance_valid(_mobile_controls_owner):
		return _mobile_controls_owner
	var root = get_tree().current_scene
	if root:
		for child in root.get_children():
			if child is CanvasLayer and child.name == "MobileControls":
				_mobile_controls_owner = child
				return _mobile_controls_owner
		for child in root.get_children():
			if child.has_node("MobileControls"):
				var mobile = child.get_node("MobileControls")
				if mobile:
					_mobile_controls_owner = mobile
					return _mobile_controls_owner
	return null

func _apply_config_to_owner() -> void:
	var owner = _find_mobile_controls_owner()
	if owner == null or not owner.has_method("apply_layout_config"):
		return
	var config = owner.get_layout_config()
	config["layout_mode"] = layout_mode_option.selected
	config["dpad_center"] = Vector2(dpad_center_x.value, dpad_center_y.value)
	config["dpad_spacing"] = dpad_spacing.value
	config["dpad_btn_size"] = dpad_size.value
	config["jump_size"] = jump_size.value
	config["action_size"] = action_size.value
	config["button_alpha"] = button_alpha.value
	config["button_pressed_alpha"] = pressed_alpha.value
	owner.apply_layout_config(config)

func _refresh_from_owner() -> void:
	var owner = _find_mobile_controls_owner()
	if owner == null or not owner.has_method("get_layout_config"):
		return
	var cfg = owner.get_layout_config()
	layout_mode_option.select(int(cfg.get("layout_mode", 0)))
	if cfg.has("dpad_center"):
		var c = cfg["dpad_center"] as Vector2
		dpad_center_x.value = c.x
		dpad_center_y.value = c.y
	if cfg.has("dpad_spacing"):
		dpad_spacing.value = cfg["dpad_spacing"]
	if cfg.has("dpad_btn_size"):
		dpad_size.value = cfg["dpad_btn_size"]
	if cfg.has("jump_size"):
		jump_size.value = cfg["jump_size"]
	if cfg.has("action_size"):
		action_size.value = cfg["action_size"]
	if cfg.has("button_alpha"):
		button_alpha.value = cfg["button_alpha"]
	if cfg.has("button_pressed_alpha"):
		pressed_alpha.value = cfg["button_pressed_alpha"]
