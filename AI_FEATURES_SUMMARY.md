# Ghostty AI Assistant Implementation Summary

This document summarizes the Warp-like AI features implemented for Ghostty terminal.

## Overview

The AI assistant provides intelligent terminal assistance similar to Warp Dev, including:
- Explaining commands and outputs
- Debugging errors and suggesting fixes
- Optimizing terminal workflows
- Writing and improving shell scripts
- Context-aware assistance using terminal history

## Implementation Files

### Configuration (`src/config/`)

1. **ai.zig** - AI configuration types and templates
   - `Provider` enum: openai, anthropic, ollama, custom
   - `Assistant` struct with all AI configuration options
   - Built-in prompt templates (explain, fix, optimize, rewrite, debug, etc.)
   - Template formatting with {selection} and {context} placeholders

2. **ai_default_prompt.txt** - Default system prompt for the AI assistant
   - Optimized for terminal assistance
   - Concise, practical, example-driven responses

3. **Config.zig** - Main configuration integration
   - Added AI configuration fields after command-palette-entry
   - Fields include:
     - `ai-enabled`: Master switch for AI features
     - `ai-provider`: Select AI provider (openai, anthropic, ollama, custom)
     - `ai-api-key`: API key for selected provider
     - `ai-endpoint`: Custom endpoint URL
     - `ai-model`: Model to use (e.g., gpt-4, claude-3-opus, mistral)
     - `ai-max-tokens`: Maximum response tokens (default: 1000)
     - `ai-temperature`: Response randomness (0.0-2.0, default: 0.7)
     - `ai-context-aware`: Include terminal history as context (default: true)
     - `ai-context-lines`: Number of context lines (default: 50)
     - `ai-system-prompt`: Custom system prompt

### Input System (`src/input/`)

4. **Binding.zig** - Action binding integration
   - Added `ai_input_mode` action to Action.Key enum
   - Documented the action with comprehensive usage info
   - Added to surface actions category for proper handling

5. **command.zig** - Command palette integration
   - Added ai_input_mode to the command system
   - Excluded from command palette (opens its own UI)

### UI Components (`src/apprt/gtk/`)

6. **ui/1.5/ai-input-mode.blp** - Blueprint UI definition
   - GTK4/libadwaita dialog widget
   - Template dropdown for prompt selection
   - Text input view for custom prompts
   - Response list view for AI responses
   - Loading indicator during AI processing
   - Context label for selected text awareness

7. **class/ai_input_mode.zig** - UI widget implementation
   - `AiInputMode` widget following Ghostty's patterns
   - Integration with terminal for selection/context
   - Template-based prompt system
   - Response display with markdown support

### AI Client (`src/ai/`)

8. **client.zig** - API client implementations
   - `Client` struct with provider-specific implementations
   - OpenAI API support (GPT-4, GPT-3.5)
   - Anthropic Claude API support
   - Ollama support for local LLMs
   - Custom OpenAI-compatible endpoint support
   - `ChatResponse` struct for parsed responses

9. **main.zig** - AI assistant main interface
   - `Assistant` struct as main entry point
   - Configuration validation and initialization
   - Context management for terminal history
   - Ready state checking

## Configuration Example

```ini
# Enable AI features
ai-enabled = true

# Configure provider
ai-provider = openai
ai-api-key = ${OPENAI_API_KEY}
ai-model = gpt-4-turbo

# Or use Ollama (free, local)
# ai-provider = ollama
# ai-model = mistral
# ai-endpoint = http://localhost:11434/api/chat

# Customize behavior
ai-max-tokens = 2000
ai-temperature = 0.7
ai-context-aware = true
ai-context-lines = 100

# Optional: Custom system prompt
ai-system-prompt = You are a DevOps expert specializing in container orchestration and CI/CD pipelines.
```

## Keybinding Configuration

```ini
# Open AI input mode (similar to Warp's Ctrl+Space)
keybind = ctrl+space=ai_input_mode
```

## Usage Flow

1. **Trigger AI Input**: Press configured keybinding (e.g., Ctrl+Space)
2. **Select Template**: Choose from pre-built templates or use custom input
3. **Context Awareness**: If text is selected, it's automatically included
4. **Send Request**: AI processes with terminal context if enabled
5. **View Response**: Response displayed in the dialog with copy support

## Built-in Templates

- **Custom Question**: Free-form input
- **Explain**: Simple explanation of commands/outputs
- **Fix**: Identify and fix command issues
- **Optimize**: Suggest performance improvements
- **Rewrite**: Modernize commands with best practices
- **Debug**: Debug errors with full terminal context
- **Complete**: Auto-complete commands based on patterns
- **Document**: Generate documentation

## Technical Architecture

```
User Input (Keybinding)
    ↓
AiInputMode Widget (GTK)
    ↓
Template Selection + Context
    ↓
AI Client (HTTP)
    ↓
Provider API (OpenAI/Anthropic/Ollama)
    ↓
Response Display
```

## Integration Points

1. **Terminal**: Provides selection and history context
2. **Config**: Stores AI settings and API credentials
3. **Input System**: Routes keybindings to AI input mode
4. **GTK UI**: Modal dialog for user interaction
5. **HTTP Client**: Communicates with AI providers

## Future Enhancements

Potential areas for expansion:
- Streaming responses for real-time output
- Multiple provider failover
- Custom template management
- Response history and saved conversations
- Shell-specific optimizations (bash, zsh, fish)
- Command learning and suggestions
- Direct terminal integration (execute suggested commands)

## Security Considerations

1. **API Keys**: Stored in config file, support environment variables
2. **Context**: Terminal history may contain sensitive data
3. **Network**: All API calls go over HTTPS
4. **Local Option**: Ollama provides fully offline option

## Dependencies

- Zig 0.15+
- GTK4/libadwaita 1.5+ (for Linux UI)
- HTTP client (standard library)
- JSON parser (standard library)

## Testing Notes

The implementation follows Ghostty's patterns:
- Comprehensive error handling
- Memory safety with Zig's ownership model
- Type-safe configuration parsing
- Cross-platform support (macOS, Linux)

## Version

Added in Ghostty 1.5.0 (development)
