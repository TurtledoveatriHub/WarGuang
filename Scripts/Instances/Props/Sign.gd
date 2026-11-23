# Scripts/Instances/Props/Sign.gd
extends Area2D
class_name Sign
## 告示牌：玩家靠近并按交互键时弹出对话（文本直接用 Dialogues 资源）。
## 交互逻辑参考 NPC（BaseNPC）：
##   - Area2D 检测玩家进入/离开；交互提示用可选的 InteractionPrompt 子节点
##   - 按 `interactive` 触发；对话进行中不重复触发
##   - 弹框用 MyBalloon（可用 balloon_scene 覆盖）
## 纹理使用 Sprite2D（不需要 AnimatedSprite2D，因此没有动画相关逻辑）。
## 使用方式：把 .dialogue 资源拖到 dialogue_resource 即可（弹框使用资源里的第一个标题）。

## 对话资源（.dialogue 编译出的 DialogueResource）
@export var dialogue_resource: DialogueResource
## 弹框场景（留空则使用 ScenePaths.UI_MY_BALLOON）
@export var balloon_scene: PackedScene
## 是否只允许交互一次（例如一次性的提示牌）
@export var interact_once: bool = false

## 交互提示节点（可空）
@onready var _prompt: Node = get_node_or_null("InteractionPrompt")

## 玩家是否在交互范围内
var _player_in_range: bool = false
## 是否已经交互过（interact_once 使用）
var _has_interacted: bool = false


func _ready() -> void:
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	if not body_exited.is_connected(_on_body_exited):
		body_exited.connect(_on_body_exited)
	_update_prompt()


## 玩家在范围内时监听交互键（与 NPC 一致：轮询 interactive 动作）
func _process(_delta: float) -> void:
	if _player_in_range and Input.is_action_just_pressed("interactive"):
		try_interact()


## 尝试交互：对话进行中或已交互过则忽略
func try_interact() -> void:
	if not _player_in_range:
		return
	if interact_once and _has_interacted:
		return
	var dialogue_system: Node = get_node_or_null("/root/DialogueSystem")
	if dialogue_system and dialogue_system.is_dialogue_active:
		return
	_start_interaction()


## 打开对话弹框
func _start_interaction() -> void:
	if dialogue_resource == null:
		push_warning("Sign: 未配置 dialogue_resource")
		return
	var scene: PackedScene = balloon_scene
	if scene == null:
		scene = load(ScenePaths.UI_MY_BALLOON)
	if scene == null:
		push_error("Sign: balloon_scene 未配置且无法加载 MyBalloon")
		return
	var tree: SceneTree = get_tree()
	var host: Node = tree.current_scene if tree != null and tree.current_scene != null else tree.root
	var balloon: Node = MyDialogueBalloon.acquire(host, scene)
	if balloon == null:
		return
	if balloon.has_method("start"):
		balloon.start(dialogue_resource, "", [])
	elif balloon.has_method("set_dialogue"):
		balloon.set_dialogue(dialogue_resource, self)
	_has_interacted = true
	_update_prompt()


func _on_body_entered(body: Node) -> void:
	if body == null or not body.is_in_group("player"):
		return
	_player_in_range = true
	_update_prompt()


func _on_body_exited(body: Node) -> void:
	if body == null or not body.is_in_group("player"):
		return
	_player_in_range = false
	_update_prompt()


## 刷新交互提示显示
func _update_prompt() -> void:
	if _prompt == null:
		return
	_prompt.visible = _player_in_range and not (interact_once and _has_interacted)
