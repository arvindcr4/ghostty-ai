# GitLab AI Code Review Setup

This is an adaptation of the [argus-code-review-action](https://github.com/sasa-tomic/argus-code-review-action) for self-hosted GitLab.

## Overview

The AI code review system uses Cursor's AI agent to automatically review merge requests and post feedback as comments. It analyzes code changes, checks for security issues, code quality, consistency, and provides approval recommendations.

## Setup

### 1. Required Variables

Set these CI/CD variables in your GitLab project settings:

- **`CURSOR_API_KEY`** (required): Get your API key from [Cursor Dashboard](https://cursor.com/dashboard?tab=integrations)
- **`CURSOR_MODEL`** (optional): Defaults to `sonnet-4.5-thinking`
- **`CUSTOM_PROMPT_FILE`** (optional): Path to a custom review prompt file

### 2. GitLab Token

The job uses `CI_JOB_TOKEN` by default, which has limited permissions. For full functionality, you may want to:

- Use a project access token with `api` scope, or
- Use a personal access token with `api` scope

Set it as `GITLAB_TOKEN` CI/CD variable if you need more permissions than `CI_JOB_TOKEN` provides.

### 3. GitLab URL

For self-hosted GitLab, set the `GITLAB_URL` variable to your GitLab API URL:

- Format: `https://your-gitlab-instance.com/api/v4`
- Defaults to `https://gitlab.com/api/v4` if not set

## How It Works

1. **Trigger**: Runs automatically on merge request events (opened, updated, reopened)
2. **Skip Label**: Add `skip-ai-review` label to skip AI review
3. **Data Collection**: Fetches MR metadata, diff, approvals, and notes via GitLab API
4. **AI Review**: Uses Cursor agent to analyze the changes
5. **Comment Posting**: Posts or updates a comment on the MR with the review

## File Structure

```
.gitlab-ci.yml                    # GitLab CI configuration
scripts/
  prepare-mr-review.ts            # Script to collect MR data using GitLab API
  prompts/
    default.md                    # Default review prompt template
```

## Customization

### Custom Prompt

Create a custom prompt file and set `CUSTOM_PROMPT_FILE` variable:

```yaml
variables:
  CUSTOM_PROMPT_FILE: ".gitlab/ai-review-prompt.md"
```

### Model Selection

Change the Cursor model:

```yaml
variables:
  CURSOR_MODEL: "sonnet-4.5-thinking" # or other available models
```

## Differences from GitHub Version

- Uses GitLab Merge Requests (MRs) instead of Pull Requests (PRs)
- Uses GitLab API instead of GitHub API
- Uses GitLab CI/CD variables (`CI_MERGE_REQUEST_IID`, `CI_PROJECT_ID`, etc.)
- Comments are posted via GitLab API notes endpoint
- Uses `glab` CLI or direct API calls instead of `gh` CLI

## Troubleshooting

### Job fails with "cursor-agent not found"

- Ensure Cursor CLI installation succeeds
- Check network connectivity to `cursor.com`

### API errors

- Verify `GITLAB_TOKEN` has proper permissions
- Check `GITLAB_URL` is correct for self-hosted instances
- Ensure `CI_PROJECT_ID` is set correctly

### No review output

- Check Cursor API key is valid
- Verify API rate limits haven't been exceeded
- Check job logs for detailed error messages

## Security Notes

- Store `CURSOR_API_KEY` as a masked CI/CD variable
- Use project access tokens with minimal required scopes
- Review the prompt file to ensure it doesn't expose sensitive information
