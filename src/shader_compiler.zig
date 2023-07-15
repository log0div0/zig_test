const std = @import("std");
const c = @import("c.zig");
const ShortTermMem = @import("short_term_mem.zig");

fn VK_CHECK(result: c.VkResult) !void {
	return if (result == c.VK_SUCCESS) {} else error.VkError;
}

handle: c.shaderc_compiler_t,

pub fn init() @This() {
	return .{
		.handle = c.shaderc_compiler_initialize(),
	};
}

pub fn deinit(self: *@This()) void {
	c.shaderc_compiler_release(self.handle);
}

const Definition = struct {
	name: []const u8,
	value: []const u8,
};

pub fn load(self: *@This(), device: c.VkDevice,
	comptime name: []const u8,
	comptime definitions: []const Definition,
	short_term_mem: *ShortTermMem) !c.VkShaderModule
{
	var tmp = [_]u8{undefined} ** 200;
    const shader_path = try std.fmt.bufPrint(&tmp, "shaders\\{s}", .{name});

	var file = try std.fs.cwd().openFile(shader_path, .{ .mode = .read_only });
	defer file.close();

	const file_size = try file.getEndPos();

	var temp_buf = try short_term_mem.lock(u8, file_size);
	defer short_term_mem.unlock();

	if (try file.readAll(temp_buf) != file_size) {
		return error.FailedToReadShaderSouceCode;
	}

	const options = c.shaderc_compile_options_initialize();
	defer c.shaderc_compile_options_release(options);

	c.shaderc_compile_options_set_warnings_as_errors(options);
	for (definitions) |definition| {
		c.shaderc_compile_options_add_macro_definition(options,
			definition.name.ptr, definition.name.len,
			definition.value.ptr, definition.value.len);
	}
	// put more options here

	const shader_kind: c.shaderc_shader_kind = comptime
		if (std.mem.indexOf(u8, name, ".vert.") != null) c.shaderc_glsl_vertex_shader
		else if (std.mem.indexOf(u8, name, ".frag.") != null) c.shaderc_glsl_fragment_shader
		else if (std.mem.indexOf(u8, name, ".comp.") != null) c.shaderc_glsl_compute_shader
		else @compileError("invalid shader extension");

	const result = c.shaderc_compile_into_spv(
		self.handle, temp_buf.ptr, file_size,
		shader_kind, name.ptr, "main", options);
	defer c.shaderc_result_release(result);

	const status = c.shaderc_result_get_compilation_status(result);
	if (status != c.shaderc_compilation_status_success) {
		const msg = c.shaderc_result_get_error_message(result);
		std.log.err("{s}", .{msg});
		return error.ShaderCompilationError;
	}

	const create_info = c.VkShaderModuleCreateInfo{
		.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.pNext = null,
		.flags = 0,
		.codeSize = c.shaderc_result_get_length(result),
		.pCode = @ptrCast(@alignCast(c.shaderc_result_get_bytes(result))),
	};

	var shader_module: c.VkShaderModule = null;
	try VK_CHECK(c.vkCreateShaderModule(device, &create_info, 0, &shader_module));
    return shader_module;
}
