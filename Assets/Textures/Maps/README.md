# 地图系统说明（纯代码生成，手绘整图已彻底废弃）

地图整图**不是美术画的**，而是运行时由 `MapManager` 按「已探索的房间」逐块画进一张 `Image`，
再当成普通贴图贴到 `MapUI/ContentRoot/MapWindow/MapContainer/MapSprite` 上。
`MapManager.get_map_texture()` 只有这一条来源，没有任何美术贴图回退。

---

## 1. 坐标换算（整套地图唯一的换算规则）

```
纹理像素 = (世界坐标 - map_world_origin) / world_units_per_map_pixel
世界坐标 = 纹理像素 * world_units_per_map_pixel + map_world_origin
```

* `world_units_per_map_pixel`：**1 个纹理像素 = 多少世界像素**，同时决定地图精细度与贴图尺寸。
  当前 `20`：世界包围盒 33280×11584 → 贴图 **1696×612**，一个 2560×1920 的房间 ≈ 128×96 像素。
  调小 = 更大更清楚（面积按平方膨胀）。
* `map_world_origin`：**不要手改**，由「全部房间包围盒左上角 − `map_padding_world`」自动推导并吸附像素网格。
* 三个值由 `RoomLayoutData.sync_generated_canvas()` 一起算出来，永不过期；改比例 = 整张自动重画。

---

## 2. 生成规则（`MapManager`，绘制顺序不可变）

1. **房间底色块** — 每个**已探索**房间的 `room_bounds` 整块填一种颜色，颜色按房间名前缀查
   `map_terrain_colors`（GrassLand→绿 / SnowMountain→蓝 / SuperMario→棕），没命中用 `map_default_terrain_color`。
2. **实体地面** — 房间内 `TileMapLayers` 下名字以 `Ground` / `Block` / `Hidden` 开头的 `TileMapLayer`，
   逐格画成**底色加深**（`map_ground_brightness`，默认 0.55 = 55% 亮度）。
   * `BlockTile` 和 `GroundTile` 一视同仁。
   * `HiddenTile`：**未激活时算地面**的（游戏里它看起来就是地面）；
     玩家触发激活后（`HiddenRegionFade` 会把整层 `visible=false`）就**不再算地面**。
     开图时会重扫仍在场景树里的房间来捕捉这个变化。
   * **`room_bounds` 之外的地形一律裁掉不画**（房间外沿的补墙 / 装饰地形不属于这张地图）。
   * 同一行的相邻格子先合并成横条再画，绘制次数从上万格降到几百条；
     不足 1 像素的细地形兜底成 1 像素，否则 1 格厚的地板会消失。
3. **特殊标志** — 房间里的容器节点名命中 `map_landmark_colors` 前缀时（`ChairSavePoints` /
   `DynamicCheckpoints` / `TeleportPoints`……），给容器下每个 `Node2D` 子节点打**一个像素点**
   （颜色取自配色表，边长 `map_landmark_pixel_size`）。因为它们画在贴图里，所以**同样吃战争迷雾**。
   以后加商店：房间场景里放一个对应前缀的容器 + 配色表加一行即可。
4. **门连线** — 满足全部条件才画：
   * 两个房间都已登记（都已探索）
   * **两个门都在各自房间 `room_bounds` 之外**（房间内部的门通往的是「另一层地图」，
     其房间在世界里被放得很远，连线会横穿整张地图，所以不参与）
   * **两个门的位置都已揭开迷雾**（真走到过门附近）
   颜色 = 本房间的地形底色，宽度 = `map_connector_width_px`（默认 1 像素）。

**未探索的房间不会在贴图里产生任何像素**（不是被盖住，而是根本没有），所以不可能「刚进房间就看到整间房」。

---

## 3. 参数速查（`Assets/Configs/RoomLayoutData.tres`）

| 参数 | 当前值 | 作用 |
| --- | --- | --- |
| `world_units_per_map_pixel` | `20.0` | 地图精细度 |
| `center_texture_on_world_origin` | `false` | 用「包围盒 + 留白」自动定原点 |
| `map_padding_world` | `320.0` | 画布四周留白（世界像素） |
| `map_terrain_colors` | 见资源 | 房间名前缀 → 房间底色 |
| `map_ground_brightness` | `0.55` | 实体地面相对底色的亮度 |
| `map_room_fill_alpha` | `1.0` | 房间底色不透明度 |
| `map_landmark_colors` | 见资源 | 标志容器名前缀 → 像素点颜色 |
| `map_landmark_pixel_size` | `1` | 每个标志占的像素边长 |
| `map_connector_width_px` | `1` | 门连线宽度（单像素） |

改完比例或配色不需要任何烘焙步骤 —— 开一次图（或进一次房间）就会重画。

---

## 4. 显示与操作（`MapUI`）

* 观察窗口 `MapWindow` 大小恒定；打开时把视野对准玩家一次，之后地图不动，只有玩家图标跟着玩家走。
* **滚轮**：缩放（以窗口中心为锚点）。缩放下限不是 `min_zoom`，而是「地图刚好铺满窗口」的倍率。
* **鼠标左键拖拽**：平移；`_clamp_pan()` 保证窗口不会跑出地图。
* **关闭键**：`Esc` 或 `Tab`（`map` 动作）。
* 打开地图期间不锁玩家操作，只把交互键 `U`（`interactive`）从 InputMap 里暂时摘掉，
  避免看地图时误触发 NPC / 存档点 / 传送点；受伤会自动关掉地图。
* `MapSprite` 上**不要手挂贴图**，挂了也没用（贴图完全由代码生成）。

---

## 5. 战争迷雾（渐进揭露）

* 未探索处纯黑，已探索处显示地图；边界用 `step()` 取硬边，没有模糊过渡。
* **RADIUS 模式（默认，渐进揭露）**：`MapUI._process` 每帧按玩家位置揭一个圆
  （半径 `reveal_radius_world`，默认 720 世界像素 = 36 纹理像素），
  并向外扩一个半径避免「门永远揭不开」。**绝不在一进房间就点亮整间房。**
* ROOM 模式：一进房间整块点亮（空洞骑士式）。此时 `MapManager.room_level_reveal = true`，
  由 `MapUI._push_reveal_config()` 下发；地图就绪后 `_process` 会被彻底关掉。
* ★ `FogRevealMode` 枚举顺序不可改：场景文件里存的是整数，`0 = ROOM`、`1 = RADIUS`。
* 两种模式下，没进过的房间无论玩家靠多近都不会显示（贴图里本来就没有它的像素）。

---

## 6. 界面暗化（全项目统一，唯一来源 `Scripts/UI/DarkOverlay.gd`）

| 界面 | 黑幕 | 世界亮度 | 黑幕宿主 | 会暂停游戏 |
| --- | --- | --- | --- | --- |
| MapUI（地图） | 0.5 秒渐到 0.7 | ×0.45 | 自己的 `Background` | 否 |
| TeleportPanel（传送） | 0.5 秒渐到 0.7 | ×0.45 | 自己的 `Background` | **是** |
| GameSettingScene（游戏内设置） | 0.5 秒渐到 0.7 | ×0.45 | 共用 `DarkOverlay` 单例 | **是** |

* 打开时**立即**开始渐暗，约 0.5 秒后到达 0.7；点击关闭时**立即**开始渐亮，约 0.5 秒回到全透明。
* 传送面板 / 游戏内设置在**按下关闭按钮的那一刻**就解除暂停并开始恢复暗化，不等退场动画播完。
