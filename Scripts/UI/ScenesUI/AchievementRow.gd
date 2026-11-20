extends Control
## 成就条目：图标（未解锁自动转黑白 + 压暗）+ 描述文本（未解锁变暗）。
## 由 AchievementScene 在切页时调 apply() 填入内容。

## 未解锁时的描述文字颜色（暗）
@export var locked_text_color: Color = Color(0.42, 0.42, 0.42, 1.0)
## 已解锁时的描述文字颜色（提亮）
@export var unlocked_text_color: Color = Color(1.0, 1.0, 1.0, 1.0)

@onready var icon_rect: TextureRect = $Icon
@onready var description_label: Label = $Description

var _icon_material: ShaderMaterial = null


func _ready() -> void:
	# 着色器材质必须是每个条目一份：场景实例之间会共享子资源，
	# 共享的话改一个条目的 unlocked 会把所有条目的图标一起改掉。
	if icon_rect.material is ShaderMaterial:
		_icon_material = (icon_rect.material as ShaderMaterial).duplicate() as ShaderMaterial
		icon_rect.material = _icon_material


## 填入一个成就的显示内容：unlocked 决定图标是否上色、描述是否提亮。
func apply(data: AchievementData, unlocked: bool) -> void:
	description_label.text = data.description
	description_label.modulate = unlocked_text_color if unlocked else locked_text_color
	if data.icon != null:
		icon_rect.texture = data.icon
	if _icon_material != null:
		_icon_material.set_shader_parameter("unlocked", 1.0 if unlocked else 0.0)
