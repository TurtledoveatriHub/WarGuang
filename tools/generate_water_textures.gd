@tool
extends SceneTree

## 程序生成像素风水面贴图（对标蔚蓝的水面画法）
##
## ★ 为什么要「先生成、再手绘替换」：水面观感全在这两张图里，脚本不掺和图案，
##   所以你换图 = 换观感，不用改任何代码。两张图都只需保证**可横向平铺**。
##
## 运行（项目根目录下）：
##   godot --headless --path . --script tools/generate_water_textures.gd
##
## 输出：
##   Assets/Textures/FX/water_surface_tile.png  水面条带（贴在水面线上、横向滚动）
##   Assets/Textures/FX/water_body_tile.png     水体色阶（浅 → 深，纵向铺满）
##   Assets/Textures/FX/water_splash_dot.png    入水水花用的小方点

## 输出目录（注意实际目录名是 FXs，旧名 FX 已不存在）
const OUTPUT_DIR: String = "res://Assets/Textures/FXs"
## 水面条带宽度（48 = 顶边图案周期 12 的 4 倍，保证可横向平铺）
const SURFACE_W: int = 48
## 水面条带高度（世界像素；1 纹素 = 1 像素）
const SURFACE_H: int = 6
## 水体贴图宽度（4 的倍数，保证抖动点可横向平铺）
const BODY_W: int = 64
## 水体贴图高度（= 浅色到最深色的总深度）
const BODY_H: int = 64

## 顶边参差图案：每列顶部被「吃掉」的像素数（周期 12）
var _notch: PackedInt32Array = PackedInt32Array([1, 0, 0, 2, 1, 0, 0, 1, 2, 0, 1, 0])
## 水体色阶分界行（浅 → 深；与 _band_colors 一一对应）
var _band_rows: PackedInt32Array = PackedInt32Array([0, 12, 24, 40, 64])
## 水体色阶颜色（浅 → 深）
var _band_colors: Array = [
	Color8(158, 220, 248),
	Color8(104, 176, 226),
	Color8(62, 126, 194),
	Color8(42, 92, 154),
]
## 水面亮线颜色
var _highlight: Color = Color8(234, 250, 255)

## 入口：生成两张贴图后退出
func _initialize() -> void:
	var dir_path: String = ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir_path)
	_save_image(_make_surface_image(), "water_surface_tile.png")
	_save_image(_make_body_image(), "water_body_tile.png")
	_save_image(_make_splash_image(), "water_splash_dot.png")
	quit()

## 生成水面条带贴图
func _make_surface_image() -> Image:
	var img: Image = Image.create_empty(SURFACE_W, SURFACE_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for x in range(SURFACE_W):
		var notch: int = _notch[x % _notch.size()]
		for y in range(SURFACE_H):
			## row = 相对水面线以下的第几行（负数 = 在水面之上 → 留空，形成参差顶边）
			var row: int = y - notch
			if row < 0:
				continue
			var col: Color = _band_colors[0]
			if row == 0:
				col = _highlight
			elif row == 2 and x % 16 == 7:
				## 稀疏波光像素：横向滚动时才会看到，给水面一点活气
				col = _highlight.lerp(_band_colors[0], 0.35)
			img.set_pixel(x, y, col)
	return img

## 生成水体贴图（纵向色阶 + 交界处的 1px 抖动点，手绘像素感）
func _make_body_image() -> Image:
	var img: Image = Image.create_empty(BODY_W, BODY_H, false, Image.FORMAT_RGBA8)
	img.fill(_band_colors[0])
	for y in range(BODY_H):
		var base: Color = _band_color_at(y)
		var edge: bool = _is_band_edge(y)
		for x in range(BODY_W):
			var col: Color = base
			if edge and (x + y * 2) % 4 == 0:
				## 色阶交界：撒一层上一个色阶的像素，避免出现一条死板直线
				col = _band_color_at(y - 1)
			img.set_pixel(x, y, col)
	return img

## 生成入水水花用的小方点（中心亮、边缘半透明）
func _make_splash_image() -> Image:
	var size: int = 4
	var img: Image = Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 0.0))
	for y in range(size):
		for x in range(size):
			var edge: bool = x == 0 or y == 0 or x == size - 1 or y == size - 1
			if edge:
				img.set_pixel(x, y, Color(0.78, 0.94, 1.0, 0.45))
			else:
				img.set_pixel(x, y, Color(1.0, 1.0, 1.0, 1.0))
	return img

## 取某一行所属的色阶颜色
func _band_color_at(row: int) -> Color:
	var index: int = 0
	for i in range(_band_colors.size()):
		if row >= _band_rows[i]:
			index = i
	return _band_colors[index]

## 该行是否是色阶交界行
func _is_band_edge(row: int) -> bool:
	for i in range(1, _band_rows.size()):
		if row == _band_rows[i] and i < _band_colors.size():
			return true
	return false

## 保存图片到输出目录
func _save_image(img: Image, file_name: String) -> void:
	var path: String = OUTPUT_DIR + "/" + file_name
	var err: int = img.save_png(path)
	if err == OK:
		print("已生成: " + path + "  (" + str(img.get_width()) + "x" + str(img.get_height()) + ")")
	else:
		push_error("生成失败(" + str(err) + "): " + path)
