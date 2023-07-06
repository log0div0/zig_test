
const std = @import("std");
const c = @import("c.zig");

fn VK_CHECK(result: c.VkResult) !void {
	return if (result == c.VK_SUCCESS) {} else error.VkError;
}

fn selectMemoryType(memory_properties: c.VkPhysicalDeviceMemoryProperties, memory_type_bits: u32, flags: c.VkMemoryPropertyFlags) !u32
{
	for (0..memory_properties.memoryTypeCount) |i| {
		const bit = @as(u32, 1) << @intCast(std.math.Log2Int(u32), i);
		if ((memory_type_bits & bit) != 0 and (memory_properties.memoryTypes[i].propertyFlags & flags) == flags)
			return @intCast(u32, i);
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
