const za = @import("zaudio");
const std = @import("std");

const WaveFormDisplayMode = enum(u8) {
    FollowingPlayHead,
    FreeFloating,
};

pub const WaveFormDisplayState = struct {
    chunks: []f32,
    startChunk: u64,
    displayMode: WaveFormDisplayMode,
};

pub const FRAMES_PER_CHUNK = 2000;

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
        .startChunk = 0,
        .displayMode = .FollowingPlayHead,
    };
}

pub fn deInitWaveFormDisplay(alloc: std.mem.Allocator, display: WaveFormDisplayState) void {
    alloc.free(display.chunks);
}

pub fn getXCoordFromPCMFrame(display_state: WaveFormDisplayState, playhead_frame: u64, channels: u32, total_chunks: u64) u64 {
    // Calculate chunk index in floating point to avoid overflow
    const playhead_frame_f: f32 = @floatFromInt(playhead_frame);
    const channels_f: f32 = @floatFromInt(channels);
    const chunk_size_f: f32 = @floatFromInt(FRAMES_PER_CHUNK);
    const playhead_frame_chunk_f = (playhead_frame_f * channels_f) / chunk_size_f;
    const playhead_frame_chunk: u64 = @intFromFloat(@min(playhead_frame_chunk_f, @as(f32, @floatFromInt(total_chunks - 1))));
    return playhead_frame_chunk -| display_state.startChunk;
}

pub fn getChunksForRendering(display: *WaveFormDisplayState, playhead_frame: u64, chunks_to_display: u64, channels: u32) []f32 {
    return switch (display.displayMode) {
        .FollowingPlayHead => getChunksFromPlayheadFrame(display, playhead_frame, chunks_to_display, channels),
        .FreeFloating => getChunksFromStartChunk(display, chunks_to_display),
    };
}

fn getChunksFromStartChunk(display: *WaveFormDisplayState, chunks_to_display: u64) []f32 {
    return display.chunks[display.startChunk..display.startChunk + chunks_to_display];
}

fn getChunksFromPlayheadFrame(display: *WaveFormDisplayState, playhead_frame: u64, chunks_to_display: u64, channels: u32) []f32 {
    const total_chunks: u64 = @intCast(display.chunks.len);
    // Calculate chunk index in floating point to avoid overflow
    const playhead_frame_f: f32 = @floatFromInt(playhead_frame);
    const channels_f: f32 = @floatFromInt(channels);
    const chunk_size_f: f32 = @floatFromInt(FRAMES_PER_CHUNK);
    const playhead_frame_chunk_f = (playhead_frame_f * channels_f) / chunk_size_f;
    const playhead_frame_chunk: u64 = @intFromFloat(@min(playhead_frame_chunk_f, @as(f32, @floatFromInt(total_chunks - 1))));

    const half_display = chunks_to_display / 2;

    const start_chunk = getStartChunk(playhead_frame_chunk, half_display, total_chunks, chunks_to_display);
    display.startChunk = start_chunk;

    return display.chunks[start_chunk..getEndChunk(playhead_frame_chunk, half_display, total_chunks, chunks_to_display)];
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

const SCROLL_INCREMENTS = 10;

pub const ScrollDirection = enum {
    Up,
    Down,
};

pub fn scrollDisplay(displayState: *WaveFormDisplayState, scroll_direction: ScrollDirection, window_x_size: u64) void {
    displayState.displayMode = .FreeFloating;
    var new_start_chunk = displayState.startChunk;
    std.debug.print("new start chunk before scroll: {}", .{new_start_chunk});
    switch (scroll_direction) {
        .Down => {
            new_start_chunk = new_start_chunk -| SCROLL_INCREMENTS;
        },
        .Up => {
            if (new_start_chunk + SCROLL_INCREMENTS > displayState.chunks.len - window_x_size) {
                new_start_chunk = displayState.chunks.len - window_x_size;
            } else {
                new_start_chunk = new_start_chunk + SCROLL_INCREMENTS;
            }
        }
    }

    std.debug.print("new start chunk after scroll: {}", .{new_start_chunk});
    displayState.startChunk = new_start_chunk;
}

pub fn getFrameIndex(displayState: *WaveFormDisplayState, x_pos: u64, channels: u32) u64 {
    const index = x_pos + displayState.startChunk;
    return index * FRAMES_PER_CHUNK / channels;
}
