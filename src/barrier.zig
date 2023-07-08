
const std = @import("std");
const c = @import("c.zig");

pub fn pipeline(
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

pub fn imageMemory(
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

pub const full_color = c.VkImageSubresourceRange {
	.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
	.baseMipLevel = 0,
	.levelCount = c.VK_REMAINING_MIP_LEVELS,
	.baseArrayLayer = 0,
	.layerCount = c.VK_REMAINING_ARRAY_LAYERS,
};

pub fn colorAttachmentOutput2TransferSrc(image: c.VkImage) c.VkImageMemoryBarrier2 {
	return imageMemory(image, full_color,
		c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_ACCESS_TRANSFER_READ_BIT, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
}

pub fn undefined2TransferDst(image: c.VkImage) c.VkImageMemoryBarrier2 {
	return imageMemory(image, full_color,
		0, 0, c.VK_IMAGE_LAYOUT_UNDEFINED,
		c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_ACCESS_TRANSFER_WRITE_BIT, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
}

pub fn undefined2ColorAttachmentOutput(image: c.VkImage) c.VkImageMemoryBarrier2 {
	return imageMemory(image, full_color,
		0, 0, c.VK_IMAGE_LAYOUT_UNDEFINED,
		c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
}

pub fn transferDst2PresentSrc(image: c.VkImage) c.VkImageMemoryBarrier2 {
	return imageMemory(image, full_color,
		c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_ACCESS_TRANSFER_WRITE_BIT, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
		0, 0, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
}