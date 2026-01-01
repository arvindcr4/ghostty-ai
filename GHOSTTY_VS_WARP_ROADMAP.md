# Ghostty AI Features - Warp Terminal Parity Roadmap

## Overview

This document tracks Ghostty's AI feature implementation progress toward feature parity with Warp Terminal's AI capabilities as of 2025.

**Current Status:** Ghostty has foundational AI input mode (completed ~Q1 2025) but lacks Warp's flagship agentic features.

---

## Feature Comparison Matrix

| Feature | Warp Terminal | Ghostty Current | Ghostty Task ID | Priority |
|---------|--------------|-----------------|-----------------|----------|
| **AI Command Search** (# prefix) | ✅ Native | ❌ Missing | ghostty-4pq | P0 |
| **Active AI** (proactive suggestions) | ✅ Native | ❌ Missing | ghostty-7q1 | P0 |
| **Agent Mode** (conversational workflows) | ✅ Native | ❌ Missing | ghostty-9of | P0 |
| Streaming Responses | ✅ Yes | ❌ Blocking | ghostty-i38 | P1 |
| Conversation History | ✅ Yes | ❌ Missing | ghostty-0tc | P1 |
| Inline Explanations (hover) | ✅ Yes | ❌ Missing | ghostty-095 | P1 |
| Workflow Automation | ✅ Warp Drive | ❌ Missing | ghostty-5si | P2 |
| Multi-Provider Failover | ❌ No | ❌ Missing | ghostty-5al | P2 |
| Shell-Specific AI | ✅ Yes | ⚠️ Partial | ghostty-0q2 | P1 |
| One-Click Command Execution | ✅ Yes | ❌ Missing | ghostty-75y | P1 |
| Voice Input | ✅ Yes | ❌ Missing | ghostty-7pb | P3 |
| Custom Templates | ✅ Yes | ❌ Missing | ghostty-9up | P2 |
| Script Generation | ✅ Yes | ❌ Missing | ghostty-7nj | P2 |
| Note-Taking Integration | ✅ Warp Drive | ❌ Missing | ghostty-2ti | P3 |
| Team Collaboration | ✅ Enterprise | ❌ Missing | ghostty-hty | P3 |
| Codebase Awareness (RAG) | ✅ Yes | ❌ Missing | ghostty-9rp | P2 |

**Legend:** ✅ Implemented | ⚠️ Partial | ❌ Missing

---

## Completed Features (Ghostty)

Ghostty's current AI implementation (Q1 2025) includes:

- ✅ AI Configuration System (providers: OpenAI, Anthropic, Ollama, custom)
- ✅ AI Input Mode UI (GTK4/libadwaita dialog)
- ✅ Template System (8 built-in templates)
- ✅ Terminal Context Extraction (selection + history)
- ✅ Keybinding Support (Ctrl+Space configurable)
- ✅ Response Display with copy support

**Files:** `src/config/ai.zig`, `src/ai/client.zig`, `src/ai/main.zig`, `src/apprt/gtk/class/ai_input_mode.zig`

---

## Remaining Tasks by Priority

### Priority P0 (Warp Flagships) - High Impact, Core Differentiators

#### 1. AI Command Search with '#' Prefix [ghostty-4pq]
**Warp Reference:** https://docs.warp.dev/features/ai-command-search

**What:** Type `#` + natural language to find commands semantically
**Example:** `#list all docker containers running` → suggests `docker ps`

**Implementation:**
- [ ] Add '#' keybinding handler in input system
- [ ] Create command search UI overlay
- [ ] Index terminal history for semantic search
- [ ] AI integration for NL understanding
- [ ] Ranked suggestions with explanations

**Estimated Complexity:** High (requires indexing + search UI)

---

#### 2. Active AI - Proactive Error Detection [ghostty-7q1]
**Warp Reference:** https://docs.warp.dev/agents/active-ai

**What:** AI monitors terminal output and suggests fixes automatically
**Example:** `command not found: kubectl` → Suggestion: "Install kubectl via brew..."

**Implementation:**
- [ ] Background error detection service
- [ ] Pattern matching for common errors
- [ ] AI contextual fix generation
- [ ] Non-intrusive suggestion cards UI
- [ ] Telemetry for suggestion feedback

**Estimated Complexity:** High (async + threading)

---

#### 3. Agent Mode - Conversational Workflows [ghostty-9of]
**Warp Reference:** https://www.warp.dev/ai

**What:** Multi-turn AI conversations that execute terminal commands
**Example:** "Deploy my app to staging and verify it's running" → Agent runs git push, checks logs, etc.

**Implementation:**
- [ ] Conversation loop with message history
- [ ] Tool execution framework
- [ ] Context management across turns
- [ ] Streaming response rendering
- [ ] Safety boundaries and confirmations
- [ ] MCP protocol support

**Estimated Complexity:** Very High (full agent architecture)

---

### Priority P1 (Core UX) - Essential for Daily Use

#### 4. Streaming Responses [ghostty-i38]
**Why:** Current blocking calls feel slow; streaming provides instant feedback
**Current:** `req.readAllAlloc()` in client.zig:94 blocks UI

**Implementation:**
- [ ] Add SSE support to client.zig
- [ ] Streaming response parser
- [ ] Incremental GTK renderer
- [ ] Partial markdown handling
- [ ] Stop/regenerate buttons

**Estimated Complexity:** Medium

---

#### 5. Conversation History [ghostty-0tc]
**Why:** Users lose context between sessions; can't recall past AI help

**Implementation:**
- [ ] Storage schema (JSON/SQLite)
- [ ] History manager (src/ai/history.zig)
- [ ] History browser UI
- [ ] Search and filter
- [ ] Continue/edit functionality

**Estimated Complexity:** Medium

---

#### 6. Inline Explanations on Hover [ghostty-095]
**Why:** Learning happens in-context; no need to open separate docs

**Implementation:**
- [ ] Text hover detection in terminal
- [ ] Command/flag parsing
- [ ] Cached AI explanations
- [ ] Tooltip UI component

**Estimated Complexity:** Medium (terminal widget integration)

---

#### 7. Shell-Specific AI Optimizations [ghostty-0q2]
**Why:** Generated commands must match current shell syntax

**Implementation:**
- [ ] Shell detection (SHELL env var)
- [ ] Shell-specific prompt templates
- [ ] Alias awareness and expansion
- [ ] Syntax validation

**Estimated Complexity:** Low-Medium

---

#### 8. One-Click Command Execution [ghostty-75y]
**Why:** Closes loop between suggestion and action; reduces typing

**Implementation:**
- [ ] Parse commands from AI responses
- [ ] 'Run' button UI
- [ ] Surface.performBindingAction integration
- [ ] Safety confirmations for destructive commands

**Estimated Complexity:** Low-Medium

---

### Priority P2 (Advanced Features) - Power User Capabilities

#### 9. Workflow Automation [ghostty-5si]
**What:** Save and reuse AI-powered task sequences
**Example:** "Deploy to staging" workflow: git status → run tests → push → verify

**Implementation:**
- [ ] Workflow file format (YAML)
- [ ] Workflow engine (src/ai/workflow.zig)
- [ ] Recorder UI
- [ ] Variable substitution

**Estimated Complexity:** High

---

#### 10. Custom Template Management [ghostty-9up]
**What:** Users create and share prompt templates

**Implementation:**
- [ ] Template user directory
- [ ] Template editor UI
- [ ] 'Save as template' action
- [ ] Import/export functionality

**Estimated Complexity:** Medium

---

#### 11. Script Generation [ghostty-7nj]
**What:** AI generates complete scripts from descriptions

**Implementation:**
- [ ] Script generation template
- [ ] File context awareness
- [ ] Language detection (shebang)
- [ ] Insert into editor or save

**Estimated Complexity:** Medium

---

#### 12. Multi-Provider Failover [ghostty-5al]
**Why:** Improve reliability and manage rate limits

**Implementation:**
- [ ] Provider priority list in config
- [ ] Retry logic with exponential backoff
- [ ] Health check system
- [ ] Cost tracking

**Estimated Complexity:** Medium

---

#### 13. Codebase-Aware Suggestions (RAG) [ghostty-9rp]
**What:** AI understands project context from code files

**Implementation:**
- [ ] File indexing service
- [ ] Embedding generation
- [ ] Vector database (sqlite-vss)
- [ ] RAG pipeline
- [ ] Privacy controls (.aiignore)

**Estimated Complexity:** Very High

---

### Priority P3 (Future Enhancements) - Nice to Have

#### 14. Voice Input [ghostty-7pb]
**Platform challenges:** macOS Speech Framework, Linux speech-dispatcher

#### 15. Note-Taking Integration [ghostty-2ti]
**Integration options:** Obsidian, Logseq, or built-in notes

#### 16. Team Collaboration [ghostty-hty]
**Enterprise feature:** Requires cloud backend, authentication

---

## Architecture Recommendations

### For Command Search (ghostty-4pq)
```zig
// Proposed: src/ai/command_search.zig
pub const CommandSearch = struct {
    index: std.StringHashMap(CommandEntry),
    embeddings: ?EmbeddingEngine,

    pub fn search(self: *const Self, query: []const u8) ![]Suggestion {
        // Semantic search over indexed commands
    }
};
```

### For Active AI (ghostty-7q1)
```zig
// Proposed: src/ai/active_monitor.zig
pub const ActiveMonitor = struct {
    event_channel: std.Channel(OutputEvent),
    suggestion_channel: std.Channel(Suggestion),

    pub fn start(self: *Self) !void {
        // Background thread monitoring terminal output
    }
};
```

### For Agent Mode (ghostty-9of)
```zig
// Proposed: src/ai/agent.zig
pub const Agent = struct {
    conversation: ConversationHistory,
    tools: []Tool,
    running: bool,

    pub fn run(self: *Self, user_input: []const u8) !void {
        // Multi-turn agent loop with tool use
    }
};
```

---

## Dependencies to Add

For full Warp parity:
- **Embeddings:** OpenAI text-embedding-3 or ollama/nomic-embed-text
- **Vector DB:** sqlite-vss (SQLite extension) or standalone qdrant
- **Streaming:** SSE parser for HTTP client
- **Threading:** Async task queue for Active AI monitoring

---

## Implementation Phases

### Phase 1: Quick Wins (1-2 weeks)
- ghostty-i38 (Streaming) - High UX impact
- ghostty-75y (One-Click Execution) - Low complexity
- ghostty-0q2 (Shell-Specific AI) - Medium value

### Phase 2: Core Features (4-6 weeks)
- ghostty-4pq (Command Search) - Warp signature feature
- ghostty-0tc (Conversation History) - Expected table stakes
- ghostty-095 (Inline Explanations) - Educational value

### Phase 3: Advanced (8-12 weeks)
- ghostty-7q1 (Active AI) - Complex threading
- ghostty-5si (Workflows) - New subsystem
- ghostty-9up (Custom Templates) - User empowerment

### Phase 4: Flagship (12-20 weeks)
- ghostty-9of (Agent Mode) - Largest effort
- ghostty-9rp (Codebase RAG) - Requires embeddings infrastructure

---

## Warp Terminal Resources

- [All Features](https://www.warp.dev/all-features)
- [AI Command Search](https://docs.warp.dev/features/ai-command-search)
- [Active AI](https://docs.warp.dev/agents/active-ai)
- [Agent Mode](https://www.warp.dev/ai)
- [Agents Overview](https://docs.warp.dev/agents/agents-overview)

---

**Last Updated:** 2025-01-01 (Ralph Loop Iteration 1)
**Maintained By:** Ghostty AI Feature Development Team
