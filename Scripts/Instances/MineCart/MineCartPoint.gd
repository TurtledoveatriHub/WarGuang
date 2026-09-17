# Scripts/Instances/MineCart/MineCartPoint.gd
## 轨道控制点：可选挂到 Marker2D 上，用于声明“该点是三点圆弧的中点”。
## 说明：
##   把它挂到某个 Marker2D，并勾选 curve_apex=true，则该点与前一个点、后一个点
##   会连成一个过这三点的圆/圆弧；不勾（或不用本脚本）则相邻控制点之间为直线。
## 快捷方式：即使不挂本脚本，只要把 Marker2D 节点名以 "Arc" / "Curve" 开头，
##   同样会被当作三点圆弧的中点处理。
extends Marker2D
class_name MineCartPoint

## 此点是否为“三点圆弧”的中点（前一点—本点—后一点 构成一段圆弧）
@export var curve_apex: bool = false
