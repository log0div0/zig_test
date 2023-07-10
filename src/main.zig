const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const Swapchain = @import("swapchain.zig");
const ShaderCompiler = @import("shader_compiler.zig");
const App = @import("app.zig");
const barrier = @import("barrier.zig");

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
			return @intCast(i);
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

		std.log.info("GPU{}: {s}", .{i, @as([*c]const u8, @ptrCast(&props.deviceName))});

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

		std.log.info("Selected GPU {s}", .{@as([*c]const u8, @ptrCast(&props.deviceName))});
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
		c.VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME, // Required by VK_KHR_ray_query; allows work to be offloaded onto background threads and parallelized
		c.VK_KHR_RAY_QUERY_EXTENSION_NAME,
		c.VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME,
	};

	var features13 = std.mem.zeroInit(c.VkPhysicalDeviceVulkan13Features, .{
		.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.dynamicRendering = 1,
		.synchronization2 = 1,
	});

	var acceleration_structures_features = std.mem.zeroInit(c.VkPhysicalDeviceAccelerationStructureFeaturesKHR, .{
		.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR,
		.pNext = &features13,
		.accelerationStructure = 1,
	});

	var ray_query_features = std.mem.zeroInit(c.VkPhysicalDeviceRayQueryFeaturesKHR, .{
		.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR,
		.pNext = &acceleration_structures_features,
		.rayQuery = 1,
	});

	const create_info = std.mem.zeroInit(c.VkDeviceCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.pNext = &ray_query_features,
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

pub fn main() !void {
	defer std.debug.assert(general_purpose_allocator.deinit() == .ok);

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

	var app = try App.init(physical_device, device, swapchain.width, swapchain.height);
	defer app.deinit(device);

	defer _ = c.vkDeviceWaitIdle(device);

	while (c.glfwWindowShouldClose(window) == 0)
	{
		c.glfwPollEvents();

		const swapchain_status = try swapchain.update(physical_device, device, surface, family_index, surface_format);

		if (swapchain_status == .not_ready) {
			continue;
		}

		if (swapchain_status == .resized) {
			app.deinitResolutionDependentResources(device);
			try app.initResolutionDependentResources(device, swapchain.width, swapchain.height);
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

		app.renderFrame(command_buffer);

		barrier.pipeline(command_buffer, c.VK_DEPENDENCY_BY_REGION_BIT, &.{}, &[_]c.VkImageMemoryBarrier2{
            barrier.colorAttachmentOutput2TransferSrc(app.color_target.image),
            barrier.undefined2TransferDst(swapchain.images[image_index]),
		});

		const blit_subresource = c.VkImageSubresourceLayers{
			.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
			.mipLevel = 0,
			.baseArrayLayer = 0,
			.layerCount = 1,
		};

		const blit = c.VkImageBlit {
			.srcSubresource = blit_subresource,
			.srcOffsets = [2]c.VkOffset3D{
                .{ .x = 0, .y = 0, .z = 0},
                .{ .x = @intCast(app.out_width), .y = @intCast(app.out_height), .z = 1},
            },
			.dstSubresource = blit_subresource,
			.dstOffsets = [2]c.VkOffset3D{
                .{ .x = 0, .y = 0, .z = 0},
                .{ .x = @intCast(swapchain.width), .y = @intCast(swapchain.height), .z = 1},
            },
		};

		c.vkCmdBlitImage(command_buffer,
			app.color_target.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			swapchain.images[image_index], c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			1, &blit, c.VK_FILTER_NEAREST);

		barrier.pipeline(command_buffer, c.VK_DEPENDENCY_BY_REGION_BIT, &.{}, &[_]c.VkImageMemoryBarrier2{
			barrier.transferDst2PresentSrc(swapchain.images[image_index])
		});

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
