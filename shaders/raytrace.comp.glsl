#version 460

layout(local_size_x = LOCAL_SIZE_X, local_size_y = LOCAL_SIZE_Y, local_size_z = 1) in;

layout(set=0, binding=0) uniform writeonly image2D color_output;

void main()
{
	const uvec2 resolution = imageSize(color_output).xy;
	const uvec2 pixel = gl_GlobalInvocationID.xy;

	if ((pixel.x >= resolution.x) || (pixel.y >= resolution.y))
	{
		return;
	}

	vec2 uv = vec2(pixel) / resolution;

	imageStore(color_output, ivec2(pixel), vec4(uv, 0, 0));
}
