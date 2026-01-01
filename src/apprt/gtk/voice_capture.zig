//! Voice Capture Module for Linux/GTK
//!
//! This module provides voice input capability using PulseAudio/PipeWire
//! for audio capture and OpenAI's Whisper API for transcription.
//!
//! Architecture:
//! 1. Audio capture via `parecord` subprocess (PulseAudio) or `arecord` (ALSA)
//! 2. Audio data sent to Whisper API for transcription
//! 3. Transcribed text returned to callback

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const glib = @import("glib.zig");
const gio = glib.gio;
const gobject = glib.gobject;

const log = std.log.scoped(.voice_capture);

/// Voice capture state
pub const CaptureState = enum {
    idle,
    recording,
    transcribing,
    completed,
    error_state,
};

/// Voice capture result
pub const CaptureResult = struct {
    text: []const u8,
    duration_ms: i64,
    success: bool,
    error_message: ?[]const u8,
};

/// Voice capture configuration
pub const CaptureConfig = struct {
    /// Maximum recording duration in seconds
    max_duration_seconds: u32 = 30,
    /// Sample rate for audio capture
    sample_rate: u32 = 16000,
    /// Audio format (wav is most compatible)
    format: AudioFormat = .wav,
    /// Whisper API endpoint
    whisper_endpoint: []const u8 = "https://api.openai.com/v1/audio/transcriptions",
    /// API key for Whisper
    api_key: ?[]const u8 = null,
    /// Language hint for transcription
    language: []const u8 = "en",

    pub const AudioFormat = enum {
        wav,
        flac,
        mp3,
    };
};

/// Voice Capture Manager
pub const VoiceCaptureManager = struct {
    allocator: Allocator,
    config: CaptureConfig,
    state: CaptureState,
    audio_data: std.ArrayList(u8),
    record_process: ?*gio.Subprocess,
    start_time: i64,
    error_message: ?[]const u8,

    /// Callback for when transcription completes
    on_complete: ?*const fn (result: CaptureResult, user_data: ?*anyopaque) void,
    callback_user_data: ?*anyopaque,

    pub fn init(allocator: Allocator) VoiceCaptureManager {
        return .{
            .allocator = allocator,
            .config = .{},
            .state = .idle,
            .audio_data = std.ArrayList(u8).init(allocator),
            .record_process = null,
            .start_time = 0,
            .error_message = null,
            .on_complete = null,
            .callback_user_data = null,
        };
    }

    pub fn deinit(self: *VoiceCaptureManager) void {
        self.stopRecording();
        self.audio_data.deinit();
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }

    /// Configure the voice capture
    pub fn configure(self: *VoiceCaptureManager, config: CaptureConfig) void {
        self.config = config;
    }

    /// Set the callback for completion
    pub fn setCallback(
        self: *VoiceCaptureManager,
        callback: ?*const fn (CaptureResult, ?*anyopaque) void,
        user_data: ?*anyopaque,
    ) void {
        self.on_complete = callback;
        self.callback_user_data = user_data;
    }

    /// Start recording audio
    pub fn startRecording(self: *VoiceCaptureManager) !void {
        if (self.state == .recording) {
            return error.AlreadyRecording;
        }

        self.audio_data.clearRetainingCapacity();
        self.start_time = std.time.milliTimestamp();
        self.state = .recording;

        // Build the audio capture command
        // Try parecord (PulseAudio) first, fall back to arecord (ALSA)
        const format_arg = switch (self.config.format) {
            .wav => "--file-format=wav",
            .flac => "--file-format=flac",
            .mp3 => "--file-format=wav", // mp3 encoding typically requires lame
        };

        const rate_arg = std.fmt.allocPrint(self.allocator, "--rate={d}", .{self.config.sample_rate}) catch return error.OutOfMemory;
        defer self.allocator.free(rate_arg);

        // Try to detect which audio capture tool is available
        const capture_cmd = detectAudioCaptureCommand() orelse {
            self.setError("No audio capture tool found. Install pulseaudio-utils or alsa-utils.");
            return error.NoAudioCapture;
        };

        log.info("Starting audio capture with: {s}", .{capture_cmd});

        // Create subprocess launcher
        const launcher = gio.SubprocessLauncher.new(.{
            .flags = .{ .stdout_pipe = true, .stderr_pipe = true },
        });
        defer launcher.unref();

        // Build command arguments
        var args = std.ArrayList([*:0]const u8).init(self.allocator);
        defer args.deinit();

        try args.append(capture_cmd);
        try args.append("--channels=1");
        try args.appendSlice(&[_][*:0]const u8{
            format_arg,
            "-",
        });

        // Spawn the process
        self.record_process = launcher.spawn(args.items.ptr) catch |err| {
            log.err("Failed to spawn audio capture: {}", .{err});
            self.setError("Failed to start audio capture");
            return error.SpawnFailed;
        };

        log.info("Audio capture started", .{});
    }

    /// Stop recording and begin transcription
    pub fn stopRecording(self: *VoiceCaptureManager) void {
        if (self.state != .recording) return;

        const duration = std.time.milliTimestamp() - self.start_time;
        log.info("Stopping recording after {d}ms", .{duration});

        // Send SIGTERM to the recording process
        if (self.record_process) |proc| {
            proc.sendSignal(15); // SIGTERM

            // Read captured audio from stdout
            const stdout = proc.getStdoutPipe();
            if (stdout) |pipe| {
                self.readAudioData(pipe) catch |err| {
                    log.err("Failed to read audio data: {}", .{err});
                };
            }

            proc.unref();
            self.record_process = null;
        }

        if (self.audio_data.items.len > 0) {
            self.state = .transcribing;
            self.transcribeAudio(duration);
        } else {
            self.setError("No audio data captured");
            self.state = .error_state;
        }
    }

    /// Toggle recording state
    pub fn toggleRecording(self: *VoiceCaptureManager) !void {
        if (self.state == .recording) {
            self.stopRecording();
        } else {
            try self.startRecording();
        }
    }

    /// Check if currently recording
    pub fn isRecording(self: *const VoiceCaptureManager) bool {
        return self.state == .recording;
    }

    /// Get current state
    pub fn getState(self: *const VoiceCaptureManager) CaptureState {
        return self.state;
    }

    // Private methods

    fn readAudioData(self: *VoiceCaptureManager, stream: *gio.InputStream) !void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = stream.read(&buffer) catch break;
            if (bytes_read == 0) break;
            try self.audio_data.appendSlice(buffer[0..bytes_read]);
        }
    }

    fn transcribeAudio(self: *VoiceCaptureManager, duration: i64) void {
        // If no API key, use mock transcription
        const api_key = self.config.api_key orelse {
            self.deliverResult(.{
                .text = "[Voice input requires ai-api-key to be set for OpenAI Whisper transcription]",
                .duration_ms = duration,
                .success = false,
                .error_message = "No API key configured",
            });
            return;
        };

        // Make HTTP request to Whisper API
        self.sendToWhisperApi(api_key, duration) catch |err| {
            log.err("Whisper API request failed: {}", .{err});
            self.setError("Transcription failed");
            self.deliverResult(.{
                .text = "",
                .duration_ms = duration,
                .success = false,
                .error_message = self.error_message,
            });
        };
    }

    fn sendToWhisperApi(self: *VoiceCaptureManager, api_key: []const u8, duration: i64) !void {
        // Use std.http.Client for the request
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = std.Uri.parse(self.config.whisper_endpoint) catch {
            return error.InvalidUri;
        };

        // Build multipart form data
        const boundary = "----GhosttyVoiceBoundary" ++ std.fmt.comptimePrint("{d}", .{std.time.milliTimestamp()});

        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();

        // Add model field
        try body.appendSlice("--");
        try body.appendSlice(boundary);
        try body.appendSlice("\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n");

        // Add language field
        try body.appendSlice("--");
        try body.appendSlice(boundary);
        try body.appendSlice("\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n");
        try body.appendSlice(self.config.language);
        try body.appendSlice("\r\n");

        // Add audio file
        try body.appendSlice("--");
        try body.appendSlice(boundary);
        try body.appendSlice("\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n");
        try body.appendSlice(self.audio_data.items);
        try body.appendSlice("\r\n--");
        try body.appendSlice(boundary);
        try body.appendSlice("--\r\n");

        // Prepare headers
        var headers_buf: [2048]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&headers_buf, "Bearer {s}", .{api_key}) catch return error.HeaderTooLong;

        var req = try client.open(.POST, uri, .{
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "multipart/form-data; boundary=" ++ boundary },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.items.len };
        try req.send();
        try req.writeAll(body.items);
        try req.finish();
        try req.wait();

        if (req.status != .ok) {
            self.deliverResult(.{
                .text = "",
                .duration_ms = duration,
                .success = false,
                .error_message = "Whisper API returned error",
            });
            return;
        }

        // Read response
        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        var reader = req.reader();
        try reader.readAllArrayList(&response_body, 1024 * 1024);

        // Parse JSON response to get transcribed text
        const text = self.parseWhisperResponse(response_body.items) catch {
            self.deliverResult(.{
                .text = "",
                .duration_ms = duration,
                .success = false,
                .error_message = "Failed to parse response",
            });
            return;
        };

        self.state = .completed;
        self.deliverResult(.{
            .text = text,
            .duration_ms = duration,
            .success = true,
            .error_message = null,
        });
    }

    fn parseWhisperResponse(self: *VoiceCaptureManager, json: []const u8) ![]const u8 {
        // Simple JSON parsing for {"text": "..."}
        const text_key = "\"text\":";
        const start = std.mem.indexOf(u8, json, text_key) orelse return error.NoTextInResponse;
        const after_key = start + text_key.len;

        // Find the opening quote
        var pos = after_key;
        while (pos < json.len and json[pos] != '"') : (pos += 1) {}
        if (pos >= json.len) return error.MalformedJson;
        pos += 1; // Skip opening quote

        // Find closing quote
        const text_start = pos;
        while (pos < json.len and json[pos] != '"') : (pos += 1) {}
        if (pos >= json.len) return error.MalformedJson;

        return self.allocator.dupe(u8, json[text_start..pos]) catch return error.OutOfMemory;
    }

    fn deliverResult(self: *VoiceCaptureManager, result: CaptureResult) void {
        if (self.on_complete) |callback| {
            callback(result, self.callback_user_data);
        }
    }

    fn setError(self: *VoiceCaptureManager, message: []const u8) void {
        if (self.error_message) |old| {
            self.allocator.free(old);
        }
        self.error_message = self.allocator.dupe(u8, message) catch null;
        self.state = .error_state;
    }
};

/// Detect available audio capture command
fn detectAudioCaptureCommand() ?[*:0]const u8 {
    // Check for parecord (PulseAudio/PipeWire)
    if (std.fs.cwd().access("/usr/bin/parecord", .{})) {
        return "parecord";
    } else |_| {}

    // Check for arecord (ALSA)
    if (std.fs.cwd().access("/usr/bin/arecord", .{})) {
        return "arecord";
    } else |_| {}

    // Check common alternative paths
    if (std.fs.cwd().access("/bin/parecord", .{})) {
        return "parecord";
    } else |_| {}

    if (std.fs.cwd().access("/bin/arecord", .{})) {
        return "arecord";
    } else |_| {}

    return null;
}

/// Check if voice capture is available on this system
pub fn isAvailable() bool {
    return detectAudioCaptureCommand() != null;
}

test "voice capture manager initialization" {
    const allocator = std.testing.allocator;
    var manager = VoiceCaptureManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqual(CaptureState.idle, manager.state);
}
