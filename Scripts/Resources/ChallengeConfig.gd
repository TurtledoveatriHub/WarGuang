extends Resource
class_name ChallengeConfig

## 挑战名称（仅调试显示）
@export var challenge_name: String = ""
## 需要成功触发的 JumpBox 总次数
@export var target_count: int = 12
## 无尽模式：不判定通关（target_count 无效），失败时把本局积分记入无尽积分榜
@export var endless_mode: bool = false
## JumpBox 容器路径（ChallengeController 扫描此容器下所有 is_challenge_jumpbox=true 的 JumpBox）
@export_node_path var challenge_container_path: NodePath
## 要求玩家不能落地
var require_no_floor: bool = true
## 要求玩家不能离开 ChallengeArea（由 ChallengeController.challenge_area_path 指定）
var require_in_bounds: bool = true
