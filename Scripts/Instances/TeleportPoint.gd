extends Area2D

## 传送阵
##
## 动画状态（由 AnimatedSprite2D 播放，你添加 sprite frames）：
##   INACTIVE        — 未激活，循环
##   ACTIVATEBLEND   — 未激活→激活过渡，不循环
##   ACTIVE          — 已激活，循环
##   INTERACTACTIVE  — 已激活+交互中，循环

enum State { INACTIVE, ACTIVATEBLEND, ACTIVE, INTERACTACTIVE }

@export var teleport_id: String = ""
@export var display_name: String = "传送阵"
@export var interaction_lock_duration: float = 1.0

@onready var anim: AnimatedSprite2D = $AnimatedSprite2D
@onready var prompt: Sprite2D = $InteractionPrompt

var current_state: State = State.INACTIVE
var player_in_range: bool = false
var _interaction_locked: bool = false


func _ready() -> void:
	if teleport_id == "":
		teleport_id = "teleport_%s" % str(global_position).replace("(", "").replace(")", "").replace(", ", "_")
	
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	prompt.visible = false
	
	## 注册到 TeleportManager
	var room_id = _resolve_room_id()
	TeleportManager.register(self, teleport_id, room_id, global_position, display_name)
	
	## 如果已激活则直接显示 ACTIVE
	if TeleportManager.is_activated(teleport_id):
		current_state = State.ACTIVE
		anim.play("ACTIVE")
	else:
		current_state = State.INACTIVE
		anim.play("INACTIVE")


func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	player_in_range = true
	if current_state in [State.INACTIVE, State.ACTIVE]:
		prompt.visible = true


func _on_body_exited(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	player_in_range = false
	prompt.visible = false


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("interactive") or not player_in_range or _interaction_locked:
		return
	
	var player := get_tree().get_first_node_in_group("player")
	if player and player.has_method("get_player_state") and player.get_player_state() == player.PlayerState.DASH:
		return
	
	match current_state:
		State.INACTIVE:
			_start_activation(player)
		State.ACTIVE:
			_open_teleport_panel()
		_:  # ACTIVATEBLEND / INTERACTACTIVE
			return


func _start_activation(_player: Node) -> void:
	_interaction_locked = true
	current_state = State.ACTIVATEBLEND
	prompt.visible = false
	anim.play("ACTIVATEBLEND")
	await anim.animation_finished
	
	current_state = State.ACTIVE
	anim.play("ACTIVE")
	TeleportManager.activate(teleport_id)
	_interaction_locked = false
	
	if player_in_range:
		prompt.visible = true


func _open_teleport_panel() -> void:
	current_state = State.INTERACTACTIVE
	prompt.visible = false
	anim.play("INTERACTACTIVE")
	
	## 打开传送面板（稍后实现 TeleportPanel）
	var panel_scene := preload("res://Scenes/UI/TeleportPanel.tscn")
	var panel := panel_scene.instantiate()
	panel.source_teleport_id = teleport_id
	get_tree().root.add_child(panel)
	panel.menu_closed.connect(_on_panel_closed)


func _on_panel_closed() -> void:
	current_state = State.ACTIVE
	anim.play("ACTIVE")
	_interaction_locked = false
	if player_in_range:
		prompt.visible = true


func _resolve_room_id() -> String:
	var parent = get_parent()
	while parent:
		if parent.has_method("get_room_data"):
			var data = parent.get_room_data()
			if data and data.has("id"):
				return data.id
		parent = parent.get_parent()
	return ""
