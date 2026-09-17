# Scripts/Instances/MineCart/MineCartTrack.gd
## 矿车轨道 —— 由子控制点定义，默认“相邻两点为直线”，并把“Arc 点”作为三点圆弧中点：
##   例：A、B、C 三个控制点，把 B 标记为圆弧中点（B 的节点名以 Arc/Curve 开头，
##   或 B 挂 MineCartPoint.gd 并勾 curve_apex），则 A→B→C 连成一段过 A/B/C 三点的圆弧；
##   其它相邻点仍是直线。想一条直轨 + 一段弯，就 A(直线)→B(C直线)→ 再到需要弧的位置放三个点。
## 这样“哪三个点成弧、哪段是直线”由你显式控制，无需成百上千个 Marker。
## 分断/空档：把某个控制点名字以 Gap 开头（或挂 MineCartPoint 勾 is_gap），轨道会在该点两侧断开：
##   车到断口前一段的末端会按当前速度沿切线飞出做抛物线，落回断口后一段（或另一条 MineCartTrack）。
## Point0 固定是起点（s=0），矿车初始即在 Point0 上；Point0→Point1 方向即“前进方向”。
## 运行后若需要轨条视觉，把直轨贴图拖到 rail_texture。
extends Node2D
class_name MineCartTrack

## 弧线段采样数量（圆弧光滑度）
@export var arc_samples: int = 36
## 编辑器/运行是否绘制调试轨道线（默认关，避免干扰视觉）
@export var debug_draw_track: bool = false
## 轨道美术：直轨贴图（横向为轨条走向；留空则不铺视觉轨条）
@export var rail_texture: Texture2D
## 轨条每段弧长（像素）
@export var rail_segment_px: float = 24.0
## 轨条贴图整体缩放
@export var rail_scale: Vector2 = Vector2.ONE
## 起点端（s=0）是否开放：到端后矿车可沿切线飞出（默认 false=封闭到端停下；站台端点即使勾选也永不飞出）
@export var open_start: bool = false
## 终点端（s=总长）是否开放：到端后矿车可沿切线飞出
@export var open_end: bool = false

## 烘焙后的折线顶点（局部坐标，相邻控制点/弧线被细分成折线）
var _pts: PackedVector2Array = PackedVector2Array()
## 每个顶点的累计弧长
var _cum: PackedFloat32Array = PackedFloat32Array()
## 轨道总长
var _total: float = 0.0
var _rail_container: Node2D = null
## 分断(空档)两侧弧长区间数组：每项 Vector2(前段终点弧长, 后段起点弧长)
var _gap_edges: Array = []
## 分断缝所在折线顶点下标（该顶点与下一顶点之间是空档，无轨道）
var _seams: PackedInt32Array = PackedInt32Array()


func _ready() -> void:
	bake()
	# 归入全局组，供 MineCart 脱轨后寻找可吸附的轨道
	add_to_group("minecart_tracks")


## 是否为“三点圆弧中点”（挂 MineCartPoint 且 curve_apex，或节点名以 Arc/Curve 开头）。
func _is_arc_mid(node: Node) -> bool:
	var apex: Variant = node.get("curve_apex")
	if typeof(apex) == TYPE_BOOL:
		return bool(apex)
	var nm := node.name.to_lower()
	return nm.begins_with("arc") or nm.begins_with("curve")


## 是否为“断口点”（空档/轨道分断）：节点名以 Gap/gap 开头，或挂 MineCartPoint 勾 is_gap。
func _is_gap(node: Node) -> bool:
	var g: Variant = node.get("is_gap")
	if typeof(g) == TYPE_BOOL and bool(g):
		return true
	return node.name.to_lower().begins_with("gap")


## 收集控制点节点（跳过运行时生成的视觉容器）。
func _collect_points() -> Array:
	var out: Array = []
	for ch in get_children():
		if ch is Marker2D and ch.name != "RailVisual":
			out.append(ch)
	return out


## 把控制点按 Gap 断口切成若干“段”（段内仍可用 Arc 三点圆弧；段与段之间是空档）。
func _collect_pieces(ctrl: Array) -> Array:
	var pieces: Array = []
	var cur: Array = []
	for node in ctrl:
		if _is_gap(node):
			if cur.size() >= 2:
				pieces.append(cur.duplicate())
			cur = []
		else:
			cur.append(node)
	if cur.size() >= 2:
		pieces.append(cur.duplicate())
	return pieces


## 生成整条折线：直线段取端点，弧线段按三点圆弧细分。
func _build_geom(ctrl: Array) -> PackedVector2Array:
	var dense := PackedVector2Array()
	var i: int = 0
	while i < ctrl.size() - 1:
		var p0: Marker2D = ctrl[i]
		var p1: Marker2D = ctrl[i + 1]
		if _is_arc_mid(p1) and i + 2 < ctrl.size():
			var p2: Marker2D = ctrl[i + 2]
			_append_line_if_needed(dense, p0.position)
			_append_arc(dense, p0.position, p1.position, p2.position)
			i += 2
		else:
			_append_line_if_needed(dense, p0.position)
			_append_line_if_needed(dense, p1.position)
			i += 1
	return dense


## 追加直线端点（若与末点不同）。
func _append_line_if_needed(dense: PackedVector2Array, p: Vector2) -> void:
	if dense.is_empty():
		dense.append(p)
	elif not dense[dense.size() - 1].is_equal_approx(p):
		dense.append(p)


## 追加“过 p0,pmid,p1 三点”的圆弧（细分折线）。
func _append_arc(dense: PackedVector2Array, p0: Vector2, pmid: Vector2, p1: Vector2) -> void:
	var res := _compute_circle(p0, pmid, p1)
	if res.is_empty():
		# 近共线/退化：按三点折线近似（仍经过三点）
		for k in range(1, arc_samples + 1):
			var t: float = float(k) / float(arc_samples)
			var q := _quad_through(p0, pmid, p1, t)
			if not dense.is_empty() and not dense[dense.size() - 1].is_equal_approx(q):
				dense.append(q)
		return
	var center: Vector2 = res["center"]
	var radius: float = res["radius"]
	# 确定从 a0 到 a1 需经过 am 的方向并采样
	var a0: float = (p0 - center).angle()
	var am: float = (pmid - center).angle()
	var a1: float = (p1 - center).angle()
	var dir: float = 1.0
	var span_pos := _ang_dist(a0, a1, 1.0)
	var mid_pos := _ang_dist(a0, am, 1.0)
	var span_neg := _ang_dist(a0, a1, -1.0)
	var mid_neg := _ang_dist(a0, am, -1.0)
	if span_pos <= span_neg:
		dir = 1.0
		if mid_pos > span_pos + 0.001:
			dir = -1.0
	else:
		dir = -1.0
		if mid_neg > span_neg + 0.001:
			dir = 1.0
	var total_span: float = _ang_dist(a0, a1, dir)
	if total_span < 0.001:
		total_span = TAU
	for k in range(1, arc_samples + 1):
		var t: float = float(k) / float(arc_samples)
		var ang: float = a0 + dir * total_span * t
		var q: Vector2 = center + Vector2(cos(ang), sin(ang)) * radius
		if not dense.is_empty() and dense[dense.size() - 1].is_equal_approx(q):
			continue
		dense.append(q)
	# 确保终点吻合（避免浮点误差导致与后续点不连续）
	if dense.size() > 0:
		dense[dense.size() - 1] = p1


## 计算过三点圆的圆心与半径（返回 Dictionary；三点近共线时返回空）。
func _compute_circle(a: Vector2, b: Vector2, c: Vector2) -> Dictionary:
	var denom: float = 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
	if absf(denom) < 0.0001:
		return {}
	var a2: float = a.x * a.x + a.y * a.y
	var b2: float = b.x * b.x + b.y * b.y
	var c2: float = c.x * c.x + c.y * c.y
	var ux: float = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / denom
	var uy: float = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / denom
	var center := Vector2(ux, uy)
	return {"center": center, "radius": a.distance_to(center)}


## 从 a0 沿 dir 方向到 a1 的有向角度距离（[0,2π)）。
func _ang_dist(a0: float, a1: float, dir: float) -> float:
	var d: float = a1 - a0
	if dir > 0.0 and d < 0.0:
		d += TAU
	elif dir < 0.0 and d > 0.0:
		d -= TAU
	return absf(d)


## 过三点 p0,p1,p2 的二次（贝塞尔式）近似，用于退化情况。
func _quad_through(p0: Vector2, p1: Vector2, p2: Vector2, t: float) -> Vector2:
	# 把 p1 作为控制点会让曲线“靠近”p1 但不过它；退化为三点折线更直观：
	# 这里直接用两段直线近似保证仍经过三点。
	if t < 0.5:
		return p0.lerp(p1, t * 2.0)
	return p1.lerp(p2, (t - 0.5) * 2.0)


func bake() -> void:
	var ctrl := _collect_points()
	var pieces := _collect_pieces(ctrl)
	_pts = PackedVector2Array()
	_gap_edges = []
	_seams = PackedInt32Array()
	# 每段内部仍走“直线/Arc 三点圆弧”；段与段之间（有 Gap 断口）互不相连
	for piece in pieces:
		if piece.size() < 2:
			continue
		var piece_pts := _build_geom(piece)
		if piece_pts.size() < 2:
			continue
		if _pts.size() > 0:
			_seams.append(_pts.size() - 1)
		for k in range(piece_pts.size()):
			if _pts.is_empty() or not _pts[_pts.size() - 1].is_equal_approx(piece_pts[k]):
				_pts.append(piece_pts[k])
	_cum = PackedFloat32Array()
	if _pts.size() >= 2:
		_cum.resize(_pts.size())
		_cum[0] = 0.0
		for i in range(1, _pts.size()):
			_cum[i] = _cum[i - 1] + _pts[i].distance_to(_pts[i - 1])
		_total = _cum[_pts.size() - 1]
	else:
		_total = 0.0
	# 依据缝点生成空档弧长区间（忽略过近的伪缝，避免误触发脱轨）
	for si in _seams:
		if si + 1 >= _pts.size():
			continue
		var near_a: float = _cum[si]
		var far_a: float = _cum[si + 1]
		if far_a - near_a >= 2.0:
			_gap_edges.append(Vector2(near_a, far_a))
	queue_redraw()
	_rebuild_rail_visual()


func total_length() -> float:
	return _total


## 返回空档弧长区间数组（每项 Vector2(前段终点弧长, 后段起点弧长)）。
func gap_edges() -> Array:
	return _gap_edges


## 某弧长 s 是否落在空档（断口间隙）内。
func _in_gap(s: float) -> bool:
	for e in _gap_edges:
		if typeof(e) == TYPE_VECTOR2:
			var v := e as Vector2
			if s > v.x and s < v.y:
				return true
	return false


## 在世界坐标下求距某点最近的弧长 s（空中吸附用；粗略分段即可）。
func nearest_s(world_pos: Vector2) -> float:
	if _pts.size() < 2:
		return 0.0
	var best_s: float = 0.0
	var best_d2: float = INF
	for i in range(_pts.size() - 1):
		if _seams.has(i):
			continue  # 空档缝段不算轨道，避免吸附到“空中虚点”
		var a := to_global(_pts[i])
		var b := to_global(_pts[i + 1])
		var ab := b - a
		var len2 := ab.length_squared()
		var t: float = 0.0
		if len2 > 0.0001:
			t = clampf((world_pos - a).dot(ab) / len2, 0.0, 1.0)
		var p := a.lerp(b, t)
		var d2 := (world_pos - p).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best_s = _cum[i] + (_cum[i + 1] - _cum[i]) * t
	return clampf(best_s, 0.0, _total)


## 按弧长取采样点（局部坐标；s 越界夹到端点）。
func sample_local(s: float) -> Vector2:
	if _pts.size() < 2:
		return Vector2.ZERO
	var t: float = clampf(s, 0.0, _total)
	var idx := _find_index(t)
	var seg_len: float = _cum[idx + 1] - _cum[idx]
	var f: float = 0.0
	if seg_len > 0.001:
		f = clampf((t - _cum[idx]) / seg_len, 0.0, 1.0)
	return _pts[idx].lerp(_pts[idx + 1], f)


func tangent_local(s: float) -> Vector2:
	if _pts.size() < 2:
		return Vector2.RIGHT
	var a := sample_local(s - 2.0)
	var b := sample_local(s + 2.0)
	var d: Vector2 = b - a
	return d.normalized() if d.length_squared() > 0.0001 else Vector2.RIGHT


func slope_at(s: float) -> float:
	return tangent_local(s).y


func _find_index(s: float) -> int:
	if _cum.is_empty():
		return 0
	var lo: int = 0
	var hi: int = _cum.size() - 1
	while lo < hi:
		var mid: int = (lo + hi) >> 1
		if _cum[mid + 1] < s:
			lo = mid + 1
		else:
			hi = mid
	return clampi(lo, 0, _cum.size() - 2)


func _draw() -> void:
	if not debug_draw_track or _pts.size() < 2:
		return
	for i in range(_pts.size() - 1):
		if _seams.has(i):
			continue  # 空档不画调试线
		draw_line(_pts[i], _pts[i + 1], Color(0.9, 0.4, 0.3, 0.6), 2.0)


func _rebuild_rail_visual() -> void:
	if _rail_container == null:
		_rail_container = Node2D.new()
		_rail_container.name = "RailVisual"
		add_child(_rail_container)
	else:
		for c in _rail_container.get_children():
			c.queue_free()
	if rail_texture == null or _total < 2.0:
		return
	var tex_w: float = maxf(float(rail_texture.get_width()), 1.0)
	var step: float = maxf(rail_segment_px, 4.0)
	# 用 while 铺满到 _total：旧 for 用 int(total/step) 会漏掉末端不足一步的“尾巴”，导致缆车跑到轨道贴图终点之外
	var s0: float = 0.0
	while s0 < _total - 0.001:
		var s1: float = minf(s0 + step, _total)
		if not _in_gap((s0 + s1) * 0.5):
			var p0: Vector2 = sample_local(s0)
			var p1: Vector2 = sample_local(s1)
			var seg: Vector2 = p1 - p0
			if seg.length_squared() > 0.0001:
				var sp := Sprite2D.new()
				sp.texture = rail_texture
				sp.position = (p0 + p1) * 0.5
				sp.rotation = seg.angle()
				sp.scale = Vector2(seg.length() / tex_w, 1.0) * rail_scale
				_rail_container.add_child(sp)
		if s1 - s0 < 0.01:
			break  # 防呆：避免除零/死循环
		s0 = s1
