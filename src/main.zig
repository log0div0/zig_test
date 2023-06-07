const std = @import("std");

extern fn stbi_write_png(arg_filename: [*c]const u8, arg_x: c_int, arg_y: c_int, arg_comp: c_int, arg_data: ?*const anyopaque, arg_stride_bytes: c_int) c_int;

const RGB = struct {
    r: u8,
    g: u8,
    b: u8,
};

test "RGB size should be 3" {
    try std.testing.expect(@sizeOf(RGB) == 3);
}

pub fn main() !void {
    const start_time = std.time.nanoTimestamp();

    const w = 600;
    const h = 400;
    var img: [h][w]RGB = undefined;

    for (0..h) |y| {
        for (0..w) |x| {
            img[y][x] = .{
                .r = @floatToInt(u8, @intToFloat(f32, x) / w * 255),
                .g = @floatToInt(u8, @intToFloat(f32, y) / h * 255),
                .b = 0,
            };
        }
    }

    const end_time = std.time.nanoTimestamp();

    const res = stbi_write_png("out.png", w, h, @sizeOf(RGB), &img, @sizeOf(RGB) * w);
    if (res != 1) {
        return error.UnexpectedError;
    }

    const time_ms = @divFloor(end_time - start_time, std.time.ns_per_ms);

    std.log.info("Done in {} ms", .{time_ms});
}
