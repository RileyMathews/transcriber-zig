/// Zig bindings for SoundTouch audio processing library
/// SoundTouch allows changing tempo while preserving pitch
const std = @import("std");

// Direct extern declarations for SoundTouch DLL C API
// These match the functions exported by SoundTouchDLL.cpp
const HANDLE = ?*anyopaque;

extern fn soundtouch_createInstance() HANDLE;
extern fn soundtouch_destroyInstance(h: HANDLE) void;
extern fn soundtouch_getVersionString() [*:0]const u8;
extern fn soundtouch_getVersionId() c_uint;
extern fn soundtouch_setRate(h: HANDLE, newRate: f32) void;
extern fn soundtouch_setTempo(h: HANDLE, newTempo: f32) void;
extern fn soundtouch_setRateChange(h: HANDLE, newRate: f32) void;
extern fn soundtouch_setTempoChange(h: HANDLE, newTempo: f32) void;
extern fn soundtouch_setPitch(h: HANDLE, newPitch: f32) void;
extern fn soundtouch_setPitchOctaves(h: HANDLE, newPitch: f32) void;
extern fn soundtouch_setPitchSemiTones(h: HANDLE, newPitch: f32) void;
extern fn soundtouch_setChannels(h: HANDLE, numChannels: c_uint) c_int;
extern fn soundtouch_setSampleRate(h: HANDLE, srate: c_uint) c_int;
extern fn soundtouch_flush(h: HANDLE) c_int;
extern fn soundtouch_putSamples(h: HANDLE, samples: [*]const f32, numSamples: c_uint) c_int;
extern fn soundtouch_clear(h: HANDLE) void;
extern fn soundtouch_setSetting(h: HANDLE, settingId: c_int, value: c_int) c_int;
extern fn soundtouch_getSetting(h: HANDLE, settingId: c_int) c_int;
extern fn soundtouch_numUnprocessedSamples(h: HANDLE) c_uint;
extern fn soundtouch_receiveSamples(h: HANDLE, outBuffer: [*]f32, maxSamples: c_uint) c_uint;
extern fn soundtouch_numSamples(h: HANDLE) c_uint;
extern fn soundtouch_isEmpty(h: HANDLE) c_int;

pub const SoundTouch = struct {
    handle: HANDLE,

    pub fn create() ?SoundTouch {
        const handle = soundtouch_createInstance();
        if (handle == null) return null;
        return SoundTouch{ .handle = handle };
    }

    pub fn destroy(self: *SoundTouch) void {
        soundtouch_destroyInstance(self.handle);
        self.handle = null;
    }

    /// Sets the number of channels (1 = mono, 2 = stereo)
    pub fn setChannels(self: *SoundTouch, num_channels: u32) void {
        _ = soundtouch_setChannels(self.handle, num_channels);
    }

    /// Sets the sample rate
    pub fn setSampleRate(self: *SoundTouch, sample_rate: u32) void {
        _ = soundtouch_setSampleRate(self.handle, sample_rate);
    }

    /// Sets the tempo (playback speed). 1.0 = normal, <1.0 = slower, >1.0 = faster
    /// This changes speed WITHOUT affecting pitch
    pub fn setTempo(self: *SoundTouch, tempo: f32) void {
        soundtouch_setTempo(self.handle, tempo);
    }

    /// Sets tempo change as percentage (-50% to +100%)
    pub fn setTempoChange(self: *SoundTouch, percent: f32) void {
        soundtouch_setTempoChange(self.handle, percent);
    }

    /// Sets pitch (1.0 = original pitch)
    pub fn setPitch(self: *SoundTouch, pitch: f32) void {
        soundtouch_setPitch(self.handle, pitch);
    }

    /// Sets pitch change in semitones (-12 to +12)
    pub fn setPitchSemiTones(self: *SoundTouch, semitones: f32) void {
        soundtouch_setPitchSemiTones(self.handle, semitones);
    }

    /// Sets rate (affects both tempo and pitch). 1.0 = normal
    pub fn setRate(self: *SoundTouch, rate: f32) void {
        soundtouch_setRate(self.handle, rate);
    }

    /// Puts samples into the processor
    pub fn putSamples(self: *SoundTouch, samples: []const f32, num_frames: u32) void {
        _ = soundtouch_putSamples(self.handle, samples.ptr, num_frames);
    }

    /// Receives processed samples from the output buffer
    /// Returns the number of frames actually received
    pub fn receiveSamples(self: *SoundTouch, buffer: []f32, max_frames: u32) u32 {
        return soundtouch_receiveSamples(self.handle, buffer.ptr, max_frames);
    }

    /// Returns the number of samples currently available in the output buffer
    pub fn numSamples(self: *SoundTouch) u32 {
        return soundtouch_numSamples(self.handle);
    }

    /// Returns number of samples currently unprocessed in input buffer
    pub fn numUnprocessedSamples(self: *SoundTouch) u32 {
        return soundtouch_numUnprocessedSamples(self.handle);
    }

    /// Returns true if output buffer is empty
    pub fn isEmpty(self: *SoundTouch) bool {
        return soundtouch_isEmpty(self.handle) != 0;
    }

    /// Clears all samples from input/output buffers
    pub fn clear(self: *SoundTouch) void {
        soundtouch_clear(self.handle);
    }

    /// Flushes remaining samples from the processing pipeline
    pub fn flush(self: *SoundTouch) void {
        _ = soundtouch_flush(self.handle);
    }

    /// Sets a processing setting
    pub fn setSetting(self: *SoundTouch, setting_id: Setting, value: i32) bool {
        return soundtouch_setSetting(self.handle, @intFromEnum(setting_id), value) != 0;
    }

    /// Gets a processing setting value
    pub fn getSetting(self: *SoundTouch, setting_id: Setting) i32 {
        return soundtouch_getSetting(self.handle, @intFromEnum(setting_id));
    }
};

/// SoundTouch settings
pub const Setting = enum(i32) {
    /// Enable/disable anti-alias filter (1 = enabled, 0 = disabled)
    use_aa_filter = 0,
    /// Sequence duration in ms for time-stretch algorithm
    sequence_ms = 1,
    /// Seek window duration in ms for time-stretch algorithm
    seekwindow_ms = 2,
    /// Overlap duration in ms for time-stretch algorithm
    overlap_ms = 3,
    /// Enable/disable quick seek mode (1 = enabled, 0 = disabled)
    use_quickseek = 4,
};

/// Get the SoundTouch library version string
pub fn getVersionString() [*:0]const u8 {
    return soundtouch_getVersionString();
}

/// Get the SoundTouch library version ID
pub fn getVersionId() u32 {
    return soundtouch_getVersionId();
}
