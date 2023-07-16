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

const BufferView = struct {
	buffer: usize,
	byteLength: usize,
	byteOffset: usize = 0,
};

const Primitive = struct {

};

const Mesh = struct {
	name: ?[]u8 = null,
	// primitives: []Primitive,
};

const JsonChunk = struct {
	meshes: []Mesh = &.{},
};

pub const GltfModel = struct {
	main_file: std.fs.File,
	json: JsonChunk,
	arena: std.heap.ArenaAllocator,
	path: []const u8,
	is_binary: bool,

	pub fn deinit(self: *GltfModel) void {
		self.arena.deinit();
		self.main_file.close();
	}
};

pub fn loadFile(path: []const u8, child_allocator: std.mem.Allocator) !GltfModel
{
	const ext = std.fs.path.extension(path);

	const file = try std.fs.cwd().openFile(path, .{});
	errdefer file.close();

	var arena = std.heap.ArenaAllocator.init(child_allocator);
	errdefer arena.deinit();

	const allocator = arena.allocator();

	if (std.mem.eql(u8, ext, ".glb")) {
		try readBinaryHeader(file);

		const reader = file.reader();

		const json_chunk = blk: {
			const chunk_length = try reader.readIntLittle(u32);
			const chunk_type = try reader.readIntLittle(u32);
			if (chunk_type != chunk_type_json) {
				return error.FirstChunkMustBeJson;
			}

			var json_str = try allocator.alloc(u8, chunk_length);
			try reader.readNoEof(json_str);
			const json_chunk = try std.json.parseFromSliceLeaky(JsonChunk, allocator, json_str, .{.ignore_unknown_fields = true});

			if (chunk_length % 4 != 0) {
				try reader.skipBytes(4 - chunk_length % 4, .{});
			}

			break :blk json_chunk;
		};

		_ = try reader.readIntLittle(u32);
		const chunk_type = try reader.readIntLittle(u32);
		if (chunk_type != chunk_type_bin) {
			return error.SecondChunkMustBeBin;
		}

		return .{
			.main_file = file,
			.json = json_chunk,
			.arena = arena,
			.path = path,
			.is_binary = true,
		};
	} else if (std.mem.eql(u8, ext, ".gltf")) {
		return error.ImplementMe;
	} else {
		return error.UnsupportedFileFormat;
	}
}
