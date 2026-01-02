#!/usr/bin/env tsx
/**
 * MR review collector for AI-based MR review in GitLab CI.
 * Collects MR metadata, diff, reviews, and comments for AI review.
 * Adapted from prepare-pr-review.ts for GitLab API.
 */

import { execFileSync, execSync, type ExecSyncOptions } from "child_process";
import { writeFileSync } from "fs";

// Types
export interface MRMetadata {
  iid: number;
  title: string;
  web_url: string;
  source_branch: string;
  target_branch: string;
  author: { username: string; name?: string };
  created_at?: string;
  updated_at?: string;
  state?: string;
  sha?: string;
}

export interface MRApproval {
  user: { username: string; name?: string };
  approved_at?: string;
}

export interface MRNote {
  id: number;
  body: string;
  author: { username: string; name?: string };
  created_at?: string;
  position?: {
    base_sha?: string;
    start_sha?: string;
    head_sha?: string;
    old_path?: string;
    new_path?: string;
    old_line?: number;
    new_line?: number;
  };
  resolvable?: boolean;
  resolved?: boolean;
}

// Utilities
function runCmd(
  cmd: string[],
  options: { timeout?: number; check?: boolean } = {},
): string {
  const { timeout = 30000, check = true } = options;
  const [command, ...args] = cmd;
  const execOptions: ExecSyncOptions = {
    encoding: "utf8",
    timeout,
    stdio: ["pipe", "pipe", "pipe"],
    maxBuffer: 100 * 1024 * 1024, // 100MB for large monorepo diffs
  };

  try {
    return execFileSync(command, args, execOptions) as string;
  } catch (error) {
    if (check) throw error;
    return "";
  }
}

function gitlabApi<T>(endpoint: string, token: string, gitlabUrl: string): T {
  const url = `${gitlabUrl}/${endpoint}`;
  const output = runCmd(
    [
      "curl",
      "-s",
      "--header",
      `PRIVATE-TOKEN: ${token}`,
      "--header",
      "Content-Type: application/json",
      url,
    ],
    { timeout: 30000 },
  );
  return JSON.parse(output) as T;
}

function gitlabApiPaginated<T>(
  endpoint: string,
  token: string,
  gitlabUrl: string,
): T[] {
  const items: T[] = [];
  let page = 1;
  const perPage = 100;

  while (true) {
    const url = `${gitlabUrl}/${endpoint}?page=${page}&per_page=${perPage}`;
    const output = runCmd(
      [
        "curl",
        "-s",
        "--header",
        `PRIVATE-TOKEN: ${token}`,
        "--header",
        "Content-Type: application/json",
        url,
      ],
      { timeout: 60000, check: false },
    );

    if (!output.trim()) break;

    try {
      const pageItems = JSON.parse(output) as T[];
      if (pageItems.length === 0) break;
      items.push(...pageItems);
      if (pageItems.length < perPage) break;
      page++;
    } catch {
      break;
    }
  }

  return items;
}

function getMRMetadata(
  projectId: string,
  mrIid: number,
  token: string,
  gitlabUrl: string,
): MRMetadata {
  const result = gitlabApi<MRMetadata>(
    `projects/${projectId}/merge_requests/${mrIid}`,
    token,
    gitlabUrl,
  );
  if (!result) {
    throw new Error(`Could not fetch metadata for MR !${mrIid}`);
  }
  return result;
}

function getMRDiff(
  projectId: string,
  mrIid: number,
  token: string,
  gitlabUrl: string,
): string {
  const diff = gitlabApi<{
    changes: Array<{ diff: string; new_path: string; old_path: string }>;
  }>(`projects/${projectId}/merge_requests/${mrIid}/changes`, token, gitlabUrl);

  if (!diff.changes || diff.changes.length === 0) return "";

  // Filter out lockfiles
  const lockSuffixes = [
    "Cargo.lock",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
  ];
  const filtered = diff.changes.filter(
    (change) =>
      !lockSuffixes.some((suffix) =>
        (change.new_path || change.old_path || "").endsWith(suffix),
      ),
  );
  if (filtered.length === 0) return "";

  // Combine diffs
  const diffChunks: string[] = [];
  for (const change of filtered) {
    if (change.diff) {
      diffChunks.push(change.diff);
    }
  }

  const fullDiff = diffChunks.join("\n");

  const MAX_DIFF_LINES = 10000;
  const diffLines = fullDiff.split("\n");
  if (diffLines.length > MAX_DIFF_LINES) {
    console.warn(
      `[prepare-mr-review] WARNING: Diff too large (${diffLines.length} lines), truncating to ${MAX_DIFF_LINES} lines`,
    );
    return (
      `# WARNING: Diff truncated from ${diffLines.length} to ${MAX_DIFF_LINES} lines\n\n` +
      diffLines.slice(0, MAX_DIFF_LINES).join("\n")
    );
  }

  return fullDiff;
}

function getMRApprovals(
  projectId: string,
  mrIid: number,
  token: string,
  gitlabUrl: string,
): MRApproval[] {
  try {
    return gitlabApiPaginated<MRApproval>(
      `projects/${projectId}/merge_requests/${mrIid}/approvals`,
      token,
      gitlabUrl,
    );
  } catch {
    // Approvals API might not be available, return empty array
    return [];
  }
}

function getMRNotes(
  projectId: string,
  mrIid: number,
  token: string,
  gitlabUrl: string,
): MRNote[] {
  return gitlabApiPaginated<MRNote>(
    `projects/${projectId}/merge_requests/${mrIid}/notes`,
    token,
    gitlabUrl,
  );
}

export function summarizeApprovals(
  approvals: MRApproval[],
): [number, string[]] {
  const approvers: string[] = [];
  for (const approval of approvals) {
    const username = approval.user?.username;
    if (username && !approvers.includes(username)) {
      approvers.push(username);
    }
  }
  return [approvers.length, approvers];
}

export function fenced(code: string, lang = ""): string {
  const trimmed = code.trimEnd();
  return trimmed ? `\`\`\`${lang}\n${trimmed}\n\`\`\`\n` : "(no output)\n";
}

export function truncate(text: string, maxLen: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= maxLen) return trimmed;
  return trimmed.slice(0, maxLen) + "\n... (truncated)";
}

export function buildMarkdownReport(
  mrIid: number,
  meta: MRMetadata,
  diffText: string,
  approvals: MRApproval[],
  notes: MRNote[],
): string {
  const title = meta.title || `MR !${mrIid}`;
  const url = meta.web_url || "";
  const head = meta.source_branch || "";
  const base = meta.target_branch || "";
  const [approvalsCount, approvers] = summarizeApprovals(approvals);

  const notesLines: string[] = [];
  for (const note of notes.slice(0, 200)) {
    const username = note.author?.username || "unknown";
    const created = note.created_at || "";
    const body = truncate(note.body || "", 1000);
    const position = note.position;

    let header = `- by ${username} at ${created}`;
    if (position) {
      const path = position.new_path || position.old_path || "";
      const line = position.new_line || position.old_line;
      if (path && line) {
        header += ` ${path}:${line}`;
      } else if (path) {
        header += ` ${path}`;
      }
    }
    notesLines.push(`${header}\n\n${fenced(body)}`);
  }

  const md: string[] = [];
  md.push(`### MR !${mrIid}: ${title}`);
  if (url) md.push(`- **URL**: ${url}`);
  if (head || base) md.push(`- **Branches**: ${head || "?"} -> ${base || "?"}`);
  md.push(
    `- **Approvals**: ${approvalsCount} (${approvers.length > 0 ? approvers.join(", ") : "none"})`,
  );
  md.push(
    `\n**Note**: To view full file contents, use \`git show origin/${head || "?"} -- <file-path>\``,
  );

  if (diffText.trim()) {
    md.push("\n### Diff (excluding lockfiles)");
    md.push(fenced(diffText, "diff"));
  }

  md.push("\n### Notes/Comments");
  md.push(notesLines.length > 0 ? notesLines.join("\n") : "(no notes)\n");

  return md.join("\n").trimEnd() + "\n";
}

function main(): void {
  const args = process.argv.slice(2);

  let mrIid: number | undefined;
  let outputPath: string | undefined;
  let gitlabUrl = process.env.GITLAB_URL || "https://gitlab.com/api/v4";
  let gitlabToken = process.env.GITLAB_TOKEN || "";
  let projectId = process.env.CI_PROJECT_ID || "";

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "-o" || arg === "--output") {
      outputPath = args[++i];
    } else if (arg === "--gitlab-url") {
      gitlabUrl = args[++i];
    } else if (arg === "--gitlab-token") {
      gitlabToken = args[++i];
    } else if (arg === "--project-id") {
      projectId = args[++i];
    } else if (!arg.startsWith("-") && !mrIid) {
      mrIid = parseInt(arg, 10);
    }
  }

  if (!mrIid || isNaN(mrIid)) {
    console.error(
      "Usage: prepare-mr-review.ts <mr_iid> -o <output_file> [--gitlab-url URL] [--gitlab-token TOKEN] [--project-id ID]",
    );
    process.exit(1);
  }

  if (!outputPath) {
    console.error("ERROR: --output / -o is required");
    process.exit(1);
  }

  if (!gitlabToken) {
    console.error(
      "ERROR: GITLAB_TOKEN environment variable or --gitlab-token required",
    );
    process.exit(1);
  }

  if (!projectId) {
    console.error(
      "ERROR: CI_PROJECT_ID environment variable or --project-id required",
    );
    process.exit(1);
  }

  const log = (msg: string) => console.log(`[prepare-mr-review] ${msg}`);

  log(`Fetching MR !${mrIid} metadata from project ${projectId}...`);
  const meta = getMRMetadata(projectId, mrIid, gitlabToken, gitlabUrl);
  log(`  Title: "${meta.title}"`);
  log(`  Branches: ${meta.source_branch} -> ${meta.target_branch}`);

  log(`Fetching diff...`);
  const diffText = getMRDiff(projectId, mrIid, gitlabToken, gitlabUrl);
  const diffLines = diffText.split("\n").length;
  log(`  Diff: ${diffLines} lines`);

  log("Fetching approvals...");
  const approvals = getMRApprovals(projectId, mrIid, gitlabToken, gitlabUrl);
  log(`  Approvals: ${approvals.length}`);

  log("Fetching notes/comments...");
  const notes = getMRNotes(projectId, mrIid, gitlabToken, gitlabUrl);
  log(`  Notes: ${notes.length}`);

  log("Building markdown report...");
  const report = buildMarkdownReport(mrIid, meta, diffText, approvals, notes);

  if (outputPath === "-") {
    console.log(report);
  } else {
    writeFileSync(outputPath, report, "utf8");
    const reportLines = report.split("\n").length;
    log(`Report written to ${outputPath} (${reportLines} lines)`);
  }
}

const isMainModule = process.argv[1]?.endsWith("prepare-mr-review.ts");
if (isMainModule) {
  main();
}
