extends Area2D

## 传送阵
## 动画状态（在 AnimatedSprite2D 中添加 sprite frames）：
##   INACTIVE       未激活，循环
##   ACTIVATEBLEND  激活过渡，不循环
##   ACTIVE         已激活，循环
##   INTERACTACTIVE 交互中，循环

enum State { INACTIVE, ACTIVATEBLEND, ACTIVE, INTERACTACTIVE }

## 此传送阵的唯一 ID，与面板按钮的 target_teleport_id 匹配
@export var teleport_id: String = ""

@export_category("音效")
## 首次激活时播放一遍
@export var activate_sfx: AudioStream
## 已激活后每次交互（打开传送面板）时播放一遍
@export var interact_sfx: AudioStream

@onready var anim: AnimatedSprite2D = $AnimatedSprite2D
@onready var prompt: Sprite2D = $InteractionPrompt

var current_state: State = State.INACTIVE
var player_in_range: bool = false


func _ready() -> void:
	if teleport_id == "":
		teleport_id = "teleport_%s" % str(global_position).replace("(", "").replace(")", "").replace(", ", "_")
	
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	prompt.visible = false
	
	var room_id: String = _resolve_room_id()
	TeleportManager.register(self, teleport_id, room_id, global_position)
	
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
	if not event.is_action_pressed("interactive") or not player_in_range:
		return
	
	var player := get_tree().get_first_node_in_group("player")
	if player and player.has_method("get_player_state") and player.get_player_state() == player.PlayerState.DASH:
		return
	
	match current_state:
		State.INACTIVE:
			_start_activation()
		State.ACTIVE:
			_open_teleport_panel()
		_:  return


func _start_activation() -> void:
	current_state = State.ACTIVATEBLEND
	prompt.visible = false
	_play_sfx(activate_sfx)
	anim.play("ACTIVATEBLEND")
	await anim.animation_finished
	
	current_state = State.ACTIVE
	anim.play("ACTIVE")
	TeleportManager.activate(teleport_id)
	
	if player_in_range:
		prompt.visible = true


func _open_teleport_panel() -> void:
	prompt.visible = false
	_play_sfx(interact_sfx)
	
	var panel_scene: PackedScene = ScenePaths.load_teleport_panel()
	var panel: CanvasLayer = panel_scene.instantiate()
	panel.source_teleport_id = teleport_id
	get_tree().root.add_child(panel)
	panel.menu_closed.connect(_on_panel_closed)


func _on_panel_closed() -> void:
	if player_in_range:
		prompt.visible = true


func _play_sfx(stream: AudioStream) -> void:
	if stream != null:
		AudioManager.play_stream_sfx(stream)


func _resolve_room_id() -> String:
	var parent = get_parent()
	while parent:
		if parent.has_method("get_room_data"):
			var data: Dictionary = parent.get_room_data()
			if data and data.has("id"):
				return str(data.id)
		parent = parent.get_parent()
	return ""
