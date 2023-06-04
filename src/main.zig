const std = @import("std");

extern fn stbi_write_png(arg_filename: [*c]const u8, arg_x: c_int, arg_y: c_int, arg_comp: c_int, arg_data: ?*const anyopaque, arg_stride_bytes: c_int) c_int;

pub fn main() !void {
    const buf = [_]u8 {
        255,0,0,
        0,255,0,
        0,0,255,
        255,255,255
    };
    const res = stbi_write_png("out.png", 2, 2, 3, &buf, 6);
    std.debug.assert(res == 1);

    std.log.warn("hello world! {d}", .{res});
}
