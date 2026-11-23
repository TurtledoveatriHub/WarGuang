extends BaseNPC
class_name SnowOldMaster
## 雪山老者

@export_category("动画状态")
## 待机动画名
@export var idle_animation: String = "IDLE"
## 对话动画名
@export var talk_animation: String = "TALK"

func _ready():
	npc_id = "SnowOldMaster"
	super._ready()
	_play_default_idle()

func _start_interaction():
	var player = get_tree().get_first_node_in_group("player")
	var task_manager = get_node_or_null("/root/TaskManager")
	
	if not player:
		return
	
	if not dialogue_resource:
		return
	
	if animated_sprite and animated_sprite.sprite_frames:
		if animated_sprite.sprite_frames.has_animation(talk_animation):
			play_animation(talk_animation)
	
	var dialogue_count = TaskManager.get_npc_dialogue_count(npc_id)
	
	if not balloon_scene:
		push_error("Master: balloon_scene 未配置！请在 Inspector 中拖拽 MyBalloon.tscn")
		return
	
	var balloon: Node = MyDialogueBalloon.acquire(get_tree().current_scene, balloon_scene)
	if balloon == null:
		return
	
	if dialogue_count == 0:
		balloon.start(dialogue_resource, "first_meeting", [])
	elif dialogue_count == 1:
		_grant_vertical_dash_ability(player)
		balloon.start(dialogue_resource, "second_meeting", [])
	else:
		# 后续：直接结束
		balloon.start(dialogue_resource, "no_more_teachings", [])
	
	if task_manager:
		task_manager.record_npc_dialogue(npc_id)


## 授予垂直冲刺能力。
## Player 与 Global 两边都要写：前者是本局立即生效，后者是存档数据。
func _grant_vertical_dash_ability(player):
	if player.has_method("unlock_ability"):
		player.unlock_ability("vertical_dash")
	Global.unlock_ability("vertical_dash")


func _on_dialogue_ended():
	await get_tree().process_frame
	super._on_dialogue_ended()
	_play_default_idle()
