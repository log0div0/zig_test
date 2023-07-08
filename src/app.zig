
const std = @import("std");
const c = @import("c.zig");
const sync = @import("sync.zig");

fn VK_CHECK(result: c.VkResult) !void {
	return if (result == c.VK_SUCCESS) {} else error.VkError;
}

fn selectMemoryType(memory_properties: c.VkPhysicalDeviceMemoryProperties, memory_type_bits: u32, flags: c.VkMemoryPropertyFlags) !u32
{
	for (0..memory_properties.memoryTypeCount) |i| {
		const bit = @as(u32, 1) << @intCast(i);
		if ((memory_type_bits & bit) != 0 and (memory_properties.memoryTypes[i].propertyFlags & flags) == flags)
			return @intCast(i);
	}

	return error.NoCompatibleMemoryTypeFound;
}

fn createImageView(device: c.VkDevice, image: c.VkImage, format: c.VkFormat, base_mip_level: u32, level_count: u32) !c.VkImageView
{
	const aspect_mask: c.VkImageAspectFlags = if(format == c.VK_FORMAT_D32_SFLOAT) c.VK_IMAGE_ASPECT_DEPTH_BIT else c.VK_IMAGE_ASPECT_COLOR_BIT;

	const create_info = std.mem.zeroInit(c.VkImageViewCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
		.image = image,
		.viewType = c.VK_IMAGE_VIEW_TYPE_2D,
		.format = format,
		.subresourceRange = .{
			.aspectMask = aspect_mask,
			.baseMipLevel = base_mip_level,
			.levelCount = level_count,
			.baseArrayLayer = 0,
			.layerCount = 1,
		},
	});

	var view: c.VkImageView = null;
	try VK_CHECK(c.vkCreateImageView(device, &create_info, 0, &view));
	return view;
}

pub const Image = struct{
	memory: c.VkDeviceMemory,
	image: c.VkImage,
	image_view: c.VkImageView,

	pub fn init(
		device: c.VkDevice,
		memory_properties: c.VkPhysicalDeviceMemoryProperties,
		width: u32,
		height: u32,
		mip_levels: u32,
		format: c.VkFormat,
		usage: c.VkImageUsageFlags) !Image
	{

		const create_info = std.mem.zeroInit(c.VkImageCreateInfo, .{
			.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
			.imageType = c.VK_IMAGE_TYPE_2D,
			.format = format,
			.extent = .{ width, height, 1 },
			.mipLevels = mip_levels,
			.arrayLayers = 1,
			.samples = c.VK_SAMPLE_COUNT_1_BIT,
			.tiling = c.VK_IMAGE_TILING_OPTIMAL,
			.usage = usage,
			.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
		});


		var image: c.VkImage = null;
		try VK_CHECK(c.vkCreateImage(device, &create_info, null, &image));

		var memory_requirements: c.VkMemoryRequirements = undefined;
		c.vkGetImageMemoryRequirements(device, image, &memory_requirements);

		const memory_type_index = try selectMemoryType(memory_properties, memory_requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

		const allocate_info = c.VkMemoryAllocateInfo{
			.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
			.pNext = null,
			.allocationSize = memory_requirements.size,
			.memoryTypeIndex = memory_type_index,
		};

		var memory: c.VkDeviceMemory = undefined;
		try VK_CHECK(c.vkAllocateMemory(device, &allocate_info, null, &memory));

		try VK_CHECK(c.vkBindImageMemory(device, image, memory, 0));

		return .{
			.image = image,
			.image_view = try createImageView(device, image, format, 0, mip_levels),
			.memory = memory,
		};
	}

	pub fn deinit(self: *Image, device: c.VkDevice) void {
		c.vkDestroyImageView(device, self.image_view, null);
		c.vkDestroyImage(device, self.image, null);
		c.vkFreeMemory(device, self.memory, null);
	}
};

pub const ResolutionDependentData = struct{
	const color_format = c.VK_FORMAT_R16G16B16A16_UNORM;
	const depth_format = c.VK_FORMAT_D32_SFLOAT;

	color_target: Image,
	depth_target: Image,
	out_width: u32,
	out_height: u32,

	pub fn init(
		device: c.VkDevice,
		memory_properties: c.VkPhysicalDeviceMemoryProperties,
		out_width: u32,
		out_height: u32,
	) !ResolutionDependentData {

		const color_target = try Image.init(device, memory_properties, out_width, out_height, 1, color_format,
			c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
		const depth_target = try Image.init(device, memory_properties, out_width, out_height, 1, depth_format,
			c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);

		return .{
			.color_target = color_target,
			.depth_target = depth_target,
			.out_width = out_width,
			.out_height = out_height,
		};
	}
	pub fn deinit(self: *ResolutionDependentData, device: c.VkDevice) void {
		self.color_target.deinit(device);
		self.depth_target.deinit(device);
	}
};

pub fn renderFrame(command_buffer: c.VkCommandBuffer, rdd: *ResolutionDependentData) void {

	sync.pipelineBarrier(command_buffer, c.VK_DEPENDENCY_BY_REGION_BIT, &.{}, &[_]c.VkImageMemoryBarrier2{
		sync.imageBarrier(rdd.color_target.image, sync.full_color,
			0, 0, c.VK_IMAGE_LAYOUT_UNDEFINED,
			c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL),
	});

	const color_attachment = std.mem.zeroInit(c.VkRenderingAttachmentInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
		.imageView = rdd.color_target.image_view,
		.imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
		.clearValue = .{
			.color = c.VkClearColorValue{ .float32 = .{0.2,0.2,0.2,0} }
		},
	});

	const depth_attachment = std.mem.zeroInit(c.VkRenderingAttachmentInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
		.imageView = rdd.depth_target.image_view,
		.imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
		.clearValue = .{
			.depthStencil = c.VkClearDepthStencilValue{ .depth = 0, .stencil = 0}
		},
	});

	const pass_info = std.mem.zeroInit(c.VkRenderingInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
		.renderArea = c.VkRect2D{
			.offset = .{ .x = 0, .y = 0 },
			.extent = .{
				.width = rdd.out_width,
				.height = rdd.out_height
			},
		},
		.layerCount = 1,
		.colorAttachmentCount = 1,
		.pColorAttachments = &color_attachment,
		.pDepthAttachment = &depth_attachment,
	});

	c.vkCmdBeginRendering(command_buffer, &pass_info);

	const viewport = c.VkViewport{
		.x = 0,
		.y = @floatFromInt(rdd.out_height),
		.width = @floatFromInt(rdd.out_width),
		.height = -@as(f32, @floatFromInt(rdd.out_height)),
		.minDepth = 0,
		.maxDepth = 1
	};
	const scissor = c.VkRect2D{
		.offset = .{ .x = 0, .y = 0},
		.extent = .{
			.width = rdd.out_width,
			.height = rdd.out_height
		}
	};

	c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
	c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);


	c.vkCmdEndRendering(command_buffer);
}
