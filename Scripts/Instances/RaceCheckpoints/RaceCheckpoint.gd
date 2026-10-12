extends Area2D
class_name RaceCheckpoint

## 途中检查点（起点/终点线请用 RaceStartLine，它不做纹理变化）
## checkpoint_index 从 1 开始编号；玩家必须按顺序经过，顺序判定在 RaceController。
##
## ★ 关于「Sprite2D 上手动设置的纹理」：
##   * inactive_texture / active_texture 两个都为空 → 脚本**完全不碰** Sprite2D 的纹理，
##     你在场景里手动设的纹理保持原样（只按状态改 modulate）；
##   * 只填其中一张也行：空的那些状态就不换图，仍按 modulate 变化；
##   * 两张都填 → 按状态切换纹理。

## 玩家进入检查点时发出（顺序判定交给 RaceController）
signal player_entered(checkpoint: Node)

@export_category("检查点")
## 检查点序号（从 1 开始；必须唯一且连续）
@export var checkpoint_index: int = 1
## 检查点名称（仅调试显示用）
@export var checkpoint_label: String = ""

@export_category("外观")
## 未激活（未通过）时的纹理（留空 = 不动 Sprite2D 原本的纹理）
@export var inactive_texture: Texture2D
## 已激活（已通过）时的纹理（留空 = 不动 Sprite2D 原本的纹理）
@export var active_texture: Texture2D
## 未激活时的着色（默认压暗，未通过的检查点一眼能看出来）
@export var inactive_modulate: Color = Color(0.55, 0.55, 0.62, 1.0)
## 已激活时的着色
@export var active_modulate: Color = Color(1.0, 1.0, 1.0, 1.0)

## 纹理显示节点
@onready var sprite: Sprite2D = $Sprite2D

## 当前是否已被激活
var is_activated: bool = false

## 初始化：连接进入信号并复位为未激活
func _ready() -> void:
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	set_activated(false)

## 玩家进入 → 交给 RaceController 判断顺序
func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return
	player_entered.emit(self)

## 切换激活状态（换圈时由控制器复位为 false）
func set_activated(activated: bool) -> void:
	is_activated = activated
	if sprite == null:
		return
	if activated:
		if active_texture != null:
			sprite.texture = active_texture
		sprite.modulate = active_modulate
	else:
		if inactive_texture != null:
			sprite.texture = inactive_texture
		sprite.modulate = inactive_modulate
