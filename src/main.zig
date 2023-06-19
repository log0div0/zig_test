const std = @import("std");

extern fn stbi_write_png(arg_filename: [*c]const u8, arg_x: c_int, arg_y: c_int, arg_comp: c_int, arg_data: ?*const anyopaque, arg_stride_bytes: c_int) c_int;

const RGB = struct {
    r: u8,
    g: u8,
    b: u8,
};

test "RGB size should be 3" {
    try std.testing.expectEqual(@sizeOf(RGB), 3);
}

const Vec3 = @Vector(3, f64);

test "vector devide" {
    const v = Vec3{1, 2, 4};
    const v2 = v / @splat(3, @as(f64, 2));
    try std.testing.expectEqual(v2, Vec3{0.5, 1, 2});
}

fn dot(x: Vec3) f64 {
    return @reduce(.Add, x * x);
}

fn length(x: Vec3) f64 {
    return @sqrt(dot(x));
}

test "vector length" {
    const v = Vec3{1, 2, 4};
    const len = length(v);
    try std.testing.expectApproxEqAbs(len, 4.5825756, 0.00001);
}

fn cross(u: Vec3, v: Vec3) Vec3 {
    return .{u[1]*v[2] - u[2]*v[1],
             u[2]*v[0] - u[0]*v[2],
             u[0]*v[1] - u[1]*v[0]};
}

test "vector cross" {
    const a = .{1, 2, 3};
    const b = .{-1, 4, 5};
    const c = cross(a, b);
    try std.testing.expectEqual(c, .{-2, -8, 6});
}

pub fn main() !void {
    const start_time = std.time.nanoTimestamp();

    const w = 600;
    const h = 400;
    var img: [h][w]RGB = undefined;

    for (0..h) |y| {
        for (0..w) |x| {
            img[y][x] = .{
                .r = @floatToInt(u8, @intToFloat(f64, x) / w * 255),
                .g = @floatToInt(u8, @intToFloat(f64, y) / h * 255),
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
