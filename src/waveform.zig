const za = @import("zaudio");
const std = @import("std");

pub const WaveFormDisplayState = struct {
    chunks: []f32,
};

pub const FRAMES_PER_CHUNK = 1000;

pub fn loadAudioBufferFromDecoder(alloc: std.mem.Allocator, decoder: *za.Decoder, total_frames: u64, channels: u32) ![]f32 {
    const audio_buffer_f32 = try alloc.alloc(f32, total_frames * channels);
    errdefer alloc.free(audio_buffer_f32);

    _ = try decoder.readPCMFrames(@ptrCast(audio_buffer_f32.ptr), total_frames);
    return audio_buffer_f32;
}

pub fn initWaveFormState(alloc: std.mem.Allocator, audio_buffer_f32: []f32) !WaveFormDisplayState {
    const chunk_count = audio_buffer_f32.len / FRAMES_PER_CHUNK;
    var chunks = try alloc.alloc(f32, chunk_count);

    for (0..chunk_count) |i| {
        const window_start = i * FRAMES_PER_CHUNK;
        const window_end = window_start + FRAMES_PER_CHUNK;
        const chunk = audio_buffer_f32[window_start..window_end];

        var acc: f32 = 0;
        for (chunk) |sample| {
            acc += sample;
        }
        const avg_amplitude = acc / @as(f32, @floatFromInt(FRAMES_PER_CHUNK));
        const log_scaled = std.math.sqrt(@abs(avg_amplitude) + 0.0001);
        chunks[i] = log_scaled;
    }

    return WaveFormDisplayState{
        .chunks = chunks,
    };
}

pub fn deInitWaveFormDisplay(alloc: std.mem.Allocator, display: WaveFormDisplayState) void {
    alloc.free(display.chunks);
}

pub fn getPlayheadScreenPosition(playhead_frame: u64, chunks_to_display: u64, channels: u32, total_chunks: u64) u64 {
    // Calculate chunk index in floating point to avoid overflow
    const playhead_frame_f: f32 = @floatFromInt(playhead_frame);
    const channels_f: f32 = @floatFromInt(channels);
    const chunk_size_f: f32 = @floatFromInt(FRAMES_PER_CHUNK);
    const playhead_frame_chunk_f = (playhead_frame_f * channels_f) / chunk_size_f;
    const playhead_frame_chunk: u64 = @intFromFloat(@min(playhead_frame_chunk_f, @as(f32, @floatFromInt(total_chunks - 1))));
    const half_display = chunks_to_display / 2;

    var playhead_x: u64 = undefined;
    if (playhead_frame_chunk <= half_display) {
        playhead_x = playhead_frame_chunk;
    } else if (playhead_frame_chunk >= total_chunks - half_display) {
        const remaining_chunks = total_chunks - playhead_frame_chunk;
        if (remaining_chunks <= half_display) {
            playhead_x = half_display + (half_display - remaining_chunks);
        } else {
            playhead_x = half_display;
        }
    } else {
        playhead_x = half_display;
    }

    return playhead_x;
}

pub fn getChunksFromPlayheadFrame(display: WaveFormDisplayState, playhead_frame: u64, chunks_to_display: u64, channels: u32) []f32 {
    const total_chunks: u64 = @intCast(display.chunks.len);
    // Calculate chunk index in floating point to avoid overflow
    const playhead_frame_f: f32 = @floatFromInt(playhead_frame);
    const channels_f: f32 = @floatFromInt(channels);
    const chunk_size_f: f32 = @floatFromInt(FRAMES_PER_CHUNK);
    const playhead_frame_chunk_f = (playhead_frame_f * channels_f) / chunk_size_f;
    const playhead_frame_chunk: u64 = @intFromFloat(@min(playhead_frame_chunk_f, @as(f32, @floatFromInt(total_chunks - 1))));

    const half_display = chunks_to_display / 2;

    return display.chunks[getStartChunk(playhead_frame_chunk, half_display, total_chunks, chunks_to_display)..getEndChunk(playhead_frame_chunk, half_display, total_chunks, chunks_to_display)];
}

fn getStartChunk(playhead_frame_chunk: u64, half_display: u64, total_chunks: u64, chunks_to_display: u64) u64 {
    if (playhead_frame_chunk <= half_display) {
        return 0;
    } else if (playhead_frame_chunk >= total_chunks - half_display) {
        if (total_chunks > chunks_to_display) {
            return total_chunks - chunks_to_display;
        } else {
            return 0;
        }
    } else {
        return playhead_frame_chunk - half_display;
    }
}

fn getEndChunk(playhead_frame_chunk: u64, half_display: u64, total_chunks: u64, chunks_to_display: u64) u64 {
    const start_chunk = getStartChunk(playhead_frame_chunk, half_display, total_chunks, chunks_to_display);
    var end_chunk = start_chunk + chunks_to_display;
    if (end_chunk > total_chunks) {
        end_chunk = total_chunks;
    }
    return end_chunk;
}
