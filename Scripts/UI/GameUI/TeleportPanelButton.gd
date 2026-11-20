extends UIButtonFx

## 传送面板按钮——在 Inspector 中设置此按钮对应的传送阵 ID。
## 必须与某个 TeleportPoint 的 teleport_id 完全一致才能匹配。
##
## 本脚本继承 UIButtonFx，因此该按钮自动获得统一的悬停 / 入场 / 退场动效；
## 这里只负责业务数据。
@export var target_teleport_id: String = ""
