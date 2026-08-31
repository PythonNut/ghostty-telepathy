//! Optional, bounded telemetry for Telepathy's Android Vulkan renderer.
//!
//! The hot path performs one relaxed atomic load while telemetry is disabled.
//! Detailed timing is enabled only by Telepathy's renderer harness.
const std = @import("std");

pub const Timing = struct {
    samples: u64 = 0,
    total_ns: u64 = 0,
};

pub const Snapshot = struct {
    model_update: Timing = .{},
    acquire: Timing = .{},
    encode: Timing = .{},
    queue_submit: Timing = .{},
    queue_present: Timing = .{},
    gpu_completion: Timing = .{},
    display: Timing = .{},
    submitted_frames: u64 = 0,
    completed_frames: u64 = 0,
    displayed_frames: u64 = 0,
    in_flight_frames: u64 = 0,
    max_in_flight_frames: u64 = 0,
    completion_queue_depth: u64 = 0,
    max_completion_queue_depth: u64 = 0,
};

pub const Telemetry = struct {
    enabled_value: std.atomic.Value(bool) = .{ .raw = false },
    mutex: std.Thread.Mutex = .{},
    data: Snapshot = .{},

    pub fn setEnabled(self: *Telemetry, value: bool) void {
        self.enabled_value.store(value, .release);
    }

    pub fn enabled(self: *const Telemetry) bool {
        return self.enabled_value.load(.acquire);
    }

    pub fn recordModelUpdate(self: *Telemetry, duration_ns: u64) void {
        self.record("model_update", duration_ns);
    }

    pub fn recordAcquire(self: *Telemetry, duration_ns: u64) void {
        self.record("acquire", duration_ns);
    }

    pub fn recordEncode(self: *Telemetry, duration_ns: u64) void {
        self.record("encode", duration_ns);
    }

    pub fn recordQueueSubmit(self: *Telemetry, duration_ns: u64) void {
        self.record("queue_submit", duration_ns);
    }

    pub fn recordQueuePresent(self: *Telemetry, duration_ns: u64) void {
        self.record("queue_present", duration_ns);
    }

    pub fn recordDisplay(self: *Telemetry, duration_ns: u64) void {
        if (!self.enabled()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data.display.samples += 1;
        self.data.display.total_ns += duration_ns;
        self.data.displayed_frames += 1;
    }

    pub fn frameSubmitted(self: *Telemetry, completion_queue_depth: usize) bool {
        if (!self.enabled()) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data.submitted_frames += 1;
        self.data.in_flight_frames += 1;
        self.data.max_in_flight_frames = @max(
            self.data.max_in_flight_frames,
            self.data.in_flight_frames,
        );
        self.data.completion_queue_depth = completion_queue_depth;
        self.data.max_completion_queue_depth = @max(
            self.data.max_completion_queue_depth,
            completion_queue_depth,
        );
        return true;
    }

    pub fn frameCompleted(
        self: *Telemetry,
        duration_ns: u64,
        completion_queue_depth: usize,
        recorded: bool,
    ) void {
        if (!recorded) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data.gpu_completion.samples += 1;
        self.data.gpu_completion.total_ns += duration_ns;
        self.data.completed_frames += 1;
        if (self.data.in_flight_frames > 0) self.data.in_flight_frames -= 1;
        self.data.completion_queue_depth = completion_queue_depth;
    }

    pub fn snapshot(self: *Telemetry) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.data;
    }

    fn record(self: *Telemetry, comptime field: []const u8, duration_ns: u64) void {
        if (!self.enabled()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        const timing = &@field(self.data, field);
        timing.samples += 1;
        timing.total_ns += duration_ns;
    }
};

pub const DeviceSnapshot = struct {
    atlas_upload: Timing = .{},
    atlas_upload_bytes: u64 = 0,
};

pub const DeviceTelemetry = struct {
    enabled_count: std.atomic.Value(u32) = .{ .raw = 0 },
    mutex: std.Thread.Mutex = .{},
    data: DeviceSnapshot = .{},

    pub fn enable(self: *DeviceTelemetry) void {
        _ = self.enabled_count.fetchAdd(1, .acq_rel);
    }

    pub fn disable(self: *DeviceTelemetry) void {
        const previous = self.enabled_count.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
    }

    pub fn enabled(self: *const DeviceTelemetry) bool {
        return self.enabled_count.load(.acquire) > 0;
    }

    pub fn recordAtlasUpload(self: *DeviceTelemetry, bytes: usize, duration_ns: u64) void {
        if (!self.enabled()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data.atlas_upload.samples += 1;
        self.data.atlas_upload.total_ns += duration_ns;
        self.data.atlas_upload_bytes += bytes;
    }

    pub fn snapshot(self: *DeviceTelemetry) DeviceSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.data;
    }
};
