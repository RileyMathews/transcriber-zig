const rl = @import("raylib");
const za = @import("zaudio");
const std = @import("std");
const wf = @import("waveform.zig");

const SongSpeedEntry = struct {
    speed_modifier: f32,
    audio_file_path: []const u8,
};

const SongData = struct {
    base_speed_audio_path: []const u8,
    speed_entries: []SongSpeedEntry,
};

const MusicTrack = struct {
    sound: *za.Sound,
    speed_modifier: f32,
    channels: u32,
    sample_rate: u32,
    total_frames: u64,
    total_seconds: f32,
};

const PlayerState = struct {
    tracks: std.ArrayList(MusicTrack),
    current_track: ?*MusicTrack,
    base_track_total_seconds: f32,
    all_samples: []f32,
};

const FRAMES_PER_CHUNK = 1000;

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

fn f32Floor(init: f32, floor: f32) f32 {
    return if (init < floor) floor else init;
}

fn f32Ceil(init: f32, ceil: f32) f32 {
    return if (init > ceil) ceil else init;
}

fn initDataForSong(alloc: std.mem.Allocator, song_file_path: []const u8) !SongData {
    const data_dir = std.posix.getenv("XDG_DATA_HOME") orelse blk: {
        const home = std.posix.getenv("HOME") orelse ".local/share";
        break :blk try std.fs.path.join(alloc, &.{ home, ".local", "share" });
    };
    defer if (std.posix.getenv("XDG_DATA_HOME") != null) alloc.free(data_dir);
    defer if (std.posix.getenv("XDG_DATA_HOME") == null) alloc.free(data_dir);

    const app_data_dir = try std.fs.path.join(alloc, &.{ data_dir, "transcriber" });
    defer alloc.free(app_data_dir);

    std.fs.makeDirAbsolute(app_data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const song_base = std.fs.path.basename(song_file_path);
    const song_name = song_base[0..std.fs.path.stem(song_base).len];
    const song_data_dir = try std.fs.path.join(alloc, &.{ app_data_dir, song_name });
    defer alloc.free(song_data_dir);

    std.fs.makeDirAbsolute(song_data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const song_data_path = try std.fs.path.join(alloc, &.{ song_data_dir, "data.json" });
    defer alloc.free(song_data_path);

    // For simplicity, always create new data for now
    // Copy song into <data_dir>/base_audio.<ext>
    const song_filename = try std.fmt.allocPrint(alloc, "audio_base{s}", .{std.fs.path.extension(song_base)});
    defer alloc.free(song_filename);

    const dest_song_path = try std.fs.path.join(alloc, &.{ song_data_dir, song_filename });
    defer alloc.free(dest_song_path);

    if (std.fs.accessAbsolute(dest_song_path, .{})) |_| {
        // File exists
    } else |_| {
        try std.fs.copyFileAbsolute(song_file_path, dest_song_path, .{});
    }

    const speed_entries = try alloc.alloc(SongSpeedEntry, 1);
    speed_entries[0] = .{
        .speed_modifier = 1.0,
        .audio_file_path = try alloc.dupe(u8, dest_song_path),
    };

    const song_data = SongData{
        .speed_entries = speed_entries,
        .base_speed_audio_path = try alloc.dupe(u8, dest_song_path),
    };

    return song_data;
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

    if (!std.fs.path.isAbsolute(filePath)) {
        // Check if file exists
        std.fs.accessAbsolute(filePath, .{}) catch {
            renderFileError(filePath);
            return;
        };
    }

    const song_data = try initDataForSong(alloc, filePath);
    defer {
        alloc.free(song_data.base_speed_audio_path);
        for (song_data.speed_entries) |entry| {
            alloc.free(entry.audio_file_path);
        }
        alloc.free(song_data.speed_entries);
    }

    try startMainLoop(alloc, song_data);
}

fn startMainLoop(alloc: std.mem.Allocator, song_data: SongData) !void {
    // za initialization
    za.init(alloc);
    defer za.deinit();

    const engine = try za.Engine.create(null);
    defer engine.destroy();

    var player_state = PlayerState{
        .tracks = try std.ArrayList(MusicTrack).initCapacity(alloc, 10),
        .current_track = null,
        .base_track_total_seconds = 0,
        .all_samples = undefined,
    };
    defer {
        for (player_state.tracks.items) |track| {
            track.sound.destroy();
        }
        player_state.tracks.deinit(alloc);
        alloc.free(player_state.all_samples);
    }

    var wave_form_state: wf.WaveFormDisplayState = undefined;
    defer wf.deInitWaveFormDisplay(alloc, wave_form_state);

    for (song_data.speed_entries) |entry| {
        const c_path = try alloc.dupeZ(u8, entry.audio_file_path);
        defer alloc.free(c_path);
        const sound = try engine.createSoundFromFile(c_path, .{});
        errdefer sound.destroy();

        var channels: u32 = undefined;
        var sample_rate: u32 = undefined;
        var format: za.Format = undefined;
        try sound.getDataFormat(&format, &channels, &sample_rate, null);

        const total_frames = try sound.getLengthInPcmFrames();
        const total_seconds: f32 = @as(f32, @floatFromInt(total_frames)) / @as(f32, @floatFromInt(sample_rate));

        const track = MusicTrack{
            .sound = sound,
            .speed_modifier = entry.speed_modifier,
            .channels = channels,
            .sample_rate = sample_rate,
            .total_frames = total_frames,
            .total_seconds = total_seconds,
        };
        try player_state.tracks.append(alloc, track);

        if (track.speed_modifier == 1) {
            std.debug.print("Setting current track to base speed {}\n", .{entry.speed_modifier});
            player_state.current_track = &player_state.tracks.items[player_state.tracks.items.len - 1];
            player_state.base_track_total_seconds = track.total_seconds;

            // Load audio buffer for waveform using Decoder
            const decoder_config = za.Decoder.Config.init(.float32, channels, sample_rate);
            const decoder = try za.Decoder.createFromFile(c_path, decoder_config);
            defer decoder.destroy();

            player_state.all_samples = try wf.loadAudioBufferFromDecoder(alloc, decoder, total_frames, channels);
            wave_form_state = try wf.initWaveFormState(alloc, player_state.all_samples);
        }
    }

    std.debug.print("About to start sound...\n", .{});
    try player_state.current_track.?.sound.seekToPcmFrame(0);
    try player_state.current_track.?.sound.start();

    std.debug.print("{}\n", .{player_state.all_samples.len});

    // raylib setup
    rl.setConfigFlags(.{ .vsync_hint = true });
    rl.initWindow(800, 600, "Music Player");
    defer rl.closeWindow();

    const frame_display_scale: f32 = 100;

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.ray_white);
        rl.drawFPS(10, 10);
        rl.drawText("Playing Music...", 10, 40, 20, rl.Color.dark_gray);

        const cursor_frame_raw = try player_state.current_track.?.sound.getCursorInPcmFrames();
        // Handle invalid cursor positions (zaudio sometimes returns garbage after seeking)
        const cursor_frame = if (cursor_frame_raw > player_state.current_track.?.total_frames or cursor_frame_raw >= 0xFFFFFFFFFFFFF000) 0 else cursor_frame_raw;
        const current_seconds_real: f32 = @as(f32, @floatFromInt(cursor_frame)) / @as(f32, @floatFromInt(player_state.current_track.?.sample_rate));
        const current_time_adjusted = current_seconds_real * player_state.current_track.?.speed_modifier;
        rl.drawText(rl.textFormat("Current Position (seconds): %f/%f", .{ current_time_adjusted, player_state.base_track_total_seconds }), 10, 80, 20, rl.Color.dark_gray);
        rl.drawText(rl.textFormat("Speed Modifier: %f", .{player_state.current_track.?.speed_modifier}), 10, 120, 20, rl.Color.dark_gray);

        // Draw waveform
        const wave_frames = wf.getChunksFromPlayheadFrame(wave_form_state, cursor_frame, 800, player_state.current_track.?.channels, player_state.current_track.?.speed_modifier);
        for (wave_frames, 0..) |frame, index| {
            const y_offset = @as(i32, @intFromFloat(frame * frame_display_scale));
            rl.drawLine(@intCast(index), 200 - y_offset, @intCast(index), 200 + y_offset, rl.Color.dark_gray);
        }

        // Draw vertical bar at playhead position
        const total_chunks: u64 = @intCast(wave_form_state.chunks.len);
        const playhead_x = wf.getPlayheadScreenPosition(cursor_frame, 800, player_state.current_track.?.channels, player_state.current_track.?.speed_modifier, total_chunks);
        rl.drawLine(@intCast(playhead_x), 50, @intCast(playhead_x), 350, rl.Color.red);

        // Controls
        if (rl.isKeyPressed(.down)) {
            std.debug.print("Down key pressed - decreasing speed\n", .{});
            const current_speed = player_state.current_track.?.speed_modifier;
            var next_track: ?*MusicTrack = player_state.current_track;
            for (player_state.tracks.items) |*track| {
                if (track.speed_modifier < current_speed) {
                    if (next_track == player_state.current_track or track.speed_modifier > next_track.?.speed_modifier) {
                        next_track = track;
                    }
                }
            }
            if (next_track != player_state.current_track) {
                try player_state.current_track.?.sound.stop();
                // For speed decrease, we need to seek to a later position in the slower track
                const adjusted_frame = @as(u64, @intFromFloat(@as(f32, @floatFromInt(cursor_frame)) * (current_speed / next_track.?.speed_modifier)));
                try next_track.?.sound.seekToPcmFrame(adjusted_frame);
                try next_track.?.sound.start();
                player_state.current_track = next_track;
            }
        }

        if (rl.isKeyPressed(.up)) {
            std.debug.print("Up key pressed - increasing speed\n", .{});
            const current_speed = player_state.current_track.?.speed_modifier;
            var next_track: ?*MusicTrack = player_state.current_track;
            for (player_state.tracks.items) |*track| {
                if (track.speed_modifier > current_speed) {
                    if (next_track == player_state.current_track or track.speed_modifier < next_track.?.speed_modifier) {
                        next_track = track;
                    }
                }
            }
            if (next_track != player_state.current_track) {
                try player_state.current_track.?.sound.stop();
                // For speed increase, we need to seek to an earlier position in the faster track
                const adjusted_frame = @as(u64, @intFromFloat(@as(f32, @floatFromInt(cursor_frame)) * (current_speed / next_track.?.speed_modifier)));
                try next_track.?.sound.seekToPcmFrame(adjusted_frame);
                try next_track.?.sound.start();
                player_state.current_track = next_track;
            }
        }

        if (rl.isKeyPressed(.left)) {
            const seek_time = @max(f32Floor(current_seconds_real - 5 / player_state.current_track.?.speed_modifier, 0), 0);
            const seek_frame = @as(u64, @intFromFloat(seek_time * @as(f32, @floatFromInt(player_state.current_track.?.sample_rate))));
            try player_state.current_track.?.sound.seekToPcmFrame(seek_frame);
        }

        if (rl.isKeyPressed(.right)) {
            const seek_time = @min(f32Ceil(current_seconds_real + 5 / player_state.current_track.?.speed_modifier, player_state.base_track_total_seconds), player_state.base_track_total_seconds);
            const seek_frame = @as(u64, @intFromFloat(seek_time * @as(f32, @floatFromInt(player_state.current_track.?.sample_rate))));
            try player_state.current_track.?.sound.seekToPcmFrame(seek_frame);
        }

        if (rl.isKeyPressed(.space)) {
            const is_playing = player_state.current_track.?.sound.isPlaying();
            if (is_playing) {
                try player_state.current_track.?.sound.stop();
            } else {
                try player_state.current_track.?.sound.start();
            }
        }
    }
}
