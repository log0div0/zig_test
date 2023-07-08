
const std = @import("std");
const c = @import("c.zig");

pub const full_color = c.VkImageSubresourceRange {
	.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
	.baseMipLevel = 0,
	.levelCount = c.VK_REMAINING_MIP_LEVELS,
	.baseArrayLayer = 0,
	.layerCount = c.VK_REMAINING_ARRAY_LAYERS,
};

pub fn imageBarrier(
	image: c.VkImage,
	subresource_range: c.VkImageSubresourceRange,
	srcStageMask: c.VkPipelineStageFlags2,
	srcAccessMask: c.VkAccessFlags2,
	oldLayout: c.VkImageLayout,
	dstStageMask: c.VkPipelineStageFlags2,
	dstAccessMask: c.VkAccessFlags2,
	newLayout: c.VkImageLayout,
	) c.VkImageMemoryBarrier2
{
	return std.mem.zeroInit(c.VkImageMemoryBarrier2, .{
		.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
		.srcStageMask = srcStageMask,
		.srcAccessMask = srcAccessMask,
		.dstStageMask = dstStageMask,
		.dstAccessMask = dstAccessMask,
		.oldLayout = oldLayout,
		.newLayout = newLayout,
		.image = image,
		.subresourceRange = subresource_range,
	});
}

pub fn pipelineBarrier(
	command_buffer: c.VkCommandBuffer,
	dependency_flags: c.VkDependencyFlags,
	buffer_barriers: []const c.VkBufferMemoryBarrier2,
	image_barriers: []const c.VkImageMemoryBarrier2) void
{
	const dependency_info = c.VkDependencyInfo{
		.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
		.pNext = null,
		.dependencyFlags = dependency_flags,
		.memoryBarrierCount = 0,
		.pMemoryBarriers = null,
		.bufferMemoryBarrierCount = @intCast(buffer_barriers.len),
		.pBufferMemoryBarriers = buffer_barriers.ptr,
		.imageMemoryBarrierCount = @intCast(image_barriers.len),
		.pImageMemoryBarriers = image_barriers.ptr,
	};

	c.vkCmdPipelineBarrier2(command_buffer, &dependency_info);
}
