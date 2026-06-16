extends TextureButton

## 传送面板按钮——在 Inspector 中设置此按钮对应的传送阵 ID。
## 必须与某个 TeleportPoint 的 teleport_id 完全一致才能匹配。
@export var target_teleport_id: String = ""
