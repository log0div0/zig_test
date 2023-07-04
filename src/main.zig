const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
	@cDefine("GLFW_EXPOSE_NATIVE_WIN32", {});
	@cInclude("GLFW/glfw3.h");
	@cInclude("GLFW/glfw3native.h");

	@cDefine("VK_USE_PLATFORM_WIN32_KHR", {});
	@cInclude("vulkan/vulkan.h");
});

export fn glfwErrorCallback(err: c_int, description: [*c]const u8) void {
    std.log.err("GLFW error #{}: {s}", .{err, description});
}

fn VK_CHECK(result: c.VkResult) !void {
	return if (result == c.VK_SUCCESS) {} else error.VkError;
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

	const create_info = std.mem.zeroInit(c.VkDeviceCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
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

fn getSwapchainFormat(physical_device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !c.VkFormat
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


fn createRenderPass(device: c.VkDevice, color_format: c.VkFormat, depth_format: c.VkFormat) !c.VkRenderPass
{
	const attachments = [_]c.VkAttachmentDescription{
		.{
			.flags = 0,
			.format = color_format,
			.samples = c.VK_SAMPLE_COUNT_1_BIT,
			.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
			.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
			.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
			.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
			.initialLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
			.finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		},
		.{
			.flags = 0,
			.format = depth_format,
			.samples = c.VK_SAMPLE_COUNT_1_BIT,
			.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
			.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
			.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
			.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
			.initialLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
			.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		}
	};

	const color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	const depth_def = c.VkAttachmentReference{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };

	const subpass = std.mem.zeroInit(c.VkSubpassDescription, .{
		.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
		.colorAttachmentCount = 1,
		.pColorAttachments = &color_ref,
		.pDepthStencilAttachment = &depth_def,
	});

	const create_info = std.mem.zeroInit(c.VkRenderPassCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
		.attachmentCount = attachments.len,
		.pAttachments = &attachments,
		.subpassCount = 1,
		.pSubpasses = &subpass,
	});

	var renderPass: c.VkRenderPass = null;
	try VK_CHECK(c.vkCreateRenderPass(device, &create_info, null, &renderPass));
	return renderPass;
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

const VSYNC = true;

const Swapchain = struct {
	const max_image_count = 3;

	swapchain: c.VkSwapchainKHR,
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

	fn init(physical_device: c.VkPhysicalDevice,
		device: c.VkDevice,
		surface: c.VkSurfaceKHR,
		family_index: u32,
		format: c.VkFormat,
		old_swapchain: c.VkSwapchainKHR) !Swapchain
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

		return Swapchain {
			.swapchain = swapchain,
			.images = images,
			.width = width,
			.height = height,
			.image_count = image_count,
		};
	}

	fn deinit(self: *Swapchain, device: c.VkDevice) void
	{
		c.vkDestroySwapchainKHR(device, self.swapchain, null);
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

	const swapchain_format = try getSwapchainFormat(physical_device, surface);
	const depth_format = c.VK_FORMAT_D32_SFLOAT;

	const acquire_semaphore = try createSemaphore(device);
	defer c.vkDestroySemaphore(device, acquire_semaphore, null);
	const release_semaphore = try createSemaphore(device);
	defer c.vkDestroySemaphore(device, release_semaphore, null);

	const queue = blk: {
		var tmp: c.VkQueue = null;
		c.vkGetDeviceQueue(device, family_index, 0, &tmp);
		break :blk tmp;
	};

	const render_pass = try createRenderPass(device, swapchain_format, depth_format);
	defer c.vkDestroyRenderPass(device, render_pass, null);

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

	_ = command_buffer;
	_ = queue;

	var swapchain = try Swapchain.init(physical_device, device, surface, family_index, swapchain_format, null);
	defer swapchain.deinit(device);

	while (c.glfwWindowShouldClose(window) == 0)
	{
		c.glfwPollEvents();
	}

	std.debug.print("Hello world\n", .{});
}
