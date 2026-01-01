# AI Module Architecture

## Overview

The AI module provides Warp-like AI features for the Ghostty terminal, including intelligent command assistance, error debugging, workflow optimization, and more.

## Module Structure

### Core Components

- **`main.zig`**: Central `Assistant` struct that orchestrates all AI features
- **`client.zig`**: Low-level client for communicating with AI providers (OpenAI, Anthropic, Ollama, custom)
- **`redactor.zig`**: Secret redaction for removing sensitive information before sending to AI

### Feature Modules

#### Command Assistance

- **`next_command.zig`**: Predicts next command based on history and context
- **`command_corrections.zig`**: Detects and suggests corrections for command typos
- **`completions.zig`**: Smart command completions
- **`suggestions.zig`**: Context-aware prompt suggestions

#### Workflow Management

- **`workflows.zig`**: Reusable command sequences (workflows)
- **`blocks.zig`**: Grouping related commands into logical blocks
- **`rich_history.zig`**: Enhanced command history with metadata

#### Advanced Features

- **`mcp.zig`**: Model Context Protocol integration for tool access
- **`ide_editing.zig`**: IDE-like text editing features
- **`active.zig`**: Proactive AI recommendations
- **`multi_turn.zig`**: Multi-turn conversation management

#### Data Management

- **`export_import.zig`**: Export/import workflows and conversations
- **`notebooks.zig`**: Terminal notebooks (incomplete - type definitions only)
- **`sharing.zig`**: Share command blocks and workflows

#### Security & Validation

- **`validation.zig`**: Pre-execution command validation
- **`security.zig`**: Advanced secret detection (incomplete - basic patterns only)

#### Performance & Analytics

- **`performance.zig`**: Response caching for performance
- **`analytics.zig`**: Usage tracking and insights

#### UI Integration

- **`theme.zig`**: Theme suggestions and management
- **`theme_suggestions.zig`**: AI-powered theme recommendations

#### Collaboration (Incomplete)

- **`collaboration.zig`**: Multi-user features (type definitions only)
- **`session_sharing.zig`**: Collaborative terminal sessions

#### Other Features

- **`voice.zig`**: Speech-to-text (stub implementation)
- **`embeddings.zig`**: Vector search (type definitions only)
- **`plugins.zig`**: Plugin system for extensions
- **`notifications.zig`**: Desktop notifications
- **`progress.zig`**: Progress indicators
- **`error_recovery.zig`**: Error recovery strategies
- **`documentation.zig`**: Auto-generate documentation
- **`rollback.zig`**: Command execution rollback

## Data Flow

### AI Request Flow

1. User enters prompt in AI input mode (`ai_input_mode.zig`)
2. Context is built from terminal state (CWD, git, history, selection)
3. Secrets are redacted from prompt and context (`redactor.zig`)
4. Request sent to AI provider via `Client` (`client.zig`)
5. Response streamed back and displayed in UI
6. Commands extracted from response and executed

### Workflow Execution Flow

1. Commands extracted from AI response
2. `WorkflowManager` checks for matching workflow
3. If match found, execute as workflow with proper sequencing
4. Otherwise, execute commands sequentially
5. Rich history tracks execution with metadata

### Secret Redaction Flow

1. User input received
2. `Redactor` applies all enabled patterns
3. Patterns matched using basic string search (regex not fully supported)
4. Matches replaced with placeholders
5. Redacted text sent to AI provider

## Memory Management

### Ownership Semantics

- **Assistant**: Owns `Client` and optional `Redactor`
- **Services**: Owned by `AiInputMode`, cleaned up in `dispose()`
- **Workflows**: Owned by `WorkflowManager`, persisted to disk
- **Redaction**: Creates new allocations, caller owns returned strings

### Allocation Patterns

- All services use the application allocator
- Error paths use `errdefer` for cleanup
- Defer blocks ensure cleanup on all paths
- Services check for null before use

## Threading Model

### Main Thread

- UI updates and GTK operations
- Service initialization and cleanup
- Command execution

### Background Threads

- AI API requests (via `aiThreadMain`)
- Streaming responses use mutex-protected global state
- Thread-safe callbacks via `glib.idleAdd`

### Synchronization

- `streaming_state_mutex` protects global streaming state
- All streaming state access is mutex-protected
- UI updates happen on main thread via idle callbacks

## Error Handling

### Service Initialization

- Services initialized with error handling
- Failures logged with warnings
- Services set to null on failure
- UI checks for null before use

### API Errors

- Network errors handled gracefully
- API errors logged and displayed to user
- Fallback to error message in UI

### Memory Errors

- Allocation failures handled with `catch`
- Proper cleanup on error paths
- No silent failures

## Security Considerations

### Secret Redaction

- ⚠️ **LIMITATION**: Only supports literal string matching
- Complex regex patterns will NOT work
- Simple prefixes (e.g., "sk-", "ghp\_") work correctly
- For production, integrate proper regex library

### Command Validation

- Pre-execution validation for dangerous commands
- Risk assessment before execution
- User warnings for high-risk operations

### Input Sanitization

- All user input validated before processing
- Command extraction validates format
- No arbitrary code execution

## Extension Points

### Plugins

- `PluginManager` allows registering hooks
- Plugins can intercept AI requests/responses
- Custom tools can be added via MCP

### Custom Prompts

- Users can define custom prompt templates
- Variable substitution supported
- Templates stored and loaded from disk

## Performance Optimizations

### Caching

- `PerformanceOptimizer` caches AI responses
- Cache keyed by prompt hash
- TTL-based expiration
- LRU-like eviction

### String Operations

- Pre-allocated buffers where possible
- Reduced reallocations in hot paths
- Efficient pattern matching

## Testing Recommendations

1. **Unit Tests**: Each service module should have unit tests
2. **Integration Tests**: Test AI request/response flow
3. **Memory Tests**: Valgrind/ASan for leak detection
4. **Thread Safety**: Stress test streaming with concurrent requests
5. **Security Tests**: Verify secret redaction works correctly

## Future Improvements

1. **Regex Library**: Integrate proper regex for secret redaction
2. **Complete Stub Modules**: Finish implementations for notebooks, embeddings, collaboration
3. **Better Error Recovery**: More sophisticated retry strategies
4. **Performance**: Profile and optimize hot paths
5. **Documentation**: More examples and usage guides
