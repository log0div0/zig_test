
const std = @import("std");
const c = @import("c.zig");
const barrier = @import("barrier.zig");
const ShaderCompiler = @import("shader_compiler.zig");

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

fn createGraphicsPipeline(
	device: c.VkDevice,
	vs: c.VkShaderModule,
	fs: c.VkShaderModule,
	pipeline_layout: c.VkPipelineLayout,
	a_color_format: c.VkFormat,
	a_depth_format: c.VkFormat) !c.VkPipeline
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
		.pColorAttachmentFormats = &a_color_format,
		.depthAttachmentFormat = a_depth_format,
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

pub const color_format = c.VK_FORMAT_R16G16B16A16_UNORM;
pub const depth_format = c.VK_FORMAT_D32_SFLOAT;

color_target: Image,
depth_target: Image,
out_width: u32,
out_height: u32,
triangle_vs: c.VkShaderModule,
triangle_fs: c.VkShaderModule,
graphics_pipeline: c.VkPipeline,
raytrace_cs: c.VkShaderModule,
compute_pipeline: c.VkPipeline,

pub fn init(
	device: c.VkDevice,
	out_width: u32,
	out_height: u32,

	// TODO combine to a single structure:
	shader_compiler: *ShaderCompiler,
	pipeline_layout: c.VkPipelineLayout,
	memory_properties: c.VkPhysicalDeviceMemoryProperties,
) !@This() {

	const color_target = try Image.init(device, memory_properties, out_width, out_height, 1, color_format,
		c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
	const depth_target = try Image.init(device, memory_properties, out_width, out_height, 1, depth_format,
		c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);


	const triangle_vs = try shader_compiler.load(device, "triangle.vert.glsl");
	const triangle_fs = try shader_compiler.load(device, "triangle.frag.glsl");

	const graphics_pipeline = try createGraphicsPipeline(device,
		triangle_vs, triangle_fs,
		pipeline_layout,
		color_format, depth_format);

	const raytrace_cs = try shader_compiler.load(device, "raytrace.comp.glsl");

	return .{
		.color_target = color_target,
		.depth_target = depth_target,
		.out_width = out_width,
		.out_height = out_height,
		.triangle_vs = triangle_vs,
		.triangle_fs = triangle_fs,
		.graphics_pipeline = graphics_pipeline,
		.raytrace_cs = raytrace_cs,
		.compute_pipeline = null,
	};
}
pub fn deinit(self: *@This(), device: c.VkDevice) void {
	c.vkDestroyShaderModule(device, self.triangle_vs, null);
	c.vkDestroyShaderModule(device, self.triangle_fs, null);
	c.vkDestroyPipeline(device, self.graphics_pipeline, null);
	c.vkDestroyShaderModule(device, self.raytrace_cs, null);
	self.color_target.deinit(device);
	self.depth_target.deinit(device);
}

pub fn renderFrame(self: *@This(), command_buffer: c.VkCommandBuffer) void {

	barrier.pipeline(command_buffer, c.VK_DEPENDENCY_BY_REGION_BIT, &.{}, &[_]c.VkImageMemoryBarrier2{
		barrier.undefined2ColorAttachmentOutput(self.color_target.image),
	});

	const color_attachment = std.mem.zeroInit(c.VkRenderingAttachmentInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
		.imageView = self.color_target.image_view,
		.imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
		.clearValue = .{
			.color = c.VkClearColorValue{ .float32 = .{0.5,0.5,0.5,0} }
		},
	});

	const depth_attachment = std.mem.zeroInit(c.VkRenderingAttachmentInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
		.imageView = self.depth_target.image_view,
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
				.width = self.out_width,
				.height = self.out_height
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
		.y = @floatFromInt(self.out_height),
		.width = @floatFromInt(self.out_width),
		.height = -@as(f32, @floatFromInt(self.out_height)),
		.minDepth = 0,
		.maxDepth = 1
	};
	const scissor = c.VkRect2D{
		.offset = .{ .x = 0, .y = 0},
		.extent = .{
			.width = self.out_width,
			.height = self.out_height
		}
	};

	c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
	c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

	c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);
	c.vkCmdDraw(command_buffer, 3, 1, 0, 0);

	c.vkCmdEndRendering(command_buffer);
}
