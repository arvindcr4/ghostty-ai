//! Knowledge Rules Module
//!
//! This module implements Warp-like knowledge rules that learn from user interactions
//! and apply learned patterns to provide intelligent suggestions and assistance.
//!
//! Features:
//! - Learn from command history and patterns
//! - Store knowledge rules persistently
//! - Apply rules for context-aware suggestions
//! - Pattern matching and rule inference
//! - Knowledge sharing and export

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const json = std.json;

const log = std.log.scoped(.ai_knowledge_rules);

/// A knowledge rule that captures patterns and provides suggestions
pub const KnowledgeRule = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    pattern: Pattern,
    action: Action,
    context: Context,
    confidence: f32,
    usage_count: u32,
    last_used: i64,
    created_at: i64,
    tags: ArrayList([]const u8),

    pub const Pattern = union(enum) {
        command_prefix: []const u8,
        command_sequence: ArrayList([]const u8),
        file_pattern: []const u8,
        git_state: GitStatePattern,
        directory_pattern: []const u8,
        output_pattern: []const u8,
        custom: []const u8, // JSON pattern expression
    };

    pub const GitStatePattern = struct {
        branch_pattern: ?[]const u8 = null,
        has_uncommitted: ?bool = null,
        has_staged: ?bool = null,
        is_detached: ?bool = null,
    };

    pub const Action = union(enum) {
        suggest_command: []const u8,
        suggest_workflow: []const u8,
        show_hint: []const u8,
        auto_complete: []const u8,
        warn: []const u8,
        execute: []const u8,
    };

    pub const Context = struct {
        cwd_patterns: ArrayList([]const u8),
        required_files: ArrayList([]const u8),
        required_env_vars: ArrayList([]const u8),
        time_of_day: ?TimeOfDay = null,
        day_of_week: ?DayOfWeek = null,
        min_history_length: usize = 0,
    };

    pub const TimeOfDay = enum {
        morning,
        afternoon,
        evening,
        night,
    };

    pub const DayOfWeek = enum {
        monday,
        tuesday,
        wednesday,
        thursday,
        friday,
        saturday,
        sunday,
    };

    pub fn deinit(self: *KnowledgeRule, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.description);
        
        switch (self.pattern) {
            .command_prefix => |p| alloc.free(p),
            .command_sequence => |seq| {
                for (seq.items) |cmd| alloc.free(cmd);
                seq.deinit();
            },
            .file_pattern => |p| alloc.free(p),
            .git_state => |_| {},
            .directory_pattern => |p| alloc.free(p),
            .output_pattern => |p| alloc.free(p),
            .custom => |p| alloc.free(p),
        }
        
        switch (self.action) {
            .suggest_command => |c| alloc.free(c),
            .suggest_workflow => |w| alloc.free(w),
            .show_hint => |h| alloc.free(h),
            .auto_complete => |a| alloc.free(a),
            .warn => |w| alloc.free(w),
            .execute => |e| alloc.free(e),
        }
        
        for (self.context.cwd_patterns.items) |p| alloc.free(p);
        self.context.cwd_patterns.deinit();
        for (self.context.required_files.items) |f| alloc.free(f);
        self.context.required_files.deinit();
        for (self.context.required_env_vars.items) |v| alloc.free(v);
        self.context.required_env_vars.deinit();
        for (self.tags.items) |t| alloc.free(t);
        self.tags.deinit();
    }
};

/// Rule match result
pub const RuleMatch = struct {
    rule: *KnowledgeRule,
    confidence: f32,
    matched_pattern: MatchedPattern,
    suggested_action: KnowledgeRule.Action,

    pub const MatchedPattern = struct {
        pattern_type: KnowledgeRule.Pattern,
        match_details: []const u8,
    };

    pub fn deinit(self: *RuleMatch, alloc: Allocator) void {
        alloc.free(self.matched_pattern.match_details);
    }
};

/// Knowledge Rules Manager
pub const KnowledgeRulesManager = struct {
    alloc: Allocator,
    rules: ArrayList(*KnowledgeRule),
    storage_path: []const u8,
    learning_enabled: bool,
    auto_learn_threshold: f32 = 0.7,

    /// Initialize knowledge rules manager
    pub fn init(alloc: Allocator) !KnowledgeRulesManager {
        const home = std.os.getenv("HOME") orelse return error.HomeNotSet;
        const storage_path = try std.fs.path.join(alloc, &.{ home, ".config", "ghostty", "knowledge_rules" });

        std.fs.makeDirAbsolute(storage_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var manager = KnowledgeRulesManager{
            .alloc = alloc,
            .rules = ArrayList(*KnowledgeRule).init(alloc),
            .storage_path = storage_path,
            .learning_enabled = true,
        };

        // Load existing rules
        manager.loadAllRules() catch |err| {
            log.warn("Failed to load knowledge rules: {}", .{err});
        };

        // Register built-in rules
        manager.registerBuiltInRules() catch |err| {
            log.warn("Failed to register built-in rules: {}", .{err});
        };

        return manager;
    }

    pub fn deinit(self: *KnowledgeRulesManager) void {
        for (self.rules.items) |rule| {
            rule.deinit(self.alloc);
            self.alloc.destroy(rule);
        }
        self.rules.deinit();
        self.alloc.free(self.storage_path);
    }

    /// Register built-in knowledge rules
    fn registerBuiltInRules(self: *KnowledgeRulesManager) !void {
        // Rule: After git clone, often run cd into the directory
        try self.addRule(.{
            .name = "cd after git clone",
            .description = "After cloning a repository, suggest changing into the directory",
            .pattern = .{
                .command_sequence = blk: {
                    var seq = ArrayList([]const u8).init(self.alloc);
                    try seq.append(try self.alloc.dupe(u8, "git clone"));
                    break :blk seq;
                },
            },
            .action = .{
                .suggest_command = try self.alloc.dupe(u8, "cd <repo-name>"),
            },
            .context = .{
                .cwd_patterns = ArrayList([]const u8).init(self.alloc),
                .required_files = ArrayList([]const u8).init(self.alloc),
                .required_env_vars = ArrayList([]const u8).init(self.alloc),
            },
            .confidence = 0.8,
            .tags = ArrayList([]const u8).init(self.alloc),
        });

        // Rule: After npm install, often run npm start
        try self.addRule(.{
            .name = "npm start after install",
            .description = "After installing npm packages, suggest starting the app",
            .pattern = .{
                .command_sequence = blk: {
                    var seq = ArrayList([]const u8).init(self.alloc);
                    try seq.append(try self.alloc.dupe(u8, "npm install"));
                    break :blk seq;
                },
            },
            .action = .{
                .suggest_command = try self.alloc.dupe(u8, "npm start"),
            },
            .context = .{
                .cwd_patterns = blk: {
                    var patterns = ArrayList([]const u8).init(self.alloc);
                    try patterns.append(try self.alloc.dupe(u8, "*package.json"));
                    break :blk patterns;
                },
                .required_files = blk: {
                    var files = ArrayList([]const u8).init(self.alloc);
                    try files.append(try self.alloc.dupe(u8, "package.json"));
                    break :blk files;
                },
                .required_env_vars = ArrayList([]const u8).init(self.alloc),
            },
            .confidence = 0.75,
            .tags = blk: {
                var tags = ArrayList([]const u8).init(self.alloc);
                try tags.append(try self.alloc.dupe(u8, "npm"));
                try tags.append(try self.alloc.dupe(u8, "node"));
                break :blk tags;
            },
        });

        // Rule: After making changes in git repo, suggest git status
        try self.addRule(.{
            .name = "git status after changes",
            .description = "After making file changes, suggest checking git status",
            .pattern = .{
                .command_prefix = try self.alloc.dupe(u8, "git"),
            },
            .action = .{
                .suggest_command = try self.alloc.dupe(u8, "git status"),
            },
            .context = .{
                .cwd_patterns = ArrayList([]const u8).init(self.alloc),
                .required_files = blk: {
                    var files = ArrayList([]const u8).init(self.alloc);
                    try files.append(try self.alloc.dupe(u8, ".git"));
                    break :blk files;
                },
                .required_env_vars = ArrayList([]const u8).init(self.alloc),
                .min_history_length = 1,
            },
            .confidence = 0.6,
            .tags = blk: {
                var tags = ArrayList([]const u8).init(self.alloc);
                try tags.append(try self.alloc.dupe(u8, "git"));
                break :blk tags;
            },
        });

        // Rule: After cd into project, suggest common commands
        try self.addRule(.{
            .name = "project commands after cd",
            .description = "After changing into a project directory, suggest common commands",
            .pattern = .{
                .command_prefix = try self.alloc.dupe(u8, "cd"),
            },
            .action = .{
                .show_hint = try self.alloc.dupe(u8, "Common commands: make, npm start, cargo build"),
            },
            .context = .{
                .cwd_patterns = ArrayList([]const u8).init(self.alloc),
                .required_files = ArrayList([]const u8).init(self.alloc),
                .required_env_vars = ArrayList([]const u8).init(self.alloc),
            },
            .confidence = 0.5,
            .tags = ArrayList([]const u8).init(self.alloc),
        });
    }

    /// Add a new knowledge rule
    pub fn addRule(self: *KnowledgeRulesManager, rule_data: struct {
        name: []const u8,
        description: []const u8,
        pattern: KnowledgeRule.Pattern,
        action: KnowledgeRule.Action,
        context: KnowledgeRule.Context,
        confidence: f32,
        tags: ArrayList([]const u8),
    }) !*KnowledgeRule {
        const id = try std.fmt.allocPrint(self.alloc, "rule_{d}", .{std.time.timestamp()});
        
        const rule = try self.alloc.create(KnowledgeRule);
        rule.* = .{
            .id = id,
            .name = try self.alloc.dupe(u8, rule_data.name),
            .description = try self.alloc.dupe(u8, rule_data.description),
            .pattern = rule_data.pattern,
            .action = rule_data.action,
            .context = rule_data.context,
            .confidence = rule_data.confidence,
            .usage_count = 0,
            .last_used = 0,
            .created_at = std.time.timestamp(),
            .tags = rule_data.tags,
        };

        try self.rules.append(rule);
        try self.saveRule(rule);

        return rule;
    }

    /// Match rules against current context
    pub fn matchRules(
        self: *KnowledgeRulesManager,
        context: RuleContext,
    ) !ArrayList(RuleMatch) {
        var matches = ArrayList(RuleMatch).init(self.alloc);
        errdefer {
            for (matches.items) |*m| m.deinit(self.alloc);
            matches.deinit();
        }

        for (self.rules.items) |rule| {
            const confidence = self.calculateMatchConfidence(rule, context) catch continue;
            
            if (confidence >= self.auto_learn_threshold) {
                const matched_pattern = try self.extractMatchedPattern(rule, context);
                try matches.append(.{
                    .rule = rule,
                    .confidence = confidence,
                    .matched_pattern = matched_pattern,
                    .suggested_action = rule.action,
                });
            }
        }

        // Sort by confidence (highest first)
        std.sort.insertion(
            RuleMatch,
            matches.items,
            {},
            struct {
                fn compare(_: void, a: RuleMatch, b: RuleMatch) bool {
                    return a.confidence > b.confidence;
                }
            }.compare,
        );

        return matches;
    }

    /// Calculate how well a rule matches the current context
    fn calculateMatchConfidence(
        self: *const KnowledgeRulesManager,
        rule: *KnowledgeRule,
        context: RuleContext,
    ) !f32 {
        var confidence: f32 = 0.0;
        var factors: usize = 0;

        // Check pattern matching
        const pattern_match = self.matchPattern(rule.pattern, context);
        if (pattern_match > 0.0) {
            confidence += pattern_match * 0.5;
            factors += 1;
        } else {
            return 0.0; // Pattern must match
        }

        // Check context requirements
        var context_score: f32 = 0.0;
        var context_factors: usize = 0;

        // Check CWD patterns
        if (rule.context.cwd_patterns.items.len > 0) {
            for (rule.context.cwd_patterns.items) |pattern| {
                if (self.matchPathPattern(context.cwd, pattern)) {
                    context_score += 1.0;
                    break;
                }
            }
            context_factors += 1;
        }

        // Check required files
        if (rule.context.required_files.items.len > 0) {
            var all_present = true;
            for (rule.context.required_files.items) |file| {
                if (!self.fileExists(context.cwd, file)) {
                    all_present = false;
                    break;
                }
            }
            if (all_present) {
                context_score += 1.0;
            }
            context_factors += 1;
        }

        // Check required env vars
        if (rule.context.required_env_vars.items.len > 0) {
            var all_present = true;
            for (rule.context.required_env_vars.items) |var_name| {
                if (std.os.getenv(var_name) == null) {
                    all_present = false;
                    break;
                }
            }
            if (all_present) {
                context_score += 1.0;
            }
            context_factors += 1;
        }

        // Time-based context
        if (rule.context.time_of_day) |tod| {
            const current_tod = getCurrentTimeOfDay();
            if (current_tod == tod) {
                context_score += 0.5;
            }
            context_factors += 1;
        }

        // Combine scores
        if (context_factors > 0) {
            confidence += (context_score / @as(f32, @floatFromInt(context_factors))) * 0.3;
        }

        // Apply rule's base confidence
        confidence *= rule.confidence;

        // Boost confidence based on usage
        const usage_boost = @min(@as(f32, @floatFromInt(rule.usage_count)) / 10.0, 0.2);
        confidence += usage_boost;

        return @min(confidence, 1.0);
    }

    /// Match a pattern against context
    fn matchPattern(
        self: *const KnowledgeRulesManager,
        pattern: KnowledgeRule.Pattern,
        context: RuleContext,
    ) f32 {
        return switch (pattern) {
            .command_prefix => |prefix| {
                if (context.last_command) |cmd| {
                    if (std.mem.startsWith(u8, cmd, prefix)) {
                        return 1.0;
                    }
                }
                return 0.0;
            },
            .command_sequence => |seq| {
                if (context.command_history.items.len < seq.items.len) {
                    return 0.0;
                }
                var matches: usize = 0;
                const start_idx = context.command_history.items.len - seq.items.len;
                for (seq.items, 0..) |expected_cmd, i| {
                    const actual_cmd = context.command_history.items[start_idx + i];
                    if (std.mem.startsWith(u8, actual_cmd, expected_cmd)) {
                        matches += 1;
                    }
                }
                return @as(f32, @floatFromInt(matches)) / @as(f32, @floatFromInt(seq.items.len));
            },
            .file_pattern => |file_pattern| {
                if (self.matchPathPattern(context.cwd, file_pattern)) {
                    return 1.0;
                }
                return 0.0;
            },
            .git_state => |git_pattern| {
                if (context.git_state) |git| {
                    var score: f32 = 0.0;
                    var factors: usize = 0;
                    
                    if (git_pattern.branch_pattern) |branch_pat| {
                        if (git.branch) |branch| {
                            if (self.matchPathPattern(branch, branch_pat)) {
                                score += 1.0;
                            }
                        }
                        factors += 1;
                    }
                    
                    if (git_pattern.has_uncommitted) |expected| {
                        if (git.has_uncommitted == expected) {
                            score += 1.0;
                        }
                        factors += 1;
                    }
                    
                    if (git_pattern.has_staged) |expected| {
                        if (git.has_staged == expected) {
                            score += 1.0;
                        }
                        factors += 1;
                    }
                    
                    if (factors > 0) {
                        return score / @as(f32, @floatFromInt(factors));
                    }
                }
                return 0.0;
            },
            .directory_pattern => |dir_pattern| {
                if (self.matchPathPattern(context.cwd, dir_pattern)) {
                    return 1.0;
                }
                return 0.0;
            },
            .output_pattern => |output_pattern| {
                if (context.last_output) |output| {
                    if (std.mem.indexOf(u8, output, output_pattern) != null) {
                        return 1.0;
                    }
                }
                return 0.0;
            },
            .custom => |_| {
                // Custom patterns would be evaluated here
                return 0.5; // Placeholder
            },
        };
    }

    /// Match a path pattern (supports wildcards)
    fn matchPathPattern(_: *const KnowledgeRulesManager, path: []const u8, pattern: []const u8) bool {
        // Simple wildcard matching (* and ?)
        var path_idx: usize = 0;
        var pattern_idx: usize = 0;

        while (pattern_idx < pattern.len) {
            const p_char = pattern[pattern_idx];
            
            if (p_char == '*') {
                // Match zero or more characters
                pattern_idx += 1;
                if (pattern_idx >= pattern.len) return true; // * at end matches everything
                
                // Find next occurrence of pattern[pattern_idx] in path
                while (path_idx < path.len) {
                    if (path[path_idx] == pattern[pattern_idx]) {
                        break;
                    }
                    path_idx += 1;
                }
                if (path_idx >= path.len) return false;
            } else if (p_char == '?') {
                // Match single character
                if (path_idx >= path.len) return false;
                path_idx += 1;
                pattern_idx += 1;
            } else {
                // Exact match
                if (path_idx >= path.len or path[path_idx] != p_char) {
                    return false;
                }
                path_idx += 1;
                pattern_idx += 1;
            }
        }

        return path_idx >= path.len; // Must consume entire path
    }

    /// Check if file exists
    fn fileExists(_: *const KnowledgeRulesManager, cwd: []const u8, file_path: []const u8) bool {
        const full_path = std.fs.path.join(std.heap.page_allocator, &.{ cwd, file_path }) catch return false;
        defer std.heap.page_allocator.free(full_path);
        
        std.fs.accessAbsolute(full_path, .{}) catch return false;
        return true;
    }

    /// Extract matched pattern details
    fn extractMatchedPattern(
        self: *const KnowledgeRulesManager,
        rule: *KnowledgeRule,
        _: RuleContext,
    ) !RuleMatch.MatchedPattern {
        const details = switch (rule.pattern) {
            .command_prefix => |prefix| try std.fmt.allocPrint(self.alloc, "Command prefix: {s}", .{prefix}),
            .command_sequence => |seq| try std.fmt.allocPrint(self.alloc, "Command sequence: {d} commands", .{seq.items.len}),
            .file_pattern => |pattern| try std.fmt.allocPrint(self.alloc, "File pattern: {s}", .{pattern}),
            .git_state => |_| try self.alloc.dupe(u8, "Git state match"),
            .directory_pattern => |pattern| try std.fmt.allocPrint(self.alloc, "Directory pattern: {s}", .{pattern}),
            .output_pattern => |pattern| try std.fmt.allocPrint(self.alloc, "Output pattern: {s}", .{pattern}),
            .custom => |_| try self.alloc.dupe(u8, "Custom pattern"),
        };

        return .{
            .pattern_type = rule.pattern,
            .match_details = details,
        };
    }

    /// Learn from user behavior
    pub fn learnFromInteraction(
        self: *KnowledgeRulesManager,
        context: RuleContext,
        user_action: []const u8,
    ) !void {
        if (!self.learning_enabled) return;

        // Find matching rules
        const matches = try self.matchRules(context);
        defer {
            for (matches.items) |*m| m.deinit(self.alloc);
            matches.deinit();
        }

        // Check if user action matches any rule's suggestion
        for (matches.items) |match| {
            const action_matches = switch (match.suggested_action) {
                .suggest_command => |cmd| std.mem.startsWith(u8, user_action, cmd),
                .suggest_workflow => |wf| std.mem.eql(u8, user_action, wf),
                .auto_complete => |ac| std.mem.startsWith(u8, user_action, ac),
                else => false,
            };

            if (action_matches) {
                // User followed the suggestion - boost rule confidence
                match.rule.usage_count += 1;
                match.rule.last_used = std.time.timestamp();
                match.rule.confidence = @min(match.rule.confidence + 0.05, 1.0);
                try self.saveRule(match.rule);
            }
        }

        // Auto-learn: If user repeatedly does the same thing after a pattern,
        // create a new rule
        if (context.command_history.items.len >= 2) {
            const last_cmd = context.command_history.items[context.command_history.items.len - 1];
            const prev_cmd = context.command_history.items[context.command_history.items.len - 2];
            
            // Check if this pattern has occurred before
            var pattern_count: u32 = 0;
            if (context.command_history.items.len >= 4) {
                for (0..context.command_history.items.len - 1) |i| {
                    if (i + 1 < context.command_history.items.len) {
                        const cmd1 = context.command_history.items[i];
                        const cmd2 = context.command_history.items[i + 1];
                        if (std.mem.eql(u8, cmd1, prev_cmd) and std.mem.eql(u8, cmd2, last_cmd)) {
                            pattern_count += 1;
                        }
                    }
                }
            }

            // If pattern occurred 3+ times, create a rule
            if (pattern_count >= 3) {
                try self.addRule(.{
                    .name = try std.fmt.allocPrint(self.alloc, "Auto-learned: {s} -> {s}", .{ prev_cmd, last_cmd }),
                    .description = try self.alloc.dupe(u8, "Auto-learned from user behavior"),
                    .pattern = .{
                        .command_sequence = blk: {
                            var seq = ArrayList([]const u8).init(self.alloc);
                            try seq.append(try self.alloc.dupe(u8, prev_cmd));
                            break :blk seq;
                        },
                    },
                    .action = .{
                        .suggest_command = try self.alloc.dupe(u8, last_cmd),
                    },
                    .context = .{
                        .cwd_patterns = ArrayList([]const u8).init(self.alloc),
                        .required_files = ArrayList([]const u8).init(self.alloc),
                        .required_env_vars = ArrayList([]const u8).init(self.alloc),
                    },
                    .confidence = 0.6,
                    .tags = ArrayList([]const u8).init(self.alloc),
                });
            }
        }
    }

    /// Get current time of day
    fn getCurrentTimeOfDay() KnowledgeRule.TimeOfDay {
        const now = std.time.timestamp();
        const tm = std.posix.localtime(@intCast(now));
        const hour = tm.tm_hour;
        
        return if (hour >= 6 and hour < 12)
            .morning
        else if (hour >= 12 and hour < 17)
            .afternoon
        else if (hour >= 17 and hour < 22)
            .evening
        else
            .night;
    }

    /// Save a rule to disk
    fn saveRule(self: *KnowledgeRulesManager, rule: *KnowledgeRule) !void {
        const file_path = try std.fs.path.join(self.alloc, &.{ self.storage_path, rule.id ++ ".json" });
        defer self.alloc.free(file_path);

        const file = try std.fs.createFileAbsolute(file_path, .{});
        defer file.close();

        var json_stream = json.writeStream(file.writer(), .{});
        try json_stream.beginObject();
        
        try json_stream.objectField("id");
        try json_stream.emitString(rule.id);
        
        try json_stream.objectField("name");
        try json_stream.emitString(rule.name);
        
        try json_stream.objectField("description");
        try json_stream.emitString(rule.description);
        
        try json_stream.objectField("confidence");
        try json_stream.emitNumber(rule.confidence);
        
        try json_stream.objectField("usage_count");
        try json_stream.emitNumber(rule.usage_count);
        
        try json_stream.objectField("last_used");
        try json_stream.emitNumber(rule.last_used);
        
        try json_stream.objectField("created_at");
        try json_stream.emitNumber(rule.created_at);
        
        try json_stream.endObject();
    }

    /// Load all rules from disk
    fn loadAllRules(self: *KnowledgeRulesManager) !void {
        var dir = std.fs.openDirAbsolute(self.storage_path, .{}) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                _ = self.loadRule(entry.name) catch |err| {
                    log.warn("Failed to load rule {s}: {}", .{ entry.name, err });
                    continue;
                };
            }
        }
    }

    /// Load a single rule from disk
    fn loadRule(self: *KnowledgeRulesManager, filename: []const u8) !*KnowledgeRule {
        const file_path = try std.fs.path.join(self.alloc, &.{ self.storage_path, filename });
        defer self.alloc.free(file_path);
        
        const file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();
        
        const file_size = try file.getEndPos();
        const contents = try self.alloc.alloc(u8, file_size);
        defer self.alloc.free(contents);
        
        _ = try file.readAll(contents);
        
        var json_parser = json.Parser.init(self.alloc, .alloc_always);
        defer json_parser.deinit();
        
        const tree = try json_parser.parse(contents);
        defer tree.deinit();
        
        const root = tree.root;
        const id = root.object.get("id").?.string;
        
        // Create rule from JSON (simplified - full implementation would parse all fields)
        const rule = try self.alloc.create(KnowledgeRule);
        rule.* = .{
            .id = try self.alloc.dupe(u8, id),
            .name = try self.alloc.dupe(u8, root.object.get("name").?.string),
            .description = try self.alloc.dupe(u8, root.object.get("description").?.string),
            .pattern = .{ .command_prefix = try self.alloc.dupe(u8, "") },
            .action = .{ .suggest_command = try self.alloc.dupe(u8, "") },
            .context = .{
                .cwd_patterns = ArrayList([]const u8).init(self.alloc),
                .required_files = ArrayList([]const u8).init(self.alloc),
                .required_env_vars = ArrayList([]const u8).init(self.alloc),
            },
            .confidence = @floatCast(root.object.get("confidence").?.float),
            .usage_count = @intCast(root.object.get("usage_count").?.integer),
            .last_used = @intCast(root.object.get("last_used").?.integer),
            .created_at = @intCast(root.object.get("created_at").?.integer),
            .tags = ArrayList([]const u8).init(self.alloc),
        };
        
        try self.rules.append(rule);
        return rule;
    }

    /// Enable or disable learning
    pub fn setLearningEnabled(self: *KnowledgeRulesManager, enabled: bool) void {
        self.learning_enabled = enabled;
    }

    /// Get top suggestions based on current context
    pub fn getSuggestions(
        self: *KnowledgeRulesManager,
        context: RuleContext,
        max_suggestions: usize,
    ) !ArrayList(Suggestion) {
        const matches = try self.matchRules(context);
        defer {
            for (matches.items) |*m| m.deinit(self.alloc);
            matches.deinit();
        }

        var suggestions = ArrayList(Suggestion).init(self.alloc);
        errdefer {
            for (suggestions.items) |*s| s.deinit(self.alloc);
            suggestions.deinit();
        }

        const limit = @min(max_suggestions, matches.items.len);
        for (matches.items[0..limit]) |match| {
            const suggestion = switch (match.suggested_action) {
                .suggest_command => |cmd| Suggestion{
                    .type = .command,
                    .text = try self.alloc.dupe(u8, cmd),
                    .confidence = match.confidence,
                    .rule_name = try self.alloc.dupe(u8, match.rule.name),
                },
                .suggest_workflow => |wf| Suggestion{
                    .type = .workflow,
                    .text = try self.alloc.dupe(u8, wf),
                    .confidence = match.confidence,
                    .rule_name = try self.alloc.dupe(u8, match.rule.name),
                },
                .show_hint => |hint| Suggestion{
                    .type = .hint,
                    .text = try self.alloc.dupe(u8, hint),
                    .confidence = match.confidence,
                    .rule_name = try self.alloc.dupe(u8, match.rule.name),
                },
                else => continue,
            };
            try suggestions.append(suggestion);
        }

        return suggestions;
    }

    pub const Suggestion = struct {
        type: SuggestionType,
        text: []const u8,
        confidence: f32,
        rule_name: []const u8,

        pub const SuggestionType = enum {
            command,
            workflow,
            hint,
            warning,
        };

        pub fn deinit(self: *Suggestion, alloc: Allocator) void {
            alloc.free(self.text);
            alloc.free(self.rule_name);
        }
    };

    pub const RuleContext = struct {
        cwd: []const u8,
        last_command: ?[]const u8,
        command_history: ArrayList([]const u8),
        last_output: ?[]const u8,
        git_state: ?GitState = null,
        env_vars: StringHashMap([]const u8),

        pub const GitState = struct {
            branch: ?[]const u8,
            has_uncommitted: bool,
            has_staged: bool,
            is_detached: bool,
        };
    };
};
