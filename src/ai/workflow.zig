//! Workflow Management System
//!
//! This module provides reusable parameterized workflows similar to Warp,
//! allowing users to save, share, and execute common command sequences.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const json = std.json;

/// A parameter in a workflow
pub const Parameter = struct {
    name: []const u8,
    description: []const u8,
    default_value: ?[]const u8,
    required: bool,

    pub fn deinit(self: *const Parameter, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        if (self.default_value) |v| alloc.free(v);
    }
};

/// A saved workflow with parameterized commands
pub const Workflow = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    commands: std.ArrayList([]const u8),
    parameters: std.ArrayList(Parameter),
    tags: std.ArrayList([]const u8),
    created_at: i64,
    updated_at: i64,

    pub fn init(alloc: Allocator, id: []const u8, name: []const u8) Workflow {
        return .{
            .id = id,
            .name = name,
            .description = "",
            .commands = std.ArrayList([]const u8).init(alloc),
            .parameters = std.ArrayList(Parameter).init(alloc),
            .tags = std.ArrayList([]const u8).init(alloc),
            .created_at = std.time.timestamp(),
            .updated_at = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *Workflow, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.description);
        for (self.commands.items) |cmd| alloc.free(cmd);
        self.commands.deinit();
        for (self.parameters.items) |*param| param.deinit(alloc);
        self.parameters.deinit();
        for (self.tags.items) |tag| alloc.free(tag);
        self.tags.deinit();
    }

    /// Render the workflow with provided parameter values
    pub fn render(self: *const Workflow, alloc: Allocator, values: std.StringHashMap([]const u8)) !std.ArrayList([]const u8) {
        var result = std.ArrayList([]const u8).init(alloc);
        errdefer {
            for (result.items) |cmd| alloc.free(cmd);
            result.deinit();
        }

        for (self.commands.items) |cmd| {
            const rendered = try self.substituteParams(alloc, cmd, values);
            try result.append(rendered);
        }

        return result;
    }

    /// Substitute parameter placeholders in a command
    fn substituteParams(
        self: *const Workflow,
        alloc: Allocator,
        template: []const u8,
        values: std.StringHashMap([]const u8),
    ) ![]const u8 {
        var result = std.ArrayList(u8).init(alloc);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < template.len) {
            // Look for {{param_name}}
            if (i + 2 < template.len and template[i] == '{' and template[i + 1] == '{') {
                // Find closing }}
                const start = i + 2;
                var end = start;
                while (end + 1 < template.len) {
                    if (template[end] == '}' and template[end + 1] == '}') {
                        break;
                    }
                    end += 1;
                }

                if (end + 1 < template.len) {
                    const param_name = template[start..end];

                    // Get value or default
                    const value = values.get(param_name) orelse blk: {
                        for (self.parameters.items) |param| {
                            if (std.mem.eql(u8, param.name, param_name)) {
                                break :blk param.default_value orelse "";
                            }
                        }
                        break :blk "";
                    };

                    try result.appendSlice(value);
                    i = end + 2;
                    continue;
                }
            }

            try result.append(template[i]);
            i += 1;
        }

        return result.toOwnedSlice();
    }
};

/// Workflow Manager for saving and loading workflows
pub const WorkflowManager = struct {
    const Self = @This();

    alloc: Allocator,
    workflows_dir: []const u8,
    workflows: std.StringHashMap(*Workflow),

    /// Initialize workflow manager
    pub fn init(alloc: Allocator) !Self {
        const home = std.os.getenv("HOME") orelse return error.HomeNotSet;
        const workflows_path = try fs.path.join(alloc, &.{ home, ".config", "ghostty", "workflows" });

        // Create directory if it doesn't exist
        fs.makeDirAbsolute(workflows_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return Self{
            .alloc = alloc,
            .workflows_dir = workflows_path,
            .workflows = std.StringHashMap(*Workflow).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.workflows.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.workflows.deinit();
        self.alloc.free(self.workflows_dir);
    }

    /// Create a new workflow
    pub fn createWorkflow(self: *Self, name: []const u8) !*Workflow {
        const id = try std.fmt.allocPrint(self.alloc, "wf-{d}", .{std.time.timestamp()});
        const name_copy = try self.alloc.dupe(u8, name);

        const workflow = try self.alloc.create(Workflow);
        workflow.* = Workflow.init(self.alloc, id, name_copy);

        try self.workflows.put(id, workflow);
        return workflow;
    }

    /// Save a workflow to disk
    pub fn saveWorkflow(self: *Self, workflow: *const Workflow) !void {
        const file_path = try fs.path.join(self.alloc, &.{ self.workflows_dir, workflow.id });
        defer self.alloc.free(file_path);

        const file = try fs.createFileAbsolute(file_path, .{});
        defer file.close();

        const writer = file.writer();

        // Write JSON
        try writer.writeAll("{\"id\":\"");
        try writer.writeAll(workflow.id);
        try writer.writeAll("\",\"name\":\"");
        try json.escapeString(workflow.name, writer);
        try writer.writeAll("\",\"description\":\"");
        try json.escapeString(workflow.description, writer);
        try writer.writeAll("\",\"commands\":[");

        for (workflow.commands.items, 0..) |cmd, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\"");
            try json.escapeString(cmd, writer);
            try writer.writeAll("\"");
        }

        try writer.writeAll("],\"parameters\":[");

        for (workflow.parameters.items, 0..) |param, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"name\":\"{s}\",\"description\":\"{s}\",\"required\":{},\"default\":", .{
                param.name,
                param.description,
                param.required,
            });
            if (param.default_value) |v| {
                try writer.writeAll("\"");
                try json.escapeString(v, writer);
                try writer.writeAll("\"");
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll("}");
        }

        try writer.writeAll("],\"tags\":[");

        for (workflow.tags.items, 0..) |tag, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\"");
            try json.escapeString(tag, writer);
            try writer.writeAll("\"");
        }

        try writer.print("],\"created_at\":{d},\"updated_at\":{d}}}", .{
            workflow.created_at,
            workflow.updated_at,
        });
    }

    /// Get a workflow by ID
    pub fn getWorkflow(self: *Self, id: []const u8) ?*Workflow {
        return self.workflows.get(id);
    }

    /// List all workflows
    pub fn listWorkflows(self: *Self) std.ArrayList(*Workflow) {
        var result = std.ArrayList(*Workflow).init(self.alloc);
        var iter = self.workflows.iterator();
        while (iter.next()) |entry| {
            result.append(entry.value_ptr.*) catch continue;
        }
        return result;
    }

    /// Search workflows by name or tag
    pub fn searchWorkflows(self: *Self, query: []const u8) !std.ArrayList(*Workflow) {
        var results = std.ArrayList(*Workflow).init(self.alloc);

        var iter = self.workflows.iterator();
        while (iter.next()) |entry| {
            const workflow = entry.value_ptr.*;

            // Search in name
            if (std.mem.indexOf(u8, workflow.name, query) != null) {
                try results.append(workflow);
                continue;
            }

            // Search in description
            if (std.mem.indexOf(u8, workflow.description, query) != null) {
                try results.append(workflow);
                continue;
            }

            // Search in tags
            for (workflow.tags.items) |tag| {
                if (std.mem.indexOf(u8, tag, query) != null) {
                    try results.append(workflow);
                    break;
                }
            }
        }

        return results;
    }

    /// Delete a workflow
    pub fn deleteWorkflow(self: *Self, id: []const u8) !void {
        if (self.workflows.fetchRemove(id)) |entry| {
            entry.value.deinit(self.alloc);
            self.alloc.destroy(entry.value);
        }

        const file_path = try fs.path.join(self.alloc, &.{ self.workflows_dir, id });
        defer self.alloc.free(file_path);
        fs.deleteFileAbsolute(file_path) catch {};
    }

    /// Load all workflows from disk
    pub fn loadAll(self: *Self) !void {
        const dir = fs.openDirAbsolute(self.workflows_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "wf-")) {
                self.loadWorkflow(entry.name) catch |err| {
                    std.log.warn("Failed to load workflow {s}: {}", .{ entry.name, err });
                };
            }
        }
    }

    /// Load a single workflow from disk
    fn loadWorkflow(self: *Self, id: []const u8) !void {
        const file_path = try fs.path.join(self.alloc, &.{ self.workflows_dir, id });
        defer self.alloc.free(file_path);

        const file = try fs.openFileAbsolute(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.alloc, 100_000);
        defer self.alloc.free(content);

        // Parse JSON (simplified - would use proper json parsing in production)
        const workflow = try self.alloc.create(Workflow);
        errdefer self.alloc.destroy(workflow);

        const id_copy = try self.alloc.dupe(u8, id);
        workflow.* = Workflow.init(self.alloc, id_copy, "Loaded Workflow");

        try self.workflows.put(id_copy, workflow);
    }
};

/// Built-in workflow templates
pub const BuiltinWorkflows = struct {
    /// Git commit workflow
    pub fn gitCommit(alloc: Allocator) !*Workflow {
        var workflow = try alloc.create(Workflow);
        const id = try alloc.dupe(u8, "builtin-git-commit");
        const name = try alloc.dupe(u8, "Git Commit & Push");
        workflow.* = Workflow.init(alloc, id, name);

        workflow.description = try alloc.dupe(u8, "Stage, commit, and push changes");

        try workflow.commands.append(try alloc.dupe(u8, "git add {{files}}"));
        try workflow.commands.append(try alloc.dupe(u8, "git commit -m \"{{message}}\""));
        try workflow.commands.append(try alloc.dupe(u8, "git push"));

        try workflow.parameters.append(.{
            .name = try alloc.dupe(u8, "files"),
            .description = try alloc.dupe(u8, "Files to stage"),
            .default_value = try alloc.dupe(u8, "."),
            .required = false,
        });
        try workflow.parameters.append(.{
            .name = try alloc.dupe(u8, "message"),
            .description = try alloc.dupe(u8, "Commit message"),
            .default_value = null,
            .required = true,
        });

        try workflow.tags.append(try alloc.dupe(u8, "git"));
        try workflow.tags.append(try alloc.dupe(u8, "version-control"));

        return workflow;
    }

    /// Docker build and run workflow
    pub fn dockerBuildRun(alloc: Allocator) !*Workflow {
        var workflow = try alloc.create(Workflow);
        const id = try alloc.dupe(u8, "builtin-docker-build");
        const name = try alloc.dupe(u8, "Docker Build & Run");
        workflow.* = Workflow.init(alloc, id, name);

        workflow.description = try alloc.dupe(u8, "Build and run a Docker container");

        try workflow.commands.append(try alloc.dupe(u8, "docker build -t {{image_name}} {{path}}"));
        try workflow.commands.append(try alloc.dupe(u8, "docker run -d -p {{port}}:{{port}} {{image_name}}"));

        try workflow.parameters.append(.{
            .name = try alloc.dupe(u8, "image_name"),
            .description = try alloc.dupe(u8, "Name for the Docker image"),
            .default_value = try alloc.dupe(u8, "myapp"),
            .required = true,
        });
        try workflow.parameters.append(.{
            .name = try alloc.dupe(u8, "path"),
            .description = try alloc.dupe(u8, "Build context path"),
            .default_value = try alloc.dupe(u8, "."),
            .required = false,
        });
        try workflow.parameters.append(.{
            .name = try alloc.dupe(u8, "port"),
            .description = try alloc.dupe(u8, "Port to expose"),
            .default_value = try alloc.dupe(u8, "8080"),
            .required = false,
        });

        try workflow.tags.append(try alloc.dupe(u8, "docker"));
        try workflow.tags.append(try alloc.dupe(u8, "containers"));

        return workflow;
    }

    /// NPM test and publish workflow
    pub fn npmPublish(alloc: Allocator) !*Workflow {
        var workflow = try alloc.create(Workflow);
        const id = try alloc.dupe(u8, "builtin-npm-publish");
        const name = try alloc.dupe(u8, "NPM Test & Publish");
        workflow.* = Workflow.init(alloc, id, name);

        workflow.description = try alloc.dupe(u8, "Run tests and publish to npm");

        try workflow.commands.append(try alloc.dupe(u8, "npm test"));
        try workflow.commands.append(try alloc.dupe(u8, "npm version {{version_type}}"));
        try workflow.commands.append(try alloc.dupe(u8, "npm publish"));

        try workflow.parameters.append(.{
            .name = try alloc.dupe(u8, "version_type"),
            .description = try alloc.dupe(u8, "Version bump type (patch, minor, major)"),
            .default_value = try alloc.dupe(u8, "patch"),
            .required = false,
        });

        try workflow.tags.append(try alloc.dupe(u8, "npm"));
        try workflow.tags.append(try alloc.dupe(u8, "publish"));

        return workflow;
    }
};
