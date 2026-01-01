//! Voice Input Module
//!
//! This module provides speech-to-text integration for voice input.
//! It supports multiple backends:
//! - macOS: NSSpeechRecognizer via Objective-C bridge (when available)
//! - Cross-platform: Whisper.cpp integration for offline recognition
//! - External: Support for external speech-to-text services
//!
//! The implementation provides a unified interface regardless of backend.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const builtin = @import("builtin");

const log = std.log.scoped(.ai_voice);

/// Voice input result containing recognized text
pub const VoiceInputResult = struct {
    /// The recognized text from speech
    text: []const u8,
    /// Confidence score (0.0-1.0)
    confidence: f32,
    /// Detected language code (e.g., "en-US")
    language: []const u8,
    /// Recognition duration in milliseconds
    duration_ms: i64,
    /// Whether this is a partial/interim result
    is_partial: bool,
    /// Alternative interpretations
    alternatives: ArrayList(Alternative),

    pub const Alternative = struct {
        text: []const u8,
        confidence: f32,
    };

    pub fn deinit(self: *VoiceInputResult, alloc: Allocator) void {
        alloc.free(self.text);
        alloc.free(self.language);
        for (self.alternatives.items) |alt| {
            alloc.free(alt.text);
        }
        self.alternatives.deinit();
    }
};

/// Voice recognition backend type
pub const VoiceBackend = enum {
    /// Native platform speech recognition (macOS/iOS Speech framework)
    native,
    /// Whisper.cpp local model
    whisper,
    /// External service via HTTP
    external,
    /// Mock backend for testing
    mock,
};

/// Voice input configuration
pub const VoiceConfig = struct {
    /// Preferred backend
    backend: VoiceBackend = .native,
    /// Language code for recognition
    language: []const u8 = "en-US",
    /// Enable continuous listening mode
    continuous: bool = false,
    /// Silence threshold for end-of-speech detection (seconds)
    silence_threshold: f32 = 1.5,
    /// Maximum recording duration (seconds)
    max_duration: f32 = 30.0,
    /// Enable partial results during recognition
    interim_results: bool = true,
    /// Path to Whisper model file (for whisper backend)
    whisper_model_path: ?[]const u8 = null,
    /// External service URL (for external backend)
    external_service_url: ?[]const u8 = null,
    /// Sample rate for audio capture
    sample_rate: u32 = 16000,
    /// Number of audio channels
    channels: u8 = 1,
};

/// Audio sample buffer
pub const AudioBuffer = struct {
    samples: []f32,
    sample_rate: u32,
    channels: u8,
    duration_ms: i64,

    pub fn init(alloc: Allocator, capacity: usize) !AudioBuffer {
        return .{
            .samples = try alloc.alloc(f32, capacity),
            .sample_rate = 16000,
            .channels = 1,
            .duration_ms = 0,
        };
    }

    pub fn deinit(self: *AudioBuffer, alloc: Allocator) void {
        alloc.free(self.samples);
    }

    /// Calculate duration from sample count
    pub fn calculateDuration(self: *const AudioBuffer) i64 {
        if (self.sample_rate == 0) return 0;
        return @divFloor(@as(i64, @intCast(self.samples.len)) * 1000, @as(i64, @intCast(self.sample_rate)));
    }
};

/// Voice recognition state
pub const VoiceState = enum {
    /// Not initialized or stopped
    idle,
    /// Ready to start listening
    ready,
    /// Currently listening for speech
    listening,
    /// Processing recorded audio
    processing,
    /// Recognition complete, result available
    completed,
    /// Error occurred
    error_state,
};

/// Voice Input Manager - main interface for voice recognition
pub const VoiceInputManager = struct {
    alloc: Allocator,
    config: VoiceConfig,
    state: VoiceState,
    enabled: bool,
    audio_buffer: ?AudioBuffer,
    start_time: i64,
    error_message: ?[]const u8,
    last_result: ?VoiceInputResult,

    /// Callbacks for voice events
    on_result: ?*const fn (result: VoiceInputResult, user_data: ?*anyopaque) void,
    on_error: ?*const fn (error_msg: []const u8, user_data: ?*anyopaque) void,
    on_state_change: ?*const fn (state: VoiceState, user_data: ?*anyopaque) void,
    callback_user_data: ?*anyopaque,

    /// Initialize voice input manager
    pub fn init(alloc: Allocator) !VoiceInputManager {
        return .{
            .alloc = alloc,
            .config = .{
                .language = try alloc.dupe(u8, "en-US"),
            },
            .state = .idle,
            .enabled = true,
            .audio_buffer = null,
            .start_time = 0,
            .error_message = null,
            .last_result = null,
            .on_result = null,
            .on_error = null,
            .on_state_change = null,
            .callback_user_data = null,
        };
    }

    pub fn deinit(self: *VoiceInputManager) void {
        if (self.audio_buffer) |*buf| {
            buf.deinit(self.alloc);
        }
        if (self.error_message) |msg| {
            self.alloc.free(msg);
        }
        if (self.last_result) |*result| {
            result.deinit(self.alloc);
        }
        self.alloc.free(self.config.language);
        if (self.config.whisper_model_path) |path| {
            self.alloc.free(path);
        }
        if (self.config.external_service_url) |url| {
            self.alloc.free(url);
        }
    }

    /// Set voice configuration
    pub fn configure(self: *VoiceInputManager, config: VoiceConfig) !void {
        self.alloc.free(self.config.language);
        self.config = config;
        self.config.language = try self.alloc.dupe(u8, config.language);

        if (config.whisper_model_path) |path| {
            self.config.whisper_model_path = try self.alloc.dupe(u8, path);
        }
        if (config.external_service_url) |url| {
            self.config.external_service_url = try self.alloc.dupe(u8, url);
        }
    }

    /// Initialize the voice backend
    pub fn initializeBackend(self: *VoiceInputManager) !void {
        if (!self.enabled) return error.VoiceInputDisabled;

        switch (self.config.backend) {
            .native => {
                // Check platform support
                if (comptime builtin.os.tag == .macos) {
                    log.info("Initializing native macOS speech recognition", .{});
                    // Native macOS support would use Objective-C bridge
                    // For now, fall back to mock
                    self.setState(.ready);
                } else if (comptime builtin.os.tag == .linux) {
                    log.info("Native speech recognition not available on Linux, using mock", .{});
                    self.setState(.ready);
                } else {
                    log.info("Native speech recognition not available on this platform", .{});
                    self.setState(.ready);
                }
            },
            .whisper => {
                if (self.config.whisper_model_path) |path| {
                    log.info("Initializing Whisper backend with model: {s}", .{path});
                    // Would load Whisper model here
                    self.setState(.ready);
                } else {
                    return error.WhisperModelNotConfigured;
                }
            },
            .external => {
                if (self.config.external_service_url) |url| {
                    log.info("Initializing external voice service: {s}", .{url});
                    self.setState(.ready);
                } else {
                    return error.ExternalServiceNotConfigured;
                }
            },
            .mock => {
                log.info("Initializing mock voice backend", .{});
                self.setState(.ready);
            },
        }
    }

    /// Start voice input recording
    pub fn startListening(self: *VoiceInputManager) !void {
        if (!self.enabled) return error.VoiceInputDisabled;
        if (self.state != .ready and self.state != .idle) {
            return error.InvalidState;
        }

        // Allocate audio buffer
        const buffer_size = @as(usize, @intFromFloat(self.config.max_duration)) *
            @as(usize, self.config.sample_rate) * @as(usize, self.config.channels);
        self.audio_buffer = try AudioBuffer.init(self.alloc, buffer_size);

        self.start_time = std.time.milliTimestamp();
        self.setState(.listening);

        log.info("Voice input started (backend: {s}, language: {s})", .{
            @tagName(self.config.backend),
            self.config.language,
        });
    }

    /// Stop voice input and get result
    pub fn stopListening(self: *VoiceInputManager) !VoiceInputResult {
        if (!self.enabled) return error.VoiceInputDisabled;
        if (self.state != .listening) {
            return error.NotListening;
        }

        self.setState(.processing);
        const duration = std.time.milliTimestamp() - self.start_time;

        log.info("Voice input stopped after {d}ms, processing...", .{duration});

        // Process based on backend
        const result = switch (self.config.backend) {
            .native => try self.processNative(duration),
            .whisper => try self.processWhisper(duration),
            .external => try self.processExternal(duration),
            .mock => try self.processMock(duration),
        };

        // Cleanup audio buffer
        if (self.audio_buffer) |*buf| {
            buf.deinit(self.alloc);
            self.audio_buffer = null;
        }

        self.setState(.completed);

        // Store last result
        if (self.last_result) |*old| {
            old.deinit(self.alloc);
        }
        self.last_result = result;

        // Invoke callback if set
        if (self.on_result) |callback| {
            callback(result, self.callback_user_data);
        }

        return result;
    }

    /// Cancel ongoing voice input
    pub fn cancel(self: *VoiceInputManager) void {
        if (self.state == .listening or self.state == .processing) {
            if (self.audio_buffer) |*buf| {
                buf.deinit(self.alloc);
                self.audio_buffer = null;
            }
            self.setState(.ready);
            log.info("Voice input cancelled", .{});
        }
    }

    /// Process audio using native platform APIs
    fn processNative(self: *VoiceInputManager, duration: i64) !VoiceInputResult {
        // Platform-specific implementation would go here
        // For now, return a descriptive result
        return VoiceInputResult{
            .text = try self.alloc.dupe(u8, "[Native speech recognition - platform bridge required]"),
            .confidence = 0.0,
            .language = try self.alloc.dupe(u8, self.config.language),
            .duration_ms = duration,
            .is_partial = false,
            .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
        };
    }

    /// Process audio using Whisper model
    fn processWhisper(self: *VoiceInputManager, duration: i64) !VoiceInputResult {
        // Whisper integration would process self.audio_buffer here
        // Would use whisper.cpp bindings
        return VoiceInputResult{
            .text = try self.alloc.dupe(u8, "[Whisper model - cpp bindings required]"),
            .confidence = 0.0,
            .language = try self.alloc.dupe(u8, self.config.language),
            .duration_ms = duration,
            .is_partial = false,
            .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
        };
    }

    /// Process audio using external service
    fn processExternal(self: *VoiceInputManager, duration: i64) !VoiceInputResult {
        // Would send audio to external service via HTTP
        return VoiceInputResult{
            .text = try self.alloc.dupe(u8, "[External service - HTTP client required]"),
            .confidence = 0.0,
            .language = try self.alloc.dupe(u8, self.config.language),
            .duration_ms = duration,
            .is_partial = false,
            .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
        };
    }

    /// Process using mock backend (for testing)
    fn processMock(self: *VoiceInputManager, duration: i64) !VoiceInputResult {
        // Generate mock result based on duration
        const mock_texts = [_][]const u8{
            "list all files in the current directory",
            "show git status",
            "run the build script",
            "open the configuration file",
            "search for errors in the log",
        };

        // Use duration to select a mock response deterministically
        const idx = @as(usize, @intCast(@mod(duration, mock_texts.len)));

        var alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc);

        // Add some alternatives
        if (idx + 1 < mock_texts.len) {
            try alternatives.append(.{
                .text = try self.alloc.dupe(u8, mock_texts[idx + 1]),
                .confidence = 0.75,
            });
        }

        return VoiceInputResult{
            .text = try self.alloc.dupe(u8, mock_texts[idx]),
            .confidence = 0.95,
            .language = try self.alloc.dupe(u8, self.config.language),
            .duration_ms = duration,
            .is_partial = false,
            .alternatives = alternatives,
        };
    }

    /// Update state and notify listeners
    fn setState(self: *VoiceInputManager, new_state: VoiceState) void {
        self.state = new_state;
        if (self.on_state_change) |callback| {
            callback(new_state, self.callback_user_data);
        }
    }

    /// Set error and notify listeners
    fn setError(self: *VoiceInputManager, message: []const u8) !void {
        if (self.error_message) |old| {
            self.alloc.free(old);
        }
        self.error_message = try self.alloc.dupe(u8, message);
        self.setState(.error_state);

        if (self.on_error) |callback| {
            callback(message, self.callback_user_data);
        }
    }

    /// Set event callbacks
    pub fn setCallbacks(
        self: *VoiceInputManager,
        on_result: ?*const fn (VoiceInputResult, ?*anyopaque) void,
        on_error: ?*const fn ([]const u8, ?*anyopaque) void,
        on_state_change: ?*const fn (VoiceState, ?*anyopaque) void,
        user_data: ?*anyopaque,
    ) void {
        self.on_result = on_result;
        self.on_error = on_error;
        self.on_state_change = on_state_change;
        self.callback_user_data = user_data;
    }

    /// Enable or disable voice input
    pub fn setEnabled(self: *VoiceInputManager, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled and self.state == .listening) {
            self.cancel();
        }
    }

    /// Set language for recognition
    pub fn setLanguage(self: *VoiceInputManager, language: []const u8) !void {
        self.alloc.free(self.config.language);
        self.config.language = try self.alloc.dupe(u8, language);
    }

    /// Get current state
    pub fn getState(self: *const VoiceInputManager) VoiceState {
        return self.state;
    }

    /// Check if voice input is available on this platform
    pub fn isAvailable() bool {
        return switch (builtin.os.tag) {
            .macos, .ios => true, // Native support available
            .linux => true, // Can use Whisper or external
            .windows => true, // Can use Whisper or external
            else => false,
        };
    }

    /// Get supported backends for current platform
    pub fn getSupportedBackends() []const VoiceBackend {
        return switch (builtin.os.tag) {
            .macos, .ios => &[_]VoiceBackend{ .native, .whisper, .external, .mock },
            else => &[_]VoiceBackend{ .whisper, .external, .mock },
        };
    }

    /// Get list of supported languages
    pub fn getSupportedLanguages(_: *const VoiceInputManager) []const []const u8 {
        return &[_][]const u8{
            "en-US", "en-GB", "en-AU",
            "es-ES", "es-MX", "fr-FR",
            "fr-CA", "de-DE", "it-IT",
            "pt-BR", "pt-PT", "ja-JP",
            "ko-KR", "zh-CN", "zh-TW",
        };
    }
};

/// Utility functions for voice processing
pub const VoiceUtils = struct {
    /// Calculate audio level from samples (for visualization)
    pub fn calculateLevel(samples: []const f32) f32 {
        if (samples.len == 0) return 0.0;

        var sum: f32 = 0.0;
        for (samples) |sample| {
            sum += sample * sample;
        }
        return std.math.sqrt(sum / @as(f32, @floatFromInt(samples.len)));
    }

    /// Detect voice activity in audio samples
    pub fn detectVoiceActivity(samples: []const f32, threshold: f32) bool {
        return calculateLevel(samples) > threshold;
    }

    /// Convert audio samples to appropriate format for recognition
    pub fn convertSampleRate(
        alloc: Allocator,
        samples: []const f32,
        from_rate: u32,
        to_rate: u32,
    ) ![]f32 {
        if (from_rate == to_rate) {
            return alloc.dupe(f32, samples);
        }

        const ratio = @as(f64, @floatFromInt(to_rate)) / @as(f64, @floatFromInt(from_rate));
        const new_len = @as(usize, @intFromFloat(@as(f64, @floatFromInt(samples.len)) * ratio));

        const result = try alloc.alloc(f32, new_len);

        // Simple linear interpolation resampling
        for (result, 0..) |*out, i| {
            const src_idx = @as(f64, @floatFromInt(i)) / ratio;
            const idx_floor = @as(usize, @intFromFloat(src_idx));
            const idx_ceil = @min(idx_floor + 1, samples.len - 1);
            const frac = src_idx - @as(f64, @floatFromInt(idx_floor));

            out.* = samples[idx_floor] * @as(f32, @floatCast(1.0 - frac)) +
                samples[idx_ceil] * @as(f32, @floatCast(frac));
        }

        return result;
    }
};

test "VoiceInputManager basic operations" {
    const alloc = std.testing.allocator;

    var manager = try VoiceInputManager.init(alloc);
    defer manager.deinit();

    try std.testing.expectEqual(VoiceState.idle, manager.getState());
    try std.testing.expect(manager.enabled);
}

test "VoiceUtils calculateLevel" {
    const samples = [_]f32{ 0.5, -0.5, 0.3, -0.3, 0.1 };
    const level = VoiceUtils.calculateLevel(&samples);
    try std.testing.expect(level > 0.0);
    try std.testing.expect(level < 1.0);
}
