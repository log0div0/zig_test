const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const Swapchain = @import("swapchain.zig");
const ShaderCompiler = @import("shader_compiler.zig");
const app = @import("app.zig");
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

fn createPipelineLayout(device: c.VkDevice) !c.VkPipelineLayout
{
	const create_info = std.mem.zeroInit(c.VkPipelineLayoutCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
	});

	var result: c.VkPipelineLayout = null;
	try VK_CHECK(c.vkCreatePipelineLayout(device, &create_info, null, &result));
	return result;
}

fn createGraphicsPipeline(
	device: c.VkDevice,
	vs: c.VkShaderModule,
	fs: c.VkShaderModule,
	pipeline_layout: c.VkPipelineLayout,
	color_format: c.VkFormat,
	depth_format: c.VkFormat) !c.VkPipeline
{
	const stages = [_]c.VkPipelineShaderStageCreateInfo{
		.{
			.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			.pNext = null,
			.flags = 0,
			.stage = c.VK_SHADER_STAGE_VERTEX_BIT,
			.module = vs,
			.pName = "main",
			.pSpecializationInfo = null, // TODO!!!!!!!!!!!!!
		},
		.{
			.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			.pNext = null,
			.flags = 0,
			.stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
			.module = fs,
			.pName = "main",
			.pSpecializationInfo = null, // TODO!!!!!!!!!!!!!
		},
	};

	const vertex_input = std.mem.zeroInit(c.VkPipelineVertexInputStateCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	});

	const input_assembly = std.mem.zeroInit(c.VkPipelineInputAssemblyStateCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	});

	const viewport_state = std.mem.zeroInit(c.VkPipelineViewportStateCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1,
		.scissorCount = 1,
	});

	const rasterization_state = std.mem.zeroInit(c.VkPipelineRasterizationStateCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.lineWidth = 1,
		.frontFace = c.VK_FRONT_FACE_CLOCKWISE,
		.cullMode = c.VK_CULL_MODE_BACK_BIT,
	});

	const multisample_state = std.mem.zeroInit(c.VkPipelineMultisampleStateCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
	});

	const depth_stencil_state = std.mem.zeroInit(c.VkPipelineDepthStencilStateCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		.depthTestEnable = 1,
		.depthWriteEnable = 1,
		.depthCompareOp = c.VK_COMPARE_OP_GREATER,
	});

	const color_attachment_state = std.mem.zeroInit(c.VkPipelineColorBlendAttachmentState, .{
		.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
	});

	const color_blend_state = std.mem.zeroInit(c.VkPipelineColorBlendStateCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1,
		.pAttachments = &color_attachment_state,
	});

	const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };

	const dynamic_state = std.mem.zeroInit(c.VkPipelineDynamicStateCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		.dynamicStateCount = dynamic_states.len,
		.pDynamicStates = &dynamic_states,
	});

	const rendering_info = std.mem.zeroInit(c.VkPipelineRenderingCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
		.colorAttachmentCount = 1,
		.pColorAttachmentFormats = &color_format,
		.depthAttachmentFormat = depth_format,
	});

	const create_info = std.mem.zeroInit(c.VkGraphicsPipelineCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
		.pNext = &rendering_info,
		.stageCount = stages.len,
		.pStages = &stages,
		.pVertexInputState = &vertex_input,
		.pInputAssemblyState = &input_assembly,
		.pViewportState = &viewport_state,
		.pRasterizationState = &rasterization_state,
		.pMultisampleState = &multisample_state,
		.pDepthStencilState = &depth_stencil_state,
		.pColorBlendState = &color_blend_state,
		.pDynamicState = &dynamic_state,
		.layout = pipeline_layout,
	});

	const pipeline_cache: c.VkPipelineCache = null; // TODO!!!!!!!!

	var pipeline: c.VkPipeline = null;
	try VK_CHECK(c.vkCreateGraphicsPipelines(device, pipeline_cache, 1, &create_info, null, &pipeline));
	return pipeline;
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

	const memory_properties = blk: {
		var memory_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
		c.vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_properties);
		break :blk memory_properties;
	};

	var rdd = try app.ResolutionDependentData.init(device, memory_properties, swapchain.width, swapchain.height);
	defer rdd.deinit(device);

	var shader_compiler = ShaderCompiler.init();
	defer shader_compiler.deinit();

	const triangle_vs = try shader_compiler.load(device, "triangle.vert.glsl");
	defer c.vkDestroyShaderModule(device, triangle_vs, null);

	const triangle_fs = try shader_compiler.load(device, "triangle.frag.glsl");
	defer c.vkDestroyShaderModule(device, triangle_fs, null);

	const pipeline_layout = try createPipelineLayout(device);
	defer c.vkDestroyPipelineLayout(device, pipeline_layout, null);

	const graphics_pipeline = try createGraphicsPipeline(device,
		triangle_vs, triangle_fs,
		pipeline_layout,
		app.ResolutionDependentData.color_format, app.ResolutionDependentData.depth_format);
	defer c.vkDestroyPipeline(device, graphics_pipeline, null);

	defer _ = c.vkDeviceWaitIdle(device);

	while (c.glfwWindowShouldClose(window) == 0)
	{
		c.glfwPollEvents();

		const swapchain_status = try swapchain.update(physical_device, device, surface, family_index, surface_format);

		if (swapchain_status == .not_ready) {
			continue;
		}

		if (swapchain_status == .resized) {
			rdd.deinit(device);
			rdd = try app.ResolutionDependentData.init(device, memory_properties, swapchain.width, swapchain.height);
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

		app.renderFrame(command_buffer, &rdd, graphics_pipeline);

		barrier.pipeline(command_buffer, c.VK_DEPENDENCY_BY_REGION_BIT, &.{}, &[_]c.VkImageMemoryBarrier2{
            barrier.colorAttachmentOutput2TransferSrc(rdd.color_target.image),
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
                .{ .x = @intCast(rdd.out_width), .y = @intCast(rdd.out_height), .z = 1},
            },
			.dstSubresource = blit_subresource,
			.dstOffsets = [2]c.VkOffset3D{
                .{ .x = 0, .y = 0, .z = 0},
                .{ .x = @intCast(swapchain.width), .y = @intCast(swapchain.height), .z = 1},
            },
		};

		c.vkCmdBlitImage(command_buffer,
			rdd.color_target.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
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
