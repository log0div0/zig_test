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
    std.log.err("Error {}: {s}", .{err, description});
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

	const createInfo = std.mem.zeroInit(c.VkDeviceCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.queueCreateInfoCount = 1,
		.pQueueCreateInfos = &queue_info,
		.ppEnabledExtensionNames = &extensions,
		.enabledExtensionCount = extensions.len,
	});

	var device: c.VkDevice = null;
	try VK_CHECK(c.vkCreateDevice(physical_device, &createInfo, null, &device));
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
	const createInfo = std.mem.zeroInit(c.VkSemaphoreCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
	});

	var semaphore: c.VkSemaphore = null;
	try VK_CHECK(c.vkCreateSemaphore(device, &createInfo, null, &semaphore));
	return semaphore;
}

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

	// const render_pass = createRenderPass(device, swapchain_format, depth_format, /* late= */ false);


	_ = swapchain_format;
	_ = depth_format;
	_ = queue;

	std.debug.print("Hello world\n", .{});
}
