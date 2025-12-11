const rl = @import("raylib");
const za = @import("zaudio");
const std = @import("std");
const wf = @import("waveform.zig");
const st = @import("soundtouch.zig");

const AudioState = struct {
    decoder: *za.Decoder,
    channels: u32,
    sample_rate: u32,
    total_frames: u64,
    total_seconds: f32,
    is_playing: bool,
    // Current playback position in frames (updated by audio callback)
    current_frame: std.atomic.Value(u64),
    // SoundTouch processor for time stretching
    soundtouch: st.SoundTouch,
    // playback speed represented as an integer value of percentage.
    // should be converted to a float when passed to soundtouch
    playback_speed: std.atomic.Value(u8),
    // Input buffer for reading from decoder before processing
    input_buffer: []f32,
};

// Speed adjustment constants
const SPEED_STEP: u8 = 5; // 5% speed change per key press
const MIN_SPEED: u8 = 25; // Minimum 25% speed
const MAX_SPEED: u8 = 200; // Maximum 200% speed

// Buffer size for SoundTouch processing
const SOUNDTOUCH_BUFFER_FRAMES: u32 = 4096;

// Window dimensions
const WINDOW_WIDTH = 800;
const WINDOW_HEIGHT = 600;

// UI layout constants
const WAVEFORM_Y_CENTER = 200;
const WAVEFORM_HEIGHT = 150;
const PLAYHEAD_Y_START = 50;
const PLAYHEAD_Y_END = 350;
const FRAME_DISPLAY_SCALE = 100.0;

fn renderFileError(filePath: []const u8) void {
    rl.initWindow(600, 200, "Error");
    defer rl.closeWindow();

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        rl.clearBackground(rl.Color.ray_white);
        rl.drawText("Failed to load file:", 10, 40, 20, rl.Color.dark_gray);
        rl.drawText(rl.textFormat("%s", .{filePath.ptr}), 10, 80, 20, rl.Color.red);
        rl.endDrawing();
    }
}

var debug_callback_count: u32 = 0;

fn dataCallback(device: *za.Device, output: ?*anyopaque, _: ?*const anyopaque, frame_count: u32) callconv(.c) void {
    const audio_state: *AudioState = @ptrCast(@alignCast(device.getUserData()));
    const output_ptr: [*]f32 = @ptrCast(@alignCast(output));
    const total_output_samples = frame_count * audio_state.channels;

    // Debug: print callback info occasionally
    debug_callback_count += 1;
    if (debug_callback_count == 1 or debug_callback_count % 500 == 0) {
        std.debug.print("Callback #{}: frame_count={}, channels={}, sample_rate={}\n", .{ debug_callback_count, frame_count, audio_state.channels, audio_state.sample_rate });
    }

    if (!audio_state.is_playing) {
        // Output silence when paused
        @memset(output_ptr[0..total_output_samples], 0);
        return;
    }

    var frames_output: u32 = 0;
    var eof_reached = false;

    // Keep feeding SoundTouch and retrieving output until we have enough
    while (frames_output < frame_count and !eof_reached) {
        // First check if SoundTouch has output available
        const available = audio_state.soundtouch.numSamples();
        if (available > 0) {
            const frames_to_receive = @min(available, frame_count - frames_output);
            const output_offset = frames_output * audio_state.channels;
            const output_slice = output_ptr[output_offset..total_output_samples];
            const received = audio_state.soundtouch.receiveSamples(output_slice, frames_to_receive);
            frames_output += received;

            if (frames_output >= frame_count) break;
        }

        // Need more input - read from decoder
        // Read enough to account for tempo (at 2x speed we need 2x input)
        // Use the actual input buffer size (which may be scaled for high sample rates)
        const max_buffer_frames: u32 = @intCast(audio_state.input_buffer.len / audio_state.channels);
        const frames_to_read: u32 = @min(max_buffer_frames, frame_count * 2);
        const frames_read = audio_state.decoder.readPCMFrames(audio_state.input_buffer.ptr, frames_to_read) catch 0;

        if (frames_read == 0) {
            eof_reached = true;
            // End of file - flush remaining samples from SoundTouch
            audio_state.soundtouch.flush();
        } else {
            // Feed samples to SoundTouch
            const frames_read_u32: u32 = @intCast(frames_read);
            const input_slice = audio_state.input_buffer[0 .. frames_read_u32 * audio_state.channels];
            audio_state.soundtouch.putSamples(input_slice, frames_read_u32);
        }
    }

    // Update position based on OUTPUT frames produced, scaled by tempo
    // This gives smooth playhead movement that matches what the user hears
    // At tempo 2.0, each output frame represents 2 input frames of progress
    // At tempo 0.5, each output frame represents 0.5 input frames of progress
    const current_speed = getFloatSpeedFromInt(audio_state.playback_speed.load(.acquire));
    const position_advance: u64 = @intFromFloat(@as(f32, @floatFromInt(frames_output)) * current_speed);
    const current = audio_state.current_frame.load(.acquire);
    audio_state.current_frame.store(current + position_advance, .release);

    // Fill any remaining output with silence
    if (frames_output < frame_count) {
        const start_sample = frames_output * audio_state.channels;
        @memset(output_ptr[start_sample..total_output_samples], 0);
    }
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <file_path>\n", .{args[0]});
        return;
    }

    const filePath = args[1];

    // Check if file exists
    std.fs.cwd().access(filePath, .{}) catch {
        renderFileError(filePath);
        return;
    };

    try startMainLoop(alloc, filePath);
}

fn startMainLoop(alloc: std.mem.Allocator, file_path: []const u8) !void {
    // Initialize zaudio
    za.init(alloc);
    defer za.deinit();

    // Create null-terminated path for decoder
    const c_path = try alloc.dupeZ(u8, file_path);
    defer alloc.free(c_path);

    // Create decoder to get audio format info
    const decoder_config = za.Decoder.Config.init(.float32, 0, 0); // Let decoder choose channels/sample_rate
    const decoder = try za.Decoder.createFromFile(c_path, decoder_config);
    defer decoder.destroy();

    // Get audio format info
    var format: za.Format = undefined;
    var channels: u32 = undefined;
    var sample_rate: u32 = undefined;
    try decoder.getDataFormat(&format, &channels, &sample_rate, null);

    const total_frames = try decoder.getLengthInPCMFrames();
    const total_seconds: f32 = @as(f32, @floatFromInt(total_frames)) / @as(f32, @floatFromInt(sample_rate));

    std.debug.print("Audio format: channels={}, sample_rate={}, total_frames={}, total_seconds={d:.2}\n", .{ channels, sample_rate, total_frames, total_seconds });

    // Initialize SoundTouch for time stretching
    var soundtouch = st.SoundTouch.create() orelse {
        std.debug.print("Failed to create SoundTouch instance\n", .{});
        return error.SoundTouchInitFailed;
    };
    defer soundtouch.destroy();

    soundtouch.setChannels(channels);
    soundtouch.setSampleRate(sample_rate);
    soundtouch.setTempo(1.0); // Start at normal speed

    const input_buffer = try alloc.alloc(f32, SOUNDTOUCH_BUFFER_FRAMES * channels);
    defer alloc.free(input_buffer);

    // Create audio state
    var audio_state = AudioState{
        .decoder = decoder,
        .channels = channels,
        .sample_rate = sample_rate,
        .total_frames = total_frames,
        .total_seconds = total_seconds,
        .is_playing = true,
        .current_frame = std.atomic.Value(u64).init(0),
        .soundtouch = soundtouch,
        .playback_speed = std.atomic.Value(u8).init(100),
        .input_buffer = input_buffer,
    };

    // Configure and create device
    var device_config = za.Device.Config.init(.playback);
    device_config.playback.format = .float32;
    device_config.playback.channels = channels;
    device_config.sample_rate = sample_rate;
    device_config.data_callback = dataCallback;
    device_config.user_data = &audio_state;

    const device = try za.Device.create(null, device_config);
    defer device.destroy();

    // Load audio buffer for waveform display using a separate decoder
    const waveform_decoder = try za.Decoder.createFromFile(c_path, za.Decoder.Config.init(.float32, channels, sample_rate));
    defer waveform_decoder.destroy();

    const all_samples = try wf.loadAudioBufferFromDecoder(alloc, waveform_decoder, total_frames, channels);
    defer alloc.free(all_samples);

    const wave_form_state = try wf.initWaveFormState(alloc, all_samples);
    defer wf.deInitWaveFormDisplay(alloc, wave_form_state);

    // Start playback
    try device.start();
    defer device.stop() catch {};

    std.debug.print("Playback started\n", .{});

    // raylib setup
    rl.setConfigFlags(.{ .vsync_hint = true });
    rl.initWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Music Player");
    defer rl.closeWindow();

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.ray_white);
        rl.drawFPS(10, 10);

        const status_text = if (audio_state.is_playing) "Playing..." else "Paused";
        rl.drawText(status_text, 10, 40, 20, rl.Color.dark_gray);

        // Get current playback position
        const cursor_frame = audio_state.current_frame.load(.acquire);
        const current_seconds: f32 = @as(f32, @floatFromInt(cursor_frame)) / @as(f32, @floatFromInt(sample_rate));

        rl.drawText(rl.textFormat("Position: %.2f / %.2f seconds", .{ current_seconds, total_seconds }), 10, 80, 20, rl.Color.dark_gray);

        // Display current playback speed
        const current_speed = audio_state.playback_speed.load(.acquire);
        rl.drawText(rl.textFormat("Speed: %d%%", .{current_speed}), 10, 110, 20, rl.Color.dark_blue);
        rl.drawText("Up/Down: Adjust speed", 10, 140, 16, rl.Color.gray);

        // Draw waveform
        const wave_frames = wf.getChunksFromPlayheadFrame(wave_form_state, cursor_frame, WINDOW_WIDTH, channels);
        for (wave_frames, 0..) |frame, index| {
            const y_offset = @as(i32, @intFromFloat(frame * FRAME_DISPLAY_SCALE));
            rl.drawLine(@intCast(index), WAVEFORM_Y_CENTER - y_offset, @intCast(index), WAVEFORM_Y_CENTER + y_offset, rl.Color.dark_gray);
        }

        // Draw vertical bar at playhead position
        const total_chunks: u64 = @intCast(wave_form_state.chunks.len);
        const playhead_x = wf.getPlayheadScreenPosition(cursor_frame, WINDOW_WIDTH, channels, total_chunks);
        rl.drawLine(@intCast(playhead_x), PLAYHEAD_Y_START, @intCast(playhead_x), PLAYHEAD_Y_END, rl.Color.red);

        // Controls
        if (rl.isKeyPressed(.left)) {
            const seek_time = @max(current_seconds - 5.0, 0.0);
            const seek_frame = @as(u64, @intFromFloat(seek_time * @as(f32, @floatFromInt(sample_rate))));
            audio_state.decoder.seekToPCMFrames(seek_frame) catch {};
            audio_state.current_frame.store(seek_frame, .release);
            // Clear SoundTouch buffers on seek to avoid audio artifacts
            audio_state.soundtouch.clear();
        }

        if (rl.isKeyPressed(.right)) {
            const seek_time = @min(current_seconds + 5.0, total_seconds);
            const seek_frame = @as(u64, @intFromFloat(seek_time * @as(f32, @floatFromInt(sample_rate))));
            audio_state.decoder.seekToPCMFrames(seek_frame) catch {};
            audio_state.current_frame.store(seek_frame, .release);
            // Clear SoundTouch buffers on seek to avoid audio artifacts
            audio_state.soundtouch.clear();
        }

        if (rl.isKeyPressed(.space)) {
            audio_state.is_playing = !audio_state.is_playing;
        }

        // Speed controls - Up arrow increases speed, Down arrow decreases speed
        if (rl.isKeyPressed(.up)) {
            const new_speed = @min(current_speed + SPEED_STEP, MAX_SPEED);
            audio_state.playback_speed.store(new_speed, .release);
            audio_state.soundtouch.setTempo(getFloatSpeedFromInt(new_speed));
            std.debug.print("Speed increased to {d:.0}%\n", .{new_speed});
        }

        if (rl.isKeyPressed(.down)) {
            const new_speed = @max(current_speed - SPEED_STEP, MIN_SPEED);
            audio_state.playback_speed.store(new_speed, .release);
            audio_state.soundtouch.setTempo(getFloatSpeedFromInt(new_speed));
            std.debug.print("Speed decreased to {d:.0}%\n", .{new_speed});
        }
    }
}

pub fn getFloatSpeedFromInt(speed: u8) f32 {
    const float_speed: f32 = @floatFromInt(speed);
    return float_speed / 100.0;
}
