const std = @import("std");
const c = @import("c.zig");

const Shader = struct {
	pub fn deinit(self: *Shader, device: c.VkDevice) void {
		_ = self;
		_ = device;
	}
};

gpa: std.heap.GeneralPurposeAllocator(.{}) = .{},
temp_buf: []u8 = undefined,
handle: c.shaderc_compiler_t,

pub fn init() @This() {
	return .{
		.handle = c.shaderc_compiler_initialize(),
	};
}

pub fn deinit(self: *@This()) void {
	c.shaderc_compiler_release(self.handle);
	self.gpa.allocator().free(self.temp_buf);
	std.debug.assert(self.gpa.deinit() == .ok);
}

pub fn load(self: *@This(), device: c.VkDevice, name: []const u8) !Shader {
	if (std.os.argv.len != 2) {
		std.log.err("Usage: zig build run -- /project/dir", .{});
		return error.InvalidCmdLineArguments;
	}

	const project_dir = std.os.argv[1];

	var tmp = [_]u8{undefined} ** 200;
    const shader_path = try std.fmt.bufPrint(&tmp, "{s}\\shaders\\{s}", .{project_dir, name});

    _ = device;

	var file = try std.fs.cwd().openFile(shader_path, .{ .mode = .read_only });
	defer file.close();

	const file_size = try file.getEndPos();

	if (self.temp_buf.len < file_size) {
		self.temp_buf = try self.gpa.allocator().realloc(self.temp_buf, file_size);
	}

	if (try file.readAll(self.temp_buf) != file_size) {
		return error.FailedToReadShaderSouceCode;
	}

	const options = c.shaderc_compile_options_initialize();
	defer c.shaderc_compile_options_release(options);
	c.shaderc_compile_options_set_warnings_as_errors(options);

	const result = c.shaderc_compile_into_spv(
		self.handle, self.temp_buf.ptr, file_size,
		c.shaderc_glsl_vertex_shader, name.ptr, "main", options);
	defer c.shaderc_result_release(result);

	const status = c.shaderc_result_get_compilation_status(result);
	if (status != c.shaderc_compilation_status_success) {
		const msg = c.shaderc_result_get_error_message(result);
		std.log.err("{s}", .{msg});
		return error.ShaderCompilationError;
	}

	// c.shaderc_result_get_length();
	// c.shaderc_result_get_bytes();

    return .{};
}
