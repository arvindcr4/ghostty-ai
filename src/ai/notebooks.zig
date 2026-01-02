//! Terminal Notebooks Module
//!
//! This module provides executable documentation - notebooks that combine
//! markdown documentation with executable command blocks.
//!
//! Features:
//! - .gnt (Ghostty Notebook) file format with JSON serialization
//! - Export to Markdown, HTML, and Jupyter formats
//! - Code cell execution via executor callbacks
//! - Output capture and storage
//! - Notebook persistence and loading
//! - Cell-level execution and re-execution
//! - Template notebooks for common tasks

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const StringHashMap = std.StringHashMap;
const json = std.json;

const log = std.log.scoped(.ai_notebooks);

/// A notebook cell - can be markdown or code
pub const NotebookCell = struct {
    id: []const u8,
    cell_type: CellType,
    content: []const u8,
    execution_result: ?ExecutionResult,
    execution_count: u32,
    metadata: CellMetadata,

    /// Type of notebook cell content
    pub const CellType = enum {
        /// Documentation in markdown format
        markdown,
        /// Executable shell code
        code,
        /// Execution output/results
        output,
        /// Raw unprocessed content
        raw,
    };

    /// Result of executing a code cell
    pub const ExecutionResult = struct {
        /// Process exit code (null if not terminated)
        exit_code: ?i32,
        /// Standard output captured from execution
        stdout: []const u8,
        /// Standard error captured from execution
        stderr: []const u8,
        /// Execution duration in milliseconds
        duration_ms: i64,
        /// Unix timestamp when execution completed
        timestamp: i64,
        /// Whether output was truncated due to size limits
        truncated: bool,
    };

    /// Metadata associated with a notebook cell
    pub const CellMetadata = struct {
        /// Whether cell display is collapsed
        collapsed: bool,
        /// Whether cell output is scrollable
        scrolled: bool,
        /// Whether cell content can be edited
        editable: bool,
        /// Programming language for syntax highlighting
        language: []const u8,
        /// Tags for cell categorization
        tags: ArrayListUnmanaged([]const u8),

        /// Initialize with default metadata values
        pub fn init() CellMetadata {
            return .{
                .collapsed = false,
                .scrolled = false,
                .editable = true,
                .language = "shell",
                .tags = .empty,
            };
        }

        /// Free all allocated metadata resources
        pub fn deinit(self: *CellMetadata, alloc: Allocator) void {
            for (self.tags.items) |tag| alloc.free(tag);
            self.tags.deinit(alloc);
        }
    };

    /// Create a new notebook cell with the given parameters
    pub fn init(id: []const u8, cell_type: CellType, content: []const u8) NotebookCell {
        return .{
            .id = id,
            .cell_type = cell_type,
            .content = content,
            .execution_result = null,
            .execution_count = 0,
            .metadata = CellMetadata.init(),
        };
    }

    /// Free all allocated cell resources
    pub fn deinit(self: *NotebookCell, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.content);
        if (self.execution_result) |*result| {
            alloc.free(result.stdout);
            alloc.free(result.stderr);
        }
        self.metadata.deinit(alloc);
    }

    /// Check if cell has been executed
    pub fn isExecuted(self: *const NotebookCell) bool {
        return self.execution_result != null;
    }

    /// Check if last execution was successful
    pub fn wasSuccessful(self: *const NotebookCell) bool {
        if (self.execution_result) |result| {
            return result.exit_code == 0;
        }
        return false;
    }
};

/// A terminal notebook
pub const Notebook = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    author: ?[]const u8,
    cells: ArrayListUnmanaged(NotebookCell),
    created_at: i64,
    updated_at: i64,
    tags: ArrayListUnmanaged([]const u8),
    kernel_info: KernelInfo,
    alloc: Allocator,
    next_cell_id: u32,

    /// Information about the notebook execution kernel
    pub const KernelInfo = struct {
        /// Kernel name identifier
        name: []const u8,
        /// Kernel version string
        version: []const u8,
        /// Shell path for command execution
        shell: []const u8,
    };

    /// Create a new empty notebook with the given ID and title
    pub fn init(alloc: Allocator, id: []const u8, title: []const u8) !Notebook {
        return .{
            .id = try alloc.dupe(u8, id),
            .title = try alloc.dupe(u8, title),
            .description = try alloc.dupe(u8, ""),
            .author = null,
            .cells = .empty,
            .created_at = std.time.timestamp(),
            .updated_at = std.time.timestamp(),
            .tags = .empty,
            .kernel_info = .{
                .name = "ghostty",
                .version = "1.0.0",
                .shell = "/bin/bash",
            },
            .alloc = alloc,
            .next_cell_id = 1,
        };
    }

    /// Free all notebook resources including cells and metadata
    pub fn deinit(self: *Notebook) void {
        self.alloc.free(self.id);
        self.alloc.free(self.title);
        self.alloc.free(self.description);
        if (self.author) |a| self.alloc.free(a);
        for (self.cells.items) |*cell| cell.deinit(self.alloc);
        self.cells.deinit(self.alloc);
        for (self.tags.items) |tag| self.alloc.free(tag);
        self.tags.deinit(self.alloc);
    }

    /// Generate a unique cell ID
    fn generateCellId(self: *Notebook) ![]const u8 {
        const id = try std.fmt.allocPrint(self.alloc, "cell_{d}", .{self.next_cell_id});
        self.next_cell_id += 1;
        return id;
    }

    /// Add a cell to the notebook
    pub fn addCell(self: *Notebook, cell_type: NotebookCell.CellType, content: []const u8) !*NotebookCell {
        const id = try self.generateCellId();
        errdefer self.alloc.free(id);
        const duped_content = try self.alloc.dupe(u8, content);
        errdefer self.alloc.free(duped_content);
        const cell = NotebookCell.init(id, cell_type, duped_content);
        try self.cells.append(self.alloc, cell);
        self.updated_at = std.time.timestamp();
        return &self.cells.items[self.cells.items.len - 1];
    }

    /// Insert a cell at a specific index
    pub fn insertCell(
        self: *Notebook,
        index: usize,
        cell_type: NotebookCell.CellType,
        content: []const u8,
    ) !*NotebookCell {
        const id = try self.generateCellId();
        errdefer self.alloc.free(id);
        const duped_content = try self.alloc.dupe(u8, content);
        errdefer self.alloc.free(duped_content);
        const cell = NotebookCell.init(id, cell_type, duped_content);
        try self.cells.insert(self.alloc, index, cell);
        self.updated_at = std.time.timestamp();
        return &self.cells.items[index];
    }

    /// Remove a cell by index
    pub fn removeCell(self: *Notebook, index: usize) void {
        if (index < self.cells.items.len) {
            var cell = self.cells.orderedRemove(index);
            cell.deinit(self.alloc);
            self.updated_at = std.time.timestamp();
        }
    }

    /// Move a cell to a new position
    pub fn moveCell(self: *Notebook, from_index: usize, to_index: usize) void {
        if (from_index >= self.cells.items.len or to_index >= self.cells.items.len) return;
        if (from_index == to_index) return;

        const cell = self.cells.orderedRemove(from_index);
        self.cells.insert(self.alloc, to_index, cell) catch return;
        self.updated_at = std.time.timestamp();
    }

    /// Execute all code cells
    pub fn executeAll(
        self: *Notebook,
        executor: *const fn (command: []const u8, alloc: Allocator) anyerror!NotebookCell.ExecutionResult,
    ) !void {
        for (self.cells.items) |*cell| {
            if (cell.cell_type == .code) {
                try self.executeCellInternal(cell, executor);
            }
        }
    }

    /// Execute a single code cell by index
    pub fn executeCell(
        self: *Notebook,
        cell_index: usize,
        executor: *const fn (command: []const u8, alloc: Allocator) anyerror!NotebookCell.ExecutionResult,
    ) !void {
        if (cell_index >= self.cells.items.len) return error.InvalidCellIndex;
        const cell = &self.cells.items[cell_index];
        if (cell.cell_type != .code) return;

        try self.executeCellInternal(cell, executor);
    }

    /// Internal cell execution
    fn executeCellInternal(
        self: *Notebook,
        cell: *NotebookCell,
        executor: *const fn (command: []const u8, alloc: Allocator) anyerror!NotebookCell.ExecutionResult,
    ) !void {
        // Clean up previous execution result
        if (cell.execution_result) |*old_result| {
            self.alloc.free(old_result.stdout);
            self.alloc.free(old_result.stderr);
        }

        const start_time = std.time.nanoTimestamp();
        const result = executor(cell.content, self.alloc) catch |err| {
            cell.execution_result = .{
                .exit_code = 1,
                .stdout = try self.alloc.dupe(u8, ""),
                .stderr = try std.fmt.allocPrint(self.alloc, "Error: {s}", .{@errorName(err)}),
                .duration_ms = @divTrunc(std.time.nanoTimestamp() - start_time, 1_000_000),
                .timestamp = std.time.timestamp(),
                .truncated = false,
            };
            cell.execution_count += 1;
            return;
        };

        const duration_ms = @divTrunc(std.time.nanoTimestamp() - start_time, 1_000_000);
        cell.execution_result = .{
            .exit_code = result.exit_code,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .duration_ms = duration_ms,
            .timestamp = std.time.timestamp(),
            .truncated = result.truncated,
        };
        cell.execution_count += 1;
    }

    /// Clear all execution results
    pub fn clearOutputs(self: *Notebook) void {
        for (self.cells.items) |*cell| {
            if (cell.execution_result) |*result| {
                self.alloc.free(result.stdout);
                self.alloc.free(result.stderr);
                cell.execution_result = null;
            }
            cell.execution_count = 0;
        }
    }

    /// Export to Markdown format
    pub fn exportToMarkdown(self: *const Notebook, alloc: Allocator) ![]const u8 {
        var output: ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(alloc);
        const writer = output.writer(alloc);

        // Title and metadata
        try writer.print("# {s}\n\n", .{self.title});
        if (self.description.len > 0) {
            try writer.print("{s}\n\n", .{self.description});
        }
        try writer.print("---\n\n", .{});

        // Cells
        for (self.cells.items) |cell| {
            switch (cell.cell_type) {
                .markdown => {
                    try writer.print("{s}\n\n", .{cell.content});
                },
                .code => {
                    try writer.print("```bash\n{s}\n```\n\n", .{cell.content});
                    if (cell.execution_result) |result| {
                        if (result.stdout.len > 0) {
                            try writer.print("**Output:**\n```\n{s}\n```\n\n", .{result.stdout});
                        }
                        if (result.stderr.len > 0) {
                            try writer.print("**Error:**\n```\n{s}\n```\n\n", .{result.stderr});
                        }
                    }
                },
                .output => {
                    try writer.print("```\n{s}\n```\n\n", .{cell.content});
                },
                .raw => {
                    try writer.print("{s}\n\n", .{cell.content});
                },
            }
        }

        return output.toOwnedSlice(alloc);
    }

    /// Export to HTML format
    pub fn exportToHtml(self: *const Notebook, alloc: Allocator) ![]const u8 {
        var output: ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(alloc);
        const writer = output.writer(alloc);

        // HTML header
        try writer.writeAll(
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\<meta charset="utf-8">
            \\<title>
        );
        try writer.print("{s}", .{self.title});
        try writer.writeAll(
            \\</title>
            \\<style>
            \\.notebook { font-family: system-ui, -apple-system, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
            \\.cell { margin-bottom: 20px; }
            \\.code-cell { background: #f5f5f5; border: 1px solid #ddd; border-radius: 4px; padding: 10px; }
            \\.output { background: #fff; border: 1px solid #eee; border-radius: 4px; padding: 10px; margin-top: 10px; }
            \\pre { margin: 0; overflow-x: auto; }
            \\.stderr { color: #cc0000; }
            \\.success { border-left: 3px solid #00cc00; }
            \\.failure { border-left: 3px solid #cc0000; }
            \\</style>
            \\</head>
            \\<body>
            \\<div class="notebook">
            \\
        );

        try writer.print("<h1>{s}</h1>\n", .{self.title});
        if (self.description.len > 0) {
            try writer.print("<p>{s}</p>\n", .{self.description});
        }

        // Cells
        for (self.cells.items) |cell| {
            try writer.writeAll("<div class=\"cell\">\n");

            switch (cell.cell_type) {
                .markdown => {
                    try writer.print("<div class=\"markdown\">{s}</div>\n", .{cell.content});
                },
                .code => {
                    const status_class = if (cell.execution_result) |r|
                        (if (r.exit_code == 0) "success" else "failure")
                    else
                        "";

                    try writer.print("<div class=\"code-cell {s}\">\n", .{status_class});
                    try writer.print("<pre><code>{s}</code></pre>\n", .{cell.content});

                    if (cell.execution_result) |result| {
                        if (result.stdout.len > 0) {
                            try writer.print("<div class=\"output\"><pre>{s}</pre></div>\n", .{result.stdout});
                        }
                        if (result.stderr.len > 0) {
                            try writer.print("<div class=\"output stderr\"><pre>{s}</pre></div>\n", .{result.stderr});
                        }
                    }
                    try writer.writeAll("</div>\n");
                },
                .output => {
                    try writer.print("<div class=\"output\"><pre>{s}</pre></div>\n", .{cell.content});
                },
                .raw => {
                    try writer.print("{s}\n", .{cell.content});
                },
            }

            try writer.writeAll("</div>\n");
        }

        try writer.writeAll("</div>\n</body>\n</html>\n");

        return output.toOwnedSlice(alloc);
    }

    /// Export to Jupyter notebook format (.ipynb)
    pub fn exportToJupyter(self: *const Notebook, alloc: Allocator) ![]const u8 {
        var output: ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(alloc);
        const writer = output.writer(alloc);

        try writer.writeAll("{\"nbformat\":4,\"nbformat_minor\":5,");
        try writer.writeAll("\"metadata\":{\"kernelspec\":{\"display_name\":\"Bash\",\"language\":\"bash\",\"name\":\"bash\"}},");
        try writer.writeAll("\"cells\":[");

        var first = true;
        for (self.cells.items) |cell| {
            if (!first) try writer.writeAll(",");
            first = false;

            try writer.writeAll("{");

            const jupyter_type = switch (cell.cell_type) {
                .markdown => "markdown",
                .code => "code",
                .output => "raw",
                .raw => "raw",
            };

            try writer.print("\"cell_type\":\"{s}\",", .{jupyter_type});
            try writer.writeAll("\"metadata\":{},");
            try writer.print("\"source\":[\"{s}\"]", .{cell.content});

            if (cell.cell_type == .code) {
                try writer.print(",\"execution_count\":{d},", .{cell.execution_count});
                if (cell.execution_result) |result| {
                    try writer.writeAll("\"outputs\":[{\"output_type\":\"stream\",\"name\":\"stdout\",\"text\":[\"");
                    try writer.print("{s}", .{result.stdout});
                    try writer.writeAll("\"]}]");
                } else {
                    try writer.writeAll("\"outputs\":[]");
                }
            }

            try writer.writeAll("}");
        }

        try writer.writeAll("]}");

        return output.toOwnedSlice(alloc);
    }

    /// Get statistics about the notebook
    pub fn getStats(self: *const Notebook) struct {
        total_cells: usize,
        markdown_cells: usize,
        code_cells: usize,
        executed_cells: usize,
        successful_cells: usize,
        failed_cells: usize,
        total_execution_time_ms: i64,
    } {
        var stats = .{
            .total_cells = self.cells.items.len,
            .markdown_cells = @as(usize, 0),
            .code_cells = @as(usize, 0),
            .executed_cells = @as(usize, 0),
            .successful_cells = @as(usize, 0),
            .failed_cells = @as(usize, 0),
            .total_execution_time_ms = @as(i64, 0),
        };

        for (self.cells.items) |cell| {
            switch (cell.cell_type) {
                .markdown => stats.markdown_cells += 1,
                .code => {
                    stats.code_cells += 1;
                    if (cell.execution_result) |result| {
                        stats.executed_cells += 1;
                        stats.total_execution_time_ms += result.duration_ms;
                        if (result.exit_code == 0) {
                            stats.successful_cells += 1;
                        } else {
                            stats.failed_cells += 1;
                        }
                    }
                },
                else => {},
            }
        }

        return stats;
    }
};

/// Notebook Manager
pub const NotebookManager = struct {
    alloc: Allocator,
    notebooks: StringHashMap(*Notebook),
    storage_path: []const u8,
    templates: StringHashMap(NotebookTemplate),

    pub const NotebookTemplate = struct {
        name: []const u8,
        description: []const u8,
        cells: []const TemplateCell,

        pub const TemplateCell = struct {
            cell_type: NotebookCell.CellType,
            content: []const u8,
        };
    };

    /// Initialize notebook manager
    pub fn init(alloc: Allocator) !NotebookManager {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
        const storage_path = try std.fs.path.join(alloc, &.{ home, ".config", "ghostty", "notebooks" });

        std.fs.makeDirAbsolute(storage_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var manager = NotebookManager{
            .alloc = alloc,
            .notebooks = StringHashMap(*Notebook).init(alloc),
            .storage_path = storage_path,
            .templates = StringHashMap(NotebookTemplate).init(alloc),
        };

        // Register default templates
        try manager.registerDefaultTemplates();

        return manager;
    }

    pub fn deinit(self: *NotebookManager) void {
        var iter = self.notebooks.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.notebooks.deinit();
        self.templates.deinit();
        self.alloc.free(self.storage_path);
    }

    /// Register default notebook templates
    fn registerDefaultTemplates(self: *NotebookManager) !void {
        try self.templates.put("git-workflow", .{
            .name = "Git Workflow",
            .description = "Common git operations workflow",
            .cells = &[_]NotebookTemplate.TemplateCell{
                .{ .cell_type = .markdown, .content = "# Git Workflow\n\nThis notebook documents common git operations." },
                .{ .cell_type = .code, .content = "git status" },
                .{ .cell_type = .code, .content = "git log --oneline -10" },
                .{ .cell_type = .code, .content = "git branch -a" },
            },
        });

        try self.templates.put("system-check", .{
            .name = "System Health Check",
            .description = "Check system health and resources",
            .cells = &[_]NotebookTemplate.TemplateCell{
                .{ .cell_type = .markdown, .content = "# System Health Check\n\nVerify system resources and status." },
                .{ .cell_type = .code, .content = "uname -a" },
                .{ .cell_type = .code, .content = "df -h" },
                .{ .cell_type = .code, .content = "free -m" },
                .{ .cell_type = .code, .content = "uptime" },
            },
        });
    }

    /// Create a new notebook
    pub fn createNotebook(self: *NotebookManager, title: []const u8) !*Notebook {
        const id = try std.fmt.allocPrint(self.alloc, "notebook_{d}", .{std.time.timestamp()});
        const notebook = try self.alloc.create(Notebook);
        notebook.* = try Notebook.init(self.alloc, id, title);

        try self.notebooks.put(notebook.id, notebook);
        return notebook;
    }

    /// Create notebook from template
    pub fn createFromTemplate(self: *NotebookManager, title: []const u8, template_name: []const u8) !*Notebook {
        const template = self.templates.get(template_name) orelse return error.TemplateNotFound;

        var notebook = try self.createNotebook(title);
        notebook.description = try self.alloc.dupe(u8, template.description);

        for (template.cells) |template_cell| {
            _ = try notebook.addCell(template_cell.cell_type, template_cell.content);
        }

        return notebook;
    }

    /// Get a notebook by ID
    pub fn getNotebook(self: *NotebookManager, id: []const u8) ?*Notebook {
        return self.notebooks.get(id);
    }

    /// Delete a notebook
    pub fn deleteNotebook(self: *NotebookManager, id: []const u8) !void {
        if (self.notebooks.fetchRemove(id)) |entry| {
            entry.value.deinit();
            self.alloc.destroy(entry.value);

            // Delete file
            const file_path = try std.fs.path.join(self.alloc, &.{ self.storage_path, id, ".gnt" });
            defer self.alloc.free(file_path);
            std.fs.deleteFileAbsolute(file_path) catch {};
        }
    }

    /// Save notebook to disk in .gnt (Ghostty Notebook) format
    pub fn saveNotebook(self: *NotebookManager, notebook: *const Notebook) !void {
        const filename = try std.fmt.allocPrint(self.alloc, "{s}.gnt", .{notebook.id});
        defer self.alloc.free(filename);

        const file_path = try std.fs.path.join(self.alloc, &.{ self.storage_path, filename });
        defer self.alloc.free(file_path);

        const file = try std.fs.createFileAbsolute(file_path, .{});
        defer file.close();

        var json_stream = json.writeStream(file.writer(), .{});
        try json_stream.beginObject();

        try json_stream.objectField("version");
        try json_stream.write(1);

        try json_stream.objectField("id");
        try json_stream.write(notebook.id);

        try json_stream.objectField("title");
        try json_stream.write(notebook.title);

        try json_stream.objectField("description");
        try json_stream.write(notebook.description);

        try json_stream.objectField("created_at");
        try json_stream.write(notebook.created_at);

        try json_stream.objectField("updated_at");
        try json_stream.write(notebook.updated_at);

        try json_stream.objectField("tags");
        try json_stream.beginArray();
        for (notebook.tags.items) |tag| {
            try json_stream.write(tag);
        }
        try json_stream.endArray();

        try json_stream.objectField("cells");
        try json_stream.beginArray();
        for (notebook.cells.items) |cell| {
            try json_stream.beginObject();

            try json_stream.objectField("id");
            try json_stream.write(cell.id);

            try json_stream.objectField("type");
            try json_stream.write(@tagName(cell.cell_type));

            try json_stream.objectField("content");
            try json_stream.write(cell.content);

            try json_stream.objectField("execution_count");
            try json_stream.write(cell.execution_count);

            if (cell.execution_result) |result| {
                try json_stream.objectField("execution_result");
                try json_stream.beginObject();

                if (result.exit_code) |code| {
                    try json_stream.objectField("exit_code");
                    try json_stream.write(code);
                }

                try json_stream.objectField("stdout");
                try json_stream.write(result.stdout);

                try json_stream.objectField("stderr");
                try json_stream.write(result.stderr);

                try json_stream.objectField("duration_ms");
                try json_stream.write(result.duration_ms);

                try json_stream.objectField("timestamp");
                try json_stream.write(result.timestamp);

                try json_stream.endObject();
            }

            try json_stream.endObject();
        }
        try json_stream.endArray();

        try json_stream.endObject();
    }

    /// Load notebook from disk
    pub fn loadNotebook(self: *NotebookManager, notebook_id: []const u8) !*Notebook {
        const filename = try std.fmt.allocPrint(self.alloc, "{s}.gnt", .{notebook_id});
        defer self.alloc.free(filename);

        const file_path = try std.fs.path.join(self.alloc, &.{ self.storage_path, filename });
        defer self.alloc.free(file_path);

        const file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const contents = try self.alloc.alloc(u8, file_size);
        defer self.alloc.free(contents);

        _ = try file.readAll(contents);

        const parsed = try json.parseFromSlice(json.Value, self.alloc, contents, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const id = root.get("id").?.string;
        const title = root.get("title").?.string;

        const notebook = try self.alloc.create(Notebook);
        notebook.* = try Notebook.init(self.alloc, id, title);

        if (root.get("description")) |desc| {
            self.alloc.free(notebook.description);
            notebook.description = try self.alloc.dupe(u8, desc.string);
        }

        if (root.get("created_at")) |created| {
            notebook.created_at = @intCast(created.integer);
        }

        if (root.get("updated_at")) |updated| {
            notebook.updated_at = @intCast(updated.integer);
        }

        if (root.get("cells")) |cells_array| {
            for (cells_array.array.items) |cell_obj| {
                const cell_type_str = cell_obj.object.get("type").?.string;
                const cell_type = if (std.mem.eql(u8, cell_type_str, "markdown"))
                    NotebookCell.CellType.markdown
                else if (std.mem.eql(u8, cell_type_str, "code"))
                    NotebookCell.CellType.code
                else if (std.mem.eql(u8, cell_type_str, "raw"))
                    NotebookCell.CellType.raw
                else
                    NotebookCell.CellType.output;

                const content = cell_obj.object.get("content").?.string;
                const cell = try notebook.addCell(cell_type, content);

                if (cell_obj.object.get("execution_count")) |ec| {
                    cell.execution_count = @intCast(ec.integer);
                }

                if (cell_obj.object.get("execution_result")) |exec_result| {
                    const exit_code = if (exec_result.object.get("exit_code")) |ec|
                        @as(?i32, @intCast(ec.integer))
                    else
                        null;

                    cell.execution_result = .{
                        .exit_code = exit_code,
                        .stdout = try self.alloc.dupe(u8, exec_result.object.get("stdout").?.string),
                        .stderr = try self.alloc.dupe(u8, exec_result.object.get("stderr").?.string),
                        .duration_ms = @intCast(exec_result.object.get("duration_ms").?.integer),
                        .timestamp = @intCast(exec_result.object.get("timestamp").?.integer),
                        .truncated = false,
                    };
                }
            }
        }

        try self.notebooks.put(notebook.id, notebook);
        return notebook;
    }

    /// Load all notebooks from disk
    pub fn loadAllNotebooks(self: *NotebookManager) !void {
        var dir = std.fs.openDirAbsolute(self.storage_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".gnt")) {
                const notebook_id = entry.name[0 .. entry.name.len - 4]; // Remove .gnt extension
                _ = self.loadNotebook(notebook_id) catch |err| {
                    log.warn("Failed to load notebook {s}: {}", .{ entry.name, err });
                    continue;
                };
            }
        }
    }

    /// List all available templates
    pub fn listTemplates(self: *const NotebookManager) []const []const u8 {
        var names: ArrayListUnmanaged([]const u8) = .empty;
        errdefer names.deinit(self.alloc);
        var iter = self.templates.iterator();
        while (iter.next()) |entry| {
            names.append(self.alloc, entry.key_ptr.*) catch continue;
        }
        return names.toOwnedSlice(self.alloc) catch {
            names.deinit(self.alloc);
            return &[_][]const u8{};
        };
    }

    /// Get statistics
    pub fn getStats(self: *const NotebookManager) struct {
        total_notebooks: usize,
        templates_available: usize,
    } {
        return .{
            .total_notebooks = self.notebooks.count(),
            .templates_available = self.templates.count(),
        };
    }
};

test "Notebook basic operations" {
    const alloc = std.testing.allocator;

    var notebook = try Notebook.init(alloc, "test_id", "Test Notebook");
    defer notebook.deinit();

    _ = try notebook.addCell(.markdown, "# Hello");
    _ = try notebook.addCell(.code, "echo world");

    try std.testing.expectEqual(@as(usize, 2), notebook.cells.items.len);
    try std.testing.expectEqual(NotebookCell.CellType.markdown, notebook.cells.items[0].cell_type);
    try std.testing.expectEqual(NotebookCell.CellType.code, notebook.cells.items[1].cell_type);
}

test "Notebook export to markdown" {
    const alloc = std.testing.allocator;

    var notebook = try Notebook.init(alloc, "test_id", "Test Notebook");
    defer notebook.deinit();

    _ = try notebook.addCell(.markdown, "# Introduction");
    _ = try notebook.addCell(.code, "echo hello");

    const md = try notebook.exportToMarkdown(alloc);
    defer alloc.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "Test Notebook") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Introduction") != null);
}
