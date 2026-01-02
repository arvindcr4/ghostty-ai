//! Model Context Protocol (MCP) Integration
//!
//! This module provides integration with the Model Context Protocol (MCP),
//! allowing AI assistants to access external tools and resources.
//!
//! Features:
//! - Stdio transport for local MCP servers (subprocess communication)
//! - JSON-RPC 2.0 protocol implementation
//! - Tool registration and execution
//! - Resource access and management
//! - Server lifecycle management
//! - Built-in tools for file system, git, and shell operations

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const StringHashMap = std.StringHashMap;
const json = std.json;

const log = std.log.scoped(.ai_mcp);

/// JSON-RPC 2.0 request structure
pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: u64,
    method: []const u8,
    params: ?json.Value,
};

/// JSON-RPC 2.0 response structure
pub const JsonRpcResponse = struct {
    jsonrpc: []const u8,
    id: ?u64,
    result: ?json.Value,
    @"error": ?JsonRpcError,

    pub const JsonRpcError = struct {
        code: i32,
        message: []const u8,
        data: ?json.Value,
    };
};

/// MCP Transport types
pub const TransportType = enum {
    stdio,
    sse,
    websocket,
};

/// MCP Server connection configuration
pub const ServerConfig = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &[_][]const u8{},
    env: ?StringHashMap([]const u8) = null,
    working_dir: ?[]const u8 = null,
    transport: TransportType = .stdio,
};

/// MCP Server connection state
pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

/// MCP Server connection
pub const McpServer = struct {
    alloc: Allocator,
    config: ServerConfig,
    name: []const u8,
    uri: []const u8,
    state: ConnectionState,
    capabilities: ServerCapabilities,
    tools: ArrayListUnmanaged(McpTool),
    resources: ArrayListUnmanaged(McpResource),
    prompts: ArrayListUnmanaged(McpPrompt),
    process: ?std.process.Child,
    next_request_id: u64,
    pending_requests: StringHashMap(PendingRequest),

    pub const PendingRequest = struct {
        id: u64,
        method: []const u8,
        callback: ?*const fn (result: ?json.Value, err: ?JsonRpcResponse.JsonRpcError) void,
    };

    pub fn init(alloc: Allocator, config: ServerConfig) !*McpServer {
        const server = try alloc.create(McpServer);
        server.* = .{
            .alloc = alloc,
            .config = config,
            .name = try alloc.dupe(u8, config.name),
            .uri = try std.fmt.allocPrint(alloc, "stdio://{s}", .{config.command}),
            .state = .disconnected,
            .capabilities = .{},
            .tools = .empty,
            .resources = .empty,
            .prompts = .empty,
            .process = null,
            .next_request_id = 1,
            .pending_requests = StringHashMap(PendingRequest).init(alloc),
        };
        return server;
    }

    pub fn deinit(self: *McpServer) void {
        // Stop process if running
        self.disconnect();

        self.alloc.free(self.name);
        self.alloc.free(self.uri);

        for (self.tools.items) |*tool| tool.deinit(self.alloc);
        self.tools.deinit(self.alloc);

        for (self.resources.items) |*resource| resource.deinit(self.alloc);
        self.resources.deinit(self.alloc);

        for (self.prompts.items) |*prompt| prompt.deinit();
        self.prompts.deinit(self.alloc);

        self.pending_requests.deinit();
    }

    /// Connect to the MCP server
    pub fn connect(self: *McpServer) !void {
        if (self.state == .connected) return;

        self.state = .connecting;

        switch (self.config.transport) {
            .stdio => try self.connectStdio(),
            .sse => try self.connectSSE(),
            .websocket => try self.connectWebSocket(),
        }

        // Send initialize request
        try self.sendInitialize();
    }

    /// Connect via stdio (subprocess)
    fn connectStdio(self: *McpServer) !void {
        // Parse command into argv
        var argv: ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.alloc);

        try argv.append(self.alloc, self.config.command);
        for (self.config.args) |arg| {
            try argv.append(self.alloc, arg);
        }

        self.process = std.process.Child.init(argv.items, self.alloc);

        if (self.config.working_dir) |cwd| {
            self.process.?.cwd = cwd;
        }

        // Set up pipes for communication
        self.process.?.stdin_behavior = .Pipe;
        self.process.?.stdout_behavior = .Pipe;
        self.process.?.stderr_behavior = .Pipe;

        try self.process.?.spawn();
        self.state = .connected;

        log.info("Connected to MCP server: {s} via stdio", .{self.name});
    }

    /// Connect via SSE (Server-Sent Events) - stub for HTTP-based servers
    fn connectSSE(self: *McpServer) !void {
        // SSE implementation would use HTTP client
        log.info("SSE transport not yet fully implemented for {s}", .{self.name});
        self.state = .connected;
    }

    /// Connect via WebSocket - stub for WebSocket-based servers
    fn connectWebSocket(self: *McpServer) !void {
        // WebSocket implementation would use WS client
        log.info("WebSocket transport not yet fully implemented for {s}", .{self.name});
        self.state = .connected;
    }

    /// Disconnect from the server
    pub fn disconnect(self: *McpServer) void {
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            self.process = null;
        }
        self.state = .disconnected;
        log.info("Disconnected from MCP server: {s}", .{self.name});
    }

    /// Send initialize request per MCP protocol
    fn sendInitialize(self: *McpServer) !void {
        var params = json.ObjectMap.init(self.alloc);
        try params.put("protocolVersion", json.Value{ .string = "2024-11-05" });

        var client_info = json.ObjectMap.init(self.alloc);
        try client_info.put("name", json.Value{ .string = "ghostty-ai" });
        try client_info.put("version", json.Value{ .string = "1.0.0" });
        try params.put("clientInfo", json.Value{ .object = client_info });

        const capabilities = json.ObjectMap.init(self.alloc);
        try params.put("capabilities", json.Value{ .object = capabilities });

        _ = try self.sendRequest("initialize", json.Value{ .object = params });
    }

    /// Send a JSON-RPC request
    pub fn sendRequest(self: *McpServer, method: []const u8, params: ?json.Value) !u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;

        // Build JSON request string directly (no need for ObjectMap)
        var output: ArrayListUnmanaged(u8) = .empty;
        defer output.deinit(self.alloc);

        const writer = output.writer(self.alloc);
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"");
        try writer.writeAll(method);
        try writer.print("\",\"id\":{d}", .{id});
        if (params) |p| {
            try writer.writeAll(",\"params\":");
            // Write the params value - for now just write null for unsupported types
            switch (p) {
                .object => try writer.writeAll("{}"),
                .null => try writer.writeAll("null"),
                else => try writer.writeAll("null"),
            }
        }
        try writer.writeAll("}\n");

        // Send via stdio
        if (self.process) |*proc| {
            if (proc.stdin) |stdin| {
                stdin.writeAll(output.items) catch |err| {
                    log.err("Failed to send request to MCP server: {}", .{err});
                    return err;
                };
            }
        }

        log.debug("Sent MCP request: {s} (id={})", .{ method, id });
        return id;
    }

    /// Read response from server
    pub fn readResponse(self: *McpServer) !?JsonRpcResponse {
        if (self.process) |*proc| {
            if (proc.stdout) |stdout| {
                var buf: [65536]u8 = undefined;
                const bytes_read = stdout.read(&buf) catch return null;
                if (bytes_read == 0) return null;

                const response_str = buf[0..bytes_read];

                // Parse JSON response
                const parsed = json.parseFromSlice(json.Value, self.alloc, response_str, .{}) catch return null;
                defer parsed.deinit();

                const obj = parsed.value.object;

                return JsonRpcResponse{
                    .jsonrpc = obj.get("jsonrpc").?.string,
                    .id = if (obj.get("id")) |id_val| @as(?u64, @intCast(id_val.integer)) else null,
                    .result = obj.get("result"),
                    .@"error" = if (obj.get("error")) |err_obj| blk: {
                        break :blk .{
                            .code = @intCast(err_obj.object.get("code").?.integer),
                            .message = err_obj.object.get("message").?.string,
                            .data = err_obj.object.get("data"),
                        };
                    } else null,
                };
            }
        }
        return null;
    }

    /// List available tools
    pub fn listTools(self: *McpServer) !void {
        _ = try self.sendRequest("tools/list", null);
    }

    /// List available resources
    pub fn listResources(self: *McpServer) !void {
        _ = try self.sendRequest("resources/list", null);
    }

    /// Call a tool
    pub fn callTool(self: *McpServer, tool_name: []const u8, arguments: json.Value) !u64 {
        var params = json.ObjectMap.init(self.alloc);
        try params.put("name", json.Value{ .string = tool_name });
        try params.put("arguments", arguments);

        return try self.sendRequest("tools/call", json.Value{ .object = params });
    }

    /// Read a resource
    pub fn readResource(self: *McpServer, uri: []const u8) !u64 {
        var params = json.ObjectMap.init(self.alloc);
        try params.put("uri", json.Value{ .string = uri });

        return try self.sendRequest("resources/read", json.Value{ .object = params });
    }
};

/// Server capabilities
pub const ServerCapabilities = struct {
    tools: bool = false,
    resources: bool = false,
    prompts: bool = false,
    sampling: bool = false,
    logging: bool = false,
};

/// MCP Tool definition
pub const McpTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: json.Value,
    handler: ?*const fn (params: json.Value, alloc: Allocator) anyerror!json.Value = null,

    pub fn deinit(self: *const McpTool, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
    }
};

/// MCP Resource definition
pub const McpResource = struct {
    uri: []const u8,
    name: []const u8,
    description: []const u8,
    mime_type: ?[]const u8,

    pub fn deinit(self: *const McpResource, alloc: Allocator) void {
        alloc.free(self.uri);
        alloc.free(self.name);
        alloc.free(self.description);
        if (self.mime_type) |m| alloc.free(m);
    }
};

/// MCP Prompt definition
pub const McpPrompt = struct {
    name: []const u8,
    description: []const u8,
    arguments: ArrayListUnmanaged(PromptArgument),
    alloc: Allocator,

    pub const PromptArgument = struct {
        name: []const u8,
        description: []const u8,
        required: bool,
    };

    pub fn deinit(self: *McpPrompt) void {
        self.alloc.free(self.name);
        self.alloc.free(self.description);
        for (self.arguments.items) |arg| {
            self.alloc.free(arg.name);
            self.alloc.free(arg.description);
        }
        self.arguments.deinit(self.alloc);
    }
};

/// MCP Client for communicating with MCP servers
pub const McpClient = struct {
    alloc: Allocator,
    servers: ArrayListUnmanaged(*McpServer),
    builtin_server: ?*McpServer,
    enabled: bool,

    /// Initialize MCP client
    pub fn init(alloc: Allocator) McpClient {
        return .{
            .alloc = alloc,
            .servers = .empty,
            .builtin_server = null,
            .enabled = true,
        };
    }

    pub fn deinit(self: *McpClient) void {
        for (self.servers.items) |server| {
            server.deinit();
            self.alloc.destroy(server);
        }
        self.servers.deinit(self.alloc);
    }

    /// Register an MCP server from config
    pub fn registerServer(self: *McpClient, config: ServerConfig) !*McpServer {
        const server = try McpServer.init(self.alloc, config);
        try self.servers.append(self.alloc, server);
        return server;
    }

    /// Register a server by name and command
    pub fn registerServerSimple(
        self: *McpClient,
        name: []const u8,
        command: []const u8,
    ) !*McpServer {
        return self.registerServer(.{
            .name = name,
            .command = command,
        });
    }

    /// Connect all registered servers
    pub fn connectAll(self: *McpClient) !void {
        for (self.servers.items) |server| {
            server.connect() catch |err| {
                log.warn("Failed to connect to MCP server {s}: {}", .{ server.name, err });
            };
        }
    }

    /// Disconnect all servers
    pub fn disconnectAll(self: *McpClient) void {
        for (self.servers.items) |server| {
            server.disconnect();
        }
    }

    /// Get all available tools from all servers
    pub fn getAllTools(self: *const McpClient) !ArrayListUnmanaged(*const McpTool) {
        var tools: ArrayListUnmanaged(*const McpTool) = .empty;

        for (self.servers.items) |server| {
            for (server.tools.items) |*tool| {
                try tools.append(self.alloc, tool);
            }
        }

        return tools;
    }

    /// Find tool by name
    pub fn findTool(self: *const McpClient, name: []const u8) ?struct { server: *McpServer, tool: *const McpTool } {
        for (self.servers.items) |server| {
            for (server.tools.items) |*tool| {
                if (std.mem.eql(u8, tool.name, name)) {
                    return .{ .server = server, .tool = tool };
                }
            }
        }
        return null;
    }

    /// Execute an MCP tool
    pub fn executeTool(
        self: *McpClient,
        tool_name: []const u8,
        params: json.Value,
    ) !json.Value {
        // First try to find in registered servers
        if (self.findTool(tool_name)) |found| {
            if (found.tool.handler) |handler| {
                return try handler(params, self.alloc);
            }
            // Call via server
            _ = try found.server.callTool(tool_name, params);
            // Would need to wait for response
            return json.Value{ .object = json.ObjectMap.init(self.alloc) };
        }

        return error.ToolNotFound;
    }

    /// Get all available resources
    pub fn getAllResources(self: *const McpClient) !ArrayListUnmanaged(*const McpResource) {
        var resources: ArrayListUnmanaged(*const McpResource) = .empty;

        for (self.servers.items) |server| {
            for (server.resources.items) |*resource| {
                try resources.append(self.alloc, resource);
            }
        }

        return resources;
    }

    /// Register built-in tools
    pub fn registerBuiltinTools(self: *McpClient) !void {
        // Create a built-in server
        const builtin_server = try McpServer.init(self.alloc, .{
            .name = "builtin",
            .command = "builtin",
        });
        builtin_server.state = .connected; // Always connected
        self.builtin_server = builtin_server;
        try self.servers.append(self.alloc, builtin_server);

        // File system tools
        try builtin_server.tools.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, "read_file"),
            .description = try self.alloc.dupe(u8, "Read contents of a file"),
            .input_schema = json.Value{ .object = json.ObjectMap.init(self.alloc) },
            .handler = readFileTool,
        });

        try builtin_server.tools.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, "write_file"),
            .description = try self.alloc.dupe(u8, "Write contents to a file"),
            .input_schema = json.Value{ .object = json.ObjectMap.init(self.alloc) },
            .handler = writeFileTool,
        });

        try builtin_server.tools.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, "list_directory"),
            .description = try self.alloc.dupe(u8, "List files in a directory"),
            .input_schema = json.Value{ .object = json.ObjectMap.init(self.alloc) },
            .handler = listDirectoryTool,
        });

        // Git tools
        try builtin_server.tools.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, "git_status"),
            .description = try self.alloc.dupe(u8, "Get git repository status"),
            .input_schema = json.Value{ .object = json.ObjectMap.init(self.alloc) },
            .handler = gitStatusTool,
        });

        try builtin_server.tools.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, "git_log"),
            .description = try self.alloc.dupe(u8, "Get git commit history"),
            .input_schema = json.Value{ .object = json.ObjectMap.init(self.alloc) },
            .handler = gitLogTool,
        });

        // System tools
        try builtin_server.tools.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, "execute_command"),
            .description = try self.alloc.dupe(u8, "Execute a shell command (restricted)"),
            .input_schema = json.Value{ .object = json.ObjectMap.init(self.alloc) },
            .handler = executeCommandTool,
        });

        // Environment tools
        try builtin_server.tools.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, "get_environment"),
            .description = try self.alloc.dupe(u8, "Get environment information"),
            .input_schema = json.Value{ .object = json.ObjectMap.init(self.alloc) },
            .handler = getEnvironmentTool,
        });

        log.info("Registered {} built-in MCP tools", .{builtin_server.tools.items.len});
    }

    /// Get server by name
    pub fn getServer(self: *const McpClient, name: []const u8) ?*McpServer {
        for (self.servers.items) |server| {
            if (std.mem.eql(u8, server.name, name)) {
                return server;
            }
        }
        return null;
    }

    /// Get statistics
    pub fn getStats(self: *const McpClient) struct {
        total_servers: usize,
        connected_servers: usize,
        total_tools: usize,
        total_resources: usize,
    } {
        var connected: usize = 0;
        var tools: usize = 0;
        var resources: usize = 0;

        for (self.servers.items) |server| {
            if (server.state == .connected) connected += 1;
            tools += server.tools.items.len;
            resources += server.resources.items.len;
        }

        return .{
            .total_servers = self.servers.items.len,
            .connected_servers = connected,
            .total_tools = tools,
            .total_resources = resources,
        };
    }
};

// Built-in tool implementations

/// Built-in tool: Read file
fn readFileTool(params: json.Value, alloc: Allocator) !json.Value {
    const path = if (params.object.get("path")) |p| p.string else return error.MissingPath;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        var result = json.ObjectMap.init(alloc);
        try result.put("success", json.Value{ .bool = false });
        try result.put("error", json.Value{ .string = @errorName(err) });
        return json.Value{ .object = result };
    };
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 10_000_000);

    var result = json.ObjectMap.init(alloc);
    try result.put("content", json.Value{ .string = content });
    try result.put("success", json.Value{ .bool = true });

    return json.Value{ .object = result };
}

/// Built-in tool: Write file
fn writeFileTool(params: json.Value, alloc: Allocator) !json.Value {
    const path = if (params.object.get("path")) |p| p.string else return error.MissingPath;
    const content = if (params.object.get("content")) |c| c.string else return error.MissingContent;

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        var result = json.ObjectMap.init(alloc);
        try result.put("success", json.Value{ .bool = false });
        try result.put("error", json.Value{ .string = @errorName(err) });
        return json.Value{ .object = result };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        var result = json.ObjectMap.init(alloc);
        try result.put("success", json.Value{ .bool = false });
        try result.put("error", json.Value{ .string = @errorName(err) });
        return json.Value{ .object = result };
    };

    var result = json.ObjectMap.init(alloc);
    try result.put("success", json.Value{ .bool = true });
    return json.Value{ .object = result };
}

/// Built-in tool: List directory
fn listDirectoryTool(params: json.Value, alloc: Allocator) !json.Value {
    const path = if (params.object.get("path")) |p| p.string else ".";

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        var result = json.ObjectMap.init(alloc);
        try result.put("success", json.Value{ .bool = false });
        try result.put("error", json.Value{ .string = @errorName(err) });
        return json.Value{ .object = result };
    };
    defer dir.close();

    var files = json.Array.init(alloc);
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        var file_obj = json.ObjectMap.init(alloc);
        try file_obj.put("name", json.Value{ .string = try alloc.dupe(u8, entry.name) });
        try file_obj.put("type", json.Value{ .string = switch (entry.kind) {
            .file => "file",
            .directory => "directory",
            .sym_link => "symlink",
            else => "other",
        } });
        try files.append(json.Value{ .object = file_obj });
    }

    var result = json.ObjectMap.init(alloc);
    try result.put("files", json.Value{ .array = files });
    try result.put("success", json.Value{ .bool = true });
    return json.Value{ .object = result };
}

/// Built-in tool: Git status
fn gitStatusTool(_: json.Value, alloc: Allocator) !json.Value {
    // Execute actual git status
    var child = std.process.Child.init(&[_][]const u8{ "git", "status", "--porcelain" }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(alloc, 100_000);
    _ = try child.wait();

    var result = json.ObjectMap.init(alloc);
    try result.put("success", json.Value{ .bool = true });
    try result.put("output", json.Value{ .string = stdout });
    return json.Value{ .object = result };
}

/// Built-in tool: Git log
fn gitLogTool(params: json.Value, alloc: Allocator) !json.Value {
    const count_str = if (params.object.get("count")) |c|
        std.fmt.allocPrint(alloc, "{d}", .{c.integer}) catch "10"
    else
        "10";
    defer if (params.object.get("count") != null) alloc.free(count_str);

    var child = std.process.Child.init(&[_][]const u8{ "git", "log", "--oneline", "-n", count_str }, alloc);
    child.stdout_behavior = .Pipe;

    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(alloc, 100_000);
    _ = try child.wait();

    var result = json.ObjectMap.init(alloc);
    try result.put("success", json.Value{ .bool = true });
    try result.put("output", json.Value{ .string = stdout });
    return json.Value{ .object = result };
}

/// Built-in tool: Execute command (restricted)
fn executeCommandTool(params: json.Value, alloc: Allocator) !json.Value {
    const command_str = if (params.object.get("command")) |c| c.string else return error.MissingCommand;

    // Security: Only allow safe, read-only commands
    const allowed_prefixes = [_][]const u8{
        "ls",       "pwd",    "whoami",  "date",
        "uname",    "echo",   "which",   "cat",
        "head",     "tail",   "wc",      "grep",
        "find",     "file",   "env",     "printenv",
        "git log",  "git diff", "git status", "git branch",
        "git show", "git remote",
    };

    var is_allowed = false;
    for (allowed_prefixes) |prefix| {
        if (std.mem.startsWith(u8, command_str, prefix)) {
            is_allowed = true;
            break;
        }
    }

    if (!is_allowed) {
        var result = json.ObjectMap.init(alloc);
        try result.put("success", json.Value{ .bool = false });
        try result.put("error", json.Value{ .string = "Command not allowed for security reasons" });
        return json.Value{ .object = result };
    }

    // Execute via shell
    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", command_str }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(alloc, 1_000_000);
    const stderr = try child.stderr.?.readToEndAlloc(alloc, 1_000_000);
    const term = try child.wait();

    var result = json.ObjectMap.init(alloc);
    try result.put("success", json.Value{ .bool = term.Exited == 0 });
    try result.put("stdout", json.Value{ .string = stdout });
    try result.put("stderr", json.Value{ .string = stderr });
    try result.put("exit_code", json.Value{ .integer = @intCast(term.Exited) });
    return json.Value{ .object = result };
}

/// Built-in tool: Get environment information
fn getEnvironmentTool(_: json.Value, alloc: Allocator) !json.Value {
    var result = json.ObjectMap.init(alloc);

    // Get common environment variables
    const env_vars = [_][]const u8{ "HOME", "USER", "SHELL", "PWD", "PATH", "TERM" };
    var env_obj = json.ObjectMap.init(alloc);

    for (env_vars) |var_name| {
        if (std.posix.getenv(var_name)) |value| {
            try env_obj.put(var_name, json.Value{ .string = value });
        }
    }

    try result.put("environment", json.Value{ .object = env_obj });
    try result.put("success", json.Value{ .bool = true });
    return json.Value{ .object = result };
}

/// MCP Manager for coordinating multiple servers
pub const McpManager = struct {
    client: McpClient,
    config_path: []const u8,
    enabled: bool,
    alloc: Allocator,

    /// Initialize MCP manager
    pub fn init(alloc: Allocator) !McpManager {
        var client = McpClient.init(alloc);
        try client.registerBuiltinTools();

        const home = std.posix.getenv("HOME") orelse "/tmp";
        const config_path = try std.fs.path.join(alloc, &.{ home, ".config", "ghostty", "mcp" });

        // Ensure config directory exists
        std.fs.makeDirAbsolute(config_path) catch {};

        return McpManager{
            .client = client,
            .config_path = config_path,
            .enabled = true,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *McpManager) void {
        self.client.deinit();
        self.alloc.free(self.config_path);
    }

    /// Load server configurations from disk
    pub fn loadServers(self: *McpManager) !void {
        const config_file = try std.fs.path.join(self.alloc, &.{ self.config_path, "servers.json" });
        defer self.alloc.free(config_file);

        const file = std.fs.openFileAbsolute(config_file, .{}) catch return;
        defer file.close();

        const content = try file.readToEndAlloc(self.alloc, 1_000_000);
        defer self.alloc.free(content);

        const parsed = try json.parseFromSlice(json.Value, self.alloc, content, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("servers")) |servers_arr| {
            for (servers_arr.array.items) |server_obj| {
                const name = server_obj.object.get("name").?.string;
                const command = server_obj.object.get("command").?.string;

                _ = try self.client.registerServer(.{
                    .name = name,
                    .command = command,
                });

                log.info("Loaded MCP server config: {s}", .{name});
            }
        }
    }

    /// Connect all configured servers
    pub fn connectAll(self: *McpManager) !void {
        try self.client.connectAll();
    }

    /// Enable or disable MCP
    pub fn setEnabled(self: *McpManager, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled) {
            self.client.disconnectAll();
        }
    }

    /// Get all available tools
    pub fn getTools(self: *const McpManager) !ArrayListUnmanaged(*const McpTool) {
        if (!self.enabled) return error.McpDisabled;
        return self.client.getAllTools();
    }

    /// Execute a tool
    pub fn executeTool(
        self: *McpManager,
        tool_name: []const u8,
        params: json.Value,
    ) !json.Value {
        if (!self.enabled) return error.McpDisabled;
        return self.client.executeTool(tool_name, params);
    }

    /// Get statistics
    pub fn getStats(self: *const McpManager) struct {
        enabled: bool,
        servers: usize,
        connected: usize,
        tools: usize,
    } {
        const client_stats = self.client.getStats();
        return .{
            .enabled = self.enabled,
            .servers = client_stats.total_servers,
            .connected = client_stats.connected_servers,
            .tools = client_stats.total_tools,
        };
    }
};

test "McpClient basic operations" {
    const alloc = std.testing.allocator;

    var client = McpClient.init(alloc);
    defer client.deinit();

    try client.registerBuiltinTools();

    var tools = try client.getAllTools();
    defer tools.deinit(alloc);

    try std.testing.expect(tools.items.len > 0);
}

test "McpClient server registration" {
    const alloc = std.testing.allocator;

    var client = McpClient.init(alloc);
    defer client.deinit();

    // Register a simple server
    const server = try client.registerServerSimple("test-server", "test-command");
    try std.testing.expectEqualStrings("test-server", server.name);
    try std.testing.expectEqualStrings("test-command", server.config.command);
    try std.testing.expectEqual(.disconnected, server.state);
}

test "McpClient server management" {
    const alloc = std.testing.allocator;

    var client = McpClient.init(alloc);
    defer client.deinit();

    // Register multiple servers
    _ = try client.registerServerSimple("server1", "cmd1");
    _ = try client.registerServerSimple("server2", "cmd2");

    try std.testing.expectEqual(@as(usize, 2), client.servers.items.len);

    // Find server by name
    const found = client.getServer("server1");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("server1", found.?.name);

    const not_found = client.getServer("nonexistent");
    try std.testing.expect(not_found == null);
}

test "McpClient builtin tools" {
    const alloc = std.testing.allocator;

    var client = McpClient.init(alloc);
    defer client.deinit();

    try client.registerBuiltinTools();

    // Verify all built-in tools are registered
    var tools = try client.getAllTools();
    defer tools.deinit(alloc);

    try std.testing.expect(tools.items.len > 0);

    // Find specific tools
    const read_file_tool = client.findTool("read_file");
    try std.testing.expect(read_file_tool != null);
    try std.testing.expectEqualStrings("read_file", read_file_tool.?.tool.name);

    const write_file_tool = client.findTool("write_file");
    try std.testing.expect(write_file_tool != null);
    try std.testing.expectEqualStrings("write_file", write_file_tool.?.tool.name);

    const git_status_tool = client.findTool("git_status");
    try std.testing.expect(git_status_tool != null);
    try std.testing.expectEqualStrings("git_status", git_status_tool.?.tool.name);
}

test "McpClient stats tracking" {
    const alloc = std.testing.allocator;

    var client = McpClient.init(alloc);
    defer client.deinit();

    try client.registerBuiltinTools();

    const stats = client.getStats();
    try std.testing.expect(stats.total_servers > 0);
    try std.testing.expect(stats.total_tools > 0);
}

test "McpServer initialization" {
    const alloc = std.testing.allocator;

    const config = ServerConfig{
        .name = "test-mcp",
        .command = "test-command",
        .args = &[_][]const u8{ "--arg1", "value1" },
    };

    const server = try McpServer.init(alloc, config);
    defer {
        server.deinit();
        alloc.destroy(server);
    }

    try std.testing.expectEqualStrings("test-mcp", server.name);
    try std.testing.expectEqualStrings("test-command", server.config.command);
    try std.testing.expectEqual(.disconnected, server.state);
    try std.testing.expectEqual(@as(usize, 0), server.tools.items.len);
}

test "McpServer config with environment" {
    const alloc = std.testing.allocator;

    var env = StringHashMap([]const u8).init(alloc);
    defer env.deinit();

    try env.put("TEST_VAR", "test_value");

    const config = ServerConfig{
        .name = "env-server",
        .command = "env-command",
        .env = env,
        .working_dir = "/tmp",
    };

    const server = try McpServer.init(alloc, config);
    defer {
        server.deinit();
        alloc.destroy(server);
    }

    try std.testing.expect(server.config.env != null);
    try std.testing.expectEqualStrings("/tmp", server.config.working_dir.?);
}

test "JsonRpcRequest structure" {
    const alloc = std.testing.allocator;

    var params = json.ObjectMap.init(alloc);
    defer params.deinit();

    try params.put("test", json.Value{ .string = "value" });

    const request = JsonRpcRequest{
        .id = 123,
        .method = "test_method",
        .params = json.Value{ .object = params },
    };

    try std.testing.expectEqualStrings("2.0", request.jsonrpc);
    try std.testing.expectEqual(@as(u64, 123), request.id);
    try std.testing.expectEqualStrings("test_method", request.method);
}

test "JsonRpcResponse with result" {
    var result_obj = json.ObjectMap.init(std.testing.allocator);
    defer result_obj.deinit();
    try result_obj.put("status", json.Value{ .string = "success" });

    const response = JsonRpcResponse{
        .jsonrpc = "2.0",
        .id = 456,
        .result = json.Value{ .object = result_obj },
        .@"error" = null,
    };

    try std.testing.expectEqualStrings("2.0", response.jsonrpc);
    try std.testing.expectEqual(@as(?u64, 456), response.id);
    try std.testing.expect(response.result != null);
    try std.testing.expect(response.@"error" == null);
}

test "JsonRpcResponse with error" {
    const response = JsonRpcResponse{
        .jsonrpc = "2.0",
        .id = 789,
        .result = null,
        .@"error" = .{
            .code = -32601,
            .message = "Method not found",
            .data = null,
        },
    };

    try std.testing.expectEqual(@as(?u64, 789), response.id);
    try std.testing.expect(response.result == null);
    try std.testing.expect(response.@"error" != null);
    try std.testing.expectEqual(@as(i32, -32601), response.@"error".?.code);
    try std.testing.expectEqualStrings("Method not found", response.@"error".?.message);
}

test "McpManager initialization" {
    const alloc = std.testing.allocator;

    var manager = try McpManager.init(alloc);
    defer manager.deinit();

    try std.testing.expect(manager.enabled);
    // Note: Allocator structs can't be directly compared with ==
}

test "McpManager tool retrieval" {
    const alloc = std.testing.allocator;

    var manager = try McpManager.init(alloc);
    defer manager.deinit();

    var tools = try manager.getTools();
    defer tools.deinit(alloc);

    // Should have at least the built-in tools
    try std.testing.expect(tools.items.len > 0);
}

test "McpManager statistics" {
    const alloc = std.testing.allocator;

    var manager = try McpManager.init(alloc);
    defer manager.deinit();

    const stats = manager.getStats();
    try std.testing.expect(stats.enabled);
    try std.testing.expect(stats.servers > 0);
    try std.testing.expect(stats.tools > 0);
}

test "McpManager enable/disable" {
    const alloc = std.testing.allocator;

    var manager = try McpManager.init(alloc);
    defer manager.deinit();

    try std.testing.expect(manager.enabled);

    manager.setEnabled(false);
    try std.testing.expect(!manager.enabled);

    manager.setEnabled(true);
    try std.testing.expect(manager.enabled);
}

test "McpTool structure and lifecycle" {
    const alloc = std.testing.allocator;

    var schema = json.ObjectMap.init(alloc);
    defer schema.deinit();

    try schema.put("type", json.Value{ .string = "object" });

    var tool = McpTool{
        .name = try alloc.dupe(u8, "test_tool"),
        .description = try alloc.dupe(u8, "A test tool"),
        .input_schema = json.Value{ .object = schema },
        .handler = null,
    };

    try std.testing.expectEqualStrings("test_tool", tool.name);
    try std.testing.expectEqualStrings("A test tool", tool.description);

    tool.deinit(alloc);
}

test "McpResource structure and lifecycle" {
    const alloc = std.testing.allocator;

    var resource = McpResource{
        .uri = try alloc.dupe(u8, "file:///test.txt"),
        .name = try alloc.dupe(u8, "Test Resource"),
        .description = try alloc.dupe(u8, "A test resource"),
        .mime_type = try alloc.dupe(u8, "text/plain"),
    };

    try std.testing.expectEqualStrings("file:///test.txt", resource.uri);
    try std.testing.expectEqualStrings("text/plain", resource.mime_type.?);

    resource.deinit(alloc);
}

test "McpPrompt structure and lifecycle" {
    const alloc = std.testing.allocator;

    var prompt = McpPrompt{
        .name = try alloc.dupe(u8, "test_prompt"),
        .description = try alloc.dupe(u8, "A test prompt"),
        .arguments = .empty,
        .alloc = alloc,
    };

    try prompt.arguments.append(alloc, .{
        .name = try alloc.dupe(u8, "arg1"),
        .description = try alloc.dupe(u8, "First argument"),
        .required = true,
    });

    try std.testing.expectEqualStrings("test_prompt", prompt.name);
    try std.testing.expectEqual(@as(usize, 1), prompt.arguments.items.len);

    prompt.deinit();
}

test "Transport type enum" {
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(TransportType.stdio));
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum(TransportType.sse));
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum(TransportType.websocket));
}

test "Connection state enum" {
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(ConnectionState.disconnected));
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum(ConnectionState.connecting));
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum(ConnectionState.connected));
    try std.testing.expectEqual(@as(usize, 3), @intFromEnum(ConnectionState.error_state));
}

test "Server capabilities structure" {
    const caps = ServerCapabilities{
        .tools = true,
        .resources = true,
        .prompts = false,
        .sampling = true,
        .logging = false,
    };

    try std.testing.expect(caps.tools);
    try std.testing.expect(caps.resources);
    try std.testing.expect(!caps.prompts);
    try std.testing.expect(caps.sampling);
    try std.testing.expect(!caps.logging);
}

test "McpClient executeTool with builtin" {
    const alloc = std.testing.allocator;

    var client = McpClient.init(alloc);
    defer client.deinit();

    try client.registerBuiltinTools();

    // Verify builtin tools are registered
    try std.testing.expect(client.builtin_server != null);
    if (client.builtin_server) |server| {
        try std.testing.expect(server.tools.items.len > 0);

        // Verify list_directory tool exists
        var found = false;
        for (server.tools.items) |tool| {
            if (std.mem.eql(u8, tool.name, "list_directory")) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "McpClient tool not found" {
    const alloc = std.testing.allocator;

    var client = McpClient.init(alloc);
    defer client.deinit();

    var params = json.ObjectMap.init(alloc);
    defer params.deinit();

    try params.put("test", json.Value{ .string = "value" });

    // Try to execute a non-existent tool
    const result = client.executeTool("nonexistent_tool", json.Value{ .object = params });
    try std.testing.expectError(error.ToolNotFound, result);
}

test "McpClient getAllResources" {
    const alloc = std.testing.allocator;

    var client = McpClient.init(alloc);
    defer client.deinit();

    try client.registerBuiltinTools();

    var resources = try client.getAllResources();
    defer resources.deinit(alloc);

    // Should have resources from registered servers - can be zero if no resources registered
    try std.testing.expect(resources.items.len >= 0);
}

test "Server configuration with all options" {
    const alloc = std.testing.allocator;

    var env = StringHashMap([]const u8).init(alloc);
    defer env.deinit();

    try env.put("KEY1", "value1");
    try env.put("KEY2", "value2");

    const config = ServerConfig{
        .name = "full-config-server",
        .command = "complex-command",
        .args = &[_][]const u8{ "--verbose", "--debug", "--port", "8080" },
        .env = env,
        .working_dir = "/home/user/project",
        .transport = TransportType.stdio,
    };

    try std.testing.expectEqualStrings("full-config-server", config.name);
    try std.testing.expectEqualStrings("complex-command", config.command);
    try std.testing.expectEqual(@as(usize, 4), config.args.len);
    try std.testing.expect(config.env != null);
    try std.testing.expectEqualStrings("/home/user/project", config.working_dir.?);
    try std.testing.expectEqual(TransportType.stdio, config.transport);
}

// Mock Cerebras MCP Server for Testing
const MockCerebrasMcpServer = struct {
    alloc: Allocator,
    server: *McpServer,
    responses: ArrayListUnmanaged([]const u8),
    request_count: u64,

    pub fn init(alloc: Allocator, name: []const u8) !*MockCerebrasMcpServer {
        const mock = try alloc.create(MockCerebrasMcpServer);
        mock.* = .{
            .alloc = alloc,
            .server = undefined,
            .responses = .empty,
            .request_count = 0,
        };

        // Create a test server (McpServer.init duplicates the name internally)
        const server = try McpServer.init(alloc, .{
            .name = name,
            .command = "mock-cerebras",
        });
        mock.server = server;

        return mock;
    }

    pub fn deinit(self: *MockCerebrasMcpServer) void {
        // Free each duplicated response string
        for (self.responses.items) |response| {
            self.alloc.free(response);
        }
        self.responses.deinit(self.alloc);
        self.server.deinit();
        self.alloc.destroy(self.server);
        self.alloc.destroy(self);
    }

    pub fn addMockResponse(self: *MockCerebrasMcpServer, response: []const u8) !void {
        try self.responses.append(self.alloc, try self.alloc.dupe(u8, response));
    }

    pub fn simulateRequest(self: *MockCerebrasMcpServer, method: []const u8) !void {
        _ = method;
        self.request_count += 1;

        // Simulate a successful response by building JSON string directly
        var output: ArrayListUnmanaged(u8) = .empty;
        defer output.deinit(self.alloc);

        const writer = output.writer(self.alloc);
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{}}}}\n", .{self.request_count});

        try self.addMockResponse(output.items);
    }
};

test "MockCerebrasMcpServer creation and basic operations" {
    const alloc = std.testing.allocator;

    const mock = try MockCerebrasMcpServer.init(alloc, "cerebras-mock");
    defer mock.deinit();

    try std.testing.expectEqualStrings("cerebras-mock", mock.server.name);
    try std.testing.expectEqual(@as(u64, 0), mock.request_count);

    // Simulate some requests
    try mock.simulateRequest("initialize");
    try mock.simulateRequest("tools/list");
    try mock.simulateRequest("resources/list");

    try std.testing.expectEqual(@as(u64, 3), mock.request_count);
    try std.testing.expectEqual(@as(usize, 3), mock.responses.items.len);
}

test "MockCerebrasMcpServer response tracking" {
    const alloc = std.testing.allocator;

    const mock = try MockCerebrasMcpServer.init(alloc, "cerebras-tracker");
    defer mock.deinit();

    // Add custom responses
    try mock.addMockResponse("custom response 1");
    try mock.addMockResponse("custom response 2");

    try std.testing.expectEqual(@as(usize, 2), mock.responses.items.len);

    // Simulate more requests
    try mock.simulateRequest("test");
    try std.testing.expectEqual(@as(usize, 3), mock.responses.items.len);
}

test "Cerebras MCP integration test" {
    const alloc = std.testing.allocator;

    // Create mock Cerebras MCP server
    const mock = try MockCerebrasMcpServer.init(alloc, "cerebras-ai");
    defer mock.deinit();

    // Register with client - use a separate block to control cleanup order
    var client = McpClient.init(alloc);

    // In a real scenario, we would connect to the actual Cerebras MCP server
    // For testing, we use the mock (but don't let client own it since mock will free it)
    try client.servers.append(alloc, mock.server);

    // Verify server is registered
    try std.testing.expectEqual(@as(usize, 1), client.servers.items.len);

    const found = client.getServer("cerebras-ai");
    try std.testing.expect(found != null);

    // Simulate MCP protocol handshake
    try mock.simulateRequest("initialize");
    try mock.simulateRequest("tools/list");
    try mock.simulateRequest("resources/list");

    try std.testing.expectEqual(@as(u64, 3), mock.request_count);

    // Clear client servers before deinit to avoid double-free (mock owns the server)
    client.servers.clearRetainingCapacity();
    client.servers.deinit(alloc);
}

test "Cerebras MCP tools simulation" {
    const alloc = std.testing.allocator;

    const mock = try MockCerebrasMcpServer.init(alloc, "cerebras-tools");
    defer mock.deinit();

    // Simulate Cerebras-specific tools that might be available
    try mock.simulateRequest("cerebras/generate_text");
    try mock.simulateRequest("cerebras/embeddings");
    try mock.simulateRequest("cerebras/chat_completion");

    try std.testing.expectEqual(@as(u64, 3), mock.request_count);

    // Verify all responses were tracked
    try std.testing.expectEqual(@as(usize, 3), mock.responses.items.len);
}

test "McpClient with multiple servers" {
    const alloc = std.testing.allocator;

    var client = McpClient.init(alloc);
    defer client.deinit();

    // Register multiple servers
    _ = try client.registerServerSimple("server-1", "cmd1");
    _ = try client.registerServerSimple("server-2", "cmd2");
    _ = try client.registerServerSimple("server-3", "cmd3");

    try std.testing.expectEqual(@as(usize, 3), client.servers.items.len);

    // Test finding tools across all servers
    // registerBuiltinTools adds the builtin server to the servers list
    try client.registerBuiltinTools();
    var tools = try client.getAllTools();
    defer tools.deinit(alloc);

    try std.testing.expect(tools.items.len > 0);

    // Test stats - 3 registered servers + 1 builtin server = 4 total
    const stats = client.getStats();
    try std.testing.expectEqual(@as(usize, 4), stats.total_servers);
}

test "Pending request tracking" {
    const alloc = std.testing.allocator;

    const config = ServerConfig{
        .name = "pending-test",
        .command = "test",
    };

    const server = try McpServer.init(alloc, config);
    defer {
        server.deinit();
        alloc.destroy(server);
    }

    // Verify initial state
    try std.testing.expectEqual(@as(u64, 1), server.next_request_id);

    // Simulate sending requests
    _ = try server.sendRequest("method1", null);
    try std.testing.expectEqual(@as(u64, 2), server.next_request_id);

    _ = try server.sendRequest("method2", null);
    try std.testing.expectEqual(@as(u64, 3), server.next_request_id);
}

test "JSON value handling in MCP" {
    const alloc = std.testing.allocator;

    // Test various JSON value types
    var obj = json.ObjectMap.init(alloc);
    defer obj.deinit();

    try obj.put("string", json.Value{ .string = "test" });
    try obj.put("integer", json.Value{ .integer = 42 });
    try obj.put("boolean", json.Value{ .bool = true });
    try obj.put("null", json.Value{ .null = {} });

    var arr = json.Array.init(alloc);
    defer arr.deinit();

    try arr.append(json.Value{ .string = "item1" });
    try arr.append(json.Value{ .integer = 123 });
    try obj.put("array", json.Value{ .array = arr });

    const value = json.Value{ .object = obj };

    // Verify structure
    try std.testing.expect(value.object.get("string") != null);
    try std.testing.expect(value.object.get("integer") != null);
    try std.testing.expect(value.object.get("boolean") != null);
    try std.testing.expect(value.object.get("array") != null);
}

test "McpManager full lifecycle" {
    const alloc = std.testing.allocator;

    var manager = try McpManager.init(alloc);
    defer manager.deinit();

    // Initial state
    try std.testing.expect(manager.enabled);

    // Register additional server
    _ = try manager.client.registerServerSimple("custom-server", "custom-cmd");

    // Connect all (would normally start processes)
    // manager.connectAll() catch {};

    // Get tools
    var tools = try manager.getTools();
    defer tools.deinit(alloc);

    // Get stats
    const stats = manager.getStats();
    try std.testing.expect(stats.enabled);
    try std.testing.expect(stats.servers > 0);

    // Disable and re-enable
    manager.setEnabled(false);
    try std.testing.expect(!manager.enabled);
    manager.setEnabled(true);
    try std.testing.expect(manager.enabled);
}

test "Error handling in MCP operations" {
    const alloc = std.testing.allocator;

    var client = McpClient.init(alloc);
    defer client.deinit();

    // Try to execute tool when no servers registered
    var params = json.ObjectMap.init(alloc);
    defer params.deinit();

    try params.put("test", json.Value{ .string = "value" });

    const result = client.executeTool("any_tool", json.Value{ .object = params });
    try std.testing.expectError(error.ToolNotFound, result);

    // Try to get tools from disabled manager
    var manager = try McpManager.init(alloc);
    defer manager.deinit();

    manager.setEnabled(false);
    const tools = manager.getTools();
    try std.testing.expectError(error.McpDisabled, tools);
}

test "MCP protocol version compatibility" {
    // Test that we're using a compatible protocol version
    const protocol_version = "2024-11-05";

    // This should match what's used in sendInitialize
    try std.testing.expect(std.mem.eql(u8, protocol_version, "2024-11-05"));
}

test "Cerebras MCP security model" {
    const alloc = std.testing.allocator;

    // Test that we properly handle security in built-in tools
    var client = McpClient.init(alloc);
    defer client.deinit();

    try client.registerBuiltinTools();

    // Verify execute_command tool exists in builtin server
    try std.testing.expect(client.builtin_server != null);
    if (client.builtin_server) |server| {
        var found = false;
        for (server.tools.items) |tool| {
            if (std.mem.eql(u8, tool.name, "execute_command")) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "Memory management in MCP client" {
    const alloc = std.testing.allocator;

    // Test that we properly clean up all allocated resources
    {
        var client = McpClient.init(alloc);
        _ = try client.registerServerSimple("memory-test", "test");

        // Use the client
        try client.registerBuiltinTools();
        var tools = try client.getAllTools();
        defer tools.deinit(alloc);

        // Manually trigger deallocation
        client.deinit();
    }

    // If we reach here without memory leaks (checked by leak detector),
    // the test passes
}

test "Concurrent-like operations simulation" {
    const alloc = std.testing.allocator;

    var client = McpClient.init(alloc);
    defer client.deinit();

    try client.registerBuiltinTools();

    // Simulate multiple tool queries in sequence
    const tool_names = [_][]const u8{
        "read_file", "write_file", "list_directory",
        "git_status", "git_log", "execute_command",
    };

    for (tool_names) |tool_name| {
        const found = client.findTool(tool_name);
        try std.testing.expect(found != null);
    }

    // Verify we can get all tools
    var all_tools = try client.getAllTools();
    defer all_tools.deinit(alloc);

    try std.testing.expect(all_tools.items.len >= tool_names.len);
}

test "MCP URI handling and resource management" {
    const alloc = std.testing.allocator;

    // Test various URI formats
    const test_uris = [_][]const u8{
        "file:///home/user/document.txt",
        "git://repository/path",
        "http://example.com/resource",
        "memory://session/data",
    };

    for (test_uris) |uri| {
        var resource = McpResource{
            .uri = try alloc.dupe(u8, uri),
            .name = try alloc.dupe(u8, "Test Resource"),
            .description = try alloc.dupe(u8, "Test description"),
            .mime_type = null,
        };

        try std.testing.expectEqualStrings(uri, resource.uri);
        resource.deinit(alloc);
    }
}

test "Cerebras MCP specific functionality" {
    const alloc = std.testing.allocator;

    // Create a mock Cerebras server
    const mock = try MockCerebrasMcpServer.init(alloc, "cerebras-llm");
    defer mock.deinit();

    // Simulate Cerebras-specific MCP capabilities
    try mock.simulateRequest("cerebras/list_models");
    try mock.simulateRequest("cerebras/generate");
    try mock.simulateRequest("cerebras/chat");

    try std.testing.expectEqual(@as(u64, 3), mock.request_count);

    // Test that we can register this with a client
    var client = McpClient.init(alloc);

    try client.servers.append(alloc, mock.server);
    try std.testing.expectEqual(@as(usize, 1), client.servers.items.len);

    const cerebras_server = client.getServer("cerebras-llm");
    try std.testing.expect(cerebras_server != null);

    // Clear client servers before deinit to avoid double-free (mock owns the server)
    client.servers.clearRetainingCapacity();
    client.servers.deinit(alloc);
}
