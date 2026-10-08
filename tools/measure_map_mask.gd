extends SceneTree

## 临时测量：已探索遮罩不同存储方式的实际体积
## 运行：Godot --headless --path <项目根> --script res://tools/measure_map_mask.gd

func _initialize() -> void:
	var mask_size := Vector2i(452, 177)
	var image := Image.create(mask_size.x, mask_size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 1))
	for i in range(40):
		_paint_disc(image, Vector2(30.0 + float(i) * 10.0, 30.0 + float(i % 8) * 18.0), 12.0)

	var png_bytes: PackedByteArray = image.save_png_to_buffer()
	var encoded: String = Marshalls.raw_to_base64(png_bytes)
	var raw_bytes: int = mask_size.x * mask_size.y * 4

	var gray := Image.create(mask_size.x, mask_size.y, false, Image.FORMAT_L8)
	gray.fill(Color(0, 0, 0, 1))
	for i in range(40):
		_paint_disc(gray, Vector2(30.0 + float(i) * 10.0, 30.0 + float(i % 8) * 18.0), 12.0)
	var gray_png: PackedByteArray = gray.save_png_to_buffer()

	var half := Vector2i(int(mask_size.x / 2.0), int(mask_size.y / 2.0))
	var half_image := Image.create(half.x, half.y, false, Image.FORMAT_RGBA8)
	half_image.fill(Color(0, 0, 0, 1))
	for i in range(40):
		_paint_disc(half_image, Vector2(15.0 + float(i) * 5.0, 15.0 + float(i % 8) * 9.0), 6.0)

	print("MASK_SIZE=", mask_size)
	print("RAW_RGBA_BYTES=", raw_bytes)
	print("PNG_RGBA_BYTES=", png_bytes.size())
	print("PNG_RGBA_BASE64_CHARS=", encoded.length())
	print("PNG_L8_BYTES=", gray_png.size())
	print("PNG_HALF_RGBA_BYTES=", half_image.save_png_to_buffer().size())

	var decoded := Image.new()
	var err: int = decoded.load_png_from_buffer(Marshalls.base64_to_raw(encoded))
	print("ROUNDTRIP_ERR=", err, " SIZE=", decoded.get_size())
	quit()

## 在图像上画一个实心圆
func _paint_disc(image: Image, center: Vector2, radius: float) -> void:
	var min_x: int = maxi(int(floorf(center.x - radius)), 0)
	var max_x: int = mini(int(ceilf(center.x + radius)), image.get_width() - 1)
	var min_y: int = maxi(int(floorf(center.y - radius)), 0)
	var max_y: int = mini(int(ceilf(center.y + radius)), image.get_height() - 1)
	var radius_squared: float = radius * radius
	for y in range(min_y, max_y + 1):
		var dy: float = float(y) + 0.5 - center.y
		for x in range(min_x, max_x + 1):
			var dx: float = float(x) + 0.5 - center.x
			if dx * dx + dy * dy <= radius_squared:
				image.set_pixel(x, y, Color(1, 1, 1, 1))
