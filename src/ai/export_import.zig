//! Export/Import Module
//!
//! This module provides functionality to save and load conversations, workflows,
//! and other AI-related data.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const json = std.json;
const fs = std.fs;

const log = std.log.scoped(.ai_export_import);

/// Export format
pub const ExportFormat = enum {
    json,
    markdown,
    yaml,
    plain_text,
};

/// Exportable data
pub const ExportData = struct {
    conversations: ?ArrayList(*const @import("history.zig").Conversation) = null,
    workflows: ?ArrayList(*const @import("workflows.zig").Workflow) = null,
    notebooks: ?ArrayList(*const @import("notebooks.zig").Notebook) = null,
    history: ?ArrayList(*const @import("rich_history.zig").RichHistoryEntry) = null,
};

/// Export Manager
pub const ExportManager = struct {
    alloc: Allocator,

    /// Initialize export manager
    pub fn init(alloc: Allocator) ExportManager {
        return .{
            .alloc = alloc,
        };
    }

    /// Export data to JSON
    pub fn exportToJson(self: *const ExportManager, data: ExportData) ![]const u8 {
        var buf = ArrayList(u8).init(self.alloc);
        errdefer buf.deinit();

        const writer = buf.writer();
        try writer.writeAll("{\n");

        // Export conversations
        if (data.conversations) |convs| {
            try writer.writeAll("  \"conversations\": [\n");
            for (convs.items, 0..) |conv, i| {
                if (i > 0) try writer.writeAll(",\n");
                try writer.print("    {{\"id\":\"{s}\",\"title\":\"{s}\"}}", .{ conv.id, conv.title });
            }
            try writer.writeAll("\n  ],\n");
        }

        // Export workflows
        if (data.workflows) |workflows| {
            try writer.writeAll("  \"workflows\": [\n");
            for (workflows.items, 0..) |wf, i| {
                if (i > 0) try writer.writeAll(",\n");
                try writer.print("    {{\"id\":\"{s}\",\"name\":\"{s}\"}}", .{ wf.id, wf.name });
            }
            try writer.writeAll("\n  ]\n");
        }

        try writer.writeAll("}\n");
        return buf.toOwnedSlice();
    }

    /// Export to markdown
    pub fn exportToMarkdown(self: *const ExportManager, data: ExportData) ![]const u8 {
        var buf = ArrayList(u8).init(self.alloc);
        errdefer buf.deinit();

        const writer = buf.writer();
        try writer.writeAll("# Ghostty AI Export\n\n");

        if (data.workflows) |workflows| {
            try writer.writeAll("## Workflows\n\n");
            for (workflows.items) |wf| {
                try writer.print("### {s}\n\n{s}\n\n", .{ wf.name, wf.description });
                for (wf.commands.items) |cmd| {
                    try writer.print("- `{s}`\n", .{cmd.command});
                }
                try writer.writeAll("\n");
            }
        }

        return buf.toOwnedSlice();
    }

    /// Save export to file
    pub fn saveToFile(
        _: *const ExportManager,
        file_path: []const u8,
        content: []const u8,
    ) !void {
        const file = try fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(content);
    }
};

/// Import Manager
pub const ImportManager = struct {
    alloc: Allocator,

    /// Initialize import manager
    pub fn init(alloc: Allocator) ImportManager {
        return .{
            .alloc = alloc,
        };
    }

    /// Import from JSON file
    pub fn importFromJson(
        self: *const ImportManager,
        file_path: []const u8,
    ) !json.Value {
        const file = try fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.alloc, 10_000_000);
        defer self.alloc.free(content);

        const parsed = try json.parseFromSlice(json.Value, self.alloc, content, .{});
        return parsed.value;
    }

    /// Import workflows from JSON
    pub fn importWorkflows(
        self: *const ImportManager,
        file_path: []const u8,
        workflow_manager: *@import("workflows.zig").WorkflowManager,
    ) !void {
        const data = try self.importFromJson(file_path);
        defer data.deinit();

        if (data.object.get("workflows")) |workflows_val| {
            for (workflows_val.array.items) |wf_val| {
                const wf_obj = wf_val.object;
                const name = wf_obj.get("name").?.string orelse continue;
                const workflow = try workflow_manager.createWorkflow(name);

                if (wf_obj.get("commands")) |cmds| {
                    for (cmds.array.items) |cmd_val| {
                        const cmd_obj = cmd_val.object;
                        const cmd = cmd_obj.get("command").?.string orelse continue;
                        const desc = cmd_obj.get("description").?.string orelse "";
                        try workflow.addCommand(self.alloc, cmd, desc);
                    }
                }
            }
        }
    }
};
