extends RefCounted
class_name VoxelTypes

enum VoxelType {
	AIR = 0,
	GRASS = 1,
	DIRT = 2,
	STONE = 3,
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
