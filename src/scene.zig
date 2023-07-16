const std = @import("std");
const c = @import("c.zig");

fn CGLTF_CHECK(result: c.cgltf_result) !void {
	return if (result == c.cgltf_result_success) {} else error.GltfError;
}

const Blas = struct {
};

pub const World = struct {
	blas_list: []Blas = &.{},

	pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
		_ = self;
		_ = allocator;
	}
};

pub fn loadModel(path: []const u8, allocator: std.mem.Allocator) !World {
	const options = std.mem.zeroes(c.cgltf_options);
	var data: ?*c.cgltf_data = null;
	try CGLTF_CHECK(c.cgltf_parse_file(&options, path.ptr, &data));
	defer c.cgltf_free(data);

	_ = allocator;

	return .{};
}
