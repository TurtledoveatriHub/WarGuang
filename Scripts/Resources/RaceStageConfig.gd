extends Resource
class_name RaceStageConfig

## 跑圈竞速挑战的单阶段配置资源
## 每个阶段一个 .tres（res://Assets/Configs/RaceStages/），由 RaceController.stage_configs 按顺序引用。
## ★ 每个阶段的赛道是**独立的节点组**：起点 / 检查点 / 竞速区域各自的路径都写在这里；
##   挑战未开始时 RaceController 会把整组（stage_root_path）隐藏起来。
## 路径一律相对 RaceController 自身。

## 阶段名称（调试显示 / 告示牌用）
@export var race_name: String = ""
## 需要跑完的圈数
@export var lap_count: int = 3
## 限时（秒）：总用时必须小于该值才算成功；<= 0 表示不限时，只记录用时
@export var target_time: float = 90.0
## 是否要求玩家留在竞速区域（RaceArea）内：离开即判失败
@export var require_in_bounds: bool = true

@export_category("赛道节点（相对 RaceController）")
## 本阶段赛道根节点：未开始 / 结束时整组隐藏
@export_node_path var stage_root_path: NodePath = NodePath()
## 本阶段检查点容器：子节点为 RaceStartLine（index = 0）与 RaceCheckpoint
@export_node_path var checkpoint_container_path: NodePath = NodePath()
## 本阶段竞速区域（TextArea）
@export_node_path var race_area_path: NodePath = NodePath()
## 本阶段起跑点（Marker2D）
@export_node_path var start_position_path: NodePath = NodePath()
