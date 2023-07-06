
const std = @import("std");
const c = @import("c.zig");

const VSYNC = true;

fn VK_CHECK(result: c.VkResult) !void {
	return if (result == c.VK_SUCCESS) {} else error.VkError;
}

const Status = enum {
	ready,
	not_ready,
	resized,
};

const max_image_count = 3;

handle: c.VkSwapchainKHR,
images: [max_image_count]c.VkImage,
width: u32,
height: u32,
image_count: u32,

fn createSwapchain(
	device: c.VkDevice,
	surface: c.VkSurfaceKHR,
	surface_caps: c.VkSurfaceCapabilitiesKHR,
	family_index: u32,
	format: c.VkFormat,
	width: u32,
	height: u32,
	old_swapchain: c.VkSwapchainKHR) !c.VkSwapchainKHR
{
	const surface_composite: c.VkCompositeAlphaFlagBitsKHR =
		if (surface_caps.supportedCompositeAlpha & c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR != 0)
			c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
		else if (surface_caps.supportedCompositeAlpha & c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR != 0)
			c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR
		else if (surface_caps.supportedCompositeAlpha & c.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR != 0)
			c.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR
		else
			c.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;

	const create_info = std.mem.zeroInit(c.VkSwapchainCreateInfoKHR, .{
		.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
		.surface = surface,
		.minImageCount = @max(2, surface_caps.minImageCount),
		.imageFormat = format,
		.imageColorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
		.imageExtent = .{
			.width = width,
			.height = height,
		},
		.imageArrayLayers = 1,
		.imageUsage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
		.queueFamilyIndexCount = 1,
		.pQueueFamilyIndices = &family_index,
		.preTransform = c.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
		.compositeAlpha = surface_composite,
		.presentMode = if (VSYNC) c.VK_PRESENT_MODE_FIFO_KHR else c.VK_PRESENT_MODE_IMMEDIATE_KHR,
		.oldSwapchain = old_swapchain,
	});

	var swapchain: c.VkSwapchainKHR = null;
	try VK_CHECK(c.vkCreateSwapchainKHR(device, &create_info, null, &swapchain));
	return swapchain;
}

const Self = @This();

pub fn init(
	physical_device: c.VkPhysicalDevice,
	device: c.VkDevice,
	surface: c.VkSurfaceKHR,
	family_index: u32,
	format: c.VkFormat,
	old_swapchain: c.VkSwapchainKHR) !Self
{
	var surface_caps: c.VkSurfaceCapabilitiesKHR = undefined;
	try VK_CHECK(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_caps));

	const width = surface_caps.currentExtent.width;
	const height = surface_caps.currentExtent.height;

	const swapchain = try createSwapchain(device, surface, surface_caps, family_index, format, width, height, old_swapchain);

	var image_count: u32 = 0;
	try VK_CHECK(c.vkGetSwapchainImagesKHR(device, swapchain, &image_count, 0));

	std.debug.assert(image_count <= max_image_count);

	var images: [max_image_count]c.VkImage = undefined;
	try VK_CHECK(c.vkGetSwapchainImagesKHR(device, swapchain, &image_count, &images));

	return Self {
		.handle = swapchain,
		.images = images,
		.width = width,
		.height = height,
		.image_count = image_count,
	};
}

pub fn update(self: *Self,
	physical_device: c.VkPhysicalDevice,
	device: c.VkDevice,
	surface: c.VkSurfaceKHR,
	family_index: u32,
	format: c.VkFormat) !Status
{
	var surface_caps: c.VkSurfaceCapabilitiesKHR = undefined;
	try VK_CHECK(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_caps));

	const new_width = surface_caps.currentExtent.width;
	const new_height = surface_caps.currentExtent.height;

	if (new_width == 0 or new_height == 0)
		return .not_ready;

	if (self.width == new_width and self.height == new_height)
		return .ready;

	var new_swapchain = try init(physical_device, device, surface, family_index, format, self.handle);
	errdefer new_swapchain.deinit(device);

	try VK_CHECK(c.vkDeviceWaitIdle(device));

	self.deinit(device);
	self.* = new_swapchain;
	return .resized;
}

pub fn deinit(self: *Self, device: c.VkDevice) void
{
	c.vkDestroySwapchainKHR(device, self.handle, null);
}