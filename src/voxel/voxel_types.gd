extends RefCounted
class_name VoxelTypes

## ============================================================
## 体素类型枚举定义 (VoxelTypes) — 全局常量和面方向枚举
## ============================================================
## 内容：
##   - VoxelType 枚举：所有体素类型(AIR=0, GRASS=1, DIRT=2, ...)
##   - Face 枚举：六个面方向(POS_X=0, NEG_X=1, ...)
##   - 辅助静态函数：is_solid(), default_place_type()
##
## 注意：此文件中的 get_face_tile() 为早期硬编码版本，
## 当前已被 BlockData.tile_for_face() 替代。
## 加载实际图集映射后，BlockRegistry.apply_atlas_mapping() 会将正确的
## tile坐标写入各BlockData资源的 tile_top/side/bottom 字段。
## ============================================================

enum VoxelType {
	AIR = 0,
	GRASS = 1,
	DIRT = 2,
	STONE = 3,
	OAK_LOG = 4,
	OAK_LEAVES = 5,
	BEDROCK = 6,
	GLASS = 7,
	SAND = 8,
}

enum Face {
	POS_X = 0,
	NEG_X = 1,
	POS_Y = 2,
	NEG_Y = 3,
	POS_Z = 4,
	NEG_Z = 5,
}

static func is_solid(voxel_type: int) -> bool:
	return voxel_type != VoxelType.AIR

static func default_place_type() -> int:
	return VoxelType.DIRT

static func get_face_tile(voxel_type: int, face: int) -> Vector2i:
	# --- INDEPENDENT DESIGN START ---
	# 纹理图集索引规则：
	# - 返回 (tile_x, tile_y)，代表该面的纹理位于图集的哪一个格子（从左上到右下）
	# - 你可以按课程要求把草方块的“顶面/侧面/底面”映射到不同格子以展示 UV 分配算法
	match voxel_type:
		VoxelType.GRASS:
			match face:
				Face.POS_Y:
					return Vector2i(0, 0) # 草顶
				Face.NEG_Y:
					return Vector2i(2, 0) # 泥底
				_:
					return Vector2i(1, 0) # 草侧
		VoxelType.DIRT:
			return Vector2i(2, 0)
		VoxelType.STONE:
			return Vector2i(3, 0)
		_:
			return Vector2i(2, 0)
	# --- INDEPENDENT DESIGN END ---
