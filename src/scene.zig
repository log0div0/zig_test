const std = @import("std");
const glfw = @import("gltf.zig");

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
	var glfw_file = try glfw.loadFile(path, allocator);
	defer glfw_file.deinit();

	return .{};
}
