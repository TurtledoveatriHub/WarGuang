class_name AchievementData
extends Resource
## 一个成就的**定义**（纯数据，不含解锁状态）。
##
## 解锁状态不在这里，也不在任何存档里 —— 它由 AchievementManager 单独存到
## `user://achievements.cfg`，所以删档 / 换档都不会让已解锁的成就消失。
##
## 新增一个成就 = 新建一个本类型的 .tres 填好下面三项，再挂进成就目录
## （Assets/Configs/AchievementCatalog.tres）的列表里，界面会自动多出一格。

## 唯一 ID。代码里用 `AchievementManager.unlock(&"这个id")` 解锁。
## **一旦发布就不要再改**：改了等于换了一个新成就，老玩家的解锁记录会对不上。
@export var id: StringName = &""

## 成就描述文本（弹窗里显示在图标右侧）。
@export_multiline var description: String = ""

## 成就图标。未解锁时由着色器自动转成黑白并压暗，不需要另做一张灰图。
@export var icon: Texture2D
