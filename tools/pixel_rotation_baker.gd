extends EditorScript
## 像素画「旋转帧图集」一键烘焙工具（EditorScript，在 Godot 编辑器里 File → Run 执行）
##
## ── 为什么需要它 ─────────────────────────────────────────────
## Nearest 采样下，非 90° 的旋转**必然**重采样：目标像素网格和纹素网格不对齐，
## 一部分纹素被画两次、一部分被跳过 —— 这就是运行时 rotation 看起来「像素被重新排列」的原因。
## 唯一能同时保住锐利像素与旋转观感的做法，是像 IceCrystal 那样**把旋转烘焙进美术帧**，
## 运行时只切帧索引（帧索引只是换一块纹理区域，零重采样）。
##
## ── 算法 ────────────────────────────────────────────────────
## 1. 单元格边长 = ceil(对角线) 向上取到奇数（保证源图中心正好落在单元格中心的像素缝上）。
## 2. 对每一帧角度 θ，逐目标像素做**逆向旋转**回源图坐标，再结合「超采样 + 多数票」决定颜色：
##    * supersample = 1 → 等价于纯最近邻（每个目标像素取一个源纹素）
##    * supersample = 3 → 目标像素内取 9 个子样本，票数过半才算实心，颜色取**票数最高者**
##      这样既不会丢失 1px 细线，也**不会引入调色板以外的新颜色**（不做平均混合 = 不糊）。
## 3. 输出单行图集 PNG：宽度 = 帧数 × 单元格边长，高度 = 单元格边长。
##    Sprite2D 用法：texture = 图集，hframes = 帧数，然后用 frame 索引当角度。
##
## ── 用法 ────────────────────────────────────────────────────
## A. 编辑器里直接跑：改下面 TARGETS，然后 File → Run（本脚本必须被编辑器打开/选中）。
## B. 代码/控制台调用：PixelRotationBakerHelper 见文件末尾说明，或
##       load("res://tools/pixel_rotation_baker.gd").bake(path, frames, supersample, ...)
##
## ── 注意 ────────────────────────────────────────────────────
## * 只适合小尺寸像素图（车轮 11px、冰晶十几 px 这类）。大图 × 多帧 × 超采样会明显变慢。
## * 烘焙后的每一帧仍然是「重采样过的」，只是它**是静态的**：可以人工逐帧修像素、
##   也可以用 supersample 做多数票清理。这正好是手绘帧动画能干净的原因。
## * 旋转轴心默认取**不透明包围盒中心**（车轮这类对称图形更可靠），可用 pivot_mode 覆盖。

## 要烘焙的目标：source = 源 PNG；frames = 一圈的帧数；supersample = 超采样倍率。
## pivot_mode: "bbox"（不透明包围盒中心，默认）/ "center"（图像中心）/ "custom: x,y"。
const TARGETS: Array = [
	{
		"source": "res://Assets/Textures/Instances/MineCart/轮子.png",
		"frames": 24,
		"supersample": 3,
		"pivot_mode": "bbox",
	},
	{
		"source": "res://Assets/Textures/Instances/MineCart/雪地轮子.png",
		"frames": 24,
		"supersample": 3,
		"pivot_mode": "bbox",
	},
]


func _run() -> void:
	for t in TARGETS:
		var result: Dictionary = bake(
			String(t.get("source", "")),
			int(t.get("frames", 24)),
			int(t.get("supersample", 3)),
			String(t.get("pivot_mode", "bbox")),
		)
		print("[pixel_rotation_baker] ", result)
	EditorInterface.get_resource_filesystem().scan()


## 烘焙一张源图的旋转帧图集。
## 返回 { ok, sheet, cell, frames, pivot, source_size, sheet_size } 或 { ok: false, error }。
static func bake(
	source_path: String,
	frame_count: int = 24,
	supersample: int = 3,
	pivot_mode: String = "bbox",
) -> Dictionary:
	var tex: Texture2D = load(source_path)
	if tex == null:
		return {"ok": false, "error": "无法加载: " + source_path}
	var img: Image = tex.get_image()
	if img == null:
		return {"ok": false, "error": "无法取到 Image: " + source_path}
	img = _to_rgba8(img)
	var src_size: Vector2i = img.get_size()
	if src_size.x <= 0 or src_size.y <= 0:
		return {"ok": false, "error": "图像尺寸非法"}

	frame_count = maxi(frame_count, 1)
	supersample = clampi(supersample, 1, 8)

	var src: PackedColorArray = _extract_pixels(img)
	var pivot: Vector2 = _resolve_pivot(src, src_size, pivot_mode)

	# 单元格边长：装得下旋转后的外接矩形，并向上取奇数。
	var needed: int = int(ceil(maxf(float(src_size.x), float(src_size.y)) * sqrt(2.0))) + 1
	var cell: int = needed if (needed % 2 == 1) else needed + 1
	var cell_center: Vector2 = Vector2(float(cell) * 0.5, float(cell) * 0.5)

	var sheet: Image = Image.create(cell * frame_count, cell, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))

	var samples: int = supersample * supersample

	for f in frame_count:
		var angle: float = TAU * float(f) / float(frame_count)
		var ca: float = cos(-angle)
		var sa: float = sin(-angle)
		var ox: int = f * cell
		for y in cell:
			for x in cell:
				# 目标像素内的超采样集合（坐标约定：像素 i 占据 [i, i+1)，中心在 i+0.5）
				var votes: Dictionary = {}
				var hits: int = 0
				for sy in supersample:
					var py: float = float(y) + (float(sy) + 0.5) / float(supersample)
					for sx in supersample:
						var px: float = float(x) + (float(sx) + 0.5) / float(supersample)
						# 逆旋转：目标坐标 → 源图坐标（两套坐标系中心重合，故只减 cell_center）
						var dx: float = px - cell_center.x
						var dy: float = py - cell_center.y
						var ux: float = dx * ca - dy * sa + pivot.x
						var uy: float = dx * sa + dy * ca + pivot.y
						var ix: int = int(floor(ux))
						var iy: int = int(floor(uy))
						if ix < 0 or iy < 0 or ix >= src_size.x or iy >= src_size.y:
							continue
						var c: Color = src[iy * src_size.x + ix]
						if c.a <= 0.02:
							continue
						hits += 1
						if votes.has(c):
							votes[c] = int(votes[c]) + 1
						else:
							votes[c] = 1
				if hits * 2 < samples:
					continue
				# 多数票决定颜色：保持硬边、不产生调色板以外的新颜色。
				var best: Color = Color(0, 0, 0, 0)
				var best_votes: int = -1
				for c in votes.keys():
					var v: int = int(votes[c])
					if v > best_votes:
						best_votes = v
						best = c
				sheet.set_pixel(ox + x, y, best)

	var out_path: String = _sibling_path(source_path, "_rot%d" % frame_count)
	# 图集必须整块写入：Image.create 出来的图是未压缩 RGBA8，直接 save_png 即可。
	var err: int = sheet.save_png(out_path)
	if err != OK:
		return {"ok": false, "error": "写 PNG 失败 err=" + str(err) + " 路径=" + out_path}

	return {
		"ok": true,
		"sheet": out_path,
		"cell": cell,
		"frames": frame_count,
		"pivot": pivot,
		"source_size": src_size,
		"sheet_size": Vector2i(sheet.get_width(), sheet.get_height()),
		"hint": "Sprite2D: texture=图集, hframes=%d, vframes=1；frame 索引即角度步进 %.3f°" % [frame_count, 360.0 / float(frame_count)],
	}


## 只分析不烘焙：返回源图尺寸、不透明包围盒、包围盒中心、图像中心。
static func analyze(source_path: String) -> Dictionary:
	var tex: Texture2D = load(source_path)
	if tex == null:
		return {"ok": false, "error": "无法加载: " + source_path}
	var img: Image = _to_rgba8(tex.get_image())
	var src_size: Vector2i = img.get_size()
	var src: PackedColorArray = _extract_pixels(img)
	var min_x: int = src_size.x
	var min_y: int = src_size.y
	var max_x: int = -1
	var max_y: int = -1
	for y in src_size.y:
		for x in src_size.x:
			if src[y * src_size.x + x].a > 0.02:
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)
	return {
		"ok": true,
		"size": src_size,
		"bbox": Rect2i(Vector2i(min_x, min_y), Vector2i(max_x - min_x + 1, max_y - min_y + 1)),
		"bbox_center": Vector2(float(min_x + max_x + 1) * 0.5, float(min_y + max_y + 1) * 0.5),
		"image_center": Vector2(float(src_size.x) * 0.5, float(src_size.y) * 0.5),
	}


# ──────────────────────────── 内部工具 ────────────────────────────

static func _to_rgba8(img: Image) -> Image:
	if img == null:
		return null
	# get_image() 返回的是新建的 Image，就地转换不会影响已加载的资源。
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	return img


static func _extract_pixels(img: Image) -> PackedColorArray:
	var out: PackedColorArray = PackedColorArray()
	var size: Vector2i = img.get_size()
	out.resize(size.x * size.y)
	for y in size.y:
		for x in size.x:
			out[y * size.x + x] = img.get_pixel(x, y)
	return out


## 解析旋转轴心（源图像素坐标，可以是小数 = 像素缝）。
static func _resolve_pivot(src: PackedColorArray, src_size: Vector2i, pivot_mode: String) -> Vector2:
	if pivot_mode.begins_with("custom"):
		var parts: PackedStringArray = pivot_mode.split(":", false)
		if parts.size() >= 2:
			var xy: PackedStringArray = parts[1].split(",", false)
			if xy.size() >= 2:
				return Vector2(float(xy[0].strip_edges()), float(xy[1].strip_edges()))
	if pivot_mode == "center":
		return Vector2(float(src_size.x) * 0.5, float(src_size.y) * 0.5)
	# bbox：不透明包围盒中心
	var min_x: int = src_size.x
	var min_y: int = src_size.y
	var max_x: int = -1
	var max_y: int = -1
	for y in src_size.y:
		for x in src_size.x:
			if src[y * src_size.x + x].a > 0.02:
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)
	if max_x < 0:
		return Vector2(float(src_size.x) * 0.5, float(src_size.y) * 0.5)
	return Vector2(float(min_x + max_x + 1) * 0.5, float(min_y + max_y + 1) * 0.5)


static func _sibling_path(source_path: String, suffix: String) -> String:
	var dot: int = source_path.rfind(".")
	var base: String = source_path if dot < 0 else source_path.substr(0, dot)
	return base + suffix + ".png"
