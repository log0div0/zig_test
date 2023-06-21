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

const Ray = struct {
    orig: Vec3,
    dir: Vec3,

    fn at(self: Ray, t: f64) Vec3 {
        return self.orig + self.dir * @splat(3, t);
    }
};

test "ray at" {
    const ray = Ray {
        .orig = .{1,2,3},
        .dir = .{0,1,-2}
    };
    const pos = ray.at(2);
    try std.testing.expectEqual(pos, .{1,4,-1});
}

fn normalize(vec: Vec3) Vec3 {
    return vec / @splat(3, length(vec));
}

fn ray_color(ray: Ray) Vec3 {
    const unit_direction = normalize(ray.dir);
    const t = 0.5 * (unit_direction[1] + 1.0);
    return @splat(3,(1.0-t))*Vec3{1,1,1} + @splat(3,t)*Vec3{0.5, 0.7, 1.0};
}

pub fn main() !void {
    const start_time = std.time.nanoTimestamp();

    const aspect_ratio = 16.0 / 9.0;
    const image_width = 600;
    const image_height = @floatToInt(comptime_int, @intToFloat(comptime_float, image_width) / aspect_ratio);

    const viewport_height = 2.0;
    const viewport_width = viewport_height * aspect_ratio;
    const focal_length = 1.0;

    const origin = Vec3{0,0,0};
    const horizontal = Vec3{viewport_width, 0, 0};
    const vertical = Vec3{0, viewport_height, 0};
    const two = @splat(3, @as(f64, 2));
    const lower_left_corner = origin - horizontal/two - vertical/two - Vec3{0,0,focal_length};

    var img: [image_height][image_width]RGB = undefined;

    for (0..image_height) |j| {
        for (0..image_width) |i| {
            const u = @intToFloat(f64, i) / (image_width-1);
            const v = @intToFloat(f64, j) / (image_height-1);
            const ray = Ray {
                .orig = origin,
                .dir = lower_left_corner + @splat(3,u)*horizontal + @splat(3,v)*vertical - origin,
            };
            const pixel_color_normalized = ray_color(ray);
            const pixel_color = pixel_color_normalized * @splat(3, @as(f64, 255.0));
            img[image_height-j-1][i] = RGB{
                .r = @floatToInt(u8, pixel_color[0]),
                .g = @floatToInt(u8, pixel_color[1]),
                .b = @floatToInt(u8, pixel_color[2]),
            };
        }
    }

    const end_time = std.time.nanoTimestamp();

    const res = stbi_write_png("out.png", image_width, image_height, @sizeOf(RGB), &img, @sizeOf(RGB) * image_width);
    if (res != 1) {
        return error.UnexpectedError;
    }

    const time_ms = @divFloor(end_time - start_time, std.time.ns_per_ms);

    std.log.info("Done in {} ms", .{time_ms});
}
