const std = @import("std");
const c = @import("c.zig");

fn CGLTF_CHECK(result: c.cgltf_result) !void {
	return if (result == c.cgltf_result_success) {} else error.GltfError;
}

pub const World = struct {
	pub fn deinit(self: *World) void {
		_ = self;
	}
};

fn glft2VulkanVertexFormat(accessor: *c.cgltf_accessor) c.VkFormat {
	if (accessor.component_type == c.cgltf_component_type_r_32f and accessor.type == c.cgltf_type_vec3) {
		return c.VK_FORMAT_R32G32B32_SFLOAT;
	}
	@panic("imlement me");
}

fn gltf2VulkanIndexType(accessor: *c.cgltf_accessor) c.VkIndexType {
	if (accessor.component_type == c.cgltf_component_type_r_16u and accessor.type == c.cgltf_type_scalar) {
		return c.VK_INDEX_TYPE_UINT32;
	}
	@panic("imlement me");
}

pub fn loadModel(path: []const u8) !World {
	const options = std.mem.zeroes(c.cgltf_options);
	var data: ?*c.cgltf_data = null;
	try CGLTF_CHECK(c.cgltf_parse_file(&options, path.ptr, &data));
	defer c.cgltf_free(data);

	try CGLTF_CHECK(c.cgltf_load_buffers(&options, data, std.fs.path.dirname(path).?.ptr));

	std.debug.assert(data.?.meshes_count == 1);
	const mesh = data.?.meshes[0];
	std.debug.assert(mesh.primitives_count == 1);
	const primitive = mesh.primitives[0];
	std.debug.assert(primitive.type == c.cgltf_primitive_type_triangles);

	const positions: *c.cgltf_accessor = blk: {
		for (0..primitive.attributes_count) |i| {
			if (primitive.attributes[i].type == c.cgltf_attribute_type_position) {
				break :blk primitive.attributes[i].data;
			}
		}
		@panic("imlement me");
	};
	const indices: *c.cgltf_accessor = primitive.indices;

	const vertex_address =
		@as([*]u8, @ptrCast(positions.buffer_view.*.buffer.*.data)) +
		positions.buffer_view.*.offset +
		positions.offset;

	const index_address =
		@as([*]u8, @ptrCast(indices.buffer_view.*.buffer.*.data)) +
		indices.buffer_view.*.offset +
		indices.offset;

	const triangles = std.mem.zeroInit(c.VkAccelerationStructureGeometryTrianglesDataKHR, .{
		.sType = c.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR,
		.vertexFormat = glft2VulkanVertexFormat(positions),
		.vertexData = .{
			.hostAddress = vertex_address,
		},
		.vertexStride = positions.buffer_view.*.stride,
		.indexType = gltf2VulkanIndexType(indices),
		.indexData = .{
			.hostAddress = index_address,
		},
		.maxVertex = @as(u32, @intCast(positions.count)),
	});

	const geometry = std.mem.zeroInit(c.VkAccelerationStructureGeometryKHR, .{
		.sType = c.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR,
		.geometryType = c.VK_GEOMETRY_TYPE_TRIANGLES_KHR,
		.flags = c.VK_GEOMETRY_OPAQUE_BIT_KHR,
		.geometry = .{
			.triangles = triangles,
		},
	});

	const build_range = c.VkAccelerationStructureBuildRangeInfoKHR {
		.firstVertex = 0,
		.primitiveCount = @intCast(indices.count / 3),
		.primitiveOffset = 0,
		.transformOffset = 0,
	};

	_ = geometry;
	_ = build_range;

	return .{};
}
