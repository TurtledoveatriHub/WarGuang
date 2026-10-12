extends BaseNPC
class_name RaceStarter

## 竞速挑战触发 NPC（飞毛腿 —— 热情、激情、热爱奔跑）
## 职责：
##   1. 把对话里的指令转成 RaceController.start_race(阶段索引)
##   2. 挑战结束后由 RaceController 回调 start_result_dialogue()，自动弹出结果对话
##      （成功 => result_win，失败 => result_lose），对话结束再恢复普通交互分支。
## 没有巡逻 / 狂热状态机 —— 站着不动，玩家按交互键就能开跑。

## RaceController 的 NodePath（一般就是自己身上的子节点）
@export_node_path var race_controller_path: NodePath = NodePath()

## 缓存的 RaceController 引用
var race_controller: RaceController = null

## 初始化：写入 npc_id（TaskManager 按它统计对话次数）
func _ready() -> void:
	super._ready()
	npc_id = "RaceStarter"

## 启动第一阶段竞速（由对话文件调用）
func launch_race() -> void:
	_start_race_stage(0)

## 启动第二阶段竞速
func launch_stage2_race() -> void:
	_start_race_stage(1)

## 启动第三阶段竞速
func launch_stage3_race() -> void:
	_start_race_stage(2)

## 启动第四阶段竞速
func launch_stage4_race() -> void:
	_start_race_stage(3)

## 启动第五阶段竞速
func launch_stage5_race() -> void:
	_start_race_stage(4)

## 统一启动入口：解析 RaceController 并调用 start_race
func _start_race_stage(stage_index: int) -> void:
	if race_controller_path == NodePath() or race_controller_path.is_empty():
		push_error("RaceStarter: 未设置 race_controller_path")
		return
	var ctrl: RaceController = get_node_or_null(race_controller_path) as RaceController
	if ctrl == null:
		push_error("RaceStarter: 找不到 RaceController")
		return
	race_controller = ctrl
	# 回填引用：挑战结束后 RaceController 会回调本 NPC 弹结果对话
	ctrl.starter_npc = self
	# 点击挑战那一刻就禁操控（只关输入，不冻结玩家状态）：
	# 黑屏传送 + 倒计时结束前不允许操控
	_lock_player()
	ctrl.start_race(stage_index)

## 对话结束：
##   * 开赛对话结束 → 挑战还在进行，**不能**交还操控；
##   * 结果对话结束 → 通知控制器交还操控。
func _on_dialogue_ended() -> void:
	var owned: bool = owns_dialogue
	await get_tree().process_frame
	super._on_dialogue_ended()
	if owned and race_controller != null and race_controller.has_method("on_result_dialogue_finished"):
		race_controller.on_result_dialogue_finished()

## 禁用玩家操控（只关输入，物理与状态机照常运行）
func _lock_player() -> void:
	var player: Node = get_tree().get_first_node_in_group("player")
	if player != null and player.has_method("set_player_control"):
		player.set_player_control(false)

## 挑战结束后的自动结果对话（由 RaceController 调用）
func start_result_dialogue(success: bool) -> void:
	_open_dialogue("result_win" if success else "result_lose")

## 开始交互（覆盖 BaseNPC：对话里要用到 npc / Global / TaskManager 三个对象）
func _start_interaction() -> void:
	_open_dialogue("start")

## 从指定标题打开对话
func _open_dialogue(title: String) -> void:
	owns_dialogue = true
	var dialogue_system = get_node_or_null("/root/DialogueSystem")
	if dialogue_system and dialogue_system.is_dialogue_active:
		return
	if not dialogue_resource:
		push_error("RaceStarter: 没有配置对话资源！请在检查器中指定")
		return
	if not balloon_scene:
		balloon_scene = load(ScenePaths.UI_MY_BALLOON)
	if not balloon_scene:
		push_error("RaceStarter: balloon_scene 未配置！")
		return
	_play_random_interact_sound()
	var task_manager = get_node_or_null("/root/TaskManager")
	if task_manager:
		task_manager.record_npc_dialogue(npc_id)
	var balloon = balloon_scene.instantiate()
	get_tree().current_scene.add_child(balloon)
	var game_states = {
		"npc": self,
		"Global": Global,
		"TaskManager": task_manager
	}
	balloon.start(dialogue_resource, title, [game_states])
	if interaction_prompt:
		interaction_prompt.visible = false
