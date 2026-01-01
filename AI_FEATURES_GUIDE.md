# Ghostty AI Features Guide

Ghostty terminal includes powerful AI features similar to Warp terminal, allowing you to interact with AI assistants directly from your terminal.

## Features

- **AI Input Mode**: Interactive dialog for AI assistance
- **Context Awareness**: Automatically includes terminal history and selected text
- **Multiple Providers**: OpenAI, Anthropic Claude, Ollama (local), and custom endpoints
- **Built-in Templates**: Pre-configured prompts for common tasks
- **Modern UI**: GTK4-based interface with libadwaita design

## Setup

1. **Get an API key** from your preferred provider:
   - OpenAI: https://platform.openai.com/api-keys
   - Anthropic: https://console.anthropic.com/
   - Ollama: Install locally from https://ollama.ai

2. **Configure Ghostty** by adding AI settings to your config file:

```ini
# Basic OpenAI configuration
ai-enabled = true
ai-provider = openai
ai-api-key = ${OPENAI_API_KEY}
ai-model = gpt-4-turbo
keybind = ctrl+space=ai_input_mode
```

3. **Restart Ghostty** to apply the configuration

## Usage

### Triggering AI Input Mode
- Press `Ctrl+Space` (or your configured keybinding)
- The AI assistant dialog will appear

### Using Templates
1. Select text in your terminal (optional)
2. Trigger AI input mode
3. Choose a template from the dropdown:
   - **Explain**: Get simple explanations of commands/output
   - **Fix**: Identify and fix command issues
   - **Optimize**: Get performance suggestions
   - **Rewrite**: Modernize commands with best practices
   - **Debug**: Debug errors with terminal context
   - **Complete**: Auto-complete partial commands
   - **Translate**: Convert error messages to plain English
   - **Document**: Generate documentation

### Custom Questions
- Select "Custom Question" from the template dropdown
- Type your question in the input field
- The AI will respond based on selected text and terminal context

### Tips for Best Results
- **Select relevant text** before triggering for context-specific help
- **Use specific templates** for common tasks
- **Check terminal context** is enabled for debugging help
- **Adjust context-lines** if you need more/less history

## Advanced Configuration

### Using Different Providers

**Anthropic Claude:**
```ini
ai-provider = anthropic
ai-api-key = ${ANTHROPIC_API_KEY}
ai-model = claude-3-opus-20240229
```

**Local Ollama:**
```ini
ai-provider = ollama
ai-endpoint = http://localhost:11434
ai-model = codellama
```

**Custom Endpoint:**
```ini
ai-provider = custom
ai-endpoint = https://your-endpoint.com/v1
ai-api-key = ${CUSTOM_API_KEY}
ai-model = gpt-3.5-turbo
```

### Fine-tuning Responses

```ini
# Control response creativity (0.0 - 2.0)
ai-temperature = 0.7

# Limit response length
ai-max-tokens = 1000

# Adjust context awareness
ai-context-aware = true
ai-context-lines = 50
```

### Multiple Keybindings

```ini
# Different bindings for different templates
keybind = ctrl+space=ai_input_mode
keybind = ctrl+shift+e=ai_input_mode:explain
keybind = ctrl+shift+f=ai_input_mode:fix
```

## Security Notes

- Store API keys in environment variables, not directly in config
- Use `${VAR_NAME}` syntax to reference environment variables
- Ollama runs locally and doesn't require API keys
- All API calls use HTTPS for cloud providers

## Troubleshooting

**AI button is grayed out:**
- Check `ai-enabled = true`
- Verify provider is set and API key is configured
- For cloud providers, ensure API key is valid

**No response from AI:**
- Check your internet connection
- Verify API key has credits/quota
- Check provider's status page

**Context not included:**
- Ensure `ai-context-aware = true`
- Increase `ai-context-lines` if needed
- Select text explicitly for focused context

**Keyboard shortcut not working:**
- Check for conflicts with system shortcuts
- Try a different keybinding
- Verify the binding appears in `ghostty +show-config`

## Privacy

- Selected text and terminal context are only sent when you explicitly trigger AI input mode
- Context is included to provide better assistance
- No data is stored permanently
- You control what gets sent to the AI provider

## Examples

### Debugging an Error
1. Run command that produces error
2. Select the error message
3. Press `Ctrl+Space`
4. Choose "Debug" template
5. Get explanation and fix suggestions

### Learning Commands
1. Select unfamiliar command
2. Trigger AI input mode
3. Choose "Explain" template
4. Get simple explanation with examples

### Optimizing Scripts
1. Select shell script code
2. Use "Optimize" template
3. Get performance improvements
4. Use "Rewrite" for modern best practices