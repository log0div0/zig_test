
const std = @import("std");
const c = @import("c.zig");

buf: ?*anyopaque = null,
buf_size: usize = 0,
is_locked: bool = false,

const Self = @This();

pub fn init() Self {
	return .{};
}

pub fn deinit(self: *Self) void {
	std.debug.assert(self.is_locked == false);
	std.debug.print("ShortTermMem = {}\n", .{std.fmt.fmtIntSizeBin(self.buf_size)});
	c.free(self.buf);
}

pub fn lock(self: *Self, comptime T: type, n: usize) ![]T {
	std.debug.assert(self.is_locked == false);
	self.is_locked = true;

	const new_buf_size = @sizeOf(T) * n;
	if (new_buf_size == 0) {
		return error.AllocatingZeroBytesIsUndefinedBehaviour;
	}

	if (new_buf_size > self.buf_size) {
		const new_buf = c.realloc(self.buf, new_buf_size);
		if (new_buf == null) {
			return error.ReallocFailed;
		}
		self.buf = new_buf;
		self.buf_size = new_buf_size;
	}

	const t_ptr: [*]T = @alignCast(@ptrCast(self.buf));

	return t_ptr[0..n];
}

pub fn unlock(self: *Self) void {
	std.debug.assert(self.is_locked == true);
	self.is_locked = false;
}
