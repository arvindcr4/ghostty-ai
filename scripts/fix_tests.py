#!/usr/bin/env python3
"""Fix generated test files for compilation."""

import re
from pathlib import Path

TESTS_DIR = Path(__file__).parent.parent / "src" / "ai" / "tests"

# Types that need module. prefix per file
TYPE_MAPPINGS = {
    "test_validation.zig": ["ValidationResult", "CommandValidator"],
    "test_mcp.zig": ["McpClient", "McpServer", "McpTool", "McpResource", "McpMessage"],
    "test_history.zig": ["HistoryManager", "HistoryEntry", "HistorySearchResult"],
    "test_shell.zig": ["Shell", "ShellContext", "ShellType"],
    "test_redactor.zig": ["Redactor", "RedactionPattern", "RedactionResult"],
    "test_suggestions.zig": ["SuggestionService", "Suggestion", "SuggestionType"],
    "test_prompt_suggestions.zig": ["PromptSuggestionService", "PromptSuggestion"],
    "test_completions.zig": ["CompletionsService", "Completion"],
    "test_active.zig": ["ActiveAI", "Recommendation", "TerminalState"],
    "test_ssh.zig": ["SshAssistant", "SshHost", "SshHistoryEntry"],
    "test_theme.zig": ["ThemeAssistant", "Theme", "ThemeSuggestion", "ThemeCategory"],
    "test_explanation.zig": ["ExplanationService", "Explanation"],
    "test_client.zig": ["Client", "ChatResponse", "Provider", "StreamCallback"],
    "test_workflow.zig": ["Workflow", "WorkflowStep", "WorkflowManager"],
    "test_workflows.zig": ["WorkflowRegistry", "WorkflowTemplate"],
    "test_analytics.zig": ["AnalyticsService", "AnalyticsEvent"],
    "test_blocks.zig": ["BlockManager", "Block", "BlockType"],
    "test_collaboration.zig": ["CollaborationService", "Session", "Participant"],
    "test_command_corrections.zig": ["CommandCorrectionsService", "Correction"],
    "test_command_history.zig": ["CommandHistoryService", "CommandEntry"],
    "test_corrections.zig": ["CorrectionService", "CorrectionSuggestion"],
    "test_custom_prompts.zig": ["CustomPromptManager", "CustomPrompt"],
    "test_documentation.zig": ["DocumentationGenerator", "Documentation"],
    "test_embeddings.zig": ["EmbeddingsService", "Embedding", "EmbeddingVector"],
    "test_error_recovery.zig": ["ErrorRecoveryService", "RecoveryStrategy"],
    "test_export_import.zig": ["ExportImportService", "ExportFormat"],
    "test_ide_editing.zig": ["IdeEditingService", "EditOperation"],
    "test_keyboard_shortcuts.zig": ["ShortcutManager", "Shortcut"],
    "test_knowledge_rules.zig": ["KnowledgeRulesManager", "Rule", "RuleContext"],
    "test_main.zig": ["Assistant", "Config"],
    "test_multi_turn.zig": ["MultiTurnService", "Conversation", "Turn"],
    "test_next_command.zig": ["NextCommandService", "CommandSuggestion"],
    "test_notebooks.zig": ["NotebookManager", "Notebook", "Cell"],
    "test_notifications.zig": ["NotificationService", "Notification", "NotificationCategory"],
    "test_performance.zig": ["PerformanceMonitor", "Metrics"],
    "test_plugins.zig": ["PluginManager", "Plugin"],
    "test_progress.zig": ["ProgressTracker", "ProgressUpdate"],
    "test_rich_history.zig": ["RichHistoryManager", "RichHistoryEntry"],
    "test_rollback.zig": ["RollbackManager", "RollbackPoint"],
    "test_secrets.zig": ["SecretRedactor", "DetectedSecret"],
    "test_security.zig": ["SecurityScanner", "SecurityIssue"],
    "test_session_sharing.zig": ["SessionSharingService", "SharedSession"],
    "test_sharing.zig": ["SharingService", "ShareLink"],
    "test_theme_suggestions.zig": ["ThemeSuggestionService", "AISuggestedTheme"],
    "test_voice.zig": ["VoiceService", "VoiceCommand", "TranscriptionResult"],
}

def fix_test_file(filepath: Path):
    """Fix a single test file."""
    filename = filepath.name
    if filename not in TYPE_MAPPINGS:
        return False

    types = TYPE_MAPPINGS[filename]

    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    original = content

    # Fix each type - add module. prefix if not already present
    for typename in types:
        # Match typename at word boundary, not already prefixed with module.
        # But don't match inside strings or after @import
        pattern = rf'(?<!module\.)(?<!["\'])(?<!\@import\(")(?<=[\s\(,=])({typename})(?=[\s\.\(,\)])'
        content = re.sub(pattern, r'module.\1', content)

        # Also fix cases at start of lines like "var result = TypeName.init"
        pattern = rf'^(\s*)(var|const)\s+(\w+)\s*=\s*({typename})\.'
        content = re.sub(pattern, rf'\1\2 \3 = module.\4.', content, flags=re.MULTILINE)

        # Fix type annotations like ": TypeName"
        pattern = rf':\s*({typename})(?=[,\)\s])'
        content = re.sub(pattern, r': module.\1', content)

    # Fix .deinit() to .deinit(alloc) for ArrayListUnmanaged
    # Only replace when preceded by variable names commonly used for ArrayListUnmanaged
    # This avoids breaking other types that have parameterless deinit methods
    content = re.sub(r'(\b(?:list|items|buffer|result|output|members|cursors|events|names|tags|issues|reasons|preview|tools|resources))\s*\.deinit\(\)',
                     r'\1.deinit(alloc)', content)

    if content != original:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        return True
    return False


def main():
    print("Fixing test files...")

    fixed = 0
    for test_file in TESTS_DIR.glob("test_*.zig"):
        if fix_test_file(test_file):
            print(f"  Fixed: {test_file.name}")
            fixed += 1

    print(f"\nFixed {fixed} files")


if __name__ == "__main__":
    main()
