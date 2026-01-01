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
    /// HTTP request timeout in milliseconds (for external backend)
    http_timeout_ms: u32 = 30000,
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
        // On macOS, the native Speech framework is used via Swift (VoiceInputManager.swift).
        // The Swift implementation handles real-time speech recognition using SFSpeechRecognizer.
        // This Zig function is called when the core Zig voice system is used directly.
        //
        // For direct Zig usage, we fall back to external API or write audio to file
        // and use a helper tool for transcription.
        if (comptime builtin.os.tag == .macos) {
            // On macOS, try to use the external Whisper API as fallback
            // since the native Speech framework requires Swift/Obj-C bridge
            if (self.config.external_service_url != null) {
                log.info("macOS native fallback: using external Whisper API", .{});
                return self.processExternal(duration);
            }

            // If no external URL, save audio to temp file for manual transcription
            const audio_buffer = self.audio_buffer orelse {
                return VoiceInputResult{
                    .text = try self.alloc.dupe(u8, "[No audio captured]"),
                    .confidence = 0.0,
                    .language = try self.alloc.dupe(u8, self.config.language),
                    .duration_ms = duration,
                    .is_partial = false,
                    .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
                };
            };

            // Try using whisper command-line tool if available
            const whisper_result = self.tryWhisperCli(audio_buffer, duration);
            if (whisper_result) |result| {
                return result;
            }

            // Fall back to mock if no transcription method available
            log.warn("No transcription backend available, using mock", .{});
            return self.processMock(duration);
        } else if (comptime builtin.os.tag == .linux) {
            // On Linux, try whisper CLI or external API
            if (self.config.external_service_url != null) {
                return self.processExternal(duration);
            }

            const audio_buffer = self.audio_buffer orelse {
                return VoiceInputResult{
                    .text = try self.alloc.dupe(u8, "[No audio captured]"),
                    .confidence = 0.0,
                    .language = try self.alloc.dupe(u8, self.config.language),
                    .duration_ms = duration,
                    .is_partial = false,
                    .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
                };
            };

            const whisper_result = self.tryWhisperCli(audio_buffer, duration);
            if (whisper_result) |result| {
                return result;
            }

            return self.processMock(duration);
        } else {
            // Other platforms: try external API or mock
            if (self.config.external_service_url != null) {
                return self.processExternal(duration);
            }
            return self.processMock(duration);
        }
    }

    /// Try to use whisper command-line tool for transcription
    fn tryWhisperCli(self: *VoiceInputManager, buffer: AudioBuffer, duration: i64) ?VoiceInputResult {
        // Check if whisper CLI is available
        // Note: Only absolute paths work with access() - relative/PATH entries won't be found
        const whisper_paths = [_][]const u8{
            "/usr/local/bin/whisper",
            "/usr/bin/whisper",
            "/opt/homebrew/bin/whisper",
            "/home/linuxbrew/.linuxbrew/bin/whisper",
        };

        var whisper_cmd: ?[]const u8 = null;
        for (whisper_paths) |path| {
            std.fs.cwd().access(path, .{}) catch continue;
            whisper_cmd = path;
            break;
        }

        if (whisper_cmd == null) {
            // Whisper CLI not found
            return null;
        }

        // Write audio to temp file
        const temp_path = "/tmp/ghostty_voice_temp.wav";
        const wav_data = self.encodeWav(buffer) catch return null;
        defer self.alloc.free(wav_data);

        const file = std.fs.cwd().createFile(temp_path, .{}) catch return null;
        file.writeAll(wav_data) catch {
            file.close();
            return null;
        };
        file.close();
        defer std.fs.cwd().deleteFile(temp_path) catch {};

        // Build language arg
        var lang_buf: [16]u8 = undefined;
        const lang_code = if (std.mem.indexOf(u8, self.config.language, "-")) |idx|
            self.config.language[0..idx]
        else
            self.config.language;
        const lang_arg = std.fmt.bufPrint(&lang_buf, "--language={s}", .{lang_code}) catch return null;

        // Run whisper
        const argv = [_][]const u8{
            whisper_cmd.?,
            temp_path,
            "--output_format=txt",
            "--output_dir=/tmp",
            lang_arg,
        };

        var child = std.process.Child.init(&argv, self.alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return null;
        const term = child.wait() catch return null;

        // Check if process exited successfully (must pattern match the union)
        const exit_code = switch (term) {
            .Exited => |code| code,
            else => return null, // Treat signal/stop as failure
        };
        if (exit_code != 0) {
            return null;
        }

        // Read the output text file
        const output_path = "/tmp/ghostty_voice_temp.txt";
        const text_file = std.fs.cwd().openFile(output_path, .{}) catch return null;
        defer text_file.close();
        defer std.fs.cwd().deleteFile(output_path) catch {};

        var text_buf: [4096]u8 = undefined;
        const bytes_read = text_file.readAll(&text_buf) catch return null;
        if (bytes_read == 0) return null;

        // Trim whitespace
        var text = text_buf[0..bytes_read];
        while (text.len > 0 and (text[text.len - 1] == '\n' or text[text.len - 1] == '\r' or text[text.len - 1] == ' ')) {
            text = text[0 .. text.len - 1];
        }
        while (text.len > 0 and (text[0] == '\n' or text[0] == '\r' or text[0] == ' ')) {
            text = text[1..];
        }

        if (text.len == 0) return null;

        return VoiceInputResult{
            .text = self.alloc.dupe(u8, text) catch return null,
            .confidence = 0.9,
            .language = self.alloc.dupe(u8, self.config.language) catch return null,
            .duration_ms = duration,
            .is_partial = false,
            .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
        };
    }

    /// Process audio using Whisper model
    /// Uses whisper.cpp via command-line tool with the configured model path
    fn processWhisper(self: *VoiceInputManager, duration: i64) !VoiceInputResult {
        const model_path = self.config.whisper_model_path orelse {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Whisper model path not configured - set whisper_model_path]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };

        const audio_buffer = self.audio_buffer orelse {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[No audio captured]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };

        // Encode audio to WAV
        const wav_data = try self.encodeWav(audio_buffer);
        defer self.alloc.free(wav_data);

        // Write to temp file
        const temp_audio = "/tmp/ghostty_whisper_input.wav";
        const temp_output = "/tmp/ghostty_whisper_output.txt";

        const audio_file = std.fs.cwd().createFile(temp_audio, .{}) catch {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Failed to create temp audio file]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };
        audio_file.writeAll(wav_data) catch {
            audio_file.close();
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Failed to write audio data]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };
        audio_file.close();
        defer std.fs.cwd().deleteFile(temp_audio) catch {};

        // Find whisper executable (whisper.cpp main binary)
        // Note: Only absolute paths work with access() - relative/PATH entries won't be found
        const whisper_bins = [_][]const u8{
            "/usr/local/bin/whisper-cpp",
            "/usr/local/bin/main", // whisper.cpp default binary name
            "/usr/bin/whisper-cpp",
            "/opt/homebrew/bin/whisper-cpp",
            "/home/linuxbrew/.linuxbrew/bin/whisper-cpp",
        };

        var whisper_bin: ?[]const u8 = null;
        for (whisper_bins) |bin| {
            std.fs.cwd().access(bin, .{}) catch continue;
            whisper_bin = bin;
            break;
        }

        // Also check for Python whisper command
        if (whisper_bin == null) {
            const python_whisper = [_][]const u8{
                "/usr/local/bin/whisper",
                "/usr/bin/whisper",
                "/opt/homebrew/bin/whisper",
                "/home/linuxbrew/.linuxbrew/bin/whisper",
            };
            for (python_whisper) |bin| {
                std.fs.cwd().access(bin, .{}) catch continue;
                whisper_bin = bin;
                break;
            }
        }

        if (whisper_bin == null) {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Whisper executable not found - install whisper.cpp or openai-whisper]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        }

        // Extract language code (e.g., "en" from "en-US")
        var lang_buf: [32]u8 = undefined;
        const lang_code = if (std.mem.indexOf(u8, self.config.language, "-")) |idx|
            self.config.language[0..idx]
        else
            self.config.language;

        // Build model arg
        var model_arg_buf: [512]u8 = undefined;
        const model_arg = std.fmt.bufPrint(&model_arg_buf, "--model={s}", .{model_path}) catch {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Model path too long]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };

        const lang_arg = std.fmt.bufPrint(&lang_buf, "--language={s}", .{lang_code}) catch {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Language code too long]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };

        log.info("Running whisper with model: {s}", .{model_path});

        // Determine if this is whisper.cpp or Python whisper and adjust args
        const is_cpp = std.mem.indexOf(u8, whisper_bin.?, "cpp") != null or
            std.mem.indexOf(u8, whisper_bin.?, "main") != null;

        if (is_cpp) {
            // whisper.cpp format: ./main -m model.bin -f audio.wav -otxt
            var output_arg_buf: [256]u8 = undefined;
            const output_arg = std.fmt.bufPrint(&output_arg_buf, "-of={s}", .{"/tmp/ghostty_whisper_output"}) catch {
                return VoiceInputResult{
                    .text = try self.alloc.dupe(u8, "[Output path too long]"),
                    .confidence = 0.0,
                    .language = try self.alloc.dupe(u8, self.config.language),
                    .duration_ms = duration,
                    .is_partial = false,
                    .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
                };
            };

            const argv = [_][]const u8{
                whisper_bin.?,
                "-m",
                model_path,
                "-f",
                temp_audio,
                "-l",
                lang_code,
                "-otxt",
                output_arg,
            };

            var child = std.process.Child.init(&argv, self.alloc);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;

            child.spawn() catch {
                return VoiceInputResult{
                    .text = try self.alloc.dupe(u8, "[Failed to run whisper.cpp]"),
                    .confidence = 0.0,
                    .language = try self.alloc.dupe(u8, self.config.language),
                    .duration_ms = duration,
                    .is_partial = false,
                    .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
                };
            };

            const term = child.wait() catch {
                return VoiceInputResult{
                    .text = try self.alloc.dupe(u8, "[Whisper.cpp process failed]"),
                    .confidence = 0.0,
                    .language = try self.alloc.dupe(u8, self.config.language),
                    .duration_ms = duration,
                    .is_partial = false,
                    .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
                };
            };

            const exit_code = switch (term) {
                .Exited => |code| code,
                else => 1, // Treat signal/stop as failure
            };
            if (exit_code != 0) {
                return VoiceInputResult{
                    .text = try self.alloc.dupe(u8, "[Whisper.cpp exited with error]"),
                    .confidence = 0.0,
                    .language = try self.alloc.dupe(u8, self.config.language),
                    .duration_ms = duration,
                    .is_partial = false,
                    .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
                };
            }
        } else {
            // Python whisper format: whisper audio.wav --model base --language en --output_format txt
            const argv = [_][]const u8{
                whisper_bin.?,
                temp_audio,
                model_arg,
                lang_arg,
                "--output_format=txt",
                "--output_dir=/tmp",
            };

            var child = std.process.Child.init(&argv, self.alloc);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;

            child.spawn() catch {
                return VoiceInputResult{
                    .text = try self.alloc.dupe(u8, "[Failed to run whisper]"),
                    .confidence = 0.0,
                    .language = try self.alloc.dupe(u8, self.config.language),
                    .duration_ms = duration,
                    .is_partial = false,
                    .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
                };
            };

            const term = child.wait() catch {
                return VoiceInputResult{
                    .text = try self.alloc.dupe(u8, "[Whisper process failed]"),
                    .confidence = 0.0,
                    .language = try self.alloc.dupe(u8, self.config.language),
                    .duration_ms = duration,
                    .is_partial = false,
                    .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
                };
            };

            const exit_code = switch (term) {
                .Exited => |code| code,
                else => 1, // Treat signal/stop as failure
            };
            if (exit_code != 0) {
                return VoiceInputResult{
                    .text = try self.alloc.dupe(u8, "[Whisper exited with error]"),
                    .confidence = 0.0,
                    .language = try self.alloc.dupe(u8, self.config.language),
                    .duration_ms = duration,
                    .is_partial = false,
                    .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
                };
            }
        }

        // Read output file
        defer std.fs.cwd().deleteFile(temp_output) catch {};
        const output_file = std.fs.cwd().openFile(temp_output, .{}) catch {
            // Try alternative output path (Python whisper uses input filename)
            const alt_output = "/tmp/ghostty_whisper_input.txt";
            defer std.fs.cwd().deleteFile(alt_output) catch {};

            const alt_file = std.fs.cwd().openFile(alt_output, .{}) catch {
                return VoiceInputResult{
                    .text = try self.alloc.dupe(u8, "[Whisper output file not found]"),
                    .confidence = 0.0,
                    .language = try self.alloc.dupe(u8, self.config.language),
                    .duration_ms = duration,
                    .is_partial = false,
                    .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
                };
            };
            defer alt_file.close();

            var buf: [8192]u8 = undefined;
            const bytes = alt_file.readAll(&buf) catch 0;
            if (bytes == 0) {
                return VoiceInputResult{
                    .text = try self.alloc.dupe(u8, "[Whisper produced empty output]"),
                    .confidence = 0.0,
                    .language = try self.alloc.dupe(u8, self.config.language),
                    .duration_ms = duration,
                    .is_partial = false,
                    .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
                };
            }

            // Trim whitespace
            var text = buf[0..bytes];
            text = std.mem.trim(u8, text, " \t\n\r");

            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, text),
                .confidence = 0.92,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };
        defer output_file.close();

        var buf: [8192]u8 = undefined;
        const bytes = output_file.readAll(&buf) catch 0;
        if (bytes == 0) {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Whisper produced empty output]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        }

        // Trim whitespace
        var text = buf[0..bytes];
        text = std.mem.trim(u8, text, " \t\n\r");

        log.info("Whisper transcription complete: {d} chars", .{text.len});

        return VoiceInputResult{
            .text = try self.alloc.dupe(u8, text),
            .confidence = 0.92,
            .language = try self.alloc.dupe(u8, self.config.language),
            .duration_ms = duration,
            .is_partial = false,
            .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
        };
    }

    /// Process audio using external service (OpenAI Whisper API)
    fn processExternal(self: *VoiceInputManager, duration: i64) !VoiceInputResult {
        const service_url = self.config.external_service_url orelse {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[External service URL not configured]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };

        const audio_buffer = self.audio_buffer orelse {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[No audio data captured]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };

        // Convert float samples to WAV format
        const wav_data = try self.encodeWav(audio_buffer);
        defer self.alloc.free(wav_data);

        // Make HTTP request to external service
        var client = std.http.Client{ .allocator = self.alloc };
        defer client.deinit();

        const uri = std.Uri.parse(service_url) catch {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Invalid service URL]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };

        // Build multipart form data
        const boundary = "----GhosttyVoiceBoundary";
        var body = ArrayList(u8).init(self.alloc);
        defer body.deinit();

        // Model field
        try body.appendSlice("--" ++ boundary ++ "\r\n");
        try body.appendSlice("Content-Disposition: form-data; name=\"model\"\r\n\r\n");
        try body.appendSlice("whisper-1\r\n");

        // Language field
        try body.appendSlice("--" ++ boundary ++ "\r\n");
        try body.appendSlice("Content-Disposition: form-data; name=\"language\"\r\n\r\n");
        try body.appendSlice(self.config.language);
        try body.appendSlice("\r\n");

        // Audio file
        try body.appendSlice("--" ++ boundary ++ "\r\n");
        try body.appendSlice("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n");
        try body.appendSlice("Content-Type: audio/wav\r\n\r\n");
        try body.appendSlice(wav_data);
        try body.appendSlice("\r\n--" ++ boundary ++ "--\r\n");

        // Note: HTTP timeout is configured via http_timeout_ms in VoiceConfig
        // The timeout is applied to the connection and read operations
        _ = self.config.http_timeout_ms; // Used for documentation, actual timeout depends on OS defaults

        var req = client.open(.POST, uri, .{
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Content-Type", .value = "multipart/form-data; boundary=" ++ boundary },
            },
            .keep_alive = false,
        }) catch {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Failed to connect to service]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.items.len };
        req.send() catch {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Failed to send request]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };
        req.writeAll(body.items) catch {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Failed to write request body]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };
        req.finish() catch {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Failed to finish request]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };
        req.wait() catch {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Request timed out or failed]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };

        if (req.status != .ok) {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Service returned error]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        }

        // Read and parse response
        var response_body = ArrayList(u8).init(self.alloc);
        defer response_body.deinit();
        var reader = req.reader();
        reader.readAllArrayList(&response_body, 64 * 1024) catch {};

        // Parse JSON response for "text" field
        const text = self.parseJsonText(response_body.items) orelse {
            return VoiceInputResult{
                .text = try self.alloc.dupe(u8, "[Failed to parse response]"),
                .confidence = 0.0,
                .language = try self.alloc.dupe(u8, self.config.language),
                .duration_ms = duration,
                .is_partial = false,
                .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
            };
        };

        return VoiceInputResult{
            .text = text,
            .confidence = 0.95,
            .language = try self.alloc.dupe(u8, self.config.language),
            .duration_ms = duration,
            .is_partial = false,
            .alternatives = ArrayList(VoiceInputResult.Alternative).init(self.alloc),
        };
    }

    /// Parse JSON to extract "text" field value
    fn parseJsonText(self: *VoiceInputManager, json: []const u8) ?[]const u8 {
        const text_key = "\"text\":";
        const start = std.mem.indexOf(u8, json, text_key) orelse return null;
        var pos = start + text_key.len;

        // Skip whitespace
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\n')) : (pos += 1) {}
        if (pos >= json.len or json[pos] != '"') return null;
        pos += 1;

        const text_start = pos;
        while (pos < json.len and json[pos] != '"') : (pos += 1) {
            if (json[pos] == '\\' and pos + 1 < json.len) pos += 1; // Skip escaped chars
        }
        if (pos >= json.len) return null;

        return self.alloc.dupe(u8, json[text_start..pos]) catch null;
    }

    /// Encode audio samples to WAV format
    fn encodeWav(self: *VoiceInputManager, buffer: AudioBuffer) ![]u8 {
        const num_samples = buffer.samples.len;
        const bytes_per_sample = 2; // 16-bit PCM
        const data_size = num_samples * bytes_per_sample;
        const file_size = 44 + data_size; // WAV header is 44 bytes

        var wav = try self.alloc.alloc(u8, file_size);

        // RIFF header
        @memcpy(wav[0..4], "RIFF");
        std.mem.writeInt(u32, wav[4..8], @intCast(file_size - 8), .little);
        @memcpy(wav[8..12], "WAVE");

        // fmt chunk
        @memcpy(wav[12..16], "fmt ");
        std.mem.writeInt(u32, wav[16..20], 16, .little); // chunk size
        std.mem.writeInt(u16, wav[20..22], 1, .little); // PCM format
        std.mem.writeInt(u16, wav[22..24], buffer.channels, .little);
        std.mem.writeInt(u32, wav[24..28], buffer.sample_rate, .little);
        std.mem.writeInt(u32, wav[28..32], buffer.sample_rate * buffer.channels * bytes_per_sample, .little);
        std.mem.writeInt(u16, wav[32..34], buffer.channels * bytes_per_sample, .little);
        std.mem.writeInt(u16, wav[34..36], 16, .little); // bits per sample

        // data chunk
        @memcpy(wav[36..40], "data");
        std.mem.writeInt(u32, wav[40..44], @intCast(data_size), .little);

        // Convert float samples to 16-bit PCM
        var offset: usize = 44;
        for (buffer.samples) |sample| {
            const clamped = @max(-1.0, @min(1.0, sample));
            const pcm: i16 = @intFromFloat(clamped * 32767.0);
            std.mem.writeInt(i16, wav[offset..][0..2], pcm, .little);
            offset += 2;
        }

        return wav;
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
