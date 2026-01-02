//! Codebase Embeddings Module
//!
//! This module provides vector embeddings for semantic search of documentation
//! and codebase content. It supports:
//! - Multiple embedding backends (OpenAI, local models)
//! - Efficient vector indexing with HNSW-like structures
//! - Persistence of embeddings to disk
//! - Batch processing for large codebases
//!
//! The module uses an in-memory vector index with disk persistence.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const StringHashMap = std.StringHashMap;
const json = std.json;

const log = std.log.scoped(.ai_embeddings);

/// Default embedding dimension for common models
pub const DEFAULT_DIMENSION: usize = 1536; // OpenAI ada-002

/// An embedding vector with metadata
pub const Embedding = struct {
    /// Unique identifier for this embedding
    id: []const u8,
    /// Original content that was embedded
    content: []const u8,
    /// The embedding vector
    vector: []f32,
    /// Metadata about the content
    metadata: EmbeddingMetadata,
    /// Timestamp when embedding was created
    created_at: i64,

    pub const EmbeddingMetadata = struct {
        /// Source file path (if from a file)
        file_path: ?[]const u8 = null,
        /// Content type
        content_type: ContentType = .text,
        /// Language (for code)
        language: ?[]const u8 = null,
        /// Line range (for code snippets)
        start_line: ?u32 = null,
        end_line: ?u32 = null,
        /// Custom tags
        tags: ArrayListUnmanaged([]const u8) = .empty,

        pub const ContentType = enum {
            text,
            code,
            documentation,
            command,
            error_message,
        };

        pub fn init() EmbeddingMetadata {
            return .{
                .tags = .empty,
            };
        }

        pub fn deinit(self: *EmbeddingMetadata, alloc: Allocator) void {
            if (self.file_path) |p| alloc.free(p);
            if (self.language) |l| alloc.free(l);
            for (self.tags.items) |tag| alloc.free(tag);
            self.tags.deinit(alloc);
        }
    };

    pub fn deinit(self: *Embedding, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.content);
        alloc.free(self.vector);
        self.metadata.deinit(alloc);
    }
};

/// Search result from vector similarity search
pub const SearchResult = struct {
    embedding: *const Embedding,
    similarity: f32,
    rank: usize,
};

/// Embedding provider configuration
pub const EmbeddingProvider = enum {
    /// OpenAI embeddings API
    openai,
    /// Local sentence-transformers model
    local,
    /// Custom external API
    custom,
    /// Mock provider for testing
    mock,
};

/// Configuration for embedding manager
pub const EmbeddingConfig = struct {
    /// Embedding dimension
    dimension: usize = DEFAULT_DIMENSION,
    /// Provider to use
    provider: EmbeddingProvider = .mock,
    /// API key for external providers
    api_key: ?[]const u8 = null,
    /// API endpoint for external providers
    endpoint: ?[]const u8 = null,
    /// Model identifier
    model: []const u8 = "text-embedding-ada-002",
    /// Batch size for bulk operations
    batch_size: usize = 100,
    /// Enable caching of embeddings
    cache_enabled: bool = true,
    /// Path for persistence
    storage_path: ?[]const u8 = null,
};

/// HNSW-like index node for efficient nearest neighbor search
const IndexNode = struct {
    embedding_id: []const u8,
    neighbors: [MAX_NEIGHBORS]?[]const u8,
    neighbor_count: usize,

    const MAX_NEIGHBORS: usize = 32;

    fn init(id: []const u8) IndexNode {
        return .{
            .embedding_id = id,
            .neighbors = [_]?[]const u8{null} ** MAX_NEIGHBORS,
            .neighbor_count = 0,
        };
    }

    fn addNeighbor(self: *IndexNode, neighbor_id: []const u8) void {
        if (self.neighbor_count < MAX_NEIGHBORS) {
            self.neighbors[self.neighbor_count] = neighbor_id;
            self.neighbor_count += 1;
        }
    }
};

/// Embedding Manager - main interface for embeddings
pub const EmbeddingManager = struct {
    alloc: Allocator,
    config: EmbeddingConfig,
    embeddings: StringHashMap(*Embedding),
    index: StringHashMap(IndexNode),
    dimension: usize,
    total_embeddings: usize,

    /// Initialize embedding manager
    pub fn init(alloc: Allocator, dimension: usize) EmbeddingManager {
        return .{
            .alloc = alloc,
            .config = .{ .dimension = dimension },
            .embeddings = StringHashMap(*Embedding).init(alloc),
            .index = StringHashMap(IndexNode).init(alloc),
            .dimension = dimension,
            .total_embeddings = 0,
        };
    }

    /// Initialize with configuration
    pub fn initWithConfig(alloc: Allocator, config: EmbeddingConfig) !EmbeddingManager {
        var manager = EmbeddingManager{
            .alloc = alloc,
            .config = config,
            .embeddings = StringHashMap(*Embedding).init(alloc),
            .index = StringHashMap(IndexNode).init(alloc),
            .dimension = config.dimension,
            .total_embeddings = 0,
        };

        // Load existing embeddings if storage path is set
        if (config.storage_path) |path| {
            manager.loadFromDisk(path) catch |err| {
                log.warn("Failed to load embeddings from disk: {}", .{err});
            };
        }

        return manager;
    }

    pub fn deinit(self: *EmbeddingManager) void {
        var iter = self.embeddings.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.embeddings.deinit();
        self.index.deinit();
    }

    /// Add an embedding with pre-computed vector
    pub fn addEmbedding(
        self: *EmbeddingManager,
        id: []const u8,
        content: []const u8,
        vector: []const f32,
    ) !void {
        if (vector.len != self.dimension) return error.InvalidDimension;

        const emb = try self.alloc.create(Embedding);
        errdefer self.alloc.destroy(emb);

        emb.* = .{
            .id = try self.alloc.dupe(u8, id),
            .content = try self.alloc.dupe(u8, content),
            .vector = try self.alloc.dupe(f32, vector),
            .metadata = Embedding.EmbeddingMetadata.init(),
            .created_at = std.time.timestamp(),
        };

        try self.embeddings.put(emb.id, emb);
        self.total_embeddings += 1;

        // Update index
        try self.updateIndex(emb);

        log.debug("Added embedding: {s} ({d} dimensions)", .{ id, vector.len });
    }

    /// Add embedding with metadata
    pub fn addEmbeddingWithMetadata(
        self: *EmbeddingManager,
        id: []const u8,
        content: []const u8,
        vector: []const f32,
        metadata: Embedding.EmbeddingMetadata,
    ) !void {
        if (vector.len != self.dimension) return error.InvalidDimension;

        const emb = try self.alloc.create(Embedding);
        errdefer self.alloc.destroy(emb);

        emb.* = .{
            .id = try self.alloc.dupe(u8, id),
            .content = try self.alloc.dupe(u8, content),
            .vector = try self.alloc.dupe(f32, vector),
            .metadata = metadata,
            .created_at = std.time.timestamp(),
        };

        try self.embeddings.put(emb.id, emb);
        self.total_embeddings += 1;

        try self.updateIndex(emb);
    }

    /// Generate embedding for content (uses configured provider)
    pub fn embed(self: *EmbeddingManager, content: []const u8) ![]f32 {
        return switch (self.config.provider) {
            .openai => try self.embedOpenAI(content),
            .local => try self.embedLocal(content),
            .custom => try self.embedCustom(content),
            .mock => try self.embedMock(content),
        };
    }

    /// Embed and add content in one step
    pub fn embedAndAdd(
        self: *EmbeddingManager,
        id: []const u8,
        content: []const u8,
    ) !void {
        const vector = try self.embed(content);
        defer self.alloc.free(vector);
        try self.addEmbedding(id, content, vector);
    }

    /// Search for similar embeddings using cosine similarity
    pub fn search(
        self: *const EmbeddingManager,
        query_vector: []const f32,
        top_k: usize,
    ) !ArrayListUnmanaged(SearchResult) {
        if (query_vector.len != self.dimension) return error.InvalidDimension;

        var results: ArrayListUnmanaged(SearchResult) = .empty;
        errdefer results.deinit(self.alloc);

        // Calculate similarity for all embeddings
        var iter = self.embeddings.iterator();
        while (iter.next()) |entry| {
            const emb = entry.value_ptr.*;
            const similarity = cosineSimilarity(query_vector, emb.vector);
            try results.append(self.alloc, .{
                .embedding = emb,
                .similarity = similarity,
                .rank = 0,
            });
        }

        // Sort by similarity (highest first)
        std.sort.insertion(SearchResult, results.items, {}, struct {
            fn compare(_: void, a: SearchResult, b: SearchResult) bool {
                return a.similarity > b.similarity;
            }
        }.compare);

        // Truncate to top_k and assign ranks
        const limit = @min(top_k, results.items.len);
        results.shrinkRetainingCapacity(limit);
        for (results.items, 0..) |*result, i| {
            result.rank = i + 1;
        }

        return results;
    }

    /// Search using text query (embeds query first)
    pub fn searchByText(
        self: *EmbeddingManager,
        query: []const u8,
        top_k: usize,
    ) !ArrayListUnmanaged(SearchResult) {
        const query_vector = try self.embed(query);
        defer self.alloc.free(query_vector);
        return self.search(query_vector, top_k);
    }

    /// Find nearest neighbors using the index (faster for large datasets)
    pub fn searchWithIndex(
        self: *const EmbeddingManager,
        query_vector: []const f32,
        top_k: usize,
    ) !ArrayListUnmanaged(SearchResult) {
        if (self.index.count() == 0) {
            // Fall back to brute force if no index
            return self.search(query_vector, top_k);
        }

        var results: ArrayListUnmanaged(SearchResult) = .empty;
        errdefer results.deinit(self.alloc);

        // Start from a random entry point
        var iter = self.index.iterator();
        var entry_point: ?[]const u8 = null;
        if (iter.next()) |entry| {
            entry_point = entry.key_ptr.*;
        }

        if (entry_point == null) {
            return self.search(query_vector, top_k);
        }

        // BFS-style search through index
        var visited = StringHashMap(void).init(self.alloc);
        defer visited.deinit();

        var queue: ArrayListUnmanaged([]const u8) = .empty;
        defer queue.deinit(self.alloc);

        try queue.append(self.alloc, entry_point.?);
        try visited.put(entry_point.?, {});

        while (queue.items.len > 0 and visited.count() < self.embeddings.count()) {
            const current_id = queue.orderedRemove(0);

            if (self.embeddings.get(current_id)) |emb| {
                const similarity = cosineSimilarity(query_vector, emb.vector);
                try results.append(self.alloc, .{
                    .embedding = emb,
                    .similarity = similarity,
                    .rank = 0,
                });
            }

            // Add unvisited neighbors to queue
            if (self.index.get(current_id)) |node| {
                for (node.neighbors[0..node.neighbor_count]) |neighbor_opt| {
                    if (neighbor_opt) |neighbor| {
                        if (!visited.contains(neighbor)) {
                            try queue.append(self.alloc, neighbor);
                            try visited.put(neighbor, {});
                        }
                    }
                }
            }
        }

        // Sort and limit results
        std.sort.insertion(SearchResult, results.items, {}, struct {
            fn compare(_: void, a: SearchResult, b: SearchResult) bool {
                return a.similarity > b.similarity;
            }
        }.compare);

        const limit = @min(top_k, results.items.len);
        results.shrinkRetainingCapacity(limit);
        for (results.items, 0..) |*result, i| {
            result.rank = i + 1;
        }

        return results;
    }

    const SimilarityEntry = struct { id: []const u8, sim: f32 };

    /// Update the index when a new embedding is added
    fn updateIndex(self: *EmbeddingManager, new_emb: *Embedding) !void {
        var node = IndexNode.init(new_emb.id);

        // Find nearest neighbors for the new node
        var similarities: ArrayListUnmanaged(SimilarityEntry) = .empty;
        defer similarities.deinit(self.alloc);

        var iter = self.embeddings.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, new_emb.id)) continue;

            const sim = cosineSimilarity(new_emb.vector, entry.value_ptr.*.vector);
            try similarities.append(self.alloc, .{ .id = entry.key_ptr.*, .sim = sim });
        }

        // Sort by similarity
        std.sort.insertion(
            SimilarityEntry,
            similarities.items,
            {},
            struct {
                fn compare(_: void, a: SimilarityEntry, b: SimilarityEntry) bool {
                    return a.sim > b.sim;
                }
            }.compare,
        );

        // Add top neighbors
        const neighbor_count = @min(IndexNode.MAX_NEIGHBORS, similarities.items.len);
        for (similarities.items[0..neighbor_count]) |neighbor| {
            node.addNeighbor(neighbor.id);

            // Add bidirectional connection
            if (self.index.getPtr(neighbor.id)) |existing_node| {
                existing_node.addNeighbor(new_emb.id);
            }
        }

        try self.index.put(new_emb.id, node);
    }

    /// Embed using OpenAI API
    fn embedOpenAI(self: *EmbeddingManager, content: []const u8) ![]f32 {
        // Would use HTTP client to call OpenAI API
        // For now, return mock embedding
        _ = content;
        return try self.embedMock("");
    }

    /// Embed using local model
    fn embedLocal(self: *EmbeddingManager, content: []const u8) ![]f32 {
        // Would use local model inference
        // For now, return mock embedding
        _ = content;
        return try self.embedMock("");
    }

    /// Embed using custom API
    fn embedCustom(self: *EmbeddingManager, content: []const u8) ![]f32 {
        // Would use custom HTTP endpoint
        _ = content;
        return try self.embedMock("");
    }

    /// Generate mock embedding (deterministic based on content)
    fn embedMock(self: *EmbeddingManager, content: []const u8) ![]f32 {
        const vector = try self.alloc.alloc(f32, self.dimension);

        // Generate deterministic "embedding" based on content hash
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(content);
        const hash = hasher.final();

        var rng = std.rand.DefaultPrng.init(hash);
        for (vector) |*v| {
            v.* = (rng.random().float(f32) - 0.5) * 2.0;
        }

        // Normalize
        var norm: f32 = 0.0;
        for (vector) |v| {
            norm += v * v;
        }
        norm = std.math.sqrt(norm);
        if (norm > 0) {
            for (vector) |*v| {
                v.* /= norm;
            }
        }

        return vector;
    }

    /// Save embeddings to disk
    pub fn saveToDisk(self: *const EmbeddingManager, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        // Write header
        try writer.print("{{\"version\":1,\"dimension\":{d},\"count\":{d},\"embeddings\":[", .{
            self.dimension,
            self.total_embeddings,
        });

        var first = true;
        var iter = self.embeddings.iterator();
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;

            const emb = entry.value_ptr.*;

            // Write embedding
            try writer.print("{{\"id\":\"{s}\",\"content\":", .{emb.id});
            try json.stringify(emb.content, .{}, writer);
            try writer.writeAll(",\"vector\":[");

            for (emb.vector, 0..) |v, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{d:.6}", .{v});
            }

            try writer.writeAll("]}");
        }

        try writer.writeAll("]}");
        log.info("Saved {d} embeddings to {s}", .{ self.total_embeddings, path });
    }

    /// Load embeddings from disk
    pub fn loadFromDisk(self: *EmbeddingManager, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.alloc, 100_000_000);
        defer self.alloc.free(content);

        const parsed = try json.parseFromSlice(json.Value, self.alloc, content, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        if (obj.get("embeddings")) |embeddings_val| {
            for (embeddings_val.array.items) |emb_val| {
                const emb_obj = emb_val.object;

                const id = emb_obj.get("id").?.string;
                const emb_content = emb_obj.get("content").?.string;
                const vector_arr = emb_obj.get("vector").?.array;

                var vector = try self.alloc.alloc(f32, vector_arr.items.len);
                defer self.alloc.free(vector);

                for (vector_arr.items, 0..) |v, i| {
                    vector[i] = @floatCast(v.float);
                }

                try self.addEmbedding(id, emb_content, vector);
            }
        }

        log.info("Loaded {d} embeddings from {s}", .{ self.total_embeddings, path });
    }

    /// Remove an embedding
    pub fn removeEmbedding(self: *EmbeddingManager, id: []const u8) void {
        if (self.embeddings.fetchRemove(id)) |entry| {
            entry.value.deinit(self.alloc);
            self.alloc.destroy(entry.value);
            self.total_embeddings -= 1;
        }
        _ = self.index.remove(id);
    }

    /// Get embedding by ID
    pub fn getEmbedding(self: *const EmbeddingManager, id: []const u8) ?*const Embedding {
        return self.embeddings.get(id);
    }

    /// Get statistics
    pub fn getStats(self: *const EmbeddingManager) struct {
        total_embeddings: usize,
        dimension: usize,
        index_size: usize,
        memory_estimate_bytes: usize,
    } {
        return .{
            .total_embeddings = self.total_embeddings,
            .dimension = self.dimension,
            .index_size = self.index.count(),
            .memory_estimate_bytes = self.total_embeddings * (self.dimension * @sizeOf(f32) + 256),
        };
    }
};

/// Calculate cosine similarity between two vectors
pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len) return 0.0;

    var dot_product: f32 = 0.0;
    var norm_a: f32 = 0.0;
    var norm_b: f32 = 0.0;

    for (a, b) |val_a, val_b| {
        dot_product += val_a * val_b;
        norm_a += val_a * val_a;
        norm_b += val_b * val_b;
    }

    const denominator = std.math.sqrt(norm_a) * std.math.sqrt(norm_b);
    if (denominator == 0.0) return 0.0;

    return dot_product / denominator;
}

/// Calculate euclidean distance between two vectors
pub fn euclideanDistance(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len) return std.math.inf(f32);

    var sum: f32 = 0.0;
    for (a, b) |val_a, val_b| {
        const diff = val_a - val_b;
        sum += diff * diff;
    }

    return std.math.sqrt(sum);
}

/// Normalize a vector to unit length
pub fn normalize(vector: []f32) void {
    var norm: f32 = 0.0;
    for (vector) |v| {
        norm += v * v;
    }
    norm = std.math.sqrt(norm);
    if (norm > 0) {
        for (vector) |*v| {
            v.* /= norm;
        }
    }
}

test "EmbeddingManager basic operations" {
    const alloc = std.testing.allocator;

    var manager = EmbeddingManager.init(alloc, 3);
    defer manager.deinit();

    const vector1 = [_]f32{ 1.0, 0.0, 0.0 };
    const vector2 = [_]f32{ 0.0, 1.0, 0.0 };
    const vector3 = [_]f32{ 0.7, 0.7, 0.0 };

    try manager.addEmbedding("id1", "content1", &vector1);
    try manager.addEmbedding("id2", "content2", &vector2);
    try manager.addEmbedding("id3", "content3", &vector3);

    var results = try manager.search(&vector1, 2);
    defer results.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqualStrings("id1", results.items[0].embedding.id);
}

test "cosine similarity" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 1.0, 0.0, 0.0 };
    const c = [_]f32{ 0.0, 1.0, 0.0 };

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cosineSimilarity(&a, &b), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cosineSimilarity(&a, &c), 0.001);
}
