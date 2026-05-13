const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const sdl = SDLBackend.c;
const za = @import("zaudio");
const wf = @import("waveform.zig");
const st = @import("soundtouch.zig");

comptime {
    std.debug.assert(@hasDecl(SDLBackend, "SDLBackend"));
}

const AudioState = struct {
    decoder: *za.Decoder,
    channels: u32,
    sample_rate: u32,
    total_frames: u64,
    total_seconds: f32,
    is_playing: bool,
    // Current playback position in frames (updated by audio callback)
    // TODO: is this needed? We can pull current PCM frame from decoder
    current_frame: std.atomic.Value(u64),
    // SoundTouch processor for time stretching
    soundtouch: st.SoundTouch,
    // playback speed represented as an integer value of percentage.
    // should be converted to a float when passed to soundtouch
    playback_speed: std.atomic.Value(u8),
    // TODO: soundtouch has a version of the pitch change function that takes an int.
    // figure out how to call that function instead and make this an int type.
    playback_pitch_shift_semitones: f32,
    // Input buffer for reading from decoder before processing
    input_buffer: []f32,
    loop_start: ?u64,
    loop_end: ?u64,
    is_looping: bool,
};

const AppState = struct {
    file_path: []const u8,
    audio: *AudioState,
    waveform: *wf.WaveFormDisplayState,
    waveform_rect: ?dvui.Rect.Physical = null,
};

// Speed adjustment constants
const SPEED_STEP: u8 = 5; // 5% speed change per key press
const MIN_SPEED: u8 = 25; // Minimum 25% speed
const MAX_SPEED: u8 = 200; // Maximum 200% speed

const WINDOW_WIDTH: f32 = 1000;
const WINDOW_HEIGHT: f32 = 700;
const WAVEFORM_MIN_HEIGHT: f32 = 260;

var debug_callback_count: u32 = 0;

fn dataCallback(device: *za.Device, output: ?*anyopaque, _: ?*const anyopaque, frames_requested: u32) callconv(.c) void {
    // This callback runs on the audio thread. It must be fast and deterministic:
    // produce exactly `frames_requested` output frames or fill with silence.
    const audio_state: *AudioState = @ptrCast(@alignCast(device.getUserData()));
    const output_ptr: [*]f32 = @ptrCast(@alignCast(output));
    // `frames_requested` is in PCM frames; output buffer length is samples.
    const total_output_samples = frames_requested * audio_state.channels;

    // Debug: print callback info occasionally
    debug_callback_count += 1;
    if (debug_callback_count == 1 or debug_callback_count % 500 == 0) {
        std.debug.print("Callback #{}: frame_count={}, channels={}, sample_rate={}\n", .{ debug_callback_count, frames_requested, audio_state.channels, audio_state.sample_rate });
    }

    if (!audio_state.is_playing) {
        // Paused path: always write silence so the device callback never underruns.
        @memset(output_ptr[0..total_output_samples], 0);
        return;
    }

    var frames_output: u32 = 0;
    var eof_reached = false;

    // Main fill loop:
    // 1) drain already-processed samples from SoundTouch
    // 2) if not enough output yet, decode more input and feed SoundTouch
    // Repeat until this callback's output buffer is full or EOF is reached.
    while (frames_output < frames_requested and !eof_reached) {
        // Prefer draining SoundTouch first to avoid unnecessary decoder reads.
        const available = audio_state.soundtouch.numSamples();
        if (available > 0) {
            // Only take as many frames as this callback still needs.
            const frames_to_receive = @min(available, frames_requested - frames_output);
            // `receiveSamples` writes interleaved floats starting at this offset.
            const output_offset = frames_output * audio_state.channels;
            const output_slice = output_ptr[output_offset..total_output_samples];
            const received = audio_state.soundtouch.receiveSamples(output_slice, frames_to_receive);
            frames_output += received;

            if (frames_output >= frames_requested) break;
        }

        // SoundTouch does not have enough output yet, so decode one callback-sized
        // chunk and push it into SoundTouch's input queue.
        // Note: this is frames, not samples.
        const frames_read = audio_state.decoder.readPCMFrames(audio_state.input_buffer.ptr, frames_requested) catch 0;

        if (frames_read == 0) {
            eof_reached = true;
            // No more decoder input: flush SoundTouch so delayed tail samples can
            // still be emitted in this callback/pass.
            audio_state.soundtouch.flush();
        } else {
            // Hand decoded frames to SoundTouch. The slice is an interleaved sample
            // buffer; `num_frames` tells SoundTouch how many frames to consume.
            audio_state.soundtouch.putSamples(audio_state.input_buffer, @intCast(frames_read));
        }
    }

    // Update position based on OUTPUT frames produced, scaled by tempo
    // This gives smooth playhead movement that matches what the user hears
    // At tempo 2.0, each output frame represents 2 input frames of progress
    // At tempo 0.5, each output frame represents 0.5 input frames of progress
    // TODO: reaxmine this AI generated code.
    // Does playback speed really have to be its own thread safe variable?
    // Can we just use the speed variable in soundtouch?
    const current_speed = getFloatSpeedFromInt(audio_state.playback_speed.load(.acquire));
    const position_advance: u64 = @intFromFloat(@as(f32, @floatFromInt(frames_output)) * current_speed);
    const current = audio_state.current_frame.load(.acquire);
    audio_state.current_frame.store(current + position_advance, .release);

    // If EOF or an underrun leaves part of the device buffer unfilled, zero the
    // remainder so miniaudio always receives valid output.
    if (frames_output < frames_requested) {
        const start_sample = frames_output * audio_state.channels;
        @memset(output_ptr[start_sample..total_output_samples], 0);
    }
}

pub fn main(init: std.process.Init) anyerror!void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <file_path>\n", .{args[0]});
        return;
    }

    const file_path = args[1];

    std.Io.Dir.cwd().access(init.io, file_path, .{}) catch {
        std.debug.print("Failed to load file: {s}\n", .{file_path});
        return;
    };

    try startMainLoop(init, alloc, file_path);
}

fn startMainLoop(init: std.process.Init, alloc: std.mem.Allocator, file_path: []const u8) !void {
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

    // setting anything lower here appears to crash pulse audio
    const buffer_size = 1024 * channels;

    const input_buffer = try alloc.alloc(f32, buffer_size);
    defer alloc.free(input_buffer);

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
        .playback_pitch_shift_semitones = 0,
        .input_buffer = input_buffer,
        .is_looping = false,
        .loop_start = null,
        .loop_end = null,
    };

    var device_config = za.Device.Config.init(.playback);
    device_config.playback.format = .float32;
    device_config.period_size_in_frames = 1024;
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

    var waveform_state = try wf.initWaveFormState(alloc, all_samples);
    defer wf.deInitWaveFormDisplay(alloc, waveform_state);

    try device.start();
    defer device.stop() catch {};

    SDLBackend.enableSDLLogging();
    std.log.info("SDL version: {f}", .{SDLBackend.getSDLVersion()});

    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .allocator = init.gpa,
        .size = .{ .w = WINDOW_WIDTH, .h = WINDOW_HEIGHT },
        .min_size = .{ .w = 640, .h = 420 },
        .vsync = false,
        .title = "Transcriber",
    });
    defer backend.deinit();

    _ = SDLBackend.c.SDL_EnableScreenSaver();

    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = switch (backend.preferredColorScheme() orelse .light) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        },
    });
    defer win.deinit();

    var app_state = AppState{
        .file_path = file_path,
        .audio = &audio_state,
        .waveform = &waveform_state,
    };

    std.debug.print("Playback started\n", .{});

    var interrupted = false;
    while (true) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);

        try backend.addAllEvents(&win);

        _ = sdl.SDL_SetRenderDrawColor(backend.renderer, 18, 18, 20, 255);
        _ = sdl.SDL_RenderClear(backend.renderer);

        const keep_running = appFrame(&app_state);

        const end_micros = try win.end(.{});

        drawWaveform(&backend, &app_state);

        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());
        try backend.renderPresent();

        if (!keep_running) break;

        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}

fn appFrame(app: *AppState) bool {
    const audio = app.audio;
    applyLoopIfNeeded(audio);

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .style = .window,
        .background = true,
        .padding = .{ .x = 12, .y = 12, .w = 12, .h = 12 },
    });
    defer root.deinit();

    renderHeader(app);
    renderTransport(app);
    renderWaveformPanel(app);
    renderFooter(app);

    const keep_running = handleEvents(app);
    if (audio.is_playing) {
        dvui.refresh(null, @src(), null);
    }

    return keep_running;
}

fn renderHeader(app: *AppState) void {
    const audio = app.audio;
    const cursor_frame = audio.current_frame.load(.acquire);
    const current_seconds = secondsFromFrame(audio, cursor_frame);
    const status_text = if (audio.is_playing) "Playing" else "Paused";

    var header = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer header.deinit();

    dvui.labelNoFmt(@src(), app.file_path, .{}, .{ .font = .theme(.title), .expand = .horizontal });
    dvui.label(@src(), "{s}  |  {d:.2} / {d:.2}s  |  {d:.1} FPS", .{ status_text, current_seconds, audio.total_seconds, dvui.FPS() }, .{});
}

fn renderTransport(app: *AppState) void {
    const audio = app.audio;

    var controls = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .y = 10, .h = 6 },
    });
    defer controls.deinit();

    if (dvui.button(@src(), if (audio.is_playing) "Pause" else "Play", .{}, .{})) {
        togglePlayback(audio);
    }

    if (dvui.button(@src(), "-5s", .{}, .{})) {
        seekRelativeSeconds(audio, -5.0);
    }

    if (dvui.button(@src(), "+5s", .{}, .{})) {
        seekRelativeSeconds(audio, 5.0);
    }

    if (dvui.button(@src(), "Set Loop Start", .{}, .{})) {
        audio.loop_start = audio.current_frame.load(.acquire);
    }

    if (dvui.button(@src(), "Set Loop End", .{}, .{})) {
        audio.loop_end = audio.current_frame.load(.acquire);
    }

    if (dvui.button(@src(), "Clear Loop", .{}, .{})) {
        audio.loop_start = null;
        audio.loop_end = null;
    }

    _ = dvui.checkbox(@src(), &audio.is_looping, "Loop", .{});

    var follow = app.waveform.displayMode == .FollowingPlayHead;
    if (dvui.checkbox(@src(), &follow, "Follow", .{})) {
        app.waveform.displayMode = if (follow) .FollowingPlayHead else .FreeFloating;
    }
}

fn renderWaveformPanel(app: *AppState) void {
    var panel = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = WAVEFORM_MIN_HEIGHT },
        .background = true,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .margin = .{ .y = 6, .h = 6 },
    });
    defer panel.deinit();

    app.waveform_rect = panel.data().contentRectScale().r;
}

fn renderFooter(app: *AppState) void {
    const audio = app.audio;
    var settings = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer settings.deinit();

    var speed_percent: f32 = @floatFromInt(audio.playback_speed.load(.acquire));
    const original_speed = speed_percent;
    _ = dvui.sliderEntry(@src(), "Speed: {d:0.0}%", .{
        .value = &speed_percent,
        .min = @as(f32, @floatFromInt(MIN_SPEED)),
        .max = @as(f32, @floatFromInt(MAX_SPEED)),
        .interval = @as(f32, @floatFromInt(SPEED_STEP)),
    }, .{ .expand = .horizontal });
    if (@round(speed_percent) != @round(original_speed)) {
        setSpeed(audio, @intFromFloat(@round(speed_percent)));
    }

    var pitch = audio.playback_pitch_shift_semitones;
    const original_pitch = pitch;
    _ = dvui.sliderEntry(@src(), "Pitch: {d:0.0} semitones", .{
        .value = &pitch,
        .min = -12.0,
        .max = 12.0,
        .interval = 1.0,
    }, .{ .expand = .horizontal });
    if (@round(pitch) != @round(original_pitch)) {
        setPitch(audio, @round(pitch));
    }

    var help = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
    help.addText("Shortcuts: Space play/pause, Left/Right seek, Up/Down speed, Shift+Up/Down pitch, S/E loop markers, L loop, F follow. Mouse wheel scrolls waveform; click waveform to seek.", .{});
    help.deinit();

    if (dvui.button(@src(), "Debug Window", .{}, .{})) {
        dvui.toggleDebugWindow();
    }
}

fn handleEvents(app: *AppState) bool {
    var keep_running = true;
    for (dvui.events()) |*event| {
        if (event.handled) continue;

        switch (event.evt) {
            .key => |key| {
                if (key.action != .down and key.action != .repeat) continue;
                handleKey(app, key);
            },
            .mouse => |mouse| handleMouse(app, mouse),
            .window => |window| {
                if (window.action == .close) keep_running = false;
            },
            .app => |app_event| {
                if (app_event.action == .quit) keep_running = false;
            },
            .text => {},
        }
    }

    return keep_running;
}

fn handleKey(app: *AppState, key: dvui.Event.Key) void {
    const audio = app.audio;
    switch (key.code) {
        .space => togglePlayback(audio),
        .left => seekRelativeSeconds(audio, -5.0),
        .right => seekRelativeSeconds(audio, 5.0),
        .up => {
            if (key.mod.shift()) {
                setPitch(audio, audio.playback_pitch_shift_semitones + 1.0);
            } else {
                adjustSpeed(audio, SPEED_STEP);
            }
        },
        .down => {
            if (key.mod.shift()) {
                setPitch(audio, audio.playback_pitch_shift_semitones - 1.0);
            } else {
                adjustSpeed(audio, -@as(i16, SPEED_STEP));
            }
        },
        .f => app.waveform.displayMode = .FollowingPlayHead,
        .s => audio.loop_start = audio.current_frame.load(.acquire),
        .e => audio.loop_end = audio.current_frame.load(.acquire),
        .l => audio.is_looping = !audio.is_looping,
        else => {},
    }
}

fn handleMouse(app: *AppState, mouse: dvui.Event.Mouse) void {
    const rect = app.waveform_rect orelse return;
    if (!pointInRect(mouse.p, rect)) return;

    switch (mouse.action) {
        .press => {
            if (mouse.button == .left) {
                const x = @max(mouse.p.x - rect.x, 0);
                const frame = wf.getFrameIndex(app.waveform, @intFromFloat(x), app.audio.channels);
                seekToFrame(app.audio, frame);
            }
        },
        .wheel_y => |delta| {
            const direction: wf.ScrollDirection = if (delta < 0) .Down else .Up;
            wf.scrollDisplay(app.waveform, direction, @intFromFloat(@max(rect.w, 1)));
        },
        else => {},
    }
}

fn drawWaveform(backend: *SDLBackend, app: *AppState) void {
    const rect = app.waveform_rect orelse return;
    if (rect.w <= 1 or rect.h <= 1) return;

    const audio = app.audio;
    const cursor_frame = audio.current_frame.load(.acquire);
    const width: u64 = @intFromFloat(@max(rect.w, 1));
    const chunks = wf.getChunksForRendering(app.waveform, cursor_frame, width, audio.channels);
    const center_y = rect.y + rect.h / 2.0;

    setClipRect(backend, rect);
    defer clearClipRect(backend);

    fillRect(backend, rect, 28, 29, 34, 255);
    setDrawColor(backend, 180, 185, 190, 255);

    const WAVEFORM_GAIN: f32 = 4.0;

    for (chunks, 0..) |frame, index| {
        const x = rect.x + @as(f32, @floatFromInt(index));
        const scaled = @min(@abs(frame) * WAVEFORM_GAIN, 1.0) * rect.h;
        drawLine(backend, x, center_y - scaled, x, center_y + scaled);
    }

    const total_chunks: u64 = @intCast(app.waveform.chunks.len);
    drawMarker(backend, rect, app.waveform.*, cursor_frame, audio.channels, total_chunks, 240, 64, 64);

    if (audio.loop_start) |loop_start| {
        drawMarker(backend, rect, app.waveform.*, loop_start, audio.channels, total_chunks, 76, 132, 255);
    }

    if (audio.loop_end) |loop_end| {
        drawMarker(backend, rect, app.waveform.*, loop_end, audio.channels, total_chunks, 76, 132, 255);
    }
}

fn drawMarker(backend: *SDLBackend, rect: dvui.Rect.Physical, waveform: wf.WaveFormDisplayState, frame: u64, channels: u32, total_chunks: u64, r: u8, g: u8, b: u8) void {
    if (total_chunks == 0) return;

    const x_offset = wf.getXCoordFromPCMFrame(waveform, frame, channels, total_chunks);
    if (x_offset >= @as(u64, @intFromFloat(@max(rect.w, 1)))) return;

    const x = rect.x + @as(f32, @floatFromInt(x_offset));
    setDrawColor(backend, r, g, b, 255);
    drawLine(backend, x, rect.y, x, rect.y + rect.h);
}

fn fillRect(backend: *SDLBackend, rect: dvui.Rect.Physical, r: u8, g: u8, b: u8, a: u8) void {
    setDrawColor(backend, r, g, b, a);
    if (SDLBackend.sdl3) {
        const sdl_rect = sdl.SDL_FRect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        _ = sdl.SDL_RenderFillRect(backend.renderer, &sdl_rect);
    } else {
        const sdl_rect = sdl.SDL_Rect{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(rect.w), .h = @intFromFloat(rect.h) };
        _ = sdl.SDL_RenderFillRect(backend.renderer, &sdl_rect);
    }
}

fn setDrawColor(backend: *SDLBackend, r: u8, g: u8, b: u8, a: u8) void {
    _ = sdl.SDL_SetRenderDrawColor(backend.renderer, r, g, b, a);
}

fn drawLine(backend: *SDLBackend, x1: f32, y1: f32, x2: f32, y2: f32) void {
    if (SDLBackend.sdl3) {
        _ = sdl.SDL_RenderLine(backend.renderer, x1, y1, x2, y2);
    } else {
        _ = sdl.SDL_RenderDrawLine(backend.renderer, @intFromFloat(x1), @intFromFloat(y1), @intFromFloat(x2), @intFromFloat(y2));
    }
}

fn setClipRect(backend: *SDLBackend, rect: dvui.Rect.Physical) void {
    const clip = sdl.SDL_Rect{
        .x = @intFromFloat(rect.x),
        .y = @intFromFloat(rect.y),
        .w = @intFromFloat(rect.w),
        .h = @intFromFloat(rect.h),
    };
    if (SDLBackend.sdl3) {
        _ = sdl.SDL_SetRenderClipRect(backend.renderer, &clip);
    } else {
        _ = sdl.SDL_RenderSetClipRect(backend.renderer, &clip);
    }
}

fn clearClipRect(backend: *SDLBackend) void {
    if (SDLBackend.sdl3) {
        _ = sdl.SDL_SetRenderClipRect(backend.renderer, null);
    } else {
        _ = sdl.SDL_RenderSetClipRect(backend.renderer, null);
    }
}

fn pointInRect(point: dvui.Point.Physical, rect: dvui.Rect.Physical) bool {
    return point.x >= rect.x and point.x <= rect.x + rect.w and point.y >= rect.y and point.y <= rect.y + rect.h;
}

fn applyLoopIfNeeded(audio: *AudioState) void {
    if (!audio.is_looping) return;

    const cursor_frame = audio.current_frame.load(.acquire);
    const loop_end = audio.loop_end orelse return;
    if (cursor_frame <= loop_end) return;

    seekToFrame(audio, audio.loop_start orelse 0);
}

fn togglePlayback(audio: *AudioState) void {
    audio.is_playing = !audio.is_playing;
}

fn seekRelativeSeconds(audio: *AudioState, delta: f32) void {
    const current_seconds = secondsFromFrame(audio, audio.current_frame.load(.acquire));
    const seek_time = std.math.clamp(current_seconds + delta, 0.0, audio.total_seconds);
    seekToFrame(audio, frameFromSeconds(audio, seek_time));
}

fn seekToFrame(audio: *AudioState, frame: u64) void {
    const clamped = @min(frame, audio.total_frames);
    audio.decoder.seekToPCMFrames(clamped) catch {};
    audio.current_frame.store(clamped, .release);
    audio.soundtouch.clear();
}

fn adjustSpeed(audio: *AudioState, delta: i16) void {
    const current_speed: i16 = @intCast(audio.playback_speed.load(.acquire));
    const next = std.math.clamp(current_speed + delta, MIN_SPEED, MAX_SPEED);
    setSpeed(audio, @intCast(next));
}

fn setSpeed(audio: *AudioState, speed: u8) void {
    const clamped = std.math.clamp(speed, MIN_SPEED, MAX_SPEED);
    audio.playback_speed.store(clamped, .release);
    audio.soundtouch.setTempo(getFloatSpeedFromInt(clamped));
}

fn setPitch(audio: *AudioState, pitch: f32) void {
    audio.playback_pitch_shift_semitones = std.math.clamp(pitch, -12.0, 12.0);
    audio.soundtouch.setPitchSemiTones(audio.playback_pitch_shift_semitones);
}

fn secondsFromFrame(audio: *AudioState, frame: u64) f32 {
    return @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(audio.sample_rate));
}

fn frameFromSeconds(audio: *AudioState, seconds: f32) u64 {
    return @intFromFloat(seconds * @as(f32, @floatFromInt(audio.sample_rate)));
}

pub fn getFloatSpeedFromInt(speed: u8) f32 {
    const float_speed: f32 = @floatFromInt(speed);
    return float_speed / 100.0;
}
