//! AI Client for Ghostty Terminal
//!
//! This module provides client implementations for various AI providers
//! including OpenAI, Anthropic (Claude), and Ollama.

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const log = std.log.scoped(.ai_client);

const shell_module = @import("shell.zig");

/// AI Provider types
pub const Provider = enum {
    openai,
    anthropic,
    ollama,
    custom,
};

/// Write a JSON-escaped string to the writer (without surrounding quotes)
fn writeJsonEscapedString(writer: anytype, string: []const u8) !void {
    for (string) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => {
                // Control characters - escape as \uXXXX
                // Note: 0x09 (tab) handled above, 0x0A (\n) handled above, 0x0D (\r) handled above
                try writer.print("\\u{x:0>4}", .{c});
            },
            else => try writer.writeByte(c),
        }
    }
}

/// AI Client interface and implementations
pub const Client = struct {
    const Self = @This();

    allocator: Allocator,
    provider: Provider,
    api_key: []const u8,
    endpoint: []const u8,
    model: []const u8,
    max_tokens: u32,
    temperature: f32,
    shell: shell_module.Shell,

    /// Create a new AI client
    pub fn init(
        alloc: Allocator,
        provider: Provider,
        api_key: []const u8,
        endpoint: []const u8,
        model: []const u8,
        max_tokens: u32,
        temperature: f32,
    ) Self {
        // Detect the current shell for context-aware command generation
        const detected_shell = shell_module.detectShell(alloc) catch .unknown;

        return .{
            .allocator = alloc,
            .provider = provider,
            .api_key = api_key,
            .endpoint = endpoint,
            .model = model,
            .max_tokens = max_tokens,
            .temperature = temperature,
            .shell = detected_shell,
        };
    }

    /// Send a chat completion request
    /// Note: HTTP client API needs Zig 0.15 compatibility update.
    /// Currently returns a placeholder response.
    pub fn chat(
        self: *const Self,
        system_prompt: []const u8,
        user_prompt: []const u8,
    ) !ChatResponse {
        _ = system_prompt;
        _ = user_prompt;

        // TODO: Fix Zig 0.15 HTTP client API compatibility
        // The http.Client.fetch API changed in Zig 0.15
        return .{
            .content = try self.allocator.dupe(u8, "AI feature requires Zig 0.15 HTTP API update. This is a placeholder response."),
            .model = try self.allocator.dupe(u8, self.model),
            .provider = switch (self.provider) {
                .openai => "openai",
                .anthropic => "anthropic",
                .ollama => "ollama",
                .custom => "custom",
            },
        };
    }

    /// Enhance system prompt with shell-specific context
    fn enhanceSystemPrompt(self: *const Self, system_prompt: []const u8) ![]const u8 {
        const shell_prompt = shell_module.getShellPrompt(self.shell);

        // Combine the original system prompt with shell-specific instructions
        return std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ system_prompt, shell_prompt });
    }

    /// OpenAI chat completion
    fn chatOpenAI(self: *const Self, system_prompt: []const u8, user_prompt: []const u8) !ChatResponse {
        const endpoint_str = if (self.endpoint.len > 0)
            self.endpoint
        else
            "https://api.openai.com/v1/chat/completions";

        var client: http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        // Enhance system prompt with shell-specific context
        const enhanced_prompt = try self.enhanceSystemPrompt(system_prompt);
        defer self.allocator.free(enhanced_prompt);

        // Build request body with proper JSON escaping
        const body = try self.buildOpenAIJson(enhanced_prompt, user_prompt);
        defer self.allocator.free(body);

        // Build authorization header
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        // Use Zig 0.15 fetch API with std.Io.Writer.Allocating
        var allocating_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer allocating_writer.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = endpoint_str },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .response_writer = &allocating_writer.writer,
        });

        if (result.status != .ok) {
            log.err("OpenAI API returned status: {}", .{result.status});
            return error.NetworkError;
        }

        const body_bytes = allocating_writer.written();

        // Parse JSON response
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body_bytes, .{});
        defer parsed.deinit();

        // Extract content from response
        if (parsed.value.object.get("choices")) |choices| {
            if (choices.array.items.len > 0) {
                const first_choice = choices.array.items[0];
                if (first_choice.object.get("message")) |message| {
                    if (message.object.get("content")) |content| {
                        return .{
                            .content = try self.allocator.dupe(u8, content.string),
                            .model = try self.allocator.dupe(u8, self.model),
                            .provider = "openai",
                        };
                    }
                }
            }
        }

        // Check for error in response
        if (parsed.value.object.get("error")) |err| {
            if (err.object.get("message")) |msg| {
                log.err("OpenAI API error: {s}", .{msg.string});
            }
        }

        return error.InvalidResponse;
    }

    /// Build JSON request body for OpenAI API
    fn buildOpenAIJson(self: *const Self, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        // Build: {"model":"...","messages":[{"role":"system","content":"..."},{"role":"user","content":"..."}],"max_tokens":...,"temperature":...}
        try writer.writeAll("{\"model\":\"");
        try writeJsonEscapedString(writer, self.model);
        try writer.writeAll("\",\"messages\":[");

        // System message
        try writer.writeAll("{\"role\":\"system\",\"content\":\"");
        try writeJsonEscapedString(writer, system_prompt);
        try writer.writeAll("\"},");

        // User message
        try writer.writeAll("{\"role\":\"user\",\"content\":\"");
        try writeJsonEscapedString(writer, user_prompt);
        try writer.writeAll("\"}");

        try writer.writeAll("],\"max_tokens\":");
        try writer.print("{}", .{self.max_tokens});

        try writer.writeAll(",\"temperature\":");
        try writer.print("{d:.1}", .{self.temperature});

        try writer.writeAll("}");

        return buf.toOwnedSlice(self.allocator);
    }

    /// Anthropic Claude chat completion
    fn chatAnthropic(self: *const Self, system_prompt: []const u8, user_prompt: []const u8) !ChatResponse {
        const endpoint_str = if (self.endpoint.len > 0)
            self.endpoint
        else
            "https://api.anthropic.com/v1/messages";

        var client: http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        // Enhance system prompt with shell-specific context
        const enhanced_prompt = try self.enhanceSystemPrompt(system_prompt);
        defer self.allocator.free(enhanced_prompt);

        // Build request body
        const body = try self.buildAnthropicJson(enhanced_prompt, user_prompt);
        defer self.allocator.free(body);

        // Use Zig 0.15 fetch API with std.Io.Writer.Allocating
        var allocating_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer allocating_writer.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = endpoint_str },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "x-api-key", .value = self.api_key },
                .{ .name = "anthropic-version", .value = "2023-06-01" },
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .response_writer = &allocating_writer.writer,
        });

        if (result.status != .ok) {
            log.err("Anthropic API returned status: {}", .{result.status});
            return error.InvalidResponse;
        }

        const body_bytes = allocating_writer.written();

        // Parse JSON response
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body_bytes, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("content")) |content| {
            if (content.array.items.len > 0) {
                const first_item = content.array.items[0];
                if (first_item.object.get("text")) |text| {
                    return .{
                        .content = try self.allocator.dupe(u8, text.string),
                        .model = try self.allocator.dupe(u8, self.model),
                        .provider = "anthropic",
                    };
                }
            }
        }

        // Check for error in response
        if (parsed.value.object.get("error")) |err| {
            if (err.object.get("message")) |msg| {
                log.err("Anthropic API error: {s}", .{msg.string});
            }
        }

        return error.InvalidResponse;
    }

    /// Build JSON request body for Anthropic API
    fn buildAnthropicJson(self: *const Self, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        // Build: {"model":"...","max_tokens":...,"system":"...","messages":[{"role":"user","content":"..."}],"temperature":...}
        try writer.writeAll("{\"model\":\"");
        try writeJsonEscapedString(writer, self.model);
        try writer.writeAll("\",\"max_tokens\":");
        try writer.print("{}", .{self.max_tokens});

        try writer.writeAll(",\"system\":\"");
        try writeJsonEscapedString(writer, system_prompt);
        try writer.writeAll("\",\"messages\":[{\"role\":\"user\",\"content\":\"");
        try writeJsonEscapedString(writer, user_prompt);
        try writer.writeAll("\"}],\"temperature\":");
        try writer.print("{d:.1}", .{self.temperature});

        try writer.writeAll("}");

        return buf.toOwnedSlice(self.allocator);
    }

    /// Ollama chat completion (local LLM)
    fn chatOllama(self: *const Self, system_prompt: []const u8, user_prompt: []const u8) !ChatResponse {
        const endpoint_str = if (self.endpoint.len > 0)
            self.endpoint
        else
            "http://localhost:11434/api/chat";

        var client: http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        // Enhance system prompt with shell-specific context
        const enhanced_prompt = try self.enhanceSystemPrompt(system_prompt);
        defer self.allocator.free(enhanced_prompt);

        // Build request body
        const body = try self.buildOllamaJson(enhanced_prompt, user_prompt);
        defer self.allocator.free(body);

        // Use Zig 0.15 fetch API with std.Io.Writer.Allocating
        var allocating_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer allocating_writer.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = endpoint_str },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .response_writer = &allocating_writer.writer,
        });

        if (result.status != .ok) {
            log.err("Ollama API returned status: {}", .{result.status});
            return error.InvalidResponse;
        }

        const body_bytes = allocating_writer.written();

        // Parse JSON response
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body_bytes, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("message")) |message| {
            if (message.object.get("content")) |content| {
                return .{
                    .content = try self.allocator.dupe(u8, content.string),
                    .model = try self.allocator.dupe(u8, self.model),
                    .provider = "ollama",
                };
            }
        }

        return error.InvalidResponse;
    }

    /// Build JSON request body for Ollama API
    fn buildOllamaJson(self: *const Self, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        // Build: {"model":"...","stream":false,"messages":[{"role":"system","content":"..."},{"role":"user","content":"..."}],"options":{"num_ctx":...}}
        try writer.writeAll("{\"model\":\"");
        try writeJsonEscapedString(writer, self.model);
        try writer.writeAll("\",\"stream\":false,\"messages\":[");

        // System message
        try writer.writeAll("{\"role\":\"system\",\"content\":\"");
        try writeJsonEscapedString(writer, system_prompt);
        try writer.writeAll("\"},");

        // User message
        try writer.writeAll("{\"role\":\"user\",\"content\":\"");
        try writeJsonEscapedString(writer, user_prompt);
        try writer.writeAll("\"}");

        try writer.writeAll("],\"options\":{\"num_ctx\":");
        try writer.print("{}", .{self.max_tokens});

        try writer.writeAll("}}");

        return buf.toOwnedSlice(self.allocator);
    }

    /// Custom endpoint chat completion (OpenAI-compatible)
    fn chatCustom(self: *const Self, system_prompt: []const u8, user_prompt: []const u8) !ChatResponse {
        // Use OpenAI-compatible format
        return self.chatOpenAI(system_prompt, user_prompt);
    }

    fn buildOpenAIJsonStream(self: *const Self, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        try writer.writeAll("{\"model\":\"");
        try writeJsonEscapedString(writer, self.model);
        try writer.writeAll("\",\"messages\":[");

        // System message
        try writer.writeAll("{\"role\":\"system\",\"content\":\"");
        try writeJsonEscapedString(writer, system_prompt);
        try writer.writeAll("\"},");

        // User message
        try writer.writeAll("{\"role\":\"user\",\"content\":\"");
        try writeJsonEscapedString(writer, user_prompt);
        try writer.writeAll("\"}");

        try writer.writeAll("],\"max_tokens\":");
        try writer.print("{}", .{self.max_tokens});

        try writer.writeAll(",\"temperature\":");
        try writer.print("{d:.1}", .{self.temperature});

        try writer.writeAll(",\"stream\":true}");

        return buf.toOwnedSlice(self.allocator);
    }

    fn chatStreamOpenAI(
        self: *const Self,
        system_prompt: []const u8,
        user_prompt: []const u8,
        options: StreamOptions,
    ) !void {
        // Zig 0.15 fetch() doesn't support streaming, fall back to non-streaming
        // TODO: Implement true streaming with std.http.Connection when available
        const response = try self.chatOpenAI(system_prompt, user_prompt);
        defer response.deinit(self.allocator);
        options.callback(.{ .content = response.content, .done = true });
    }

    fn buildAnthropicJsonStream(self: *const Self, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        try writer.writeAll("{\"model\":\"");
        try writeJsonEscapedString(writer, self.model);
        try writer.writeAll("\",\"max_tokens\":");
        try writer.print("{}", .{self.max_tokens});

        try writer.writeAll(",\"system\":\"");
        try writeJsonEscapedString(writer, system_prompt);
        try writer.writeAll("\",\"messages\":[{\"role\":\"user\",\"content\":\"");
        try writeJsonEscapedString(writer, user_prompt);
        try writer.writeAll("\"}],\"temperature\":");
        try writer.print("{d:.1}", .{self.temperature});

        try writer.writeAll(",\"stream\":true}");

        return buf.toOwnedSlice(self.allocator);
    }

    fn chatStreamAnthropic(
        self: *const Self,
        system_prompt: []const u8,
        user_prompt: []const u8,
        options: StreamOptions,
    ) !void {
        // Zig 0.15 fetch() doesn't support streaming, fall back to non-streaming
        // TODO: Implement true streaming with std.http.Connection when available
        const response = try self.chatAnthropic(system_prompt, user_prompt);
        defer response.deinit(self.allocator);
        options.callback(.{ .content = response.content, .done = true });
    }

    fn buildOllamaJsonStream(self: *const Self, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        try writer.writeAll("{\"model\":\"");
        try writeJsonEscapedString(writer, self.model);
        try writer.writeAll("\",\"stream\":true,\"messages\":[");

        // System message
        try writer.writeAll("{\"role\":\"system\",\"content\":\"");
        try writeJsonEscapedString(writer, system_prompt);
        try writer.writeAll("\"},");

        // User message
        try writer.writeAll("{\"role\":\"user\",\"content\":\"");
        try writeJsonEscapedString(writer, user_prompt);
        try writer.writeAll("\"}");

        try writer.writeAll("],\"options\":{\"num_ctx\":");
        try writer.print("{}", .{self.max_tokens});
        try writer.writeAll("}}");

        return buf.toOwnedSlice(self.allocator);
    }

    fn chatStreamOllama(
        self: *const Self,
        system_prompt: []const u8,
        user_prompt: []const u8,
        options: StreamOptions,
    ) !void {
        // Zig 0.15 fetch() doesn't support streaming, fall back to non-streaming
        // TODO: Implement true streaming with std.http.Connection when available
        const response = try self.chatOllama(system_prompt, user_prompt);
        defer response.deinit(self.allocator);
        options.callback(.{ .content = response.content, .done = true });
    }

    fn chatStreamCustom(
        self: *const Self,
        system_prompt: []const u8,
        user_prompt: []const u8,
        options: StreamOptions,
    ) !void {
        // Custom endpoints are OpenAI-compatible.
        return self.chatStreamOpenAI(system_prompt, user_prompt, options);
    }

    /// Send a streaming chat completion request
    /// The callback will be invoked for each chunk of the response
    pub fn chatStream(
        self: *const Self,
        system_prompt: []const u8,
        user_prompt: []const u8,
        options: StreamOptions,
    ) !void {
        if (!options.enabled) {
            // If streaming is disabled, use regular chat
            const response = try self.chat(system_prompt, user_prompt);
            defer response.deinit(self.allocator);
            options.callback(.{
                .content = response.content,
                .done = true,
            });
            return;
        }

        // Route to provider-specific streaming implementation
        switch (self.provider) {
            .openai => return self.chatStreamOpenAI(system_prompt, user_prompt, options),
            .anthropic => return self.chatStreamAnthropic(system_prompt, user_prompt, options),
            .ollama => return self.chatStreamOllama(system_prompt, user_prompt, options),
            .custom => return self.chatStreamCustom(system_prompt, user_prompt, options),
        }
    }
};

/// Chat response from AI
pub const ChatResponse = struct {
    content: []const u8,
    model: []const u8,
    provider: []const u8,

    pub fn deinit(self: *const ChatResponse, alloc: Allocator) void {
        alloc.free(self.content);
        alloc.free(self.model);
        // provider is a string literal, don't free
    }
};

/// Streaming chunk from AI
pub const StreamChunk = struct {
    content: []const u8,
    done: bool,
};

/// Callback for streaming responses
pub const StreamCallback = *const fn (chunk: StreamChunk) void;

/// Options for streaming chat completion
pub const StreamOptions = struct {
    callback: StreamCallback,
    /// If true, stream the response. Otherwise use regular completion.
    enabled: bool = false,
    /// Optional cancellation flag (true means cancel/stop).
    cancelled: ?*const std.atomic.Value(bool) = null,
};
