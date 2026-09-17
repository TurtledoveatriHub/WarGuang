# Scripts/Instances/MineCart/MineCart.gd
## 缆车（原矿车，视觉参考 Nitrome《乐园过山车》）—— Phase A/B/C（手感/朝向/脱轨）
## 玩法（操控对标 Nitrome《乐园过山车》+ Terraria 矿车）：
##   - 按住 dash(按键)：缆车朝“目标端”加速（A 上车→向 B；B 上车→向 A）。
##   - 按住 jump(按键)：缆车朝“上车端/反向”加速。
##   - 不按键时：完全靠重力沿轨道加速/减速（上坡自然减速，停下后会在重力下自行向后滑落并越滑越快）。
##   - 上坡助力：按住“朝上坡方向”的引擎键时抵消部分重力惩罚（uphill_engine_assist）。
## 缆车结构：车身/乘客始终直立且行驶中不翻转；仅轮系(WheelRig)随缆线（或空中速度）连续倾斜贴合
##   真实切向（不再夹幅/强制朝右，避免大转弯时轮子跳到轨道另一侧）。车身纹理朝向按“上车时的出发方向”
##   固定一次（素材默认向右：出发向右不翻、向左则开始时翻）；轮子不再翻转（只随速度反向自转）。
## 方向按键以“目标端”为准：dash=始终朝目标端(A 上车→B、B 上车→A)，jump=反向(朝上车端)。
## 玩家朝向跟随“按键意图”沿缆线切线换算的水平方向；被动速度反向（击退/滑落/惯性）不翻转玩家；
## 缆车车身不随按键翻转。
## 轨道：由 MineCartTrack 控制点定义（默认直线、三控制点成弧）；AreaA(=起点 s=0)/AreaB(=终点)。
## 上下车：仅 A/B 端点站台(AreaA/AreaB)内且速度低时可交互；上下车切换有冷却防连按误触；
##   骑乘非致命伤害只扣血+沿轨击退；致命伤害下车（不立即移动矿车）。
## 脱轨：靠近站台的端点恒封闭（永不脱轨）；轨道 open_start/open_end 标记的其它端点到达后可沿切线
##   飞出做真实抛物线，空中接近任意 MineCartTrack（minecart_tracks 组）时按最近点吸附并继续。
extends Node2D
class_name MineCart

## ── 节点引用 ──
@export_category("节点引用")
@export_node_path var track_path: NodePath = NodePath("Track")
@export_node_path var rotate_group_path: NodePath = NodePath("RotateGroup")
@export_node_path var player_anchor_path: NodePath = NodePath("RotateGroup/PlayerAnchor")
## A 端站台（=原起点，s=0）
@export_node_path var area_a_path: NodePath = NodePath("AreaA")
## B 端站台（=原终点，s=总长）
@export_node_path var area_b_path: NodePath = NodePath("AreaB")
## A 端下车点
@export_node_path var exit_a_path: NodePath = NodePath("ExitA")
## B 端下车点
@export_node_path var exit_b_path: NodePath = NodePath("ExitB")
@export_node_path var wheel_front_path: NodePath = NodePath("RotateGroup/WheelFront")
@export_node_path var wheel_back_path: NodePath = NodePath("RotateGroup/WheelBack")

## ── 站台/交互 ──
@export_category("站台与交互")
## 允许上下车的速度阈值（像素/秒）
@export var dismount_speed: float = 80.0
## 下车后控制锁定时长（秒）
@export var dismount_lock: float = 0.2
## 上下车切换冷却（秒）：下车/上车后该时间内不能立刻反向操作，防止同一次按键连触发
@export var interact_cooldown: float = 0.6
## A/B 两个端点都可上车/下车；上车时矿车会瞬移到玩家所在端并出现
## 上车音效（可留空）
@export var board_sfx: AudioStream
## 下车音效（可留空）
@export var disembark_sfx: AudioStream

## ── 滑行/引擎 ──
@export_category("滑行与引擎")
## 前进（dash）方向最大速度（像素/秒）
@export var max_speed: float = 540.0
## 后退（jump）方向最大速度（像素/秒）
@export var reverse_max_speed: float = 480.0
## 按住 dash 的“前进引擎”加速度（像素/秒²）
@export var engine_forward_accel: float = 360.0
## 按住 jump 的“后退引擎”加速度（像素/秒²）
@export var engine_back_accel: float = 360.0
## 重力沿轨道分量系数（像素/秒²，越大坡度影响越明显）
@export var gravity_accel: float = 980.0
## 上坡助力系数（0~1）：按住“朝上坡方向”的引擎键时，抵消该比例的重力上坡惩罚（平地/下坡不生效）
@export var uphill_engine_assist: float = 0.9
## 滚动摩擦（恒向运动反方向的减速度，像素/秒²）
@export var roll_friction: float = 24.0
## 空气阻力（每帧速度衰减系数，秒⁻¹，0=无）
@export var air_drag: float = 0.2
## 受伤击退沿轨道分量缩放
@export var hurt_knock_scale: float = 2.0

## ── 表现 ──
@export_category("表现")
## 车轮半径（像素，用于线速度→车轮角速度换算）
@export var wheel_radius: float = 11.0
## 车轮自转视觉上限（度/秒；超出会被截断，避免高速时像素纹理闪/乱）
@export var wheel_max_spin_deg_per_s: float = 900.0
## 上下车烟雾特效 SpriteFrames（动画名 Smoke；留空=程序化占位圆点烟雾），由矿车自身发出
@export var smoke_frames: SpriteFrames

## ── 脱轨 / 飞行 ──
@export_category("脱轨与飞行")
## 空中重力加速度（像素/秒²，世界 y 向下）
@export var air_gravity: float = 900.0
## 空中吸附到轨道的最远距离（像素）
@export var magnet_radius: float = 32.0
## 骑乘中死亡时给玩家的向上弹出速度（像素/秒，向上为负 y；0=不弹出）——供外部在 Inspector 调手感
@export var death_pop_up_speed: float = 420.0

## ── 相对轨道位置 ──
@export_category("相对轨道位置")
## 整车相对“轨道采样点”的世界偏移（像素，y 向下为正＝吊在缆线下）。行驶/上车/落地都按此摆放。
@export var rail_offset: Vector2 = Vector2(0,-2)
## 上车时停车点向内收进轨道的弧长（像素）：A 端从 s=0 往内、B 端从总长往内。用于精准控制上车位置。
@export var board_inset: float = 0.0

## 内部引用
var _track: Node = null
var _rotate_group: Node2D = null
var _anchor: Marker2D = null
var _wheel_front: Node2D = null
var _wheel_back: Node2D = null
var _wheel_rig: Node2D = null
var _exit_a: Marker2D = null
var _exit_b: Marker2D = null
var _area_a_node: Node = null
var _area_b_node: Node = null

## 当前是否有人乘坐
var _occupied: bool = false
## 当前乘员
var _player: Node = null
## 弧长位置
var _s: float = 0.0
## 沿轨速度（+沿前进方向 / -沿后退方向）
var _v: float = 0.0
## 目标端方向在 +s 上的符号（A 上车=+1 向 B；B 上车=-1 向 A）
var _fwd_sign: int = 1
## 矿车当前面朝是否向右（用于左右镜像 & 玩家面朝）
var facing_right: bool = true
## 上下车切换冷却剩余时间（秒）
var _toggle_cd: float = 0.0
## 站台内玩家引用（A/B 端）
var _near_a_player: Node = null
var _near_b_player: Node = null
## 是否处于脱轨飞行（真实抛物线）状态
var _air: bool = false
## 飞行中的世界坐标
var _air_pos: Vector2 = Vector2.ZERO
## 飞行中的世界速度（像素/秒）
var _air_vel: Vector2 = Vector2.ZERO
## 起飞后的防“秒吸附回原点”计时（秒）
var _air_lock: float = 0.0


func _ready() -> void:
	_track = get_node_or_null(track_path)
	_rotate_group = get_node_or_null(rotate_group_path) as Node2D
	_anchor = get_node_or_null(player_anchor_path) as Marker2D
	_wheel_front = get_node_or_null(wheel_front_path) as Node2D
	_wheel_back = get_node_or_null(wheel_back_path) as Node2D
	_exit_a = get_node_or_null(exit_a_path) as Marker2D
	_exit_b = get_node_or_null(exit_b_path) as Marker2D
	_make_placeholder_visual()
	# 缆车结构：把车轮归到 WheelRig（随缆线/运动倾斜），Body/乘客保持直立且行驶中不翻转
	_ensure_wheel_rig()
	if _rotate_group:
		_rotate_group.scale = Vector2.ONE
		_rotate_group.rotation = 0.0
	# 车身保持 Nearest；车轮会旋转，因此在 _ensure_wheel_rig 里单独给轮子开 Linear
	var area_a := get_node_or_null(area_a_path) as Area2D
	_area_a_node = area_a
	if area_a:
		area_a.body_entered.connect(_on_area_a_body_entered)
		area_a.body_exited.connect(_on_area_a_body_exited)
	var area_b := get_node_or_null(area_b_path) as Area2D
	_area_b_node = area_b
	if area_b:
		area_b.body_entered.connect(_on_area_b_body_entered)
		area_b.body_exited.connect(_on_area_b_body_exited)
	_update_cart_pose(0.0)
	# 空车（未上车）不显示矿车本体
	_set_cart_visible(false)
	_update_prompt_visibility()


## 占位视觉：Body/车轮无贴图时生成简单色块/圆点。
func _make_placeholder_visual() -> void:
	var body := get_node_or_null("RotateGroup/Body") as Sprite2D
	if body and body.texture == null:
		body.texture = _make_rect_tex(40, 16, Color(0.75, 0.6, 0.35))
	for wheel in [_wheel_front, _wheel_back]:
		if wheel and (wheel as Sprite2D).texture == null:
			(wheel as Sprite2D).texture = _make_circle_tex(int(wheel_radius * 2.0), Color(0.3, 0.3, 0.32))


func _make_rect_tex(w: int, h: int, color: Color) -> Texture2D:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)


func _make_circle_tex(size: int, color: Color) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half := (size - 1) * 0.5
	for y in range(size):
		for x in range(size):
			var d: float = Vector2(x - half, y - half).length()
			if d <= half:
				img.set_pixel(x, y, color)
	return ImageTexture.create_from_image(img)


## 生成软边圆点贴图（占位烟雾用）。
func _make_soft_circle_tex(size: int, color: Color) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half := (size - 1) * 0.5
	for y in range(size):
		for x in range(size):
			var d: float = Vector2(x - half, y - half).length()
			var a: float = clampf(1.0 - d / half, 0.0, 1.0) * color.a
			img.set_pixel(x, y, Color(color.r, color.g, color.b, a))
	return ImageTexture.create_from_image(img)


## 把 WheelFront/WheelBack 归入 WheelRig（随缆线倾斜的轮系容器）；Body/PlayerAnchor 保持直立不倾斜。
func _ensure_wheel_rig() -> void:
	if _rotate_group == null:
		return
	var rig: Node2D = _rotate_group.get_node_or_null("WheelRig") as Node2D
	if rig == null:
		rig = Node2D.new()
		rig.name = "WheelRig"
		_rotate_group.add_child(rig)
	for wheel in [_wheel_front, _wheel_back]:
		if wheel and wheel.get_parent() != rig:
			if wheel.get_parent():
				wheel.get_parent().remove_child(wheel)
			rig.add_child(wheel)
		if wheel:
			# 旋转的车轮用 Linear 过滤（避免 Nearest 旋转产生锯齿/乱纹理）；车身仍 Nearest
			wheel.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_wheel_rig = rig


func _physics_process(delta: float) -> void:
	_toggle_cd = maxf(_toggle_cd - delta, 0.0)
	_update_prompt_visibility()
	if _occupied:
		return
	# 空车：A/B 任一端点站台内按交互即可上车（冷却结束后）
	if Input.is_action_just_pressed("interactive") and not _occupied and _toggle_cd <= 0.0:
		var p := _pick_station_player()
		if p != null:
			_board(p)


# ════════════════════════════════════════
# 上下车
# ════════════════════════════════════════

func _board(p: Node) -> void:
	if _occupied or p == null or _toggle_cd > 0.0:
		return
	if not p.has_method("change_state"):
		return
	# 上次死亡遗留的空车：先在其原位放烟雾并隐藏，避免它看起来“瞬移”到上车点
	_cleanup_leftover_before_board(p)
	_player = p
	_occupied = true
	# 清空可能残留的脱轨状态，并回到本车主轨（A/B 站台都在主轨上）
	_air = false
	_air_pos = Vector2.ZERO
	_air_vel = Vector2.ZERO
	_air_lock = 0.0
	_track = get_node_or_null(track_path)
	# 把（隐藏的）矿车放到玩家所在端点（A=s0 / B=s总长）
	_s = _station_snap_for(p)
	_v = 0.0
	p.velocity = Vector2.ZERO
	p.riding_minecart = self
	if p.has_method("register_feedback_hook"):
		p.register_feedback_hook(&"damage_taken", Callable(self, "_on_player_damage_taken"))
	p.change_state(p.PlayerState.RIDECART)
	_set_cart_visible(true)
	_update_cart_pose(0.0)
	_place_player_on_seat(p)
	# 上车：按“出发方向”固定车身/玩家纹理朝向（行驶中不翻转）；并像落地一样刷新二段跳/空中冲刺限制
	_apply_boarding_facing(p)
	_reset_rider_motion_limits(p)
	# 冷却：防止下车后同一帧/同一次按键被立刻再上车
	_toggle_cd = interact_cooldown
	_play_sfx(board_sfx)
	_spawn_smoke_at(_seat_world())
	_update_prompt_visibility()


func _do_disembark() -> void:
	var p := _player
	if p == null:
		return
	# 玩家在 B 端则送到 ExitB，否则送到 ExitA
	var at_b: bool = _near_b_player == p
	var exit_pos: Vector2 = p.global_position
	var exit_marker: Marker2D = _exit_b if (at_b and _exit_b) else _exit_a
	if exit_marker:
		exit_pos = exit_marker.global_position
	_leave_common(p)
	p.global_position = exit_pos
	if p.has_method("change_state"):
		p.change_state(p.PlayerState.IDLE)
	p.velocity = Vector2.ZERO
	# 下车也像落地一样刷新二段跳/空中冲刺等限制（避免下车后无法二段跳）
	_reset_rider_motion_limits(p)
	if p.has_method("lock_control"):
		p.lock_control(dismount_lock, "minecart_exit")
	# 冷却：防止下车后立刻被同一处站台再上车（同一帧 MineCart._physics_process 也不会再触发）
	_toggle_cd = interact_cooldown
	_set_cart_visible(false)
	_play_sfx(disembark_sfx)
	_spawn_smoke_at(exit_pos)
	_update_prompt_visibility()


## 致命伤害：强制下车（不在黑屏/重生前移动或隐藏矿车，避免玩家看到突然消失）。
func _hard_eject() -> void:
	var p := _player
	if p == null:
		return
	var was_air: bool = _air
	# 骑乘中死亡：给一个可控的向上“弹出”，随后由 DIE 重力做抛物线坠落（death_pop_up_speed=0 可关闭）
	if death_pop_up_speed > 0.0:
		p.velocity = Vector2(p.velocity.x * 0.3, -death_pop_up_speed)
	_leave_common(p)
	if was_air:
		# 空中被致命伤：让空车隐藏回 A（死亡画面里不会闪现移动）
		reset_to_start()
	# 冷却：重生点若靠近站台也不会立刻被自动/误触上车
	_toggle_cd = interact_cooldown
	_update_prompt_visibility()


func _leave_common(p: Node) -> void:
	if p and p.riding_minecart == self:
		p.riding_minecart = null
		p.riding_hurt_remaining = 0.0
	if p and p.has_method("unregister_feedback_hook"):
		p.unregister_feedback_hook(&"damage_taken", Callable(self, "_on_player_damage_taken"))
	_player = null
	_occupied = false
	_v = 0.0
	# 无论何种离开都结束飞行态（空车不再由谁推进）
	_air = false
	_air_pos = Vector2.ZERO
	_air_vel = Vector2.ZERO
	_air_lock = 0.0


func force_eject() -> void:
	_leave_common(_player)
	reset_to_start()


func reset_to_start() -> void:
	_s = 0.0
	_v = 0.0
	_occupied = false
	_toggle_cd = 0.0
	_air = false
	_air_pos = Vector2.ZERO
	_air_vel = Vector2.ZERO
	_air_lock = 0.0
	_set_cart_visible(false)
	_update_cart_pose(0.0)
	_update_prompt_visibility()


func _on_player_damage_taken(payload: Dictionary) -> void:
	if not _occupied:
		return
	if int(payload.get("new_health", 1)) <= 0:
		_hard_eject()


# ════════════════════════════════════════
# 骑乘主循环（由 PlayerMineCartRideService 每物理帧调用一次）
# ════════════════════════════════════════

func ride_process(player: Node, delta: float) -> void:
	if not _occupied or _player != player:
		return
	_handle_exit_input()
	if not _occupied:
		return
	# 玩家乘车时按“前进/后退按键”翻转朝向（缆车车身不随按键翻转）
	_update_rider_facing(player)
	if _air:
		_step_air(delta)
	else:
		_integrate(delta)
	_update_cart_pose(delta)
	_place_player_on_seat(player)
	_update_prompt_visibility()


## 下车输入（仅在站台且速度够低）。
func _handle_exit_input() -> void:
	if Input.is_action_just_pressed("interactive") \
	and (_near_a_player == _player or _near_b_player == _player) \
	and absf(_v) <= dismount_speed \
	and _toggle_cd <= 0.0:
		_do_disembark()


## 物理积分：引擎 + 重力沿坡 + 摩擦/空气。
func _integrate(delta: float) -> void:
	# 重力沿轨道（斜率>0 表示沿前进方向下坡）：无论前进后退都正确做功
	if _track and _track.total_length() > 0.0:
		_v += gravity_accel * _track.slope_at(_s) * delta
	# 上坡助力：仅“所按引擎方向为上坡”时抵消部分重力惩罚（平地/下坡/被动滑落不加成）
	if uphill_engine_assist > 0.001 and _track and _track.total_length() > 0.0:
		var slope: float = _track.slope_at(_s)
		var fs: float = float(_fwd_sign)
		var climb_fwd: bool = Input.is_action_pressed("dash") and fs * slope < -0.02
		var climb_back: bool = Input.is_action_pressed("jump") and fs * slope > 0.02
		if climb_fwd or climb_back:
			_v -= slope * gravity_accel * uphill_engine_assist * delta
	# 引擎方向相对“目标端”：dash=朝目标端(A上车→B / B上车→A)，jump=反向(朝上车端)
	if Input.is_action_pressed("dash"):
		if _fwd_sign > 0:
			_v = minf(_v + engine_forward_accel * delta, max_speed)
		else:
			_v = maxf(_v - engine_forward_accel * delta, -max_speed)
	if Input.is_action_pressed("jump"):
		if _fwd_sign > 0:
			_v = maxf(_v - engine_back_accel * delta, -reverse_max_speed)
		else:
			_v = minf(_v + engine_back_accel * delta, reverse_max_speed)
	# 滚动摩擦 + 空气阻力
	if absf(_v) > 0.001:
		_v = move_toward(_v, 0.0, roll_friction * delta)
	if air_drag > 0.0:
		_v *= maxf(1.0 - air_drag * delta, 0.0)
	_v = clampf(_v, -reverse_max_speed, max_speed)
	var prev_s: float = _s
	_s += _v * delta
	# 分断(Gap)：到达空档边缘就沿切线飞出（由 _try_reattach 吸附到空档对侧/下一段轨道）
	if absf(_v) > 0.001 and _track and _track.has_method("gap_edges"):
		var edges: Array = _track.gap_edges()
		for e in edges:
			if typeof(e) != TYPE_VECTOR2:
				continue
			var g := e as Vector2
			if _v > 0.0 and prev_s < g.x and _s >= g.x:
				_s = g.x
				_launch_from_end(g.x, 1)
				return
			elif _v < 0.0 and prev_s > g.y and _s <= g.y:
				_s = g.y
				_launch_from_end(g.y, -1)
				return
	# 位移 + 端点：封闭端到端停下；开放端以当前速度沿切线脱轨
	var total := _total_len()
	if _s < 0.0:
		_s = 0.0
		if _v < 0.0:
			if _end_open(0.0):
				_launch_from_end(0.0, -1)
			else:
				_v = 0.0
	elif _s > total:
		_s = total
		if _v > 0.0:
			if _end_open(total):
				_launch_from_end(total, 1)
			else:
				_v = 0.0


# ════════════════════════════════════════
# 脱轨飞行 & 吸附（真实抛物线）
# ════════════════════════════════════════

## 该端点是否为“开放端”（到达后可按当前速度沿切线飞出）。
## 靠近本车 A/B 站台（ExitA/ExitB 附近 120px）的端点恒为封闭端——即起终点两端永不脱轨。
func _end_open(s_end: float) -> bool:
	if _track == null:
		return false
	var end_world: Vector2 = _track.to_global(_track.sample_local(s_end))
	for m in [_exit_a, _exit_b]:
		if m and is_instance_valid(m) and m.global_position.distance_to(end_world) < 120.0:
			return false
	var open_flag: Variant = false
	if s_end <= 0.0:
		open_flag = _track.get("open_start")
	else:
		open_flag = _track.get("open_end")
	return typeof(open_flag) == TYPE_BOOL and bool(open_flag)


## 从轨尾以当前速度沿切线脱轨（进入空中抛物线）。
func _launch_from_end(end_s: float, outward_sign: int) -> void:
	if _track == null:
		return
	var exit_world: Vector2 = _track.to_global(_track.sample_local(end_s))
	var inside: Vector2 = _track.to_global(_track.sample_local(end_s - 6.0 * float(outward_sign)))
	var dir: Vector2 = exit_world - inside
	if dir.length_squared() < 0.0001:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	_air = true
	_air_pos = exit_world
	_air_vel = dir * maxf(absf(_v), 0.0)
	_air_lock = 0.3
	_v = 0.0


## 空中物理：重力抛物线 + 尝试吸附最近 MineCartTrack。
func _step_air(delta: float) -> void:
	_air_vel.y += air_gravity * delta
	_air_pos += _air_vel * delta
	if _air_lock > 0.0:
		_air_lock = maxf(_air_lock - delta, 0.0)
		return
	_try_reattach()


## 找最近的 MineCartTrack，若足够近则落地恢复在轨（可切换目标轨道）。
func _try_reattach() -> void:
	var candidates: Array = get_tree().get_nodes_in_group("minecart_tracks")
	var best: Node = null
	var best_s: float = 0.0
	var best_d: float = magnet_radius
	for t in candidates:
		if t == null or not is_instance_valid(t):
			continue
		if not t.has_method("nearest_s"):
			continue
		var s: float = t.nearest_s(_air_pos)
		var p: Vector2 = t.to_global(t.sample_local(s))
		var d: float = _air_pos.distance_to(p)
		if d <= magnet_radius and d <= best_d:
			best_d = d
			best = t
			best_s = s
	if best == null:
		return
	var land_pos: Vector2 = _air_pos
	_track = best
	_s = best_s
	# 把落点速度投影到轨道切线上，作为新的沿轨速度
	var ta: Vector2 = _track.to_global(_track.sample_local(best_s + 4.0))
	var tb: Vector2 = _track.to_global(_track.sample_local(best_s - 4.0))
	var tangent: Vector2 = ta - tb
	if tangent.length_squared() < 0.0001:
		tangent = Vector2.RIGHT
	tangent = tangent.normalized()
	_v = clampf(_air_vel.dot(tangent), -reverse_max_speed, max_speed)
	_air = false
	_air_vel = Vector2.ZERO
	_spawn_smoke_at(land_pos)


## 更新缆车位置/朝向（缆车版）：车身/乘客直立、行驶中不翻转；轮系随缆线（或空中速度）连续倾斜贴合切向。
func _update_cart_pose(delta: float = 0.0) -> void:
	if _rotate_group == null:
		return
	var tilt_dir: Vector2 = Vector2.RIGHT  # 轮系倾斜参考（轨道切线 / 空中速度）
	if _air:
		_rotate_group.position = to_local(_air_pos + rail_offset)
		tilt_dir = _air_vel
	else:
		if _track == null or _track.total_length() <= 0.0:
			return
		_rotate_group.position = to_local(_track.to_global(_track.sample_local(_s)) + rail_offset)
		var ahead: Vector2 = _track.to_global(_track.sample_local(_s + 4.0))
		var behind: Vector2 = _track.to_global(_track.sample_local(_s - 4.0))
		tilt_dir = ahead - behind
	# 车身永远直立（车身不随缆线倾斜/翻转）
	if not is_equal_approx(_rotate_group.rotation, 0.0):
		_rotate_group.rotation = 0.0
	# 轮系倾斜：跟真实切线角连续变化（不强制“朝右/夹幅”，避免大转弯时轮子跳到轨道另一侧）
	if _wheel_rig and tilt_dir.length_squared() > 0.0001:
		_wheel_rig.rotation = tilt_dir.normalized().angle()
	# 车轮自转：rad/s 直接累加弧度（截断到视觉上限）；空中不转
	if delta > 0.0 and not _air and (_wheel_front or _wheel_back):
		var spin_rad: float = _v / maxf(wheel_radius, 0.5) * delta
		var spin_max: float = deg_to_rad(maxf(wheel_max_spin_deg_per_s, 0.0)) * delta
		spin_rad = clampf(spin_rad, -spin_max, spin_max)
		if _wheel_front:
			_wheel_front.rotation += spin_rad
		if _wheel_back:
			_wheel_back.rotation += spin_rad


## 上车时按“出发方向”固定纹理朝向（美术默认向右）：出发向右不翻转，出发向左则开始时翻转。
## 行驶中前进/后退都不再翻转 player/车身/轮子（轮子只反向自转）。
func _apply_boarding_facing(p: Node) -> void:
	_board_forward_dir()  # 顺带把 facing_right 固定为出发方向
	if p and p.get("is_facing_right") != null:
		p.is_facing_right = facing_right
	if p and p.animated_sprite:
		p.animated_sprite.flip_h = not facing_right
	var body := get_node_or_null("RotateGroup/Body") as Sprite2D
	if body:
		var bx: float = 1.0 if facing_right else -1.0
		if not is_equal_approx(body.scale.x, bx):
			body.scale.x = bx


## 出发方向（世界）：A 端(s=0)=沿 +s；B 端(s=总长)=沿 -s；并更新 facing_right。
func _board_forward_dir() -> Vector2:
	var fwd: Vector2 = Vector2.RIGHT
	if _track == null or _track.total_length() <= 0.0:
		return fwd
	# 用“上车所在端”决定出发方向（与 board_inset 无关）：A 端=+s，B 端=−s
	var at_b: bool = _near_b_player == _player
	_fwd_sign = -1 if at_b else 1
	if at_b:
		var c: Vector2 = _track.to_global(_track.sample_local(_total_len()))
		var d: Vector2 = _track.to_global(_track.sample_local(_total_len() - 4.0))
		fwd = -(c - d)
	else:
		var a: Vector2 = _track.to_global(_track.sample_local(4.0))
		var b: Vector2 = _track.to_global(_track.sample_local(0.0))
		fwd = a - b
	if fwd.length_squared() < 0.0001:
		facing_right = true
		return Vector2.RIGHT
	fwd = fwd.normalized()
	facing_right = fwd.x >= 0.0
	return fwd


## 上车/下车时“像落地一样”刷新空中能力限制（二段跳/空中冲刺等），并复位二段跳残影旋转。
func _reset_rider_motion_limits(p: Node) -> void:
	if p == null:
		return
	if p.animated_sprite:
		p.animated_sprite.rotation_degrees = 0.0
	if p.get("jump2_rotation") != null:
		p.jump2_rotation = 0.0
	if p.has_method("refresh_jump"):
		p.refresh_jump()
	if p.has_method("refresh_air_dash"):
		p.refresh_air_dash()
	if p.has_method("refresh_dash"):
		p.refresh_dash()
	p.has_double_jumped = false
	p.can_double_jump = true
	if p.get("coyote_time_active") != null:
		p.coyote_time_active = false
	if p.get("can_glide") != null:
		p.can_glide = false
	if p.get("is_gliding") != null:
		p.is_gliding = false
	if p.get("is_double_jump_holding") != null:
		p.is_double_jump_holding = false


## 乘车时玩家朝向跟随“操作意图方向”并沿当前缆线切线换算成世界水平方向（转弯时朝向跟着轨道走）。
## 被动反向（受伤击退/动力不足滑落/惯性滚动）不翻转玩家。
func _update_rider_facing(player: Node) -> void:
	if player == null or player.animated_sprite == null:
		return
	var fwd_key: bool = Input.is_action_pressed("dash")
	var back_key: bool = Input.is_action_pressed("jump")
	if fwd_key == back_key:
		return  # 都不按/同按：保持当前朝向（被动反向不翻转）
	var world_dir: Vector2 = Vector2.RIGHT
	if _air:
		# 空中无轨道：明显横向移动时按水平速度朝向
		if absf(_air_vel.x) >= 8.0:
			world_dir = Vector2(1.0, 0.0) if _air_vel.x >= 0.0 else Vector2(-1.0, 0.0)
		else:
			return
	else:
		if _track and _track.total_length() > 0.0:
			var a: Vector2 = _track.to_global(_track.sample_local(_s + 4.0))
			var b: Vector2 = _track.to_global(_track.sample_local(_s - 4.0))
			var tg: Vector2 = a - b
			if tg.length_squared() > 0.0001:
				tg = tg.normalized()
				# intent 意义：dash(+1)=朝目标端，jump(-1)=反向(朝上车端)
				var intent := 1 if fwd_key else -1
				var fs := float(_fwd_sign)
				world_dir = (tg * (fs if intent > 0 else -fs)).normalized()
			else:
				return
		else:
			return
	var face_right: bool = world_dir.x >= 0.0
	player.animated_sprite.flip_h = not face_right
	if player.get("is_facing_right") != null:
		player.is_facing_right = face_right


## 上车前清理“上次死亡遗留的空车”：在其原位放烟雾并隐藏，避免视觉上瞬移到上车点。
func _cleanup_leftover_before_board(p: Node) -> void:
	if _rotate_group == null or not _rotate_group.visible or _air:
		return
	if p == null:
		return
	# 上车永远发生在“本车主轨”，用主轨端点作比对基准（与残留车所在轨道无关）
	var home: Node = get_node_or_null(track_path)
	if home == null or not home.has_method("total_length") or home.total_length() <= 0.0:
		return
	var at_b: bool = _near_b_player == p
	var station_world: Vector2 = home.to_global(home.sample_local(home.total_length() if at_b else 0.0)) + rail_offset
	if _rotate_group.global_position.distance_to(station_world) < 80.0:
		return  # 已很靠近上车点，不做“消失”演出
	_spawn_smoke_at(_rotate_group.global_position)
	_set_cart_visible(false)


func _place_player_on_seat(p: Node) -> void:
	if p == null:
		return
	if _anchor:
		p.global_position = _anchor.global_position
	p.velocity = Vector2.ZERO


## 沿轨道方向的受伤击退：投影到轨道切线上。
func apply_riding_knockback(world_kb: Vector2) -> void:
	if _track == null or _track.total_length() <= 0.0:
		return
	var ahead: Vector2 = _track.to_global(_track.sample_local(_s + 4.0))
	var behind: Vector2 = _track.to_global(_track.sample_local(_s - 4.0))
	var dir: Vector2 = ahead - behind
	if dir.length_squared() < 0.0001:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	_v += dir.dot(world_kb) * hurt_knock_scale
	_v = clampf(_v, -reverse_max_speed, max_speed)


func _total_len() -> float:
	return _track.total_length() if _track else 0.0


# ════════════════════════════════════════
# 站台提示 & 检测
# ════════════════════════════════════════

func _update_prompt_visibility() -> void:
	var a_show: bool = false
	var b_show: bool = false
	if not _occupied:
		# 空车：A/B 端只要有人即可上车，显示对应站台提示
		a_show = _near_a_player != null and is_instance_valid(_near_a_player)
		b_show = _near_b_player != null and is_instance_valid(_near_b_player)
	else:
		var slow_enough: bool = absf(_v) <= dismount_speed
		a_show = _near_a_player == _player and slow_enough
		b_show = _near_b_player == _player and slow_enough
	_set_prompt(_area_a_node, a_show)
	_set_prompt(_area_b_node, b_show)


func _set_prompt(area: Node, visible_flag: bool) -> void:
	if area == null:
		return
	var prompt := area.get_node_or_null("InteractionPrompt")
	if prompt and prompt.visible != visible_flag:
		prompt.visible = visible_flag


## 矿车本体显隐（未上车时不显示）。
func _set_cart_visible(v: bool) -> void:
	if _rotate_group and _rotate_group.visible != v:
		_rotate_group.visible = v


## 空车时可交互上车的站台玩家（A 优先，B 次之）。
func _pick_station_player() -> Node:
	if _near_a_player != null and is_instance_valid(_near_a_player):
		return _near_a_player
	if _near_b_player != null and is_instance_valid(_near_b_player):
		return _near_b_player
	return null


## 玩家所在端点对应的弧长（A=0，B=总长）。
func _station_snap_for(p: Node) -> float:
	var total: float = _total_len()
	var inset: float = clampf(board_inset, 0.0, total * 0.5)
	var near_a: bool = _near_a_player == p
	var near_b: bool = _near_b_player == p
	if near_b and not near_a:
		return total - inset
	if near_b and near_a:
		# 都靠近：选距离更近的端点
		var d0: float = _exit_a.global_position.distance_to(p.global_position) if _exit_a else 1e9
		var d1: float = _exit_b.global_position.distance_to(p.global_position) if _exit_b else 1e9
		return (total - inset) if d1 <= d0 else inset
	return inset


## 载客锚点的世界坐标。
func _seat_world() -> Vector2:
	if _anchor:
		return _anchor.global_position
	if _player:
		return _player.global_position
	return global_position


## 播放一段音效（经 AudioManager 的 SFX 池）。
func _play_sfx(stream: AudioStream) -> void:
	if stream == null:
		return
	var am: Node = get_node_or_null("/root/AudioManager")
	if am and am.has_method("play_stream_sfx"):
		am.play_stream_sfx(stream)


## 上下车时由矿车自身发出烟雾（不经过 Player）：优先用 smoke_frames 动画 Smoke，否则程序化占位圆点。
func _spawn_smoke_at(world_position: Vector2) -> void:
	var host: Node = get_parent() if is_instance_valid(get_parent()) else get_tree().current_scene
	if host == null:
		return
	if smoke_frames and smoke_frames.has_animation("Smoke"):
		var fx := AnimatedSprite2D.new()
		fx.sprite_frames = smoke_frames
		fx.animation = "Smoke"
		fx.global_position = world_position
		fx.top_level = true
		fx.z_index = 20
		fx.play()
		fx.animation_finished.connect(func():
			if is_instance_valid(fx):
				fx.queue_free()
		)
		host.add_child(fx)
		return
	# 程序化占位烟雾：几个上浮淡出的软圆点
	var puff_root := Node2D.new()
	puff_root.global_position = world_position
	puff_root.top_level = true
	puff_root.z_index = 20
	host.add_child(puff_root)
	var tex := _make_soft_circle_tex(24, Color(0.85, 0.85, 0.9, 0.55))
	for i in range(5):
		var sp := Sprite2D.new()
		sp.texture = tex
		sp.modulate.a = 0.0
		var offset := Vector2(randf_range(-6.0, 6.0), randf_range(-6.0, 6.0))
		puff_root.add_child(sp)
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(sp, "modulate:a", 0.9, 0.05).set_delay(float(i) * 0.03)
		tw.tween_property(sp, "position", offset + Vector2(randf_range(-8.0, 8.0), randf_range(-16.0, -6.0)), 0.45).set_delay(float(i) * 0.03)
		tw.tween_property(sp, "scale", Vector2(2.0, 2.0), 0.45).set_delay(float(i) * 0.03)
		tw.chain().tween_property(sp, "modulate:a", 0.0, 0.25)
	var done := create_tween()
	done.tween_interval(0.8)
	done.tween_callback(func():
		if is_instance_valid(puff_root):
			puff_root.queue_free()
	)


func _is_player(b: Node) -> bool:
	return b != null and b.is_in_group("player")


func _on_area_a_body_entered(b: Node) -> void:
	if _is_player(b):
		_near_a_player = b
	_update_prompt_visibility()

func _on_area_a_body_exited(b: Node) -> void:
	if _near_a_player == b:
		_near_a_player = null
	_update_prompt_visibility()

func _on_area_b_body_entered(b: Node) -> void:
	if _is_player(b):
		_near_b_player = b
	_update_prompt_visibility()

func _on_area_b_body_exited(b: Node) -> void:
	if _near_b_player == b:
		_near_b_player = null
	_update_prompt_visibility()
