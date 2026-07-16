#include "gpu_tile_culling.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstring>
#include <stdexcept>

namespace culling {

std::vector<std::uint32_t> evaluateOnGPU(
    const std::vector<GPUCase>& cases,
    const std::string& metallibPath
) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            throw std::runtime_error("Metal device unavailable");
        }

        NSError* error = nil;
        NSString* path = [NSString stringWithUTF8String:metallibPath.c_str()];
        NSURL* libraryURL = [NSURL fileURLWithPath:path];
        id<MTLLibrary> library = [device newLibraryWithURL:libraryURL error:&error];
        if (library == nil) {
            throw std::runtime_error(
                "failed to load metallib: " +
                std::string(error.localizedDescription.UTF8String ?: "unknown error"));
        }
        id<MTLFunction> function = [library newFunctionWithName:@"evaluate_tile_culling"];
        if (function == nil) {
            throw std::runtime_error("evaluate_tile_culling kernel missing");
        }
        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:function error:&error];
        if (pipeline == nil) {
            throw std::runtime_error(
                "failed to create compute pipeline: " +
                std::string(error.localizedDescription.UTF8String ?: "unknown error"));
        }

        const NSUInteger inputBytes = cases.size() * sizeof(GPUCase);
        const NSUInteger outputBytes = cases.size() * sizeof(std::uint32_t);
        id<MTLBuffer> input = [device newBufferWithBytes:cases.data()
                                                   length:inputBytes
                                                  options:MTLResourceStorageModeShared];
        id<MTLBuffer> output = [device newBufferWithLength:outputBytes
                                                  options:MTLResourceStorageModeShared];
        if (input == nil || output == nil) {
            throw std::runtime_error("failed to allocate shared Metal buffers");
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:input offset:0 atIndex:0];
        [encoder setBuffer:output offset:0 atIndex:1];
        std::uint32_t count = static_cast<std::uint32_t>(cases.size());
        [encoder setBytes:&count length:sizeof(count) atIndex:2];
        const NSUInteger threads = std::min<NSUInteger>(
            pipeline.maxTotalThreadsPerThreadgroup, 256);
        [encoder dispatchThreads:MTLSizeMake(cases.size(), 1, 1)
            threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
        [encoder endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
            throw std::runtime_error(
                "Metal command failed: " +
                std::string(commandBuffer.error.localizedDescription.UTF8String ?: "unknown error"));
        }

        std::vector<std::uint32_t> result(cases.size());
        std::memcpy(result.data(), output.contents, outputBytes);
        return result;
    }
}

std::vector<GPURowResult> evaluateRowSpansOnGPU(
    const std::vector<GPURowCase>& cases,
    const std::string& metallibPath
) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            throw std::runtime_error("Metal device unavailable");
        }

        NSError* error = nil;
        NSString* path = [NSString stringWithUTF8String:metallibPath.c_str()];
        NSURL* libraryURL = [NSURL fileURLWithPath:path];
        id<MTLLibrary> library = [device newLibraryWithURL:libraryURL error:&error];
        if (library == nil) {
            throw std::runtime_error(
                "failed to load metallib: " +
                std::string(error.localizedDescription.UTF8String ?: "unknown error"));
        }
        id<MTLFunction> function = [library newFunctionWithName:@"evaluate_tile_row_spans"];
        if (function == nil) {
            throw std::runtime_error("evaluate_tile_row_spans kernel missing");
        }
        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:function error:&error];
        if (pipeline == nil) {
            throw std::runtime_error(
                "failed to create row-span pipeline: " +
                std::string(error.localizedDescription.UTF8String ?: "unknown error"));
        }

        const NSUInteger inputBytes = cases.size() * sizeof(GPURowCase);
        const NSUInteger outputBytes = cases.size() * sizeof(GPURowResult);
        id<MTLBuffer> input = [device newBufferWithBytes:cases.data()
                                                   length:inputBytes
                                                  options:MTLResourceStorageModeShared];
        id<MTLBuffer> output = [device newBufferWithLength:outputBytes
                                                  options:MTLResourceStorageModeShared];
        if (input == nil || output == nil) {
            throw std::runtime_error("failed to allocate row-span Metal buffers");
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:input offset:0 atIndex:0];
        [encoder setBuffer:output offset:0 atIndex:1];
        std::uint32_t count = static_cast<std::uint32_t>(cases.size());
        [encoder setBytes:&count length:sizeof(count) atIndex:2];
        const NSUInteger threads = std::min<NSUInteger>(
            pipeline.maxTotalThreadsPerThreadgroup, 256);
        [encoder dispatchThreads:MTLSizeMake(cases.size(), 1, 1)
            threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
        [encoder endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
            throw std::runtime_error(
                "Metal row-span command failed: " +
                std::string(commandBuffer.error.localizedDescription.UTF8String ?: "unknown error"));
        }

        std::vector<GPURowResult> result(cases.size());
        std::memcpy(result.data(), output.contents, outputBytes);
        return result;
    }
}

} // namespace culling
