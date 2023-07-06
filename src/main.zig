const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const Swapchain = @import("swapchain.zig");
const Image = @import("resources.zig").Image;

export fn glfwErrorCallback(err: c_int, description: [*c]const u8) void {
	std.log.err("GLFW error #{}: {s}", .{err, description});
}

fn VK_CHECK(result: c.VkResult) !void {
	return if (result == c.VK_SUCCESS) {} else error.VkError;
}

fn VK_CHECK_SWAPCHAIN(result: c.VkResult) !void {
	// just ignore the error until the next frame when we will recreate a swapchain anyway
	return if (result == c.VK_SUCCESS or result == c.VK_SUBOPTIMAL_KHR or result == c.VK_ERROR_OUT_OF_DATE_KHR) {} else error.VkError;
}

fn createInstance() !c.VkInstance {
	const app_info = std.mem.zeroInit(c.VkApplicationInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.apiVersion = c.VK_API_VERSION_1_3,
	});

	const default_layers = [_][*:0]const u8{};
	const debug_layers = [_][*:0]const u8{
		"VK_LAYER_KHRONOS_validation",
	};
	const layers = if (builtin.mode == .Debug) default_layers ++ debug_layers else default_layers;

	const default_extensions = [_][*:0]const u8{
		c.VK_KHR_SURFACE_EXTENSION_NAME,
		c.VK_KHR_WIN32_SURFACE_EXTENSION_NAME,
	};
	const debug_extensions = [_][*:0]const u8{
		c.VK_EXT_DEBUG_REPORT_EXTENSION_NAME,
	};
	const extensions = if (builtin.mode == .Debug) default_extensions ++ debug_extensions else default_extensions;

	const create_info = std.mem.zeroInit(c.VkInstanceCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
		.pApplicationInfo = &app_info,
		.ppEnabledLayerNames = &layers,
		.enabledLayerCount = layers.len,
		.ppEnabledExtensionNames = &extensions,
		.enabledExtensionCount = extensions.len,
	});

	var instance: c.VkInstance = null;
	try VK_CHECK(c.vkCreateInstance(&create_info, null, &instance));
	return instance;
}

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
var g_allocator = general_purpose_allocator.allocator();

fn getGraphicsFamilyIndex(device: c.VkPhysicalDevice) !u32 {
	var queue_count: u32 = 0;
	c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_count, null);

	var queues = try g_allocator.alloc(c.VkQueueFamilyProperties, queue_count);
	defer g_allocator.free(queues);

	c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_count, queues.ptr);

	for (0..queue_count) |i| {
		if (queues[i].queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) {
			return @intCast(u32, i);
		}
	}

	return c.VK_QUEUE_FAMILY_IGNORED;
}

fn supportsPresentation(device: c.VkPhysicalDevice, family_index: u32) bool
{
	return c.vkGetPhysicalDeviceWin32PresentationSupportKHR(device, family_index) != 0;
}

fn pickPhysicalDevice(physical_devices: []c.VkPhysicalDevice) !c.VkPhysicalDevice {
	var preferred: c.VkPhysicalDevice = null;
	var fallback: c.VkPhysicalDevice = null;

	for (physical_devices, 0..) |device, i|
	{
		var props: c.VkPhysicalDeviceProperties = undefined;
		c.vkGetPhysicalDeviceProperties(device, &props);

		std.log.info("GPU{}: {s}", .{i, @ptrCast([*c]const u8, &props.deviceName)});

		const family_index = try getGraphicsFamilyIndex(device);
		if (family_index == c.VK_QUEUE_FAMILY_IGNORED) {
			continue;
		}

		if (!supportsPresentation(device, family_index)) {
			continue;
		}

		if (props.apiVersion < c.VK_API_VERSION_1_3) {
			continue;
		}

		if (preferred == null and props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
			preferred = device;
		}

		if (fallback == null) {
			fallback = device;
		}
	}

	const result = if (preferred != null) preferred else fallback;

	if (result != null) {
		var props: c.VkPhysicalDeviceProperties = undefined;
		c.vkGetPhysicalDeviceProperties(result, &props);

		std.log.info("Selected GPU {s}", .{@ptrCast([*c]const u8, &props.deviceName)});
		return result;
	}
	else {
		return error.NoGPUFound;
	}
}

fn createDevice(physical_device: c.VkPhysicalDevice, family_index: u32) error{VkError}!c.VkDevice
{
	const queue_priorities = [_]f32{ 1.0 };

	const queue_info = std.mem.zeroInit(c.VkDeviceQueueCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueFamilyIndex = family_index,
		.queueCount = queue_priorities.len,
		.pQueuePriorities = &queue_priorities,
	});

	const extensions = [_][*:0]const u8 {
		c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
	};

	const features13 = std.mem.zeroInit(c.VkPhysicalDeviceVulkan13Features, .{
		.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.dynamicRendering = 1,
		.synchronization2 = 1,
	});

	const create_info = std.mem.zeroInit(c.VkDeviceCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.pNext = &features13,
		.queueCreateInfoCount = 1,
		.pQueueCreateInfos = &queue_info,
		.ppEnabledExtensionNames = &extensions,
		.enabledExtensionCount = extensions.len,
	});

	var device: c.VkDevice = null;
	try VK_CHECK(c.vkCreateDevice(physical_device, &create_info, null, &device));
	return device;
}

fn createSurface(instance: c.VkInstance, window: ?*c.GLFWwindow) !c.VkSurfaceKHR {
	const create_info = std.mem.zeroInit(c.VkWin32SurfaceCreateInfoKHR, .{
		.sType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
		.hinstance = c.GetModuleHandleW(null),
		.hwnd = c.glfwGetWin32Window(window),
	});

	var surface: c.VkSurfaceKHR = null;
	try VK_CHECK(c.vkCreateWin32SurfaceKHR(instance, &create_info, null, &surface));
	return surface;
}

fn getSurfaceFormat(physical_device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !c.VkFormat
{
	var format_count: u32 = 0;
	try VK_CHECK(c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, 0));

	std.debug.assert(format_count > 0);
	var formats = try g_allocator.alloc(c.VkSurfaceFormatKHR, format_count);
	defer g_allocator.free(formats);

	try VK_CHECK(c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, formats.ptr));

	if (format_count == 1 and formats[0].format == c.VK_FORMAT_UNDEFINED) {
		return c.VK_FORMAT_R8G8B8A8_UNORM;
	}

	for (0..format_count) |i| {
		if (formats[i].format == c.VK_FORMAT_R8G8B8A8_UNORM or formats[i].format == c.VK_FORMAT_B8G8R8A8_UNORM) {
			return formats[i].format;
		}
	}

	return formats[0].format;
}

fn createSemaphore(device: c.VkDevice) !c.VkSemaphore {
	const create_info = std.mem.zeroInit(c.VkSemaphoreCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
	});

	var semaphore: c.VkSemaphore = null;
	try VK_CHECK(c.vkCreateSemaphore(device, &create_info, null, &semaphore));
	return semaphore;
}


// fn createRenderPass(device: c.VkDevice, color_format: c.VkFormat, depth_format: c.VkFormat) !c.VkRenderPass
// {
// 	const attachments = [_]c.VkAttachmentDescription{
// 		.{
// 			.flags = 0,
// 			.format = color_format,
// 			.samples = c.VK_SAMPLE_COUNT_1_BIT,
// 			.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
// 			.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
// 			.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
// 			.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
// 			.initialLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
// 			.finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
// 		},
// 		.{
// 			.flags = 0,
// 			.format = depth_format,
// 			.samples = c.VK_SAMPLE_COUNT_1_BIT,
// 			.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
// 			.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
// 			.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
// 			.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
// 			.initialLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
// 			.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
// 		}
// 	};

// 	const color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
// 	const depth_def = c.VkAttachmentReference{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };

// 	const subpass = std.mem.zeroInit(c.VkSubpassDescription, .{
// 		.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
// 		.colorAttachmentCount = 1,
// 		.pColorAttachments = &color_ref,
// 		.pDepthStencilAttachment = &depth_def,
// 	});

// 	const create_info = std.mem.zeroInit(c.VkRenderPassCreateInfo, .{
// 		.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
// 		.attachmentCount = attachments.len,
// 		.pAttachments = &attachments,
// 		.subpassCount = 1,
// 		.pSubpasses = &subpass,
// 	});

// 	var renderPass: c.VkRenderPass = null;
// 	try VK_CHECK(c.vkCreateRenderPass(device, &create_info, null, &renderPass));
// 	return renderPass;
// }

fn createCommandPool(device: c.VkDevice, family_index: u32) !c.VkCommandPool
{
	const create_info = c.VkCommandPoolCreateInfo{
		.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.pNext = null,
		.flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
		.queueFamilyIndex = family_index,
	};

	var command_pool: c.VkCommandPool = null;
	try VK_CHECK(c.vkCreateCommandPool(device, &create_info, null, &command_pool));
	return command_pool;
}

export fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) void
{
	_ = mods;
	_ = scancode;

	if (action == c.GLFW_PRESS)
	{
		if (key == c.GLFW_KEY_ESCAPE)
		{
			c.glfwSetWindowShouldClose(window, 1);
		}
	}
}

const FrameData = struct{
	const color_format = c.VK_FORMAT_R16G16B16A16_UNORM;
	const depth_format = c.VK_FORMAT_D32_SFLOAT;

	color_target: Image,
	depth_target: Image,

	fn init(
		device: c.VkDevice,
		memory_properties: c.VkPhysicalDeviceMemoryProperties,
		swapchain: Swapchain,
	) !FrameData {

		const color_target = try Image.init(device, memory_properties, swapchain.width, swapchain.height, 1, color_format,
			c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
		const depth_target = try Image.init(device, memory_properties, swapchain.width, swapchain.height, 1, depth_format,
			c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);

		return .{
			.color_target = color_target,
			.depth_target = depth_target,
		};
	}
	fn deinit(self: *FrameData, device: c.VkDevice) void {
		self.color_target.deinit(device);
		self.depth_target.deinit(device);
	}
};

pub fn main() !void {
	defer _ = general_purpose_allocator.deinit();

	_ = c.glfwSetErrorCallback(glfwErrorCallback);

	if (c.glfwInit() == c.GL_FALSE) {
		return error.FailedToInitializeGLFW;
	}
	defer c.glfwTerminate();

	const instance = try createInstance();
	defer c.vkDestroyInstance(instance, null);

	c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

	var physical_devices: [16]c.VkPhysicalDevice = undefined;
	var physical_device_count: u32 = physical_devices.len;
	try VK_CHECK(c.vkEnumeratePhysicalDevices(instance, &physical_device_count, &physical_devices));

	const physical_device = try pickPhysicalDevice(physical_devices[0..physical_device_count]);

	const family_index = try getGraphicsFamilyIndex(physical_device);
	std.debug.assert(family_index != c.VK_QUEUE_FAMILY_IGNORED);

	const device = try createDevice(physical_device, family_index);
	defer c.vkDestroyDevice(device, null);

	const window = c.glfwCreateWindow(1024, 768, "zig_test", null, null);
	if (window == null) {
		return error.FailedToCreateWindow;
	}
	defer c.glfwDestroyWindow(window);

	_ = c.glfwSetKeyCallback(window, keyCallback);

	const surface = try createSurface(instance, window);
	defer c.vkDestroySurfaceKHR(instance, surface, null);

	const surface_format = try getSurfaceFormat(physical_device, surface);

	const acquire_semaphore = try createSemaphore(device);
	defer c.vkDestroySemaphore(device, acquire_semaphore, null);
	const release_semaphore = try createSemaphore(device);
	defer c.vkDestroySemaphore(device, release_semaphore, null);

	const queue = blk: {
		var tmp: c.VkQueue = null;
		c.vkGetDeviceQueue(device, family_index, 0, &tmp);
		break :blk tmp;
	};

	// const render_pass = try createRenderPass(device, surface_format, depth_format);
	// defer c.vkDestroyRenderPass(device, render_pass, null);

	const command_pool = try createCommandPool(device, family_index);
	defer c.vkDestroyCommandPool(device, command_pool, null);

	const command_buffer = blk: {
		const allocate_info = c.VkCommandBufferAllocateInfo{
			.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
			.pNext = null,
			.commandPool = command_pool,
			.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
			.commandBufferCount = 1,
		};

		var tmp: c.VkCommandBuffer = null;
		try VK_CHECK(c.vkAllocateCommandBuffers(device, &allocate_info, &tmp));
		break :blk tmp;
	};

	var swapchain = try Swapchain.init(physical_device, device, surface, family_index, surface_format, null);
	defer swapchain.deinit(device);

	const memory_properties = blk: {
		var memory_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
		c.vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_properties);
		break :blk memory_properties;
	};

	var frame_data = try FrameData.init(device, memory_properties, swapchain);
	defer frame_data.deinit(device);

	defer _ = c.vkDeviceWaitIdle(device);

	while (c.glfwWindowShouldClose(window) == 0)
	{
		c.glfwPollEvents();

		const swapchain_status = try swapchain.update(physical_device, device, surface, family_index, surface_format);

		if (swapchain_status == .not_ready) {
			continue;
		}

		if (swapchain_status == .resized) {
			frame_data.deinit(device);
			frame_data = try FrameData.init(device, memory_properties, swapchain);
		}

		const image_index = blk: {
			var image_index: u32 = 0;
			try VK_CHECK_SWAPCHAIN(c.vkAcquireNextImageKHR(device, swapchain.handle, std.math.maxInt(u64), acquire_semaphore, null, &image_index));
			break :blk image_index;
		};

		try VK_CHECK(c.vkResetCommandPool(device, command_pool, 0));

		const begin_info = std.mem.zeroInit(c.VkCommandBufferBeginInfo, .{
			.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
			.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
		});

		try VK_CHECK(c.vkBeginCommandBuffer(command_buffer, &begin_info));

		c.vkCmdPipelineBarrier2(command_buffer, &std.mem.zeroInit(c.VkDependencyInfo, .{
			.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
			.imageMemoryBarrierCount = 1,
			.pImageMemoryBarriers = &std.mem.zeroInit(c.VkImageMemoryBarrier2, .{
				.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
				.srcStageMask = c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
				.srcAccessMask = 0,
				.dstStageMask = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
				.dstAccessMask = 0,
				.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
				.newLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
				.image = swapchain.images[image_index],
				.subresourceRange = c.VkImageSubresourceRange {
					.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
					.baseMipLevel = 0,
					.levelCount = c.VK_REMAINING_MIP_LEVELS,
					.baseArrayLayer = 0,
					.layerCount = c.VK_REMAINING_ARRAY_LAYERS,
				},
			}),
		}));

		try VK_CHECK(c.vkEndCommandBuffer(command_buffer));

		const submit_dst_stage_mask: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT; // TODO!!!!!!!!!!!

		const submit_info = std.mem.zeroInit(c.VkSubmitInfo, .{
			.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
			.waitSemaphoreCount = 1,
			.pWaitSemaphores = &acquire_semaphore,
			.pWaitDstStageMask = &submit_dst_stage_mask,
			.commandBufferCount = 1,
			.pCommandBuffers = &command_buffer,
			.signalSemaphoreCount = 1,
			.pSignalSemaphores = &release_semaphore,
		});

		try VK_CHECK(c.vkQueueSubmit(queue, 1, &submit_info, null));

		const present_info = std.mem.zeroInit(c.VkPresentInfoKHR, .{
			.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
			.waitSemaphoreCount = 1,
			.pWaitSemaphores = &release_semaphore,
			.swapchainCount = 1,
			.pSwapchains = &swapchain.handle,
			.pImageIndices = &image_index,
		});

		try VK_CHECK_SWAPCHAIN(c.vkQueuePresentKHR(queue, &present_info));

		try VK_CHECK(c.vkDeviceWaitIdle(device)); // TODO!!!!!!!!!!!
	}

	std.debug.print("Hello world\n", .{});
}
