# Scripts/Entities/Neutrals/StoneBug.gd
## 石块虫：带碰撞体的中立单位，行为完全使用 NeutralBug 基类（跟随地面上的玩家）。
## 用途：可被玩家踩踏当作“垫脚石”，也会触发按压式开关（Switch 的 PRESS 模式）。
## 注意：不加入 ignore_switch_press 组（与 TrampolineBug 相反）。
extends "res://Scripts/Entities/Neutrals/NeutralBug.gd"
class_name StoneBug
