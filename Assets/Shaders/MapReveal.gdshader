shader_type canvas_item;

// 地图渲染着色器：战争迷雾 + 显示区域裁切
//
// 用法：贴在「整张世界地图」的 Sprite2D 上（centered = false，position = (0, 0)，scale = 1）。
// 贴图 1 像素 = world_units_per_map_pixel 个世界像素。
//
//   * 战争迷雾：边界为锐利像素（完全显示 / 完全遮蔽，不做任何插值），未探索处画纯黑
//   * 显示区域裁切：只在该屏幕矩形内绘制，其余 discard（地图不溢出到区域之外）

// 已探索遮罩：白 = 已探索，黑 = 未探索。与地图纹理像素一一对应。
uniform sampler2D reveal_mask : filter_nearest, repeat_disable;

// 是否启用战争迷雾
uniform bool use_reveal_mask = true;

// 是否启用显示区域裁切
uniform bool use_clip = false;

// 显示区域（屏幕归一化坐标：x, y, 宽度, 高度，取值范围 0~1）
uniform vec4 clip_rect_uv = vec4(0.0);

void fragment() {
	if (use_clip) {
		if (SCREEN_UV.x < clip_rect_uv.x || SCREEN_UV.y < clip_rect_uv.y
				|| SCREEN_UV.x > clip_rect_uv.x + clip_rect_uv.z
				|| SCREEN_UV.y > clip_rect_uv.y + clip_rect_uv.w) {
			discard;
		}
	}
	vec4 base_color = texture(TEXTURE, UV);
	// step 保证边界只有「完全显示」与「完全遮蔽」两种结果，没有模糊过渡
	float revealed = 1.0;
	if (use_reveal_mask) {
		revealed = step(0.5, texture(reveal_mask, UV).r);
	}
	// 未探索处强制为纯黑且不透明；已探索处保持贴图本身的颜色与透明度
	float alpha = base_color.a;
	if (use_reveal_mask) {
		alpha = mix(1.0, base_color.a, revealed);
	}
	COLOR = vec4(base_color.rgb * revealed, alpha);
}
