//! Voice Capture Module for Linux/GTK
//!
//! Provides voice input using PulseAudio for capture and
//! OpenAI Whisper API for transcription.
//!
//! Uses subprocess spawning for audio capture and curl for API calls.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ChildProcess = std.process.Child;

const log = std.log.scoped(.voice_capture);

/// Voice capture state
pub const CaptureState = enum {
    idle,
    recording,
    transcribing,
    completed,
    error_state,
};

/// Voice capture configuration
pub const CaptureConfig = struct {
    /// API key for Whisper
    api_key: ?[]const u8 = null,
    /// Maximum recording duration in seconds
    max_duration_seconds: u32 = 30,
    /// Language hint
    language: []const u8 = "en",
};

/// Voice Capture Manager
pub const VoiceCaptureManager = struct {
    allocator: Allocator,
    config: CaptureConfig,
    state: CaptureState = .idle,
    record_process: ?ChildProcess = null,
    temp_file_path: ?[]const u8 = null,
    start_time: i64 = 0,
    error_message: ?[]const u8 = null,
    transcribed_text: ?[]const u8 = null,

    pub fn init(allocator: Allocator) VoiceCaptureManager {
        return .{
            .allocator = allocator,
            .config = .{},
        };
    }

    pub fn deinit(self: *VoiceCaptureManager) void {
        self.cleanup();
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
        if (self.transcribed_text) |text| {
            self.allocator.free(text);
        }
    }

    /// Configure the voice capture
    pub fn configure(self: *VoiceCaptureManager, config: CaptureConfig) void {
        self.config = config;
    }

    /// Start recording audio
    pub fn startRecording(self: *VoiceCaptureManager) !void {
        if (self.state == .recording) return error.AlreadyRecording;

        // Clear previous results
        if (self.transcribed_text) |text| {
            self.allocator.free(text);
            self.transcribed_text = null;
        }
        if (self.error_message) |msg| {
            self.allocator.free(msg);
            self.error_message = null;
        }

        // Create temp file path
        var path_buf: [128]u8 = undefined;
        const timestamp = std.time.milliTimestamp();
        const path = std.fmt.bufPrint(&path_buf, "/tmp/ghostty_voice_{d}.wav", .{timestamp}) catch {
            return error.PathTooLong;
        };
        self.temp_file_path = try self.allocator.dupe(u8, path);

        // Detect audio capture command
        const capture_cmd = detectAudioCapture() orelse {
            try self.setError("No audio capture tool found. Install pulseaudio-utils (parecord) or alsa-utils (arecord).");
            return error.NoAudioCapture;
        };

        self.start_time = std.time.milliTimestamp();

        // Spawn the recording process
        // parecord and arecord have different CLI syntax
        const is_parecord = std.mem.indexOf(u8, capture_cmd, "parecord") != null;

        var argv_buf: [10][]const u8 = undefined;
        const argv: []const []const u8 = if (is_parecord) blk: {
            // parecord syntax: --file-format=wav --channels=1 --rate=16000 file.wav
            argv_buf[0] = capture_cmd;
            argv_buf[1] = "--file-format=wav";
            argv_buf[2] = "--channels=1";
            argv_buf[3] = "--rate=16000";
            argv_buf[4] = self.temp_file_path.?;
            break :blk argv_buf[0..5];
        } else blk: {
            // arecord syntax: -t wav -c 1 -r 16000 -f S16_LE file.wav
            argv_buf[0] = capture_cmd;
            argv_buf[1] = "-t";
            argv_buf[2] = "wav";
            argv_buf[3] = "-c";
            argv_buf[4] = "1";
            argv_buf[5] = "-r";
            argv_buf[6] = "16000";
            argv_buf[7] = "-f";
            argv_buf[8] = "S16_LE";
            argv_buf[9] = self.temp_file_path.?;
            break :blk argv_buf[0..10];
        };

        var child = ChildProcess.init(argv, self.allocator);
        child.spawn() catch |err| {
            log.err("Failed to spawn audio capture: {}", .{err});
            try self.setError("Failed to start audio recording");
            return error.SpawnFailed;
        };

        self.record_process = child;
        self.state = .recording;

        log.info("Audio recording started with {s}", .{capture_cmd});
    }

    /// Stop recording and transcribe
    pub fn stopRecording(self: *VoiceCaptureManager) !void {
        if (self.state != .recording) return;

        const duration_ms = std.time.milliTimestamp() - self.start_time;
        log.info("Stopping recording after {d}ms", .{duration_ms});

        // Terminate the recording process
        if (self.record_process) |*proc| {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            self.record_process = null;
        }

        // Brief delay to ensure file is flushed
        std.time.sleep(50 * std.time.ns_per_ms);

        // Start transcription
        self.state = .transcribing;
        try self.transcribeRecording();
    }

    /// Toggle recording state
    pub fn toggleRecording(self: *VoiceCaptureManager) !void {
        if (self.state == .recording) {
            try self.stopRecording();
        } else if (self.state == .idle or self.state == .completed or self.state == .error_state) {
            try self.startRecording();
        }
    }

    /// Check if recording
    pub fn isRecording(self: *const VoiceCaptureManager) bool {
        return self.state == .recording;
    }

    /// Get current state
    pub fn getState(self: *const VoiceCaptureManager) CaptureState {
        return self.state;
    }

    /// Get transcribed text (after completion)
    pub fn getText(self: *const VoiceCaptureManager) ?[]const u8 {
        return self.transcribed_text;
    }

    /// Get error message
    pub fn getError(self: *const VoiceCaptureManager) ?[]const u8 {
        return self.error_message;
    }

    // Private methods

    fn transcribeRecording(self: *VoiceCaptureManager) !void {
        const api_key = self.config.api_key orelse {
            self.state = .completed;
            self.transcribed_text = try self.allocator.dupe(u8, "[Configure ai-api-key for voice transcription]");
            return;
        };

        const temp_path = self.temp_file_path orelse {
            try self.setError("No recording file");
            return;
        };

        // Check if file exists and has content
        const file = std.fs.cwd().openFile(temp_path, .{}) catch {
            try self.setError("Recording file not found");
            return;
        };
        const stat = file.stat() catch {
            file.close();
            try self.setError("Could not read recording file");
            return;
        };
        file.close();

        if (stat.size < 1000) { // WAV header is ~44 bytes, need some actual audio
            try self.setError("Recording too short");
            return;
        }

        log.info("Transcribing {d} bytes of audio", .{stat.size});

        // Build curl command for Whisper API
        var auth_header_buf: [300]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_header_buf, "Authorization: Bearer {s}", .{api_key}) catch {
            try self.setError("API key too long");
            return;
        };

        var file_arg_buf: [256]u8 = undefined;
        const file_arg = std.fmt.bufPrint(&file_arg_buf, "file=@{s}", .{temp_path}) catch {
            try self.setError("Path too long");
            return;
        };

        const argv = [_][]const u8{
            "curl",
            "-s",
            "-X",
            "POST",
            "https://api.openai.com/v1/audio/transcriptions",
            "-H",
            auth_header,
            "-F",
            "model=whisper-1",
            "-F",
            file_arg,
        };

        var child = ChildProcess.init(&argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            log.err("Failed to spawn curl: {}", .{err});
            try self.setError("Failed to call transcription API");
            return;
        };

        // Read stdout
        var stdout_buf: [8192]u8 = undefined;
        const stdout = child.stdout.?;
        const bytes_read = stdout.readAll(&stdout_buf) catch 0;
        const response = stdout_buf[0..bytes_read];

        const term = child.wait() catch {
            try self.setError("Transcription request failed");
            return;
        };

        const exit_code = switch (term) {
            .Exited => |code| code,
            else => 1, // Treat signal/stop as failure
        };
        if (exit_code != 0) {
            try self.setError("Transcription API error");
            return;
        }

        // Parse response
        if (self.parseWhisperResponse(response)) |text| {
            self.transcribed_text = text;
            self.state = .completed;
            log.info("Transcription complete: {s}", .{text});
        } else {
            // Check for error in response
            if (std.mem.indexOf(u8, response, "\"error\"")) |_| {
                try self.setError("API returned an error. Check your API key.");
            } else {
                try self.setError("Failed to parse transcription response");
            }
        }

        self.cleanup();
    }

    fn parseWhisperResponse(self: *VoiceCaptureManager, json: []const u8) ?[]const u8 {
        const Response = struct {
            text: ?[]const u8 = null,
        };

        var parsed = std.json.parseFromSlice(Response, self.allocator, json, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();

        const text = parsed.value.text orelse return null;
        return self.allocator.dupe(u8, text) catch null;
    }

    fn cleanup(self: *VoiceCaptureManager) void {
        // Delete temp file
        if (self.temp_file_path) |path| {
            std.fs.cwd().deleteFile(path) catch {};
            self.allocator.free(path);
            self.temp_file_path = null;
        }
    }

    fn setError(self: *VoiceCaptureManager, message: []const u8) !void {
        if (self.error_message) |old| {
            self.allocator.free(old);
        }
        self.error_message = try self.allocator.dupe(u8, message);
        self.state = .error_state;
    }
};

/// Detect available audio capture command
fn detectAudioCapture() ?[]const u8 {
    // Return the full path to ensure the binary can be found regardless of PATH
    const tools = [_][]const u8{
        "/usr/bin/parecord",
        "/bin/parecord",
        "/usr/bin/arecord",
        "/bin/arecord",
    };

    for (tools) |path| {
        std.fs.cwd().access(path, .{}) catch continue;
        return path;
    }
    return null;
}

/// Check if voice capture is available on this system
pub fn isAvailable() bool {
    return detectAudioCapture() != null;
}
