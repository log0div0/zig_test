const std = @import("std");

fn readBinaryHeader(file: std.fs.File) !void {
	var buf: [12]u8 = undefined;
	const bytes_read = try file.readAll(&buf);
	if (bytes_read != buf.len) {
		return error.UnexpectedEof;
	}

	var stream = std.io.fixedBufferStream(&buf);
	const reader = stream.reader();

	const magic = try reader.readIntLittle(u32);
	if (magic != 0x46546C67) {
		return error.InvalidMagic;
	}
	const version = try reader.readIntLittle(u32);
	if (version != 2) {
		return error.UnsupportedVersion;
	}

	const length = try reader.readIntLittle(u32);
	_ = length;
}

pub fn loadModel() !void
{
	const path = "models\\Duck.glb";
	const ext = std.fs.path.extension(path);

	const file = try std.fs.cwd().openFile(path, .{});
	defer file.close();

	if (std.mem.eql(u8, ext, ".glb")) {
		try readBinaryHeader(file);
	} else if (std.mem.eql(u8, ext, ".gltf")) {
		return error.ImplementMe;
	} else {
		return error.UnsupportedFileFormat;
	}



}
