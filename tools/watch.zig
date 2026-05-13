const std = @import("std");

const poll_interval = std.Io.Duration.fromMilliseconds(250);

const Config = struct {
    zig_exe: []const u8,
    app_path: []const u8,
    app_args: []const []const u8,
};

const Fingerprint = struct {
    count: u64 = 0,
    xor: u64 = 0,
    sum: u64 = 0,

    fn eql(a: Fingerprint, b: Fingerprint) bool {
        return a.count == b.count and a.xor == b.xor and a.sum == b.sum;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(gpa);
    const config = parseArgs(args) catch {
        printUsage(args[0]);
        return error.InvalidArgs;
    };

    var app: ?std.process.Child = null;
    defer stopApp(init.io, &app);

    std.debug.print("watch: watching build.zig, build.zig.zon, and src/**/*.zig\n", .{});

    var last_fingerprint = try sourceFingerprint(gpa, init.io);
    if (try build(init, config)) {
        app = startApp(init, gpa, config) catch |err| blk: {
            std.debug.print("watch: failed to start app: {s}\n", .{@errorName(err)});
            break :blk null;
        };
    } else {
        std.debug.print("watch: initial build failed; waiting for changes\n", .{});
    }

    while (true) {
        try std.Io.sleep(init.io, poll_interval, .awake);

        const next_fingerprint = sourceFingerprint(gpa, init.io) catch |err| {
            std.debug.print("watch: failed to scan sources: {s}\n", .{@errorName(err)});
            continue;
        };

        if (next_fingerprint.eql(last_fingerprint)) continue;
        last_fingerprint = next_fingerprint;

        std.debug.print("\nwatch: change detected; rebuilding\n", .{});
        if (try build(init, config)) {
            stopApp(init.io, &app);
            app = startApp(init, gpa, config) catch |err| blk: {
                std.debug.print("watch: failed to restart app: {s}\n", .{@errorName(err)});
                break :blk null;
            };
        } else {
            if (app != null) {
                std.debug.print("watch: build failed; keeping current app process\n", .{});
            } else {
                std.debug.print("watch: build failed; waiting for changes\n", .{});
            }
        }
    }
}

fn parseArgs(args: []const []const u8) !Config {
    var zig_exe: ?[]const u8 = null;
    var app_path: ?[]const u8 = null;
    var app_args: []const []const u8 = &.{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            app_args = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "--zig")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            zig_exe = args[i];
        } else if (std.mem.eql(u8, arg, "--app")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            app_path = args[i];
        } else {
            return error.InvalidArgs;
        }
    }

    return .{
        .zig_exe = zig_exe orelse return error.InvalidArgs,
        .app_path = app_path orelse return error.InvalidArgs,
        .app_args = app_args,
    };
}

fn printUsage(program_name: []const u8) void {
    std.debug.print("Usage: {s} --zig <zig> --app <app-path> -- [app args...]\n", .{program_name});
}

fn build(init: std.process.Init, config: Config) !bool {
    const argv = [_][]const u8{ config.zig_exe, "build", "--summary", "failures" };
    var child = try std.process.spawn(init.io, .{
        .argv = &argv,
        .environ_map = init.environ_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(init.io);
    return switch (term) {
        .exited => |code| code == 0,
        .signal => |sig| blk: {
            std.debug.print("watch: build terminated by signal {t}\n", .{sig});
            break :blk false;
        },
        .stopped => |sig| blk: {
            std.debug.print("watch: build stopped by signal {t}\n", .{sig});
            break :blk false;
        },
        .unknown => |code| blk: {
            std.debug.print("watch: build terminated unexpectedly ({d})\n", .{code});
            break :blk false;
        },
    };
}

fn startApp(init: std.process.Init, gpa: std.mem.Allocator, config: Config) !std.process.Child {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try argv.append(gpa, config.app_path);
    try argv.appendSlice(gpa, config.app_args);

    std.debug.print("watch: starting app\n", .{});
    return try std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = init.environ_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

fn stopApp(io: std.Io, app: *?std.process.Child) void {
    if (app.*) |*child| {
        std.debug.print("watch: stopping app\n", .{});
        child.kill(io);
        app.* = null;
    }
}

fn sourceFingerprint(gpa: std.mem.Allocator, io: std.Io) !Fingerprint {
    var fingerprint: Fingerprint = .{};
    const cwd = std.Io.Dir.cwd();

    try addFile(&fingerprint, cwd, io, "build.zig");
    try addFile(&fingerprint, cwd, io, "build.zig.zon");
    try addZigFilesInDir(&fingerprint, gpa, cwd, io, "src");

    return fingerprint;
}

fn addZigFilesInDir(fingerprint: *Fingerprint, gpa: std.mem.Allocator, cwd: std.Io.Dir, io: std.Io, dir_path: []const u8) !void {
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const stat = entry.dir.statFile(io, entry.basename, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        addFileStat(fingerprint, dir_path, entry.path, stat);
    }
}

fn addFile(fingerprint: *Fingerprint, dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
    const stat = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    addFileStat(fingerprint, "", path, stat);
}

fn addFileStat(fingerprint: *Fingerprint, dir_path: []const u8, file_path: []const u8, stat: std.Io.Dir.Stat) void {
    var hasher = std.hash.Fnv1a_64.init();
    if (dir_path.len > 0) {
        hasher.update(dir_path);
        hasher.update("/");
    }
    hasher.update(file_path);
    updateHash(&hasher, stat.size);
    updateHash(&hasher, stat.mtime.nanoseconds);

    const hash = hasher.final();
    fingerprint.count +%= 1;
    fingerprint.xor ^= hash;
    fingerprint.sum +%= hash;
}

fn updateHash(hasher: *std.hash.Fnv1a_64, value: anytype) void {
    hasher.update(std.mem.asBytes(&value));
}
