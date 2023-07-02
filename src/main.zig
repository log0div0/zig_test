const std = @import("std");

const c = @cImport({
	@cInclude("GLFW/glfw3.h");
});

export fn glfwErrorCallback(err: c_int, description: [*c]const u8) void {
    std.log.err("Error {}: {s}\n", .{err, description});
}

pub fn main() !void {
	_ = c.glfwSetErrorCallback(glfwErrorCallback);

	if (c.glfwInit() == c.GL_FALSE) {
		std.log.err("Failed to initialize GLFW\n", .{});
		return error.UnexpectedError;
	}
	defer c.glfwTerminate();

	c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

	std.debug.print("Hello world\n", .{});
}
