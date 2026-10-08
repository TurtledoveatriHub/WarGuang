shader_type canvas_item;

// 成就图标着色器：不用为「未解锁」另做一张灰度贴图，直接在这里调。
//
// 用法：把本材质挂在成就条目的 TextureRect 上，代码里设 unlocked = 0 / 1。
//   0（未解锁）→ 转黑白 + 压暗
//   1（已解锁）→ 原色原样
//
// 只做颜色运算，不改采样方式，像素画工程全程保持 Nearest。

uniform float unlocked : hint_range(0.0, 1.0) = 0.0;
// 未解锁时的额外压暗系数（1.0 = 不额外压暗）
uniform float locked_brightness : hint_range(0.0, 1.0) = 0.7;

void fragment() {
	// COLOR 进来时已经是「贴图 × modulate」，直接在它上面做处理即可。
	vec4 c = COLOR;
	float gray = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	vec3 rgb = mix(vec3(gray), c.rgb, unlocked);
	rgb *= mix(locked_brightness, 1.0, unlocked);
	COLOR = vec4(rgb, c.a);
}
