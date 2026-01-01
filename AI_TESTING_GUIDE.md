# Ghostty AI Features - Testing Guide

## Prerequisites

### 1. Build Ghostty
```bash
zig build
```

Note: Metal shader failures are expected on systems without Xcode's Metal toolchain. These don't affect the AI features.

### 2. Configure AI Provider

Add AI configuration to your Ghostty config file (`~/.config/ghostty/config`):

```bash
# AI Configuration
ai-enabled = true
ai-provider = openai  # Options: openai, anthropic, ollama, custom
ai-api-key = sk-your-api-key-here
ai-model = gpt-4o  # or gpt-3.5-turbo, claude-3-sonnet-20240229, etc.
ai-max-tokens = 2000
ai-temperature = 0.7
ai-context-aware = true
ai-context-lines = 50
ai-endpoint =  # Optional: custom endpoint URL
```

#### Provider-Specific Setup

**OpenAI:**
```bash
ai-provider = openai
ai-api-key = sk-...
ai-model = gpt-4o
```

**Anthropic (Claude):**
```bash
ai-provider = anthropic
ai-api-key = sk-ant-...
ai-model = claude-3-5-sonnet-20241022
```

**Ollama (Local):**
```bash
ai-provider = ollama
ai-model = llama3.2
ai-endpoint = http://localhost:11434/api/chat
# No API key needed for Ollama
```

**Custom OpenAI-Compatible:**
```bash
ai-provider = custom
ai-api-key = your-key
ai-endpoint = https://your-endpoint.com/v1/chat/completions
ai-model = your-model-name
```

### 3. Set Keybinding

The default keybinding for AI input mode is not set. Add to your config:

```bash
# Add to your config file
action = ai-input-mode
```

Then bind it to a key:
```bash
keybinding = ctrl+space>a>action>ai-input-mode
```

Or configure through the existing keybinding system.

## Test Plan

### Test 1: Basic AI Input Mode

**Steps:**
1. Launch Ghostty
2. Run a command: `echo "Hello, World!"`
3. Select the output with mouse
4. Press keybinding (e.g., Ctrl+Space)
5. AI Input Mode dialog should appear

**Expected Results:**
- Dialog opens with "AI Assistant" title
- Template dropdown shows all templates (Custom Question, Explain, Fix, Optimize, Rewrite, Debug, Complete)
- Selected text context label is visible
- Text view is empty and ready for input
- Send button is enabled (if AI is configured)

**Success Criteria:**
- [ ] Dialog opens without errors
- [ ] All 7 templates appear in dropdown
- [ ] Context label shows "AI will use selected text as context"

### Test 2: Explain Template

**Steps:**
1. Run: `ls -la | grep ghostty`
2. Select the output
3. Open AI Input Mode (Ctrl+Space)
4. Select "Explain" template
5. Click Send

**Expected Results:**
- Loading label shows "Thinking..."
- Send button becomes disabled during request
- Response appears after a few seconds
- Response explains the command

**Success Criteria:**
- [ ] Loading state appears
- [ ] Send button disables during request
- [ ] Response displays in list view
- [ ] Re-enables send button after completion
- [ ] No UI freeze (threading works)

### Test 3: Fix Template with Error

**Steps:**
1. Run a command with an error: `git push origin nonexistent-branch`
2. Select the error output
3. Open AI Input Mode
4. Select "Fix" template
5. Click Send

**Expected Results:**
- AI should identify the error
- Suggest the correct command
- Explain what was wrong

**Success Criteria:**
- [ ] AI identifies the error
- [ ] Provides actionable fix
- [ ] Explanation is clear

### Test 4: Custom Question

**Steps:**
1. Select any terminal output
2. Open AI Input Mode
3. Select "Custom Question" template
4. Type: "What does this output mean?"
5. Click Send

**Expected Results:**
- AI answers the custom question
- Uses selected text as context

**Success Criteria:**
- [ ] Custom prompt works
- [ ] AI uses selected text in response
- [ ] Response is relevant to question

### Test 5: Terminal Context

**Steps:**
1. Run multiple commands:
   ```bash
   cd /tmp
   ls
   echo "test" > file.txt
   cat file.txt
   ```
2. Select the last output
3. Open AI Input Mode with "Debug" template (uses context)
4. Click Send

**Expected Results:**
- AI should have access to terminal history
- Response should show awareness of previous commands

**Success Criteria:**
- [ ] Terminal history is extracted
- [ ] AI response includes historical context
- [ ] `ai-context-lines` setting is respected

### Test 6: Error Handling - Invalid API Key

**Steps:**
1. Set invalid API key: `ai-api-key = invalid-key-123`
2. Restart Ghostty
3. Try to make an AI request

**Expected Results:**
- Error message displays in response view
- No crash or hang
- UI remains responsive

**Success Criteria:**
- [ ] Error message is user-friendly
- [ ] Dialog can be closed normally
- [ ] No console errors/panics

### Test 7: Error Handling - Network Failure

**Steps:**
1. Disconnect from network
2. Try to make an AI request

**Expected Results:**
- Network error displays
- No hang or freeze
- Can retry after reconnection

**Success Criteria:**
- [ ] Network error is caught
- [ ] Error message is clear
- [ ] UI remains functional

### Test 8: Ollama Local Provider

**Steps:**
1. Install Ollama: `brew install ollama`
2. Pull a model: `ollama pull llama3.2`
3. Configure Ghostty for Ollama
4. Test with any template

**Expected Results:**
- Local LLM responds
- No API key required
- Faster response than cloud APIs

**Success Criteria:**
- [ ] Ollama endpoint works
- [ ] Responses are generated locally
- [ ] No network required

### Test 9: Multiple Requests

**Steps:**
1. Make first AI request
2. Close dialog
3. Select different text
4. Make second AI request
5. Repeat

**Expected Results:**
- Each request is independent
- No memory leaks
- Dialog opens cleanly each time

**Success Criteria:**
- [ ] Multiple requests work
- [ ] No state pollution between requests
- [ ] Memory usage remains stable

### Test 10: Template Dropdown

**Steps:**
1. Open AI Input Mode
2. Cycle through all templates
3. Verify each one

**Expected Results:**
- All 7 templates selectable
- Selection persists
- Correct template is used

**Success Criteria:**
- [ ] All templates work
- [ ] Dropdown is responsive
- [ ] No visual glitches

## Testing Checklist

### Core Functionality
- [ ] AI Input Mode dialog opens
- [ ] Template dropdown populated
- [ ] All 7 templates accessible
- [ ] Send button sensitivity works
- [ ] Text input accepts text
- [ ] Responses display correctly
- [ ] Dialog closes cleanly
- [ ] State resets between opens

### AI Integration
- [ ] OpenAI provider works
- [ ] Anthropic provider works
- [ ] Ollama provider works
- [ ] Custom provider works
- [ ] API keys are used correctly
- [ ] Model parameter works
- [ ] Temperature affects responses
- [ ] Max tokens is respected

### Context Features
- [ ] Selected text is captured
- [ ] Terminal history is extracted
- [ ] Context lines limit works
- [ ] Context-aware toggle works
- [ ] Template replacement works

### Error Handling
- [ ] Invalid API key
- [ ] Network failure
- [ ] API rate limit
- [ ] Malformed response
- [ ] Timeout
- [ ] Empty response

### Threading
- [ ] UI doesn't freeze during request
- [ ] Loading indicator shows
- [ ] Response updates on main thread
- [ ] Multiple concurrent requests handled

### Memory Management
- [ ] No memory leaks detected
- [ ] Selected text freed properly
- [ ] Terminal context freed
- [ ] Responses freed after display
- [ ] Dialog cleanup on close

## Debugging

### Enable Logging

Ghostty uses structured logging. To see AI-related logs:

```bash
# Run with debug logging
GHOSTTY_DEBUG=1 zig build run
```

Look for logs scoped to:
- `gtk_ghostty_ai_input` - AI Input Mode widget
- `ai_client` - AI HTTP client
- `ai_main` - AI Assistant

### Common Issues

**Issue:** Send button always disabled
- **Cause:** AI not properly configured
- **Fix:** Check config has valid provider, API key, and model

**Issue:** "Failed to initialize AI assistant"
- **Cause:** Invalid provider or missing API key
- **Fix:** Verify config values

**Issue:** Responses don't appear
- **Cause:** Threading issue or callback failure
- **Fix:** Check logs for errors

**Issue:** Context label never shows
- **Cause:** Selection not captured
- **Fix:** Verify text is selected before opening dialog

## Performance Benchmarks

To track performance improvements:

| Operation | Target | Actual |
|-----------|--------|--------|
| Dialog open | <100ms | TBD |
| First response | <5s | TBD |
| Subsequent responses | <3s | TBD |
| Memory per request | <10MB | TBD |
| UI thread block time | 0ms | TBD |

## Test Report Template

```
Date: YYYY-MM-DD
Tester: [Name]
Git Commit: [commit hash]

Configuration:
- Provider: [openai/anthropic/ollama/custom]
- Model: [model name]
- OS: [macOS/Linux]

Test Results:
[Test 1]: PASS/FAIL - Notes
[Test 2]: PASS/FAIL - Notes
...

Overall Status: PASS/FAIL

Issues Found:
1. [Description]
2. [Description]

Suggestions:
1. [Improvement idea]
2. [Improvement idea]
```

## Next Steps After Testing

Once all tests pass:
1. Test with real-world workflows
2. Gather user feedback
3. Performance optimization
4. Additional feature development
