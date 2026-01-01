//! Workflows and Templates Module
//!
//! This module provides reusable command sequences (workflows) and templates
//! for common terminal tasks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_workflows);

/// A single command in a workflow
pub const WorkflowCommand = struct {
    /// The command to execute
    command: []const u8,
    /// Description of what this command does
    description: []const u8,
    /// Whether to wait for user confirmation before executing
    requires_confirmation: bool = false,
    /// Expected exit code (if not 0, workflow may stop)
    expected_exit_code: ?i32 = null,
    /// Whether to continue workflow if this command fails
    continue_on_error: bool = false,
};

/// A workflow - a sequence of commands
pub const Workflow = struct {
    /// Unique identifier for the workflow
    id: []const u8,
    /// Human-readable name
    name: []const u8,
    /// Description of what this workflow does
    description: []const u8,
    /// Commands in the workflow
    commands: ArrayList(WorkflowCommand),
    /// Tags for categorization
    tags: ArrayList([]const u8),
    /// Created timestamp
    created_at: i64,
    /// Last used timestamp
    last_used: i64,
    /// Usage count
    usage_count: u32,

    pub fn init(alloc: Allocator, id: []const u8, name: []const u8) Workflow {
        return .{
            .id = id,
            .name = name,
            .description = "",
            .commands = ArrayList(WorkflowCommand).init(alloc),
            .tags = ArrayList([]const u8).init(alloc),
            .created_at = std.time.timestamp(),
            .last_used = 0,
            .usage_count = 0,
        };
    }

    pub fn deinit(self: *Workflow, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.description);
        for (self.commands.items) |cmd| {
            alloc.free(cmd.command);
            alloc.free(cmd.description);
        }
        self.commands.deinit();
        for (self.tags.items) |tag| alloc.free(tag);
        self.tags.deinit();
    }

    /// Add a command to the workflow
    pub fn addCommand(self: *Workflow, alloc: Allocator, command: []const u8, description: []const u8) !void {
        try self.commands.append(.{
            .command = try alloc.dupe(u8, command),
            .description = try alloc.dupe(u8, description),
        });
    }

    /// Mark workflow as used
    pub fn markUsed(self: *Workflow) void {
        self.last_used = std.time.timestamp();
        self.usage_count += 1;
    }
};

/// Workflow execution state
pub const WorkflowExecution = struct {
    workflow: *Workflow,
    current_step: usize = 0,
    completed_steps: ArrayList(usize),
    failed_steps: ArrayList(usize),
    results: ArrayList(?i32), // Exit codes for each command

    pub fn init(alloc: Allocator, workflow: *Workflow) WorkflowExecution {
        return .{
            .workflow = workflow,
            .current_step = 0,
            .completed_steps = ArrayList(usize).init(alloc),
            .failed_steps = ArrayList(usize).init(alloc),
            .results = ArrayList(?i32).init(alloc),
        };
    }

    pub fn deinit(self: *WorkflowExecution) void {
        self.completed_steps.deinit();
        self.failed_steps.deinit();
        self.results.deinit();
    }

    /// Get next command to execute
    pub fn getNextCommand(self: *WorkflowExecution) ?*const WorkflowCommand {
        if (self.current_step >= self.workflow.commands.items.len) return null;
        return &self.workflow.commands.items[self.current_step];
    }

    /// Mark current step as completed
    pub fn markCompleted(self: *WorkflowExecution, exit_code: i32) !void {
        try self.completed_steps.append(self.current_step);
        try self.results.append(exit_code);
        self.current_step += 1;
    }

    /// Mark current step as failed
    pub fn markFailed(self: *WorkflowExecution, exit_code: i32) !void {
        try self.failed_steps.append(self.current_step);
        try self.results.append(exit_code);
        self.current_step += 1;
    }

    /// Check if workflow is complete
    pub fn isComplete(self: *const WorkflowExecution) bool {
        return self.current_step >= self.workflow.commands.items.len;
    }
};

/// Workflow Manager
pub const WorkflowManager = struct {
    alloc: Allocator,
    workflows: StringHashMap(*Workflow),
    storage_path: []const u8,

    /// Initialize workflow manager
    pub fn init(alloc: Allocator) !WorkflowManager {
        const home = std.os.getenv("HOME") orelse return error.HomeNotSet;
        const storage_path = try std.fs.path.join(alloc, &.{ home, ".config", "ghostty", "workflows" });

        // Create directory if it doesn't exist
        std.fs.makeDirAbsolute(storage_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return WorkflowManager{
            .alloc = alloc,
            .workflows = StringHashMap(*Workflow).init(alloc),
            .storage_path = storage_path,
        };
    }

    pub fn deinit(self: *WorkflowManager) void {
        var iter = self.workflows.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.workflows.deinit();
        self.alloc.free(self.storage_path);
    }

    /// Create a new workflow
    pub fn createWorkflow(self: *WorkflowManager, name: []const u8) !*Workflow {
        const id = try std.fmt.allocPrint(self.alloc, "workflow_{d}", .{std.time.timestamp()});
        const workflow = try self.alloc.create(Workflow);
        workflow.* = Workflow.init(self.alloc, id, name);
        workflow.name = try self.alloc.dupe(u8, name);

        try self.workflows.put(id, workflow);
        return workflow;
    }

    /// Get workflow by ID
    pub fn getWorkflow(self: *const WorkflowManager, id: []const u8) ?*Workflow {
        return self.workflows.get(id);
    }

    /// Get all workflows
    pub fn getAllWorkflows(self: *const WorkflowManager) !ArrayList(*Workflow) {
        var result = ArrayList(*Workflow).init(self.alloc);
        var iter = self.workflows.iterator();
        while (iter.next()) |entry| {
            try result.append(entry.value_ptr.*);
        }
        return result;
    }

    /// Search workflows by name or tag
    pub fn searchWorkflows(self: *const WorkflowManager, query: []const u8) !ArrayList(*Workflow) {
        var results = ArrayList(*Workflow).init(self.alloc);
        const lower_query = try self.toLower(query);
        defer self.alloc.free(lower_query);

        var iter = self.workflows.iterator();
        while (iter.next()) |entry| {
            const workflow = entry.value_ptr.*;

            // Check name
            const lower_name = try self.toLower(workflow.name);
            defer self.alloc.free(lower_name);
            if (std.mem.indexOf(u8, lower_name, lower_query) != null) {
                try results.append(workflow);
                continue;
            }

            // Check tags
            for (workflow.tags.items) |tag| {
                const lower_tag = try self.toLower(tag);
                defer self.alloc.free(lower_tag);
                if (std.mem.indexOf(u8, lower_tag, lower_query) != null) {
                    try results.append(workflow);
                    break;
                }
            }
        }

        return results;
    }

    /// Delete a workflow
    pub fn deleteWorkflow(self: *WorkflowManager, id: []const u8) !void {
        if (self.workflows.fetchRemove(id)) |entry| {
            entry.value.deinit(self.alloc);
            self.alloc.destroy(entry.value);
        }
    }

    /// Save workflow to disk
    pub fn saveWorkflow(self: *WorkflowManager, workflow: *const Workflow) !void {
        const file_path = try std.fs.path.join(self.alloc, &.{ self.storage_path, workflow.id });
        defer self.alloc.free(file_path);

        const file = try std.fs.createFileAbsolute(file_path, .{});
        defer file.close();

        const writer = file.writer();

        // Write JSON representation
        try writer.print("{{\"id\":\"{s}\",\"name\":\"{s}\",\"description\":\"{s}\",\"created_at\":{d},\"last_used\":{d},\"usage_count\":{d},\"commands\":[", .{ workflow.id, workflow.name, workflow.description, workflow.created_at, workflow.last_used, workflow.usage_count });

        for (workflow.commands.items, 0..) |cmd, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"command\":\"{s}\",\"description\":\"{s}\",\"requires_confirmation\":{},\"continue_on_error\":{}}}", .{ cmd.command, cmd.description, cmd.requires_confirmation, cmd.continue_on_error });
        }

        try writer.writeAll("],\"tags\":[");
        for (workflow.tags.items, 0..) |tag, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{tag});
        }

        try writer.writeAll("]}");
    }

    /// Load workflow from disk
    pub fn loadWorkflow(self: *WorkflowManager, id: []const u8) !*Workflow {
        const file_path = try std.fs.path.join(self.alloc, &.{ self.storage_path, id });
        defer self.alloc.free(file_path);

        const file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.alloc, 100_000);
        defer self.alloc.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, content, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        const workflow = try self.alloc.create(Workflow);
        errdefer self.alloc.destroy(workflow);

        workflow.* = Workflow.init(
            self.alloc,
            try self.alloc.dupe(u8, obj.get("id").?.string orelse return error.MissingId),
            try self.alloc.dupe(u8, obj.get("name").?.string orelse return error.MissingName),
        );

        if (obj.get("description")) |desc| {
            workflow.description = try self.alloc.dupe(u8, desc.string);
        }

        if (obj.get("created_at")) |ts| {
            workflow.created_at = @intCast(ts.integer);
        }

        if (obj.get("last_used")) |ts| {
            workflow.last_used = @intCast(ts.integer);
        }

        if (obj.get("usage_count")) |count| {
            workflow.usage_count = @intCast(count.integer);
        }

        // Load commands
        if (obj.get("commands")) |cmds| {
            for (cmds.array.items) |cmd_val| {
                const cmd_obj = cmd_val.object;
                const cmd_str = cmd_obj.get("command").?.string orelse continue;
                const desc_str = cmd_obj.get("description").?.string orelse "";
                try workflow.addCommand(self.alloc, cmd_str, desc_str);
            }
        }

        // Load tags
        if (obj.get("tags")) |tags| {
            for (tags.array.items) |tag_val| {
                try workflow.tags.append(try self.alloc.dupe(u8, tag_val.string));
            }
        }

        try self.workflows.put(workflow.id, workflow);
        return workflow;
    }

    /// Load all workflows from disk with validation
    pub fn loadAllWorkflows(self: *WorkflowManager) !void {
        const dir = try std.fs.openDirAbsolute(self.storage_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                // Validate filename to prevent directory traversal
                if (self.isValidWorkflowFilename(entry.name)) {
                    _ = self.loadWorkflow(entry.name) catch |err| {
                        log.warn("Failed to load workflow {s}: {}", .{ entry.name, err });
                    };
                } else {
                    log.warn("Skipping invalid workflow filename: {s}", .{entry.name});
                }
            }
        }
    }

    /// Validate workflow filename to prevent directory traversal attacks
    fn isValidWorkflowFilename(self: *const WorkflowManager, filename: []const u8) bool {
        _ = self;

        // Check for path separators
        if (std.mem.indexOfAny(u8, filename, &[_]u8{ '/', '\\' }) != null) {
            return false;
        }

        // Check for directory traversal attempts
        if (std.mem.indexOf(u8, filename, "..") != null) {
            return false;
        }

        // Check for hidden files
        if (filename.len > 0 and filename[0] == '.') {
            return false;
        }

        // Check length
        if (filename.len == 0 or filename.len > 255) {
            return false;
        }

        // Only allow alphanumeric, underscore, hyphen, dot
        for (filename) |c| {
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => continue,
                else => return false,
            }
        }

        return true;
    }

    /// Get built-in workflow templates
    pub fn getBuiltinTemplates() []const struct {
        name: []const u8,
        description: []const u8,
        commands: []const []const u8,
    } {
        return &.{
            .{
                .name = "Git Setup",
                .description = "Initialize git repository and make first commit",
                .commands = &.{ "git init", "git add .", "git commit -m \"Initial commit\"" },
            },
            .{
                .name = "Node.js Project Setup",
                .description = "Initialize Node.js project with npm",
                .commands = &.{ "npm init -y", "npm install", "npm run test" },
            },
            .{
                .name = "Docker Build and Run",
                .description = "Build Docker image and run container",
                .commands = &.{ "docker build -t myapp .", "docker run myapp" },
            },
            .{
                .name = "Python Virtual Environment",
                .description = "Create and activate Python virtual environment",
                .commands = &.{ "python -m venv venv", "source venv/bin/activate", "pip install -r requirements.txt" },
            },
        };
    }

    /// Convert string to lowercase
    fn toLower(self: *const WorkflowManager, input: []const u8) ![]const u8 {
        const result = try self.alloc.dupe(u8, input);
        for (result) |*c| {
            c.* = std.ascii.toLower(c.*);
        }
        return result;
    }
};
