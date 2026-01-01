//! Documentation Generator Module
//!
//! This module auto-generates help content and documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const log = std.log.scoped(.ai_documentation);

/// Generated documentation
pub const Documentation = struct {
    title: []const u8,
    content: []const u8,
    format: Format,
    sections: ArrayList(Section),

    pub const Format = enum {
        markdown,
        html,
        plain_text,
    };

    pub const Section = struct {
        heading: []const u8,
        content: []const u8,
    };

    pub fn deinit(self: *Documentation, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.content);
        for (self.sections.items) |section| {
            alloc.free(section.heading);
            alloc.free(section.content);
        }
        self.sections.deinit();
    }
};

/// Documentation Generator
pub const DocumentationGenerator = struct {
    alloc: Allocator,
    enabled: bool,

    /// Initialize documentation generator
    pub fn init(alloc: Allocator) DocumentationGenerator {
        return .{
            .alloc = alloc,
            .enabled = true,
        };
    }

    /// Generate documentation for a command
    pub fn generateCommandDocs(
        self: *const DocumentationGenerator,
        command: []const u8,
    ) !Documentation {
        var doc = Documentation{
            .title = try std.fmt.allocPrint(self.alloc, "Documentation: {s}", .{command}),
            .content = "",
            .format = .markdown,
            .sections = ArrayList(Documentation.Section).init(self.alloc),
        };

        // Generate basic documentation structure
        try doc.sections.append(.{
            .heading = try self.alloc.dupe(u8, "Description"),
            .content = try std.fmt.allocPrint(self.alloc, "Documentation for command: {s}", .{command}),
        });

        try doc.sections.append(.{
            .heading = try self.alloc.dupe(u8, "Usage"),
            .content = try self.alloc.dupe(u8, command),
        });

        try doc.sections.append(.{
            .heading = try self.alloc.dupe(u8, "Examples"),
            .content = try std.fmt.allocPrint(self.alloc, "```bash\n{s}\n```", .{command}),
        });

        // Build content from sections
        var content_buf = ArrayList(u8).init(self.alloc);
        errdefer content_buf.deinit();

        try content_buf.writer().print("# {s}\n\n", .{doc.title});
        for (doc.sections.items) |section| {
            try content_buf.writer().print("## {s}\n\n{s}\n\n", .{ section.heading, section.content });
        }

        doc.content = try content_buf.toOwnedSlice();
        return doc;
    }

    /// Generate workflow documentation
    pub fn generateWorkflowDocs(
        self: *const DocumentationGenerator,
        workflow: *const @import("workflows.zig").Workflow,
    ) !Documentation {
        var doc = Documentation{
            .title = try std.fmt.allocPrint(self.alloc, "Workflow: {s}", .{workflow.name}),
            .content = "",
            .format = .markdown,
            .sections = ArrayList(Documentation.Section).init(self.alloc),
        };

        try doc.sections.append(.{
            .heading = try self.alloc.dupe(u8, "Description"),
            .content = try self.alloc.dupe(u8, workflow.description),
        });

        try doc.sections.append(.{
            .heading = try self.alloc.dupe(u8, "Steps"),
            .content = try self.buildStepsContent(workflow),
        });

        // Build content
        var content_buf = ArrayList(u8).init(self.alloc);
        errdefer content_buf.deinit();

        try content_buf.writer().print("# {s}\n\n", .{doc.title});
        for (doc.sections.items) |section| {
            try content_buf.writer().print("## {s}\n\n{s}\n\n", .{ section.heading, section.content });
        }

        doc.content = try content_buf.toOwnedSlice();
        return doc;
    }

    /// Build steps content
    fn buildStepsContent(
        self: *const DocumentationGenerator,
        workflow: *const @import("workflows.zig").Workflow,
    ) ![]const u8 {
        var buf = ArrayList(u8).init(self.alloc);
        errdefer buf.deinit();

        for (workflow.commands.items, 1..) |cmd, i| {
            try buf.writer().print("{d}. `{s}` - {s}\n", .{ i, cmd.command, cmd.description });
        }

        return buf.toOwnedSlice();
    }

    /// Enable or disable documentation generation
    pub fn setEnabled(self: *DocumentationGenerator, enabled: bool) void {
        self.enabled = enabled;
    }
};
