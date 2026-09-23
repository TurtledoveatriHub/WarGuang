extends Node

var current_checkpoint_key: String = ""
var checkpoints: Dictionary = {}   # "room_id/cp_id" -> position
var checkpoint_rooms: Dictionary = {}  # "room_id/cp_id" -> room_id

func _make_key(room_id: String, cp_id: String) -> String:
	return room_id + "/" + cp_id

func _ready():
	add_to_group("dynamic_checkpoint_manager")
	await get_tree().process_frame

func register_checkpoint(checkpoint_id: String, position: Vector2, room_id: String):
	var key: String = _make_key(room_id, checkpoint_id)
	if checkpoints.has(key):
		var old_pos: Vector2 = checkpoints.get(key, Vector2.ZERO)
		if old_pos.distance_to(position) < 0.001:
			return
	checkpoints[key] = position
	checkpoint_rooms[key] = room_id

func set_current_checkpoint(id: String, current_room: String):
	var key: String = _make_key(current_room, id)
	var cp_room: String = checkpoint_rooms.get(key, "")
	if cp_room == "" or cp_room != current_room:
		print("错误：检查点 ", id, " 不属于当前房间 ", current_room)
		return
	current_checkpoint_key = key
	if Global and Global.has_method("set_dynamic_checkpoint"):
		Global.set_dynamic_checkpoint(checkpoints.get(key, Vector2.ZERO))

func get_current_checkpoint_position(check_room: String = "") -> Vector2:
	if current_checkpoint_key == "":
		return Vector2.ZERO
	if check_room != "":
		var cp_room: String = checkpoint_rooms.get(current_checkpoint_key, "")
		if cp_room != "" and cp_room != check_room:
			return Vector2.ZERO
	return checkpoints.get(current_checkpoint_key, Vector2.ZERO)

func on_room_changed(_new_room_id: String):
	pass

func clear_all_checkpoints_on_death():
	current_checkpoint_key = ""
	if Global and Global.has_method("clear_dynamic_checkpoints"):
		Global.clear_dynamic_checkpoints()

func get_room_checkpoints(room_id: String) -> Array:
	var result: Array = []
	var prefix: String = room_id + "/"
	for key in checkpoints.keys():
		if not key.begins_with(prefix):
			continue
		var cp_id: String = key.trim_prefix(prefix)
		result.append({"id": cp_id, "position": checkpoints[key], "room_id": room_id})
	return result

func get_best_checkpoint_for_room(room_id: String, origin_position: Vector2, facing_right: bool, tie_distance: float = 64.0) -> Dictionary:
	var candidates := get_room_checkpoints(room_id)
	if candidates.is_empty():
		return {}

	# 优先使用不高于门位太多的候选点，避免门后出生在空中 DOWN。
	var near_ground_candidates: Array = []
	for candidate in candidates:
		var candidate_pos: Vector2 = candidate.get("position", Vector2.ZERO)
		if candidate_pos.y >= origin_position.y - 12.0:
			near_ground_candidates.append(candidate)
	if not near_ground_candidates.is_empty():
		candidates = near_ground_candidates

	var best_candidate: Dictionary = {}
	var best_score: float = INF
	var best_facing_score: float = -INF
	var facing_direction := Vector2.RIGHT if facing_right else Vector2.LEFT
	var tie_tolerance: float = tie_distance * tie_distance
	var up_penalty_threshold: float = 20.0
	var up_penalty_weight: float = 6.0
	var vertical_penalty_weight: float = 0.12

	for candidate in candidates:
		var candidate_pos: Vector2 = candidate.get("position", Vector2.ZERO)
		var delta: Vector2 = candidate_pos - origin_position
		var distance_sq: float = delta.length_squared()
		var vertical_delta: float = candidate_pos.y - origin_position.y
		var upward_amount: float = maxf(-(vertical_delta + up_penalty_threshold), 0.0)
		var upward_penalty: float = upward_amount * upward_amount * up_penalty_weight
		var vertical_penalty: float = absf(vertical_delta) * vertical_penalty_weight
		var score: float = distance_sq + upward_penalty + vertical_penalty
		var facing_score: float = delta.normalized().dot(facing_direction) if delta.length_squared() > 0.0001 else 1.0

		if best_candidate.is_empty():
			best_candidate = candidate
			best_score = score
			best_facing_score = facing_score
			continue

		if score + 0.001 < best_score:
			best_candidate = candidate
			best_score = score
			best_facing_score = facing_score
			continue

		if absf(score - best_score) <= tie_tolerance and facing_score > best_facing_score:
			best_candidate = candidate
			best_score = score
			best_facing_score = facing_score

	return best_candidate
