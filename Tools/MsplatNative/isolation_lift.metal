// Modified by the EasySplat project in 2026 from msplat 1.1.3.
#include <metal_stdlib>
using namespace metal;

constant uint kIsolationRecordsPerPixel = 24;
constant float kIsolationContributionFloor = 0.04f;
constant uint kRasterFatalFlagIndex = 3;

struct IsolationContributionRecord {
    uint gaussian_id;
    ushort label;
    ushort reserved;
    float weight;
    float centrality_weight;
};

inline int2 isolation_read_int2(constant int *values, uint index) {
    return int2(values[index * 2], values[index * 2 + 1]);
}

inline float3 isolation_read_float3(constant float *values, uint index) {
    return float3(
        values[index * 3],
        values[index * 3 + 1],
        values[index * 3 + 2]
    );
}

kernel void isolation_lift_stripe_kernel(
    constant uint3 &tile_bounds [[buffer(0)]],
    constant uint3 &image_size [[buffer(1)]],
    constant int *tile_bins [[buffer(2)]],
    constant int *gaussian_ids [[buffer(3)]],
    constant float *packed_xy_opacity [[buffer(4)]],
    constant float *packed_conic [[buffer(5)]],
    constant uchar *mask_labels [[buffer(6)]],
    constant uchar *selected_gaussians [[buffer(7)]],
    constant uint &use_selection [[buffer(8)]],
    constant uint &row_start [[buffer(9)]],
    constant uint &row_count [[buffer(10)]],
    device IsolationContributionRecord *records [[buffer(11)]],
    device uint *record_counts [[buffer(12)]],
    device float *soft_alpha [[buffer(13)]],
    device atomic_uint *isolation_status [[buffer(14)]],
    device atomic_uint *raster_stats [[buffer(15)]],
    uint2 local_pixel [[thread_position_in_grid]]
) {
    if (local_pixel.x >= image_size.x || local_pixel.y >= row_count) return;
    const uint x = local_pixel.x;
    const uint y = row_start + local_pixel.y;
    if (y >= image_size.y) return;
    const uint local_index = local_pixel.y * image_size.x + x;
    record_counts[local_index] = 0;
    soft_alpha[local_index] = 0.0f;
    if (atomic_load_explicit(
            &raster_stats[kRasterFatalFlagIndex],
            memory_order_relaxed
        ) != 0u) {
        return;
    }

    const uint tile_id = (y / 16u) * tile_bounds.x + (x / 16u);
    const int2 range = isolation_read_int2(tile_bins, tile_id);
    const float pixel_x = float(x);
    const float pixel_y = float(y);
    float transmittance = 1.0f;
    uint count = 0;
    const ushort label = ushort(mask_labels[y * image_size.x + x]);
    const float normalized_x =
        (pixel_x + 0.5f - 0.5f * float(image_size.x)) /
        max(0.5f * float(image_size.x), 1.0f);
    const float normalized_y =
        (pixel_y + 0.5f - 0.5f * float(image_size.y)) /
        max(0.5f * float(image_size.y), 1.0f);
    const float centrality = clamp(
        1.0f - length(float2(normalized_x, normalized_y)) / sqrt(2.0f),
        0.0f,
        1.0f
    );

    for (int sorted_index = range.x; sorted_index < range.y; ++sorted_index) {
        const uint gaussian_id = uint(gaussian_ids[sorted_index]);
        if (use_selection != 0u && selected_gaussians[gaussian_id] == 0u) {
            continue;
        }
        const float3 xy_opacity =
            isolation_read_float3(packed_xy_opacity, uint(sorted_index));
        const float3 conic = isolation_read_float3(packed_conic, uint(sorted_index));
        const float2 delta = float2(
            xy_opacity.x - pixel_x,
            xy_opacity.y - pixel_y
        );
        const float sigma = fma(
            0.5f,
            fma(
                conic.x,
                delta.x * delta.x,
                conic.z * delta.y * delta.y
            ),
            conic.y * delta.x * delta.y
        );
        if (sigma < 0.0f || sigma >= 5.55f) continue;
        const float alpha = min(0.999f, xy_opacity.z * exp(-sigma));
        if (alpha < 1.0f / 255.0f) continue;
        const float next_transmittance = transmittance * (1.0f - alpha);
        if (next_transmittance <= 1.0e-4f) break;
        const float weight = alpha * transmittance;
        if (weight >= kIsolationContributionFloor) {
            if (count >= kIsolationRecordsPerPixel) {
                atomic_store_explicit(isolation_status, 1u, memory_order_relaxed);
                break;
            }
            records[local_index * kIsolationRecordsPerPixel + count] = {
                gaussian_id,
                label,
                0,
                weight,
                weight * centrality,
            };
            ++count;
        }
        transmittance = next_transmittance;
    }
    record_counts[local_index] = count;
    soft_alpha[local_index] = 1.0f - transmittance;
}
