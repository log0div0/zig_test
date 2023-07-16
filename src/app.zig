
const std = @import("std");
const c = @import("c.zig");
const barrier = @import("barrier.zig");
const ShaderCompiler = @import("shader_compiler.zig");
const ShortTermMem = @import("short_term_mem.zig");

fn VK_CHECK(result: c.VkResult) !void {
	return if (result == c.VK_SUCCESS) {} else error.VkError;
}








// @@@@@@@@@@@@@@@@@@ MEMORY
fn dumpMemoryTypeFlag(flags: u32, flag_value: u32, comptime flag_name: []const u8) void {
	 std.debug.print(" ", .{});
	 if (flags & flag_value != 0) {
		 std.debug.print(flag_name, .{});
	 } else {
		 std.debug.print(" " ** flag_name.len, .{});
	 }
}

fn dumpMemoryTypes(memory_properties: c.VkPhysicalDeviceMemoryProperties) void
{
	for (0..memory_properties.memoryHeapCount) |heap|{
		const size = memory_properties.memoryHeaps[heap].size;
		std.debug.print("Heap#{} size = {:.2}\n", .{heap, std.fmt.fmtIntSizeBin(size)});
		for (0..memory_properties.memoryTypeCount) |i| {
			if (memory_properties.memoryTypes[i].heapIndex != heap) {
				continue;
			}
			const flags = memory_properties.memoryTypes[i].propertyFlags;

			std.debug.print("  Type#{}:", .{i});

			dumpMemoryTypeFlag(flags, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, "device_local");
			dumpMemoryTypeFlag(flags, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, "host_visible");
			dumpMemoryTypeFlag(flags, c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, "host_coherent");
			dumpMemoryTypeFlag(flags, c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT, "host_cached");
			dumpMemoryTypeFlag(flags, c.VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT, "lazily_allocated");
			dumpMemoryTypeFlag(flags, c.VK_MEMORY_PROPERTY_PROTECTED_BIT, "protected");
			dumpMemoryTypeFlag(flags, c.VK_MEMORY_PROPERTY_DEVICE_COHERENT_BIT_AMD, "device_coherent_bit");
			dumpMemoryTypeFlag(flags, c.VK_MEMORY_PROPERTY_DEVICE_UNCACHED_BIT_AMD, "device_uncached_bit");
			dumpMemoryTypeFlag(flags, c.VK_MEMORY_PROPERTY_RDMA_CAPABLE_BIT_NV, "rdma_capable_bi");

			std.debug.print("\n", .{});
		}
	}
}

fn selectMemoryType(available_memory: c.VkPhysicalDeviceMemoryProperties,
	allowed_memory_types: u32,
	required_memory_flags: c.VkMemoryPropertyFlags,
	banned_memory_flags: c.VkMemoryPropertyFlags) !u32
{
	var remaining_bits = allowed_memory_types;
	while (remaining_bits != 0) {
		const index = @ctz(remaining_bits);
		if (available_memory.memoryTypes[index].propertyFlags & required_memory_flags == required_memory_flags and
			available_memory.memoryTypes[index].propertyFlags & banned_memory_flags == 0)
		{
			return index;
		}
		remaining_bits ^= @as(u32, 1) << @intCast(index);
	}
	return error.NoCompatibleMemoryTypeFound;
}

fn allocAndBindMemoryForAllImages(device: c.VkDevice,
	images: []const c.VkImage,
	available_memory: c.VkPhysicalDeviceMemoryProperties,
	required_memory_flags: c.VkMemoryPropertyFlags,
	banned_memory_flags: c.VkMemoryPropertyFlags,) !c.VkDeviceMemory
{
	var total_size: c.VkDeviceSize = 0;
	var memory_type_mask: u32 = ~@as(u32, 0);

	for (images) |image| {
		var requirements: c.VkMemoryRequirements = undefined;
		c.vkGetImageMemoryRequirements(device, image, &requirements);

		total_size = std.mem.alignForward(c.VkDeviceSize, total_size, requirements.alignment);
		total_size += requirements.size;

		memory_type_mask &= requirements.memoryTypeBits;
	}

	if (memory_type_mask == 0) {
		return error.CanntPutAllImagesInASingleChunkOfMemory;
	}

	const memory_type_index = try selectMemoryType(available_memory, memory_type_mask, required_memory_flags, banned_memory_flags);

	const allocate_info = c.VkMemoryAllocateInfo{
		.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.pNext = null,
		.allocationSize = total_size,
		.memoryTypeIndex = memory_type_index,
	};

	var memory: c.VkDeviceMemory = undefined;
	try VK_CHECK(c.vkAllocateMemory(device, &allocate_info, null, &memory));
	errdefer c.vkFreeMemory(device, memory, null);

	var offset: c.VkDeviceSize = 0;
	for (images) |image| {
		var requirements: c.VkMemoryRequirements = undefined;
		c.vkGetImageMemoryRequirements(device, image, &requirements);

		offset = std.mem.alignForward(c.VkDeviceSize, offset, requirements.alignment);

		try VK_CHECK(c.vkBindImageMemory(device, image, memory, offset));

		offset += requirements.size;
	}

	return memory;
}
// @@@@@@@@@@@@@@@@@@ MEMORY










// <<<<<<<<<<<<<<<<< RESOURCES
pub fn createImage2D(
	device: c.VkDevice,
	width: u32,
	height: u32,
	format: c.VkFormat,
	usage: c.VkImageUsageFlags) !c.VkImage
{
	const image_info = std.mem.zeroInit(c.VkImageCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
		.imageType = c.VK_IMAGE_TYPE_2D,
		.format = format,
		.extent = .{ width, height, 1 },
		.mipLevels = 1,
		.arrayLayers = 1,
		.samples = c.VK_SAMPLE_COUNT_1_BIT,
		.tiling = c.VK_IMAGE_TILING_OPTIMAL,
		.usage = usage,
		.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
	});

	var image: c.VkImage = null;
	try VK_CHECK(c.vkCreateImage(device, &image_info, null, &image));
	return image;
}

pub fn createImageView2D(
	device: c.VkDevice,
	image: c.VkImage,
	format: c.VkFormat,
	aspect_mask: c.VkImageAspectFlags,
	) !c.VkImageView
{
	const image_view_info = std.mem.zeroInit(c.VkImageViewCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
		.image = image,
		.viewType = c.VK_IMAGE_VIEW_TYPE_2D,
		.format = format,
		.subresourceRange = .{
			.aspectMask = aspect_mask,
			.baseMipLevel = 0,
			.levelCount = c.VK_REMAINING_MIP_LEVELS,
			.baseArrayLayer = 0,
			.layerCount = c.VK_REMAINING_ARRAY_LAYERS,
		},
	});

	var image_view: c.VkImageView = undefined;
	try VK_CHECK(c.vkCreateImageView(device, &image_view_info, 0, &image_view));
	return image_view;
}
// <<<<<<<<<<<<<<<<< RESOURCES











// $$$$$$$$$$$$$$$$$ PIPELINE LAYOUT
fn createDescriptorSetLayout(device: c.VkDevice) !c.VkDescriptorSetLayout
{
	const set_bindings = [_]c.VkDescriptorSetLayoutBinding{
		.{
			.binding = 0,
			.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
			.descriptorCount = 1,
			.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
			.pImmutableSamplers = null,
		}
	};

	const set_create_info = std.mem.zeroInit(c.VkDescriptorSetLayoutCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.flags = 0,
		.bindingCount = set_bindings.len,
		.pBindings = &set_bindings,
	});

	var set_layout: c.VkDescriptorSetLayout = null;
	try VK_CHECK(c.vkCreateDescriptorSetLayout(device, &set_create_info, null, &set_layout));
	return set_layout;
}

fn createPipelineLayout(device: c.VkDevice, set_layouts: []const c.VkDescriptorSetLayout) !c.VkPipelineLayout
{
	const create_info = std.mem.zeroInit(c.VkPipelineLayoutCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = @as(u32, @intCast(set_layouts.len)),
		.pSetLayouts = set_layouts.ptr,
	});

	var result: c.VkPipelineLayout = null;
	try VK_CHECK(c.vkCreatePipelineLayout(device, &create_info, null, &result));
	return result;
}
// $$$$$$$$$$$$$$$$$ PIPELINE LAYOUT











// %%%%%%%%%%%%%%%%% DESCRIPTORS
fn createDescriptorPool(device: c.VkDevice) !c.VkDescriptorPool
{
	const pool_sizes = [_]c.VkDescriptorPoolSize{
		.{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 128 },
	};

	const pool_info = c.VkDescriptorPoolCreateInfo{
		.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
		.pNext = null,
		.flags = 0,
		.maxSets = 1,
		.poolSizeCount = pool_sizes.len,
		.pPoolSizes = &pool_sizes,
	};

	var descriptor_pool: c.VkDescriptorPool = null;
	try VK_CHECK(c.vkCreateDescriptorPool(device, &pool_info, null, &descriptor_pool));
	return descriptor_pool;
}

fn createDescriptorSet(device: c.VkDevice,
	descriptor_pool: c.VkDescriptorPool,
	descriptor_set_layout: c.VkDescriptorSetLayout) !c.VkDescriptorSet
{
	const allocate_info = c.VkDescriptorSetAllocateInfo{
		.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.pNext = null,
		.descriptorPool = descriptor_pool,
		.descriptorSetCount = 1,
		.pSetLayouts = &descriptor_set_layout,
	};

	var set: c.VkDescriptorSet = null;
	try VK_CHECK(c.vkAllocateDescriptorSets(device, &allocate_info, &set));
	return set;
}
// %%%%%%%%%%%%%%%%% DESCRIPTORS









// ################# PIPELINES
fn createComputePipeline(device: c.VkDevice, shader: c.VkShaderModule, pipeline_layout: c.VkPipelineLayout) !c.VkPipeline
{
	const stage = std.mem.zeroInit(c.VkPipelineShaderStageCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
		.stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
		.module = shader,
		.pName = "main",
		.pSpecializationInfo = null, // TODO!!!!!!!
	});

	const create_info = std.mem.zeroInit(c.VkComputePipelineCreateInfo, .{
		.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = stage,
		.layout = pipeline_layout,
	});

	const pipeline_cache: c.VkPipelineCache = null; // TODO!!!!!!!!

	var pipeline: c.VkPipeline = null;
	try VK_CHECK(c.vkCreateComputePipelines(device, pipeline_cache, 1, &create_info, null, &pipeline));
	return pipeline;
}
// ################# PIPELINES







// ^^^^^^^^^^^^^^^^^ MODELS
fn loadModel() !void
{
	const path = "models\\Duck.glb";

	const file = try std.fs.cwd().openFile(path, .{});
	defer file.close();
}
// ^^^^^^^^^^^^^^^^^ MODELS









pub const color_format: c.VkFormat = c.VK_FORMAT_R16G16B16A16_UNORM;

const local_size_x = 16;
const local_size_y = 8;

memory_properties: c.VkPhysicalDeviceMemoryProperties,

out_width: u32,
out_height: u32,

color_target: c.VkImage,
color_target_view: c.VkImageView,

resolution_dependent_memory: c.VkDeviceMemory,

shader_compiler: ShaderCompiler,

descriptor_set_layout: c.VkDescriptorSetLayout,
pipeline_layout: c.VkPipelineLayout,

descriptor_pool: c.VkDescriptorPool,
descriptor_set: c.VkDescriptorSet,

raytrace_cs: c.VkShaderModule,
raytrace_pipeline: c.VkPipeline,

pub fn init(physical_device: c.VkPhysicalDevice, device: c.VkDevice,
	out_width: u32, out_height: u32,
	short_term_mem: *ShortTermMem) !@This()
{
	var result: @This() = undefined;

	c.vkGetPhysicalDeviceMemoryProperties(physical_device, &result.memory_properties);
	dumpMemoryTypes(result.memory_properties);

	result.shader_compiler = ShaderCompiler.init();
	errdefer result.shader_compiler.deinit();

	result.descriptor_set_layout = try createDescriptorSetLayout(device);
	errdefer c.vkDestroyDescriptorSetLayout(device, result.descriptor_set_layout, null);
	result.pipeline_layout = try createPipelineLayout(device, &.{result.descriptor_set_layout});
	errdefer c.vkDestroyPipelineLayout(device, result.pipeline_layout, null);

	result.descriptor_pool = try createDescriptorPool(device);
	errdefer c.vkDestroyDescriptorPool(device, result.descriptor_pool, null);
	result.descriptor_set = try createDescriptorSet(device, result.descriptor_pool, result.descriptor_set_layout);

	try result.initPipelines(device, short_term_mem);
	errdefer result.deinitPipelines(device);

	try result.initResolutionDependentResources(device, out_width, out_height);
	errdefer result.deinitResolutionDependentResources(device);

	try loadModel();

	return result;
}

pub fn deinit(self: *@This(), device: c.VkDevice) void {
	self.deinitPipelines(device);

	c.vkDestroyDescriptorPool(device, self.descriptor_pool, null);

	c.vkDestroyPipelineLayout(device, self.pipeline_layout, null);
	c.vkDestroyDescriptorSetLayout(device, self.descriptor_set_layout, null);

	self.shader_compiler.deinit();

	self.deinitResolutionDependentResources(device);
}

pub fn initResolutionDependentResources(self: *@This(), device: c.VkDevice, out_width: u32, out_height: u32) !void {

	self.out_width = out_width;
	self.out_height = out_height;

	self.color_target = try createImage2D(device, out_width, out_height, color_format,
		c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | c.VK_IMAGE_USAGE_STORAGE_BIT);
	errdefer c.vkDestroyImage(device, self.color_target, null);

	self.resolution_dependent_memory = try allocAndBindMemoryForAllImages(device, &.{self.color_target}, self.memory_properties,
		c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
	errdefer c.vkFreeMemory(device, self.resolution_dependent_memory, null);

	self.color_target_view = try createImageView2D(device, self.color_target, color_format, c.VK_IMAGE_ASPECT_COLOR_BIT);
	errdefer c.vkDestroyImageView(device, self.color_target_view, null);

	const write = std.mem.zeroInit(c.VkWriteDescriptorSet, .{
		.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
		.dstSet = self.descriptor_set,
		.dstBinding = 0,
		.dstArrayElement = 0,
		.descriptorCount = 1,
		.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
		.pImageInfo = &c.VkDescriptorImageInfo{
			.sampler = null,
			.imageView = self.color_target_view,
			.imageLayout = c.VK_IMAGE_LAYOUT_GENERAL,
		},
	});

	c.vkUpdateDescriptorSets(device, 1, &write, 0, null);
}

pub fn deinitResolutionDependentResources(self: *@This(), device: c.VkDevice) void {
	c.vkFreeMemory(device, self.resolution_dependent_memory, null);
	c.vkDestroyImageView(device, self.color_target_view, null);
	c.vkDestroyImage(device, self.color_target, null);
}

pub fn initPipelines(self: *@This(), device: c.VkDevice, short_term_mem: *ShortTermMem) !void {
	self.raytrace_cs = try self.shader_compiler.load(device, "raytrace.comp.glsl", &.{
		.{ .name = "LOCAL_SIZE_X", .value = std.fmt.comptimePrint("{}", .{local_size_x}) },
		.{ .name = "LOCAL_SIZE_Y", .value = std.fmt.comptimePrint("{}", .{local_size_y}) },
	}, short_term_mem);
	errdefer c.vkDestroyShaderModule(device, self.raytrace_cs, null);
	self.raytrace_pipeline = try createComputePipeline(device, self.raytrace_cs, self.pipeline_layout);
	errdefer c.vkDestroyPipeline(device, self.raytrace_pipeline, null);
}

pub fn deinitPipelines(self: *@This(), device: c.VkDevice) void {
	c.vkDestroyShaderModule(device, self.raytrace_cs, null);
	c.vkDestroyPipeline(device, self.raytrace_pipeline, null);
}

pub fn renderFrame(self: *@This(), command_buffer: c.VkCommandBuffer) void {

	c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE,
		self.pipeline_layout, 0, 1, &self.descriptor_set, 0, null);

	barrier.pipeline(command_buffer, c.VK_DEPENDENCY_BY_REGION_BIT, &.{}, &[_]c.VkImageMemoryBarrier2{
		barrier.undefined2ComputeWrite(self.color_target),
	});

	c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.raytrace_pipeline);
	const global_size_x: u32 = (self.out_width + local_size_x - 1) / local_size_x;
	const global_size_y: u32 = (self.out_height + local_size_y - 1) / local_size_y;
	c.vkCmdDispatch(command_buffer, global_size_x, global_size_y, 1);

	barrier.pipeline(command_buffer, c.VK_DEPENDENCY_BY_REGION_BIT, &.{}, &[_]c.VkImageMemoryBarrier2{
		barrier.computeWrite2TransferSrc(self.color_target),
	});
}
