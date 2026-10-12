extends Sign
class_name RaceTimeBoard

## 竞速成绩告示牌（与其它 Sign 告示牌一致：靠近按交互键 → 弹出对话）
## 成绩文本全部写在专门的对话资源里（Assets/Dialogues/Signs/gl18RaceBoard.dialogue），
## 用 {{Global.get_race_best_time_text(N)}} 取第 N 阶段的最佳时间。
## 这里只做一件事：把 Global 作为对话可用的对象传进去（Sign 默认不传任何 game state）。

## 以指定标题打开对话（覆盖 Sign 的交互入口，多传一个 Global）
func _start_interaction() -> void:
	if dialogue_resource == null:
		push_warning("RaceTimeBoard: 未配置 dialogue_resource")
		return
	var scene: PackedScene = balloon_scene
	if scene == null:
		scene = load(ScenePaths.UI_MY_BALLOON)
	if scene == null:
		push_error("RaceTimeBoard: balloon_scene 未配置且无法加载 MyBalloon")
		return
	var balloon: Node = scene.instantiate()
	var tree: SceneTree = get_tree()
	var host: Node = tree.current_scene if tree != null and tree.current_scene != null else tree.root
	host.add_child(balloon)
	var game_states: Array = [{"Global": Global, "board": self}]
	if balloon.has_method("start"):
		balloon.start(dialogue_resource, "", game_states)
	elif balloon.has_method("set_dialogue"):
		balloon.set_dialogue(dialogue_resource, self)
	_has_interacted = true
	_update_prompt()
