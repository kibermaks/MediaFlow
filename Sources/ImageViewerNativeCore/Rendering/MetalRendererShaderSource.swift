import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import Metal
import MetalKit
import Photos
import QuartzCore
import CryptoKit
import Darwin
import Security
import simd
import UniformTypeIdentifiers

enum MetalRendererShaderSource {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float2 position;
            float2 texCoord;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        struct FragmentUniforms {
            uint samplingMode;
            uint hasPreviousTexture;
            uint splitCompare;
            float viewportWidth;
            float temporalBlend;
            float denoiseStrength;
            float toneStrength;
            float magicStrength;
            float brightnessBoost;
            float temporalGuard;
        };

        vertex VertexOut vertex_main(uint vid [[vertex_id]],
                                     const device VertexIn *vertices [[buffer(0)]]) {
            VertexOut out;
            out.position = float4(vertices[vid].position, 0.0, 1.0);
            out.texCoord = vertices[vid].texCoord;
            return out;
        }

        half4 read_clamped(texture2d<half> tex, int2 coord) {
            int2 size = int2(tex.get_width(), tex.get_height());
            coord = clamp(coord, int2(0), size - int2(1));
            return tex.read(uint2(coord));
        }

        float cubic_weight(float x) {
            x = abs(x);
            if (x <= 1.0) {
                return ((1.5 * x - 2.5) * x * x) + 1.0;
            }
            if (x < 2.0) {
                return (((-0.5 * x + 2.5) * x - 4.0) * x) + 2.0;
            }
            return 0.0;
        }

        half4 sample_bicubic(texture2d<half> tex, float2 uv) {
            float2 size = float2(tex.get_width(), tex.get_height());
            float2 position = clamp(uv, float2(0.0), float2(1.0)) * size - 0.5;
            float2 baseFloat = floor(position);
            int2 base = int2(baseFloat);
            float2 fraction = position - baseFloat;

            float4 color = float4(0.0);
            float weightSum = 0.0;
            for (int y = -1; y <= 2; y++) {
                float wy = cubic_weight(float(y) - fraction.y);
                for (int x = -1; x <= 2; x++) {
                    float wx = cubic_weight(float(x) - fraction.x);
                    float weight = wx * wy;
                    color += float4(read_clamped(tex, base + int2(x, y))) * weight;
                    weightSum += weight;
                }
            }
            color /= max(weightSum, 0.0001);
            return half4(max(color, float4(0.0)));
        }

        float sinc_weight(float x) {
            x = abs(x);
            if (x < 0.0001) {
                return 1.0;
            }
            float px = x * 3.14159265358979323846;
            return sin(px) / px;
        }

        float lanczos2_weight(float x) {
            x = abs(x);
            if (x >= 2.0) {
                return 0.0;
            }
            return sinc_weight(x) * sinc_weight(x * 0.5);
        }

        half4 sample_lanczos2(texture2d<half> tex, float2 uv) {
            float2 size = float2(tex.get_width(), tex.get_height());
            float2 position = clamp(uv, float2(0.0), float2(1.0)) * size - 0.5;
            float2 baseFloat = floor(position);
            int2 base = int2(baseFloat);
            float2 fraction = position - baseFloat;

            float4 color = float4(0.0);
            float weightSum = 0.0;
            for (int y = -1; y <= 2; y++) {
                float wy = lanczos2_weight(float(y) - fraction.y);
                for (int x = -1; x <= 2; x++) {
                    float wx = lanczos2_weight(float(x) - fraction.x);
                    float weight = wx * wy;
                    color += float4(read_clamped(tex, base + int2(x, y))) * weight;
                    weightSum += weight;
                }
            }
            color /= max(weightSum, 0.0001);
            return half4(max(color, float4(0.0)));
        }

        half4 sample_mode(texture2d<half> tex,
                          float2 uv,
                          sampler linearSampler,
                          sampler nearestSampler,
                          uint samplingMode) {
            if (samplingMode == 1) {
                return tex.sample(nearestSampler, uv);
            }
            if (samplingMode == 2) {
                return sample_bicubic(tex, uv);
            }
            if (samplingMode == 3) {
                return sample_lanczos2(tex, uv);
            }
            return tex.sample(linearSampler, uv);
        }

        float luminance(half3 color) {
            return dot(float3(color), float3(0.2126, 0.7152, 0.0722));
        }

        half4 natural_denoise(texture2d<half> tex,
                              half4 center,
                              float2 uv,
                              sampler linearSampler,
                              float strength) {
            if (strength <= 0.001) {
                return center;
            }

            float2 texel = 1.0 / float2(tex.get_width(), tex.get_height());
            float centerLuma = luminance(center.rgb);
            float4 weighted = float4(0.0);
            float totalWeight = 0.0;

            for (int y = -2; y <= 2; y++) {
                for (int x = -2; x <= 2; x++) {
                    float2 offset = float2(x, y);
                    half4 sampleColor = tex.sample(linearSampler, uv + offset * texel);
                    float sampleLuma = luminance(sampleColor.rgb);
                    float spatialWeight = exp(-dot(offset, offset) * 0.30);
                    float rangeDelta = sampleLuma - centerLuma;
                    float rangeWeight = exp(-(rangeDelta * rangeDelta) * 95.0);
                    float weight = spatialWeight * rangeWeight;
                    weighted += float4(sampleColor) * weight;
                    totalWeight += weight;
                }
            }

            half4 smooth = half4(weighted / max(totalWeight, 0.0001));
            float left = luminance(tex.sample(linearSampler, uv + float2(-1.0, 0.0) * texel).rgb);
            float right = luminance(tex.sample(linearSampler, uv + float2(1.0, 0.0) * texel).rgb);
            float down = luminance(tex.sample(linearSampler, uv + float2(0.0, -1.0) * texel).rgb);
            float up = luminance(tex.sample(linearSampler, uv + float2(0.0, 1.0) * texel).rgb);
            float edge = smoothstep(0.025, 0.18, max(abs(right - left), abs(up - down)));

            half3 detail = center.rgb - smooth.rgb;
            half detailKeep = half(mix(0.20, 0.86, edge));
            half3 restored = smooth.rgb + detail * detailKeep;
            half3 contrasted = max((restored - half3(0.5)) * half3(1.065) + half3(0.5), half3(0.0));
            restored = mix(restored, contrasted, half(0.24 * strength));

            half applyAmount = half(strength * mix(0.88, 0.36, edge));
            half3 rgb = mix(center.rgb, restored, applyAmount);
            return half4(max(rgb, half3(0.0)), center.a);
        }

        half4 guarded_temporal_blend(half4 previous, half4 current, float blend, float guardAmount) {
            float t = clamp(blend, 0.0, 1.0);
            t = t * t * (3.0 - 2.0 * t);

            float3 currentRgb = max(float3(current.rgb), float3(0.0));
            float3 previousRgb = max(float3(previous.rgb), float3(0.0));
            float currentPeak = max(1.0, max(max(currentRgb.r, currentRgb.g), currentRgb.b));
            float previousPeak = max(1.0, max(max(previousRgb.r, previousRgb.g), previousRgb.b));
            float3 currentNorm = currentRgb / currentPeak;
            float3 previousNorm = previousRgb / previousPeak;
            float currentLuma = dot(currentNorm, float3(0.2126, 0.7152, 0.0722));
            float previousLuma = dot(previousNorm, float3(0.2126, 0.7152, 0.0722));
            float lumaDelta = abs(currentLuma - previousLuma);
            float chromaDelta = length((currentNorm - float3(currentLuma)) - (previousNorm - float3(previousLuma)));
            float peakDelta = abs(log2(currentPeak / max(previousPeak, 0.0001)));
            float unstable = smoothstep(0.020, 0.16, lumaDelta + chromaDelta * 0.24 + peakDelta * 0.08);
            float hdrPressure = smoothstep(1.12, 2.8, max(currentPeak, previousPeak));
            float currentBias = max(unstable * 0.86, hdrPressure * clamp(guardAmount, 0.0, 1.0) * 0.68);
            float effectiveT = mix(t, 1.0, currentBias);
            return mix(previous, current, half(effectiveT));
        }

        half4 brightness_boost(half4 color, float amount) {
            amount = clamp(amount, 0.0, 1.0);
            if (amount <= 0.001) {
                return color;
            }

            float3 rgb = max(float3(color.rgb), float3(0.0));
            float peak = max(1.0, max(max(rgb.r, rgb.g), rgb.b));
            rgb /= peak;
            float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float shadowMask = 1.0 - smoothstep(0.06, 0.50, luma);
            float midMask = smoothstep(0.10, 0.52, luma) * (1.0 - smoothstep(0.72, 0.98, luma));
            float highlightMask = smoothstep(0.66, 1.02, luma);

            float exposure = exp2(amount * 0.76);
            rgb *= exposure;
            rgb = pow(max(rgb, float3(0.0)), float3(mix(1.0, 0.68, amount * shadowMask)));
            rgb += amount * 0.075 * midMask;

            float newLuma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float contrast = 1.0 + amount * (0.08 + 0.08 * midMask);
            rgb = max((rgb - float3(newLuma)) * contrast + float3(newLuma), float3(0.0));

            float sat = max(max(rgb.r, rgb.g), rgb.b) - min(min(rgb.r, rgb.g), rgb.b);
            float vibrance = amount * (0.08 + 0.14 * (1.0 - clamp(sat, 0.0, 1.0)));
            float gray = dot(rgb, float3(0.299, 0.587, 0.114));
            rgb = mix(float3(gray), rgb, 1.0 + vibrance);

            float3 rolled = rgb / (float3(1.0) + rgb * (0.12 + 0.22 * amount));
            rgb = mix(rgb, rolled, highlightMask * amount * 0.58);
            return half4(half3(max(rgb * peak, float3(0.0))), color.a);
        }

        half4 tone_recovery(half4 color, float strength) {
            if (strength <= 0.001) {
                return color;
            }

            float3 rgb = float3(color.rgb);
            float peak = max(1.0, max(max(rgb.r, rgb.g), rgb.b));
            rgb /= peak;
            float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float shadowMask = 1.0 - smoothstep(0.06, 0.48, luma);
            float highlightMask = smoothstep(0.56, 0.98, luma);

            float shadowGamma = mix(1.0, 0.58, strength * shadowMask);
            float3 lifted = pow(max(rgb, float3(0.0)), float3(shadowGamma));

            float highlightGamma = mix(1.0, 0.70, strength * highlightMask);
            float3 compressed = 1.0 - pow(max(1.0 - lifted, float3(0.0)), float3(highlightGamma));

            float3 localContrast = max((compressed - 0.5) * (1.0 + 0.18 * strength) + 0.5, float3(0.0));
            float3 recovered = mix(compressed, localContrast, 0.34 * strength);
            return half4(half3(max(recovered * peak, float3(0.0))), color.a);
        }

        half4 magic_rescue(texture2d<half> tex,
                           half4 color,
                           float2 uv,
                           sampler linearSampler,
                           float strength) {
            if (strength <= 0.001) {
                return color;
            }

            float2 texel = 1.0 / float2(tex.get_width(), tex.get_height());
            float3 rgb = float3(color.rgb);
            float peak = max(1.0, max(max(rgb.r, rgb.g), rgb.b));
            rgb /= peak;
            float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float shadowMask = 1.0 - smoothstep(0.08, 0.52, luma);
            float highlightMask = smoothstep(0.58, 0.985, luma);

            float3 n1 = float3(tex.sample(linearSampler, uv + float2(-1.0, 0.0) * texel).rgb) / peak;
            float3 n2 = float3(tex.sample(linearSampler, uv + float2(1.0, 0.0) * texel).rgb) / peak;
            float3 n3 = float3(tex.sample(linearSampler, uv + float2(0.0, -1.0) * texel).rgb) / peak;
            float3 n4 = float3(tex.sample(linearSampler, uv + float2(0.0, 1.0) * texel).rgb) / peak;
            float3 d1 = float3(tex.sample(linearSampler, uv + float2(-2.0, -2.0) * texel).rgb) / peak;
            float3 d2 = float3(tex.sample(linearSampler, uv + float2(2.0, -2.0) * texel).rgb) / peak;
            float3 d3 = float3(tex.sample(linearSampler, uv + float2(-2.0, 2.0) * texel).rgb) / peak;
            float3 d4 = float3(tex.sample(linearSampler, uv + float2(2.0, 2.0) * texel).rgb) / peak;
            float3 localMean = (n1 + n2 + n3 + n4) * 0.18 + (d1 + d2 + d3 + d4) * 0.07;
            float3 highpass = rgb - localMean;

            float edge = smoothstep(0.035, 0.22, length(highpass));
            float detailGain = strength * (0.18 + 0.42 * shadowMask + 0.24 * highlightMask + 0.20 * edge);
            rgb += highpass * detailGain;

            float3 shadowLift = pow(max(rgb, float3(0.0)), float3(mix(1.0, 0.46, strength * shadowMask)));
            rgb = mix(rgb, shadowLift, min(0.92, strength * (0.50 + 0.34 * shadowMask)));

            float3 highlightRolloff = 1.0 - pow(max(1.0 - rgb, float3(0.0)), float3(mix(1.0, 0.54, strength * highlightMask)));
            rgb = mix(rgb, highlightRolloff, min(0.86, strength * highlightMask));

            float rescuedLuma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float3 clarity = max((rgb - rescuedLuma) * (1.0 + 0.42 * strength) + rescuedLuma, float3(0.0));
            rgb = mix(rgb, clarity, 0.42 * strength);

            float sat = max(max(rgb.r, rgb.g), rgb.b) - min(min(rgb.r, rgb.g), rgb.b);
            float vibrance = strength * (0.16 + 0.22 * (1.0 - sat));
            float gray = dot(rgb, float3(0.299, 0.587, 0.114));
            rgb = mix(float3(gray), rgb, 1.0 + vibrance);

            float3 filmic = rgb * (1.0 + 0.44 * strength);
            filmic = filmic / (filmic + float3(0.30 + 0.16 * (1.0 - strength)));
            rgb = mix(rgb, filmic, 0.34 * strength);

            return half4(half3(max(rgb * peak, float3(0.0))), color.a);
        }

        half4 apply_quality_chain(texture2d<half> sourceTex,
                                  half4 color,
                                  float2 uv,
                                  sampler linearSampler,
                                  constant FragmentUniforms &uniforms) {
            color = natural_denoise(sourceTex, color, uv, linearSampler, uniforms.denoiseStrength);
            color = tone_recovery(color, uniforms.toneStrength);
            color = brightness_boost(color, uniforms.brightnessBoost);
            color = magic_rescue(sourceTex, color, uv, linearSampler, uniforms.magicStrength);
            return color;
        }

        fragment half4 fragment_main(VertexOut in [[stage_in]],
                                     texture2d<half> tex [[texture(0)]],
                                     texture2d<half> previousTex [[texture(1)]],
                                     sampler linearSampler [[sampler(0)]],
                                     sampler nearestSampler [[sampler(1)]],
                                     constant FragmentUniforms &uniforms [[buffer(0)]]) {
            bool leftSide = in.position.x < uniforms.viewportWidth * 0.5;
            bool reversedCompare = uniforms.splitCompare == 2;
            bool rawSide = uniforms.splitCompare != 0 && (reversedCompare ? !leftSide : leftSide);
            uint samplingMode = rawSide ? 0 : uniforms.samplingMode;
            half4 color = sample_mode(tex, in.texCoord, linearSampler, nearestSampler, samplingMode);
            if (!rawSide) {
                if (uniforms.hasPreviousTexture != 0) {
                    half4 previous = sample_mode(previousTex, in.texCoord, linearSampler, nearestSampler, uniforms.samplingMode);
                    previous = apply_quality_chain(previousTex, previous, in.texCoord, linearSampler, uniforms);
                    color = apply_quality_chain(tex, color, in.texCoord, linearSampler, uniforms);
                    color = guarded_temporal_blend(previous, color, uniforms.temporalBlend, uniforms.temporalGuard);
                } else {
                    color = apply_quality_chain(tex, color, in.texCoord, linearSampler, uniforms);
                }
            }
            if (uniforms.splitCompare != 0 && abs(in.position.x - uniforms.viewportWidth * 0.5) < 1.0) {
                color = half4(1.0, 1.0, 1.0, 1.0);
            }
            return color;
        }
        """
}
