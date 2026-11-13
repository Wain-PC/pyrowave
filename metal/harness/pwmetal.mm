// Command line harness for the Metal port, file-compatible with upstream's Vulkan
// pyrowave-encode / pyrowave-decode tools so the two implementations can be
// cross-checked against each other.
//
//   pwmetal encode <in.y4m> <out.pyrowave> <bytes_per_frame> [cpu|surface]
//   pwmetal decode <in.pyrowave> <out.y4m>
//
// Container (same as encode.cpp / decode.cpp): "PYROWAVE", int32 params[8] =
// { width, height, y4m format, chroma, full range, fps num, fps den, 0 }, then one
// record per packet: uint32 size followed by the packet bytes.

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>

#include "pyrowave_metal.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace
{
// Matches YUV4MPEGFile::Format in yuv4mpeg.hpp.
enum class Format : int32_t
{
	YUV420P = 0,
	YUV444P = 1,
	YUV420P16 = 2,
	YUV444P16 = 3
};

bool is_420(Format f) { return f == Format::YUV420P || f == Format::YUV420P16; }
bool is_16(Format f) { return f == Format::YUV420P16 || f == Format::YUV444P16; }

struct Y4M
{
	FILE *file = nullptr;
	int width = 0, height = 0;
	int fps_num = 60, fps_den = 1;
	bool full_range = false;
	Format format = Format::YUV420P;
	// Sample scale of the file, as in upstream's reader: 10-bit files hold 0..1023.
	float unorm_scale = 255.0f;

	~Y4M()
	{
		if (file)
			fclose(file);
	}

	int plane_width(int p) const { return p == 0 || !is_420(format) ? width : width / 2; }
	int plane_height(int p) const { return p == 0 || !is_420(format) ? height : height / 2; }

	bool open_read(const char *path)
	{
		file = fopen(path, "rb");
		if (!file)
			return false;

		std::string header;
		for (int c; (c = fgetc(file)) != EOF && c != '\n';)
			header.push_back(char(c));
		if (header.compare(0, 9, "YUV4MPEG2") != 0)
			return false;

		auto param = [&](const char *key) -> const char * {
			auto pos = header.find(key);
			return pos == std::string::npos ? nullptr : header.c_str() + pos + strlen(key);
		};

		if (auto *w = param(" W"))
			width = atoi(w);
		if (auto *h = param(" H"))
			height = atoi(h);
		if (auto *f = param(" F"))
			sscanf(f, "%d:%d", &fps_num, &fps_den);
		full_range = header.find("XCOLORRANGE=FULL") != std::string::npos;

		struct
		{
			const char *tag;
			Format format;
			float scale;
		} static const formats[] = {
			{ "C420p10", Format::YUV420P16, 1023.0f }, { "C420p12", Format::YUV420P16, 4095.0f },
			{ "C420p14", Format::YUV420P16, 16383.0f }, { "C420p16", Format::YUV420P16, 65535.0f },
			{ "C444p10", Format::YUV444P16, 1023.0f }, { "C444p12", Format::YUV444P16, 4095.0f },
			{ "C444p14", Format::YUV444P16, 16383.0f }, { "C444p16", Format::YUV444P16, 65535.0f },
			{ "C444", Format::YUV444P, 255.0f }, { "C420", Format::YUV420P, 255.0f },
		};

		for (auto &f : formats)
		{
			if (header.find(f.tag) != std::string::npos)
			{
				format = f.format;
				unorm_scale = f.scale;
				break;
			}
		}

		return width > 0 && height > 0;
	}

	bool open_write(const char *path)
	{
		file = fopen(path, "wb");
		if (!file)
			return false;

		static const char *tags[] = { "C420", "C444", "C420p16", "C444p16" };
		unorm_scale = is_16(format) ? 65535.0f : 255.0f;
		fprintf(file, "YUV4MPEG2 W%d H%d F%d:%d Ip A1:1 XCOLORRANGE=%s %s\n", width, height, fps_num, fps_den,
		        full_range ? "FULL" : "LIMITED", tags[int(format)]);
		return true;
	}

	bool begin_read_frame()
	{
		std::string line;
		for (int c; (c = fgetc(file)) != EOF && c != '\n';)
			line.push_back(char(c));
		return line.compare(0, 5, "FRAME") == 0;
	}

	// Planes are returned as UNORM8 or UNORM16 at full scale, tightly packed.
	bool read_plane(int p, std::vector<uint8_t> &out)
	{
		const size_t count = size_t(plane_width(p)) * plane_height(p);
		out.resize(count * (is_16(format) ? 2 : 1));
		if (fread(out.data(), 1, out.size(), file) != out.size())
			return false;

		if (is_16(format) && unorm_scale != 65535.0f)
		{
			auto *v = reinterpret_cast<uint16_t *>(out.data());
			for (size_t i = 0; i < count; i++)
				v[i] = uint16_t(std::min(1.0f, float(v[i]) / unorm_scale) * 65535.0f + 0.5f);
		}

		return true;
	}

	bool write_frame(const std::vector<uint8_t> planes[3])
	{
		if (fwrite("FRAME\n", 1, 6, file) != 6)
			return false;
		for (int p = 0; p < 3; p++)
			if (fwrite(planes[p].data(), 1, planes[p].size(), file) != planes[p].size())
				return false;
		return true;
	}
};

#define CHECK(expr) \
	do \
	{ \
		pyrowave_result check_result = (expr); \
		if (check_result != PYROWAVE_SUCCESS) \
		{ \
			fprintf(stderr, "%s failed: %s\n", #expr, pyrowave_result_to_string(check_result)); \
			return EXIT_FAILURE; \
		} \
	} while (0)

// One single-plane or biplanar IOSurface-backed pixel buffer, filled from CPU planes.
CVPixelBufferRef make_pixel_buffer(OSType type, int width, int height)
{
	NSDictionary *attrs = @{ (id) kCVPixelBufferIOSurfacePropertiesKey : @{} };
	CVPixelBufferRef buffer = nullptr;
	CVPixelBufferCreate(kCFAllocatorDefault, width, height, type, (__bridge CFDictionaryRef) attrs, &buffer);
	return buffer;
}

void copy_rows(uint8_t *dst, size_t dst_stride, const uint8_t *src, size_t row_bytes, int rows)
{
	for (int y = 0; y < rows; y++)
		memcpy(dst + y * dst_stride, src + y * row_bytes, row_bytes);
}

int run_encode(const char *in_path, const char *out_path, size_t bytes_per_frame, bool use_surfaces)
{
	Y4M input;
	if (!input.open_read(in_path))
	{
		fprintf(stderr, "Failed to open %s.\n", in_path);
		return EXIT_FAILURE;
	}

	const bool chroma_420 = is_420(input.format);
	const bool sixteen = is_16(input.format);

	if (sixteen && !use_surfaces)
	{
		fprintf(stderr, "16-bit input needs the surface path; the CPU path is 8-bit only.\n");
		return EXIT_FAILURE;
	}

	FILE *out = fopen(out_path, "wb");
	if (!out)
		return EXIT_FAILURE;

	const int32_t params[8] = { input.width, input.height, int32_t(input.format), chroma_420 ? 0 : 1,
		                        input.full_range, input.fps_num, input.fps_den, 0 };
	fwrite("PYROWAVE", 1, 8, out);
	fwrite(params, sizeof(params), 1, out);

	pyrowave_device device = nullptr;
	CHECK(pyrowave_create_default_device(&device));

	pyrowave_encoder_create_info info = {};
	info.device = device;
	info.width = input.width;
	info.height = input.height;
	info.chroma = chroma_420 ? PYROWAVE_CHROMA_SUBSAMPLING_420 : PYROWAVE_CHROMA_SUBSAMPLING_444;
	pyrowave_encoder encoder = nullptr;
	CHECK(pyrowave_encoder_create(&info, &encoder));

	const pyrowave_rate_control rate = { bytes_per_frame };
	std::vector<uint8_t> planes[3];
	std::vector<uint8_t> bitstream(bytes_per_frame + 65536);
	unsigned frames = 0;

	while (input.begin_read_frame())
	{
		@autoreleasepool
		{
			for (int p = 0; p < 3; p++)
			{
				if (!input.read_plane(p, planes[p]))
				{
					fprintf(stderr, "Short read in frame %u.\n", frames);
					return EXIT_FAILURE;
				}
			}

			if (!use_surfaces)
			{
				pyrowave_cpu_buffer buffer = {};
				buffer.width = input.width;
				buffer.height = input.height;
				buffer.format = chroma_420 ? PYROWAVE_CPU_BUFFER_FORMAT_YUV420P : PYROWAVE_CPU_BUFFER_FORMAT_YUV444P;
				for (int p = 0; p < 3; p++)
				{
					buffer.data[p] = planes[p].data();
					buffer.row_stride_in_bytes[p] = size_t(input.plane_width(p));
					buffer.plane_size_in_bytes[p] = planes[p].size();
				}
				CHECK(pyrowave_encoder_encode_cpu_synchronous(encoder, &buffer, &rate));
			}
			else
			{
				const size_t texel = sixteen ? 2 : 1;
				CVPixelBufferRef buffers[3] = {};
				pyrowave_gpu_input gpu = {};

				if (chroma_420)
				{
					// One biplanar surface: NV12, or P010 for 16-bit input.
					buffers[0] = make_pixel_buffer(sixteen ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange :
					                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
					                               input.width, input.height);
					CVPixelBufferLockBaseAddress(buffers[0], 0);
					copy_rows(static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(buffers[0], 0)),
					          CVPixelBufferGetBytesPerRowOfPlane(buffers[0], 0), planes[0].data(),
					          size_t(input.width) * texel, input.height);

					auto *uv = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(buffers[0], 1));
					const size_t uv_stride = CVPixelBufferGetBytesPerRowOfPlane(buffers[0], 1);
					const int cw = input.width / 2, ch = input.height / 2;
					for (int y = 0; y < ch; y++)
					{
						for (int x = 0; x < cw; x++)
						{
							memcpy(uv + y * uv_stride + (2 * x + 0) * texel, planes[1].data() + (y * cw + x) * texel, texel);
							memcpy(uv + y * uv_stride + (2 * x + 1) * texel, planes[2].data() + (y * cw + x) * texel, texel);
						}
					}
					CVPixelBufferUnlockBaseAddress(buffers[0], 0);
					gpu.planes[0] = CVPixelBufferGetIOSurface(buffers[0]);
				}
				else
				{
					for (int p = 0; p < 3; p++)
					{
						buffers[p] = make_pixel_buffer(sixteen ? kCVPixelFormatType_OneComponent16 :
						                                         kCVPixelFormatType_OneComponent8,
						                               input.width, input.height);
						CVPixelBufferLockBaseAddress(buffers[p], 0);
						copy_rows(static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(buffers[p])),
						          CVPixelBufferGetBytesPerRow(buffers[p]), planes[p].data(),
						          size_t(input.width) * texel, input.height);
						CVPixelBufferUnlockBaseAddress(buffers[p], 0);
						gpu.planes[p] = CVPixelBufferGetIOSurface(buffers[p]);
					}
				}

				auto result = pyrowave_encoder_encode_gpu_synchronous(encoder, &gpu, &rate);
				for (auto *b : buffers)
					if (b)
						CVPixelBufferRelease(b);
				CHECK(result);
			}

			size_t num_packets = 0;
			CHECK(pyrowave_encoder_compute_num_packets(encoder, bitstream.size(), &num_packets));
			std::vector<pyrowave_packet> packets(num_packets);
			size_t written = 0;
			CHECK(pyrowave_encoder_packetize(encoder, packets.data(), bitstream.size(), &written, bitstream.data(),
			                                 bitstream.size()));

			for (size_t i = 0; i < written; i++)
			{
				const uint32_t size = uint32_t(packets[i].size);
				fwrite(&size, sizeof(size), 1, out);
				fwrite(bitstream.data() + packets[i].offset, 1, packets[i].size, out);
			}

			frames++;
		}
	}

	fclose(out);
	pyrowave_encoder_destroy(encoder);
	pyrowave_device_destroy(device);
	fprintf(stderr, "Encoded %u frames (%s input).\n", frames, use_surfaces ? "IOSurface" : "CPU");
	return EXIT_SUCCESS;
}

int run_decode(const char *in_path, const char *out_path)
{
	FILE *in = fopen(in_path, "rb");
	if (!in)
		return EXIT_FAILURE;

	char magic[9] = {};
	int32_t params[8];
	if (fread(magic, 1, 8, in) != 8 || strcmp(magic, "PYROWAVE") != 0 || fread(params, sizeof(params), 1, in) != 1)
	{
		fprintf(stderr, "Not a PyroWave container.\n");
		return EXIT_FAILURE;
	}

	Y4M output;
	output.width = params[0];
	output.height = params[1];
	output.format = Format(params[2]);
	output.full_range = params[4] != 0;
	output.fps_num = params[5];
	output.fps_den = params[6];
	if (!output.open_write(out_path))
		return EXIT_FAILURE;

	const bool sixteen = is_16(output.format);

	id<MTLDevice> mtl = MTLCreateSystemDefaultDevice();
	id<MTLCommandQueue> queue = [mtl newCommandQueue];

	pyrowave_device_create_info device_info = {};
	device_info.mtl_device = (__bridge void *) mtl;
	pyrowave_device device = nullptr;
	CHECK(pyrowave_device_create(&device_info, &device));

	pyrowave_decoder_create_info info = {};
	info.device = device;
	info.width = output.width;
	info.height = output.height;
	info.chroma = params[3] == 0 ? PYROWAVE_CHROMA_SUBSAMPLING_420 : PYROWAVE_CHROMA_SUBSAMPLING_444;
	pyrowave_decoder decoder = nullptr;
	CHECK(pyrowave_decoder_create(&info, &decoder));

	id<MTLTexture> textures[3];
	pyrowave_gpu_buffers targets = {};
	for (int p = 0; p < 3; p++)
	{
		auto *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:sixteen ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm
		                                                                width:NSUInteger(output.plane_width(p))
		                                                               height:NSUInteger(output.plane_height(p))
		                                                            mipmapped:NO];
		desc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
		desc.storageMode = MTLStorageModeShared;
		textures[p] = [mtl newTextureWithDescriptor:desc];
		targets.planes[p] = (__bridge void *) textures[p];
	}

	std::vector<uint8_t> packet;
	std::vector<uint8_t> planes[3];
	unsigned frames = 0;

	for (;;)
	{
		bool ready = false;
		uint32_t size = 0;
		while (!ready && fread(&size, sizeof(size), 1, in) == 1)
		{
			packet.resize(size);
			if (fread(packet.data(), 1, size, in) != size)
				break;
			CHECK(pyrowave_decoder_push_packet(decoder, packet.data(), packet.size()));
			ready = pyrowave_decoder_decode_is_ready(decoder, false);
		}

		if (!ready)
			break;

		@autoreleasepool
		{
			id<MTLCommandBuffer> cmd = [queue commandBuffer];
			CHECK(pyrowave_decoder_decode_gpu_buffer(decoder, (__bridge void *) cmd, &targets));
			[cmd commit];
			[cmd waitUntilCompleted];

			for (int p = 0; p < 3; p++)
			{
				const NSUInteger w = NSUInteger(output.plane_width(p)), h = NSUInteger(output.plane_height(p));
				const NSUInteger row = w * (sixteen ? 2 : 1);
				planes[p].resize(row * h);
				[textures[p] getBytes:planes[p].data() bytesPerRow:row fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
			}
		}

		if (!output.write_frame(planes))
			return EXIT_FAILURE;
		frames++;
	}

	fclose(in);
	pyrowave_decoder_destroy(decoder);
	pyrowave_device_destroy(device);
	fprintf(stderr, "Decoded %u frames.\n", frames);
	return EXIT_SUCCESS;
}
}

int main(int argc, char **argv)
{
	if (argc >= 5 && strcmp(argv[1], "encode") == 0)
	{
		const bool surfaces = argc >= 6 && strcmp(argv[5], "surface") == 0;
		return run_encode(argv[2], argv[3], strtoull(argv[4], nullptr, 0), surfaces);
	}

	if (argc == 4 && strcmp(argv[1], "decode") == 0)
		return run_decode(argv[2], argv[3]);

	fprintf(stderr, "Usage:\n"
	                "  pwmetal encode <in.y4m> <out.pyrowave> <bytes_per_frame> [cpu|surface]\n"
	                "  pwmetal decode <in.pyrowave> <out.y4m>\n");
	return EXIT_FAILURE;
}
