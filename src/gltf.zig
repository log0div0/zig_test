const std = @import("std");

const glb_magic = 0x46546C67;
const chunk_type_json = 0x4E4F534A;
const chunk_type_bin = 0x004E4942;

fn readBinaryHeader(file: std.fs.File) !void {
	var buf: [12]u8 = undefined;
	const bytes_read = try file.readAll(&buf);
	if (bytes_read != buf.len) {
		return error.UnexpectedEof;
	}

	var stream = std.io.fixedBufferStream(&buf);
	const reader = stream.reader();

	const magic = try reader.readIntLittle(u32);
	if (magic != glb_magic) {
		return error.InvalidMagic;
	}
	const version = try reader.readIntLittle(u32);
	if (version != 2) {
		return error.UnsupportedVersion;
	}

	const length = try reader.readIntLittle(u32);
	_ = length;
}

const Buffer = struct {
	byteLength: usize,
};

const Meta = struct {
	buffers: []Buffer = &.{},
};

pub fn loadModel(allocator: std.mem.Allocator) !void
{
	const path = "models\\Duck.glb";
	const ext = std.fs.path.extension(path);

	const file = try std.fs.cwd().openFile(path, .{});
	defer file.close();

	if (std.mem.eql(u8, ext, ".glb")) {
		try readBinaryHeader(file);

		const reader = file.reader();
		const chunk_length = try reader.readIntLittle(u32);
		const chunk_type = try reader.readIntLittle(u32);
		if (chunk_type != chunk_type_json) {
			return error.FirstChunkMustBeJson;
		}

		var json_str = try allocator.alloc(u8, chunk_length);
		defer allocator.free(json_str);

		try reader.readNoEof(json_str);

		const json = try std.json.parseFromSlice(Meta, allocator, json_str, .{.ignore_unknown_fields = true});
		defer json.deinit();

		std.debug.print("{}\n", .{json});
	} else if (std.mem.eql(u8, ext, ".gltf")) {
		return error.ImplementMe;
	} else {
		return error.UnsupportedFileFormat;
	}
}
