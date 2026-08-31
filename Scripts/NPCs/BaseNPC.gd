extends Area2D
class_name BaseNPC

## NPC 唯一标识符
var npc_id: String = ""

@export var dialogue_resource: DialogueResource
@export var balloon_scene: PackedScene
@export var interact_once: bool = false
@export var npc_interact_sounds: Array[AudioStream]

@onready var animated_sprite = $AnimatedSprite2D if has_node("AnimatedSprite2D") else null
@onready var interaction_prompt = $InteractionPrompt if has_node("InteractionPrompt") else null

var player_in_range: bool = false
var has_interacted: bool = false
var is_talking: bool = false

func _ready():
	var ds = get_node_or_null("/root/DialogueSystem")
	if ds:
		if ds.has_signal("dialogue_started"):
			ds.dialogue_started.connect(_on_dialogue_started)
		if ds.has_signal("dialogue_ended"):
			ds.dialogue_ended.connect(_on_dialogue_ended)
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	if not body_exited.is_connected(_on_body_exited):
		body_exited.connect(_on_body_exited)
	if interaction_prompt:
		interaction_prompt.visible = false
	_play_default_idle()

func _process(_delta):
	if player_in_range:
		if Input.is_action_just_pressed("interactive"):
			try_interact()

## 尝试与 NPC 交互（子类必须实现）
func try_interact():
	if not player_in_range:
		return
	
	var dialogue_system = get_node_or_null("/root/DialogueSystem")
	var in_dialogue = false
	if dialogue_system:
		in_dialogue = dialogue_system.is_dialogue_active
	
	if in_dialogue:
		return
	
	if interact_once and has_interacted:
		return
	
	_start_interaction()

## 开始交互
func _start_interaction():
	var task_manager = get_node_or_null("/root/TaskManager")
	if task_manager:
		task_manager.record_npc_dialogue(npc_id)
	
	# 修复：使用 ScenePaths 常量而不是实例方法
	if not balloon_scene:
		balloon_scene = load(ScenePaths.UI_MY_BALLOON)
	
	if not balloon_scene:
		push_error("BaseNPC: balloon_scene 未配置！")
		return
	
	var balloon = balloon_scene.instantiate()
	get_tree().current_scene.add_child(balloon)
	
	# 设置对话内容
	if balloon.has_method("set_dialogue"):
		balloon.set_dialogue(dialogue_resource, self)
	
	# 隐藏交互提示
	if interaction_prompt:
		interaction_prompt.visible = false

## 切换到指定动画（安全版本）
func play_animation(animation_name: String):
	if not animated_sprite:
		return
	
	if not animated_sprite.sprite_frames:
		return
	
	if animated_sprite.sprite_frames.has_animation(animation_name):
		animated_sprite.play(animation_name)
	else:
		print("警告：NPC ", npc_id, " 没有动画:", animation_name)

## 播放默认空闲动画
func _play_default_idle():
	if animated_sprite and animated_sprite.sprite_frames:
		# 尝试播放常见空闲动画名称
		var idle_names = ["IDLE", "idle", "Idle"]
		for animation_name in idle_names:
			if animated_sprite.sprite_frames.has_animation(animation_name):
				animated_sprite.play(animation_name)
				return

## 对话开始信号处理
func _on_dialogue_started():
	is_talking = true

## 对话结束信号处理
func _on_dialogue_ended():
	await get_tree().process_frame
	is_talking = false
	
	if interact_once:
		has_interacted = true
		if interaction_prompt:
			interaction_prompt.visible = false

## 身体进入信号处理
func _on_body_entered(body):
	if body.is_in_group("player"):
		player_in_range = true
		# 检查玩家状态决定是否显示提示
		var player = get_tree().get_first_node_in_group("player")
		if player and player.current_state == player.PlayerState.DASH:
			if interaction_prompt:
				interaction_prompt.visible = false
		else:
			if !interact_once or (interact_once and !has_interacted):
				if interaction_prompt:
					interaction_prompt.visible = true

## 身体离开信号处理
func _on_body_exited(body):
	if body.is_in_group("player"):
		player_in_range = false
		if interaction_prompt:
			interaction_prompt.visible = false
