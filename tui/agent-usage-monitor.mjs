#!/usr/bin/env node

// Agent Usage Monitor
// A local, read-only TUI for Codex, OpenCode, and Cline that mirrors the
// macOS "Codex Usage" app: subscription limit bars with percent left and
// reset countdowns plus clock times, today and all-time token totals,
// estimated costs, and recent sessions.
//
// Everything is read from local files. The only network calls are the two
// quota checks, which reuse the sign-ins the CLIs already store on disk.

import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const HOME = os.homedir();
const CODEX_DB = path.join(HOME, ".codex", "state_5.sqlite");
const CODEX_SESSIONS = path.join(HOME, ".codex", "sessions");
const CODEX_ARCHIVE = path.join(HOME, ".codex", "archived_sessions");
const OPENCODE_DB = path.join(HOME, ".local", "share", "opencode", "opencode.db");
const OPENCODE_AUTH = path.join(HOME, ".local", "share", "opencode", "auth.json");
const CLINE_SESSIONS = path.join(HOME, ".cline", "data", "sessions");

const REFRESH_MS = Number(process.env.AGENT_USAGE_REFRESH_MS || process.env.CODEX_USAGE_REFRESH_MS || 5000);
const QUOTA_TTL_MS = 240_000;
const AGENTS = ["codex", "opencode", "cline"];

// ---------------------------------------------------------------------------
// ANSI primitives
// ---------------------------------------------------------------------------

const ansi = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  hide: "\x1b[?25l",
  show: "\x1b[?25h",
  clear: "\x1b[2J",
  clearLine: "\x1b[2K",
  home: "\x1b[H",
  save: "\x1b[s",
  restore: "\x1b[u",
  grey: "\x1b[38;5;240m",
  greyDim: "\x1b[38;5;238m",
  rule: "\x1b[38;5;236m",
  green: "\x1b[38;5;114m",
  yellow: "\x1b[38;5;179m",
  red: "\x1b[38;5;174m",
  cyan: "\x1b[38;5;110m",
  magenta: "\x1b[38;5;139m",
  white: "\x1b[38;5;252m",
  muted: "\x1b[38;5;244m",
  accent: "\x1b[38;5;81m",
  accentSoft: "\x1b[38;5;66m",
};

function color(text, code) {
  return code ? `${code}${text}${ansi.reset}` : text;
}

function stripAnsi(text) {
  return text.replace(/\x1b\[[0-9;]*[A-Za-z]/g, "");
}

function visibleLen(text) {
  return stripAnsi(text).length;
}

function padRight(text, width) {
  const v = visibleLen(text);
  return v >= width ? text : text + " ".repeat(width - v);
}

function padLeft(text, width) {
  const v = visibleLen(text);
  return v >= width ? text : " ".repeat(width - v) + text;
}

function truncate(text, width) {
  const v = visibleLen(text);
  if (v <= width) return text;
  const ellipsis = "…";
  const keep = width - ellipsis.length;
  if (keep <= 0) return "";
  let kept = 0;
  let out = "";
  let inEscape = false;
  for (const ch of text) {
    if (inEscape) {
      out += ch;
      if (ch >= "a" && ch <= "z") inEscape = false;
      continue;
    }
    if (ch === "\x1b") {
      out += ch;
      inEscape = true;
      continue;
    }
    if (kept >= keep) break;
    out += ch;
    kept += 1;
  }
  return out + color(ellipsis, ansi.muted);
}

function terminalSize() {
  return {
    cols: Math.max(1, Math.min(160, process.stdout.columns || 80)),
    rows: Math.max(1, process.stdout.rows || 24),
  };
}

function frameCols() {
  const forced = Number(process.env.AGENT_USAGE_MONITOR_COLS || 0);
  return forced > 0 ? forced : terminalSize().cols;
}

function goto(row, col = 1) {
  return `\x1b[${row};${col}H`;
}
// ---------------------------------------------------------------------------
// Number / time formatting
// ---------------------------------------------------------------------------

function fmt(n) {
  return new Intl.NumberFormat("en-US").format(Number(n || 0));
}

function fmtCompact(n) {
  const v = Number(n || 0);
  if (v >= 1_000_000_000) return `${(v / 1_000_000_000).toFixed(2)}B`;
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(2)}M`;
  if (v >= 1_000) return `${(v / 1_000).toFixed(1)}K`;
  return String(v);
}

function fmtMoney(value) {
  return `$${Number(value || 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function clockTime(date) {
  return date.toLocaleTimeString("en-US", { hour12: false, hour: "2-digit", minute: "2-digit" });
}

// Clock time for the reset line: time alone while the reset is today, weekday
// and time within a week, date and time beyond. Matches the macOS app.
function resetClock(date) {
  if (!date) return null;
  const now = new Date();
  if (date.toDateString() === now.toDateString()) return clockTime(date);
  if (date.getTime() - now.getTime() < 7 * 24 * 60 * 60 * 1000) {
    return `${date.toLocaleDateString("en-US", { weekday: "short" })} ${clockTime(date)}`;
  }
  return `${date.toLocaleDateString("en-US", { month: "short", day: "numeric" })} at ${clockTime(date)}`;
}

function relativeTime(seconds) {
  if (!seconds) return "—";
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - seconds);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

function countdown(target) {
  if (!target) return "—";
  const ms = Math.max(0, target.getTime() - Date.now());
  const totalMinutes = Math.floor(ms / 60000);
  const days = Math.floor(totalMinutes / 1440);
  const hours = Math.floor((totalMinutes % 1440) / 60);
  const minutes = totalMinutes % 60;
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

function localMidnightSeconds() {
  const now = new Date();
  return Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000);
}

function localMidnightMs() {
  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
}
// ---------------------------------------------------------------------------
// Model pricing: USD per 1M tokens, standard tier. The same table as the
// macOS app's App/UsageReader.swift, so cost figures line up exactly.
// ---------------------------------------------------------------------------

const MODEL_PRICING = {
  // OpenAI
  "gpt-6-astra": [10.0, 1.0, 50.0],
  "gpt-6.1-sol": [2.0, 0.1, 10.0],
  "gpt-6-luna": [0.1, 0.01, 0.5],
  "gpt-6-sol": [2.0, 0.2, 10.0],
  "gpt-5.6-sol": [4.0, 0.4, 20.0],
  "gpt-5.6-terra": [2.0, 0.2, 12.0],
  "gpt-5.6-luna": [0.2, 0.02, 1.2],
  "gpt-5.5": [5.0, 0.5, 30.0],
  "gpt-5.4": [2.5, 0.25, 15.0],
  "gpt-5.4-mini": [0.75, 0.075, 4.5],
  "gpt-5.2": [1.75, 0.175, 14.0],
  "gpt-5.3-codex": [1.75, 0.175, 14.0],
  // gpt-5.2-codex is not on the public price list; matched to gpt-5.3-codex.
  "gpt-5.2-codex": [1.75, 0.175, 14.0],
  // Codex background reviewer; priced as the closest public Codex model.
  "codex-auto-review": [1.75, 0.175, 14.0],
  // DeepSeek
  "deepseek-flash": [0.3, 0.006, 1.2],
  "deepseek-v4.1-flash": [0.3, 0.006, 1.2],
  "deepseek-v4-flash": [0.3, 0.006, 1.2],
  "deepseek-v4-pro": [1.32, 0.044, 3.96],
  // Z.ai
  "glm-5.3-flash": [0.15, 0.03, 0.5],
  "glm-5.3": [1.4, 0.26, 4.4],
  "glm-5.2": [1.4, 0.26, 4.4],
  "glm-5.1": [1.4, 0.26, 4.4],
  // Moonshot (cache-hit price fitted from local usage records)
  "kimi-k3": [3.0, 0.3, 15.0],
};

// Observed split of Codex usage from rollout token_count events: ~95 % of
// tokens are cached input, which is priced far below fresh input.
const CODEX_UNCACHED_SHARE = 0.044;
const CODEX_CACHED_SHARE = 0.9517;
const CODEX_OUTPUT_SHARE = 0.0043;

function ratesFor(model) {
  const name = String(model || "").toLowerCase().split("/").pop().trim();
  return MODEL_PRICING[name] || null;
}

function estimateCost(model, input, cachedInput, output) {
  const rates = ratesFor(model);
  if (!rates) return null;
  const uncached = Math.max(0, input - cachedInput);
  return (uncached * rates[0] + cachedInput * rates[1] + output * rates[2]) / 1_000_000;
}

function codexCost(rows) {
  let total = 0;
  for (const [model, tokens] of rows) {
    const rates = ratesFor(model);
    if (!rates) continue;
    total += Number(tokens || 0) * (
      CODEX_UNCACHED_SHARE * rates[0] +
      CODEX_CACHED_SHARE * rates[1] +
      CODEX_OUTPUT_SHARE * rates[2]
    ) / 1_000_000;
  }
  return total;
}

// ---------------------------------------------------------------------------
// Limit presentation (the app colors by percent left)
// ---------------------------------------------------------------------------

function remainingPercent(usedPercent) {
  return Math.max(0, Math.min(100, 100 - Number(usedPercent || 0)));
}

function leftColor(left) {
  if (left <= 10) return ansi.red;
  if (left <= 30) return ansi.yellow;
  return ansi.green;
}

function gauge(remaining, width = 30) {
  const p = Math.max(0, Math.min(100, Number(remaining || 0)));
  const safeWidth = Math.max(0, width);
  const filled = Math.round((p / 100) * safeWidth);
  return `${"█".repeat(filled)}${"░".repeat(safeWidth - filled)}`;
}

function limitLabel(minutes) {
  const m = Number(minutes || 0);
  if (m === 300) return "5-hour limit";
  if (m === 10_080) return "Weekly limit";
  if (m === 43_200) return "Monthly limit";
  if (m >= 60 && m % 60 === 0) return `${m / 60}-hour limit`;
  return m ? `${m}-minute limit` : "Usage limit";
}
// ---------------------------------------------------------------------------
// sqlite wrapper
// ---------------------------------------------------------------------------

function sqlite(db, sql) {
  return execFileSync("sqlite3", ["-readonly", "-separator", "\t", db, sql], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trimEnd();
}

function sqliteRows(db, sql) {
  const out = sqlite(db, sql);
  if (!out) return [];
  return out.split("\n").map((line) => line.split("\t"));
}

function sqliteScalar(db, sql) {
  return Number(sqliteRows(db, sql)[0]?.[0] || 0);
}

// ---------------------------------------------------------------------------
// Codex: the local state database plus rate-limit snapshots in session logs
// ---------------------------------------------------------------------------

function walkJsonlFiles(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir)) {
    const entryPath = path.join(dir, entry);
    let stat;
    try {
      stat = fs.statSync(entryPath);
    } catch {
      continue;
    }
    if (stat.isDirectory()) walkJsonlFiles(entryPath, out);
    else if (entry.endsWith(".jsonl")) out.push(entryPath);
  }
  return out;
}

function readFileTail(file, maxBytes = 128 * 1024) {
  const fd = fs.openSync(file, "r");
  try {
    const { size } = fs.fstatSync(fd);
    const length = Math.min(size, maxBytes);
    const buffer = Buffer.alloc(length);
    fs.readSync(fd, buffer, 0, length, size - length);
    return buffer.toString("utf8");
  } finally {
    fs.closeSync(fd);
  }
}

function extractRateLimits(record) {
  return record?.payload?.rate_limits || record?.payload?.info?.rate_limits || null;
}

function scanTailForFirstMatch(files, predicate, tailBytes = 0) {
  let latest = null;
  for (const file of files) {
    let raw = "";
    try {
      raw = (tailBytes ? readFileTail(file, tailBytes) : fs.readFileSync(file, "utf8")).trimEnd();
    } catch {
      continue;
    }
    if (!raw) continue;
    const lines = raw.split("\n");
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      try {
        const record = JSON.parse(lines[i]);
        const result = predicate(record, file);
        if (!result) continue;
        if (!latest || result.timestamp > latest.timestamp) latest = result;
        break;
      } catch {
        // ignore malformed lines
      }
    }
  }
  return latest;
}

const rateSnapshotFileCache = new Map();

function latestCodexRateLimits() {
  let latest = null;
  const files = [...walkJsonlFiles(CODEX_SESSIONS), ...walkJsonlFiles(CODEX_ARCHIVE)]
    .map((file) => {
      try {
        return { file, stat: fs.statSync(file) };
      } catch {
        return null;
      }
    })
    .filter(Boolean)
    .sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);

  for (const { file, stat } of files) {
    if (latest && stat.mtimeMs / 1000 <= latest.timestamp) break;

    const cached = rateSnapshotFileCache.get(file);
    let candidate = cached && cached.size === stat.size && cached.mtimeMs === stat.mtimeMs ? cached.value : undefined;
    if (candidate === undefined) {
      const scanned = scanTailForFirstMatch([file], (record, filePath) => {
        const rateLimits = extractRateLimits(record);
        if (!rateLimits?.primary) return null;
        if (rateLimits.limit_id && rateLimits.limit_id !== "codex") return null;
        const ts = record.timestamp ? Math.floor(new Date(record.timestamp).getTime() / 1000) : Math.floor(Date.now() / 1000);
        return { file: filePath, timestamp: ts, rateLimits };
      }, 128 * 1024);
      candidate = scanned ?? cached?.value ?? null;
      rateSnapshotFileCache.set(file, { size: stat.size, mtimeMs: stat.mtimeMs, value: candidate });
    }
    if (candidate && (!latest || candidate.timestamp > latest.timestamp)) latest = candidate;
  }

  if (!latest) return [];
  const now = Math.floor(Date.now() / 1000);
  return ["primary", "secondary"]
    .map((name) => latest.rateLimits[name])
    .filter((limit) => limit && typeof limit.used_percent === "number")
    .map((limit) => {
      const expired = limit.resets_at && limit.resets_at <= now;
      return {
        label: limitLabel(limit.window_minutes),
        usedPercent: expired ? 0 : limit.used_percent,
        resetsAt: limit.resets_at ? new Date(limit.resets_at * 1000) : null,
      };
    });
}

function readCodex() {
  if (!fs.existsSync(CODEX_DB)) throw new Error("Couldn't read the local usage database.");
  const since = localMidnightSeconds();
  const todayTokens = sqliteScalar(CODEX_DB, `select coalesce(sum(tokens_used),0) from threads where archived=0 and created_at >= ${since};`);
  const totalTokens = sqliteScalar(CODEX_DB, "select coalesce(sum(tokens_used),0) from threads;");
  const threadCount = sqliteScalar(CODEX_DB, "select count(*) from threads where archived=0;");
  const modelRows = sqliteRows(CODEX_DB, "select coalesce(model,''), coalesce(sum(tokens_used),0) from threads group by 1;");
  const todayModelRows = sqliteRows(CODEX_DB, `select coalesce(model,''), coalesce(sum(tokens_used),0) from threads where created_at >= ${since} group by 1;`);
  const recent = sqliteRows(
    CODEX_DB,
    "select id, updated_at, coalesce(tokens_used,0), coalesce(model,''), replace(replace(replace(substr(coalesce(title,''),1,120),char(9),' '),char(10),' '),char(13),' ') from threads where archived=0 order by updated_at desc limit 6;"
  ).map(([id, updatedAt, tokensUsed, model, title]) => ({
    id: id || "",
    updatedAt: Number(updatedAt || 0),
    tokensUsed: Number(tokensUsed || 0),
    model: model || "",
    title: title || "",
  }));

  return {
    todayTokens,
    totalTokens,
    threadCount,
    cost: codexCost(modelRows),
    todayCost: codexCost(todayModelRows),
    limits: latestCodexRateLimits(),
    recent,
  };
}
// ---------------------------------------------------------------------------
// OpenCode: the local database
// ---------------------------------------------------------------------------

function openCodeModel(value) {
  if (!value || !value.startsWith("{")) return value || "";
  try {
    const id = JSON.parse(value)?.id;
    return typeof id === "string" && id ? id : value;
  } catch {
    return value;
  }
}

function readOpenCode() {
  if (!fs.existsSync(OPENCODE_DB)) throw new Error("Couldn't read OpenCode's local usage database.");
  const [totals = []] = sqliteRows(
    OPENCODE_DB,
    "select count(*), coalesce(sum(tokens_input),0), coalesce(sum(tokens_output),0), coalesce(sum(tokens_reasoning),0), coalesce(sum(tokens_cache_read),0), coalesce(sum(tokens_cache_write),0), coalesce(sum(cost),0) from session;"
  );
  const recent = sqliteRows(
    OPENCODE_DB,
    "select id, replace(replace(replace(substr(title,1,120),char(9),' '),char(10),' '),char(13),' '), coalesce(model,''), time_updated, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write from session order by time_updated desc limit 6;"
  ).map(([id, title, model, timeUpdated, input, output, reasoning, cacheRead, cacheWrite]) => {
    const timestamp = Number(timeUpdated || 0);
    return {
      id: id || "",
      title: title || "",
      model: openCodeModel(model),
      updatedAt: Math.floor(timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp),
      input: Number(input || 0),
      output: Number(output || 0),
      reasoning: Number(reasoning || 0),
      cacheRead: Number(cacheRead || 0),
      cacheWrite: Number(cacheWrite || 0),
    };
  });
  const midnight = localMidnightMs();
  const todayTokens = sqliteScalar(
    OPENCODE_DB,
    `select coalesce(sum(json_extract(data,'$.tokens.input')),0) + coalesce(sum(json_extract(data,'$.tokens.output')),0) + coalesce(sum(json_extract(data,'$.tokens.reasoning')),0) + coalesce(sum(json_extract(data,'$.tokens.cache.read')),0) + coalesce(sum(json_extract(data,'$.tokens.cache.write')),0) from message where time_created >= ${midnight};`
  );
  const todayCost = sqliteScalar(
    OPENCODE_DB,
    `select coalesce(sum(json_extract(data,'$.cost')),0) from message where time_created >= ${midnight};`
  );
  const input = Number(totals[1] || 0);
  const output = Number(totals[2] || 0);
  const reasoning = Number(totals[3] || 0);
  const cacheRead = Number(totals[4] || 0);
  const cacheWrite = Number(totals[5] || 0);
  return {
    todayTokens,
    sessionCount: Number(totals[0] || 0),
    input,
    output,
    reasoning,
    cacheRead,
    cacheWrite,
    totalTokens: input + output + reasoning + cacheRead + cacheWrite,
    cost: Number(totals[6] || 0),
    todayCost,
    recent,
  };
}

// ---------------------------------------------------------------------------
// Cline: local session records under ~/.cline/data/sessions
// ---------------------------------------------------------------------------

function clineTitle(value) {
  return String(value || "")
    .replace(/[\n\r\t]/g, " ")
    .trim();
}

function readCline() {
  let folders;
  try {
    folders = fs.readdirSync(CLINE_SESSIONS, { withFileTypes: true }).filter((entry) => entry.isDirectory());
  } catch {
    throw new Error("Couldn't read Cline's local session data.");
  }

  const midnight = localMidnightSeconds();
  let input = 0;
  let output = 0;
  let cacheRead = 0;
  let cacheWrite = 0;
  let cost = 0;
  let todayCost = 0;
  let todayTokens = 0;
  const sessions = [];

  for (const folder of folders) {
    const folderName = folder.name;
    if (folderName.includes("__agent_")) continue;
    const folderPath = path.join(CLINE_SESSIONS, folderName);
    let files;
    try {
      files = fs.readdirSync(folderPath);
    } catch {
      continue;
    }
    const metaName = files.find((name) => name === `${folderName}.json`)
      ?? files.find((name) => name.endsWith(".json") && !name.endsWith(".messages.json") && !name.endsWith(".compaction.json"));
    if (!metaName) continue;
    const metaPath = path.join(folderPath, metaName);

    let record;
    let modified = new Date();
    try {
      record = JSON.parse(fs.readFileSync(metaPath, "utf8"));
      modified = fs.statSync(metaPath).mtime;
    } catch {
      continue;
    }

    const metadata = record?.metadata || {};
    // Prefer Cline's aggregate totals (session plus spawned subagents); fall back to session-only usage.
    const usage = metadata.aggregateUsage || metadata.usage || {};
    const sessionInput = Number(usage.inputTokens || 0);
    const sessionOutput = Number(usage.outputTokens || 0);
    const sessionCacheRead = Number(usage.cacheReadTokens || 0);
    const sessionCacheWrite = Number(usage.cacheWriteTokens || 0);
    const sessionModel = String(record?.model || "");
    const startedRaw = record?.started_at ? new Date(record.started_at) : modified;
    const startedAt = Number.isNaN(startedRaw.getTime()) ? modified : startedRaw;

    input += sessionInput;
    output += sessionOutput;
    cacheRead += sessionCacheRead;
    cacheWrite += sessionCacheWrite;

    const recordedCost = Number(usage.totalCost || 0);
    let sessionCost = 0;
    if (recordedCost > 0) {
      sessionCost = recordedCost;
    } else {
      // Sessions covered by cline-pass record no cost; estimate the same usage at list prices.
      sessionCost = estimateCost(sessionModel, sessionInput, sessionCacheRead + sessionCacheWrite, sessionOutput) ?? 0;
    }
    cost += sessionCost;
    if (startedAt.getTime() / 1000 >= midnight) {
      todayTokens += sessionInput + sessionOutput;
      todayCost += sessionCost;
    }

    sessions.push({
      id: String(record?.session_id || folderName),
      title: clineTitle(metadata.title),
      model: sessionModel,
      startedAt: Math.floor(startedAt.getTime() / 1000),
      input: sessionInput,
      output: sessionOutput,
      cacheRead: sessionCacheRead,
      cacheWrite: sessionCacheWrite,
    });
  }

  sessions.sort((a, b) => b.startedAt - a.startedAt);
  return {
    todayTokens,
    totalTokens: input + output,
    input,
    output,
    sessionCount: sessions.length,
    cost,
    todayCost,
    recent: sessions.slice(0, 6),
  };
}
// ---------------------------------------------------------------------------
// Live subscription quotas
// ---------------------------------------------------------------------------

const LIMIT_WINDOWS = { five_hour: 300, weekly: 10_080, monthly: 43_200 };

function clineSessionToken() {
  const candidates = [];
  if (process.env.CLINE_PROVIDER_SETTINGS_PATH) candidates.push(process.env.CLINE_PROVIDER_SETTINGS_PATH);
  if (process.env.CLINE_DATA_DIR) candidates.push(path.join(process.env.CLINE_DATA_DIR, "settings", "providers.json"));
  if (process.env.CLINE_DIR) candidates.push(path.join(process.env.CLINE_DIR, "data", "settings", "providers.json"));
  candidates.push(path.join(HOME, ".cline", "data", "settings", "providers.json"));

  for (const candidate of candidates) {
    let providers;
    try {
      providers = JSON.parse(fs.readFileSync(candidate, "utf8"))?.providers;
    } catch {
      continue;
    }
    if (!providers) continue;
    for (const id of ["cline", "cline-pass"]) {
      const settings = providers[id]?.settings;
      if (!settings) continue;
      const auth = settings.auth || {};
      for (const token of [auth.accessToken, settings.apiKey, auth.apiKey]) {
        if (typeof token === "string" && token.length > 0) return token;
      }
    }
  }
  return null;
}

function openCodeApiKey() {
  try {
    const key = JSON.parse(fs.readFileSync(OPENCODE_AUTH, "utf8"))?.["opencode-go"]?.key;
    return typeof key === "string" && key.length > 0 ? key : null;
  } catch {
    return null;
  }
}

async function quotaRequest(name, url, token) {
  let response;
  try {
    response = await fetch(url, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    return { error: `Couldn't reach ${name} to check limits.` };
  }
  if (response.status === 401 || response.status === 403) {
    return {
      error: name === "Cline"
        ? "Cline sign-in was rejected — run `cline auth` in Terminal."
        : "OpenCode Go key was rejected — run `opencode auth login`.",
    };
  }
  if (response.status === 429) return { error: `${name} is rate limiting the usage check.` };
  if (response.status !== 200) return { error: `${name} limit check failed (HTTP ${response.status}).` };
  try {
    return { payload: await response.json() };
  } catch {
    return { error: `Couldn't read ${name}'s limit response.` };
  }
}

function parseIsoTimestamp(value) {
  if (typeof value !== "string") return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

async function fetchClineQuotas() {
  const token = clineSessionToken();
  if (!token) return { limits: null };
  const result = await quotaRequest("Cline", "https://api.cline.bot/api/v1/users/me/plan/usage-limits", token);
  if (result.error) return { error: result.error };
  const limits = result.payload?.success === true ? result.payload?.data?.limits : null;
  if (!Array.isArray(limits)) return { error: "Couldn't read Cline's limit response." };

  const byType = new Map();
  for (const limit of limits) {
    if (typeof limit?.percentUsed === "number") byType.set(limit?.type, limit);
  }
  const found = [];
  for (const type of ["five_hour", "weekly", "monthly"]) {
    const limit = byType.get(type);
    if (!limit) continue;
    found.push({
      label: limitLabel(LIMIT_WINDOWS[type]),
      usedPercent: limit.percentUsed,
      resetsAt: parseIsoTimestamp(limit.resetsAt),
    });
  }
  return { limits: found };
}

async function fetchOpenCodeQuotas() {
  const key = openCodeApiKey();
  if (!key) return { limits: null };
  const result = await quotaRequest("OpenCode Go", "https://opencode.ai/zen/go/v1/usage", key);
  if (result.error) return { error: result.error };
  const usage = result.payload?.usage;
  if (!usage || typeof usage !== "object") return { error: "Couldn't read OpenCode Go's limit response." };

  const found = [];
  for (const [name, type] of [["rolling", "five_hour"], ["weekly", "weekly"], ["monthly", "monthly"]]) {
    const item = usage[name];
    if (!item || typeof item.percent !== "number") continue;
    found.push({
      label: limitLabel(LIMIT_WINDOWS[type]),
      usedPercent: item.percent,
      resetsAt: parseIsoTimestamp(item.resetsAt),
    });
  }
  return { limits: found };
}
// ---------------------------------------------------------------------------
// Application state and refresh orchestration
// ---------------------------------------------------------------------------

const EMPTY_CODEX = { todayTokens: 0, totalTokens: 0, threadCount: 0, cost: 0, todayCost: 0, limits: [], recent: [] };
const EMPTY_OPENCODE = { todayTokens: 0, sessionCount: 0, input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: 0, todayCost: 0, recent: [] };
const EMPTY_CLINE = { todayTokens: 0, totalTokens: 0, input: 0, output: 0, sessionCount: 0, cost: 0, todayCost: 0, recent: [] };

const READERS = { codex: readCodex, opencode: readOpenCode, cline: readCline };

const state = {
  tab: "codex",
  agents: {
    codex: { data: EMPTY_CODEX, readAt: 0, error: null },
    opencode: { data: EMPTY_OPENCODE, readAt: 0, error: null },
    cline: { data: EMPTY_CLINE, readAt: 0, error: null },
  },
  quotas: {
    cline: { limits: null, error: null, fetchedAt: 0 },
    opencode: { limits: null, error: null, fetchedAt: 0 },
  },
  quotaFetchInFlight: false,
};

// Codex reads are cheap; the OpenCode database and the Cline session scan are
// slower, so they refresh less often (and least often when their tab is not
// on screen).
function agentTtl(agent) {
  if (agent === "codex") return REFRESH_MS;
  return agent === state.tab ? 30_000 : 60_000;
}

function refreshAgents(force = false) {
  const now = Date.now();
  for (const agent of AGENTS) {
    const slot = state.agents[agent];
    if (!force && now - slot.readAt < agentTtl(agent)) continue;
    try {
      slot.data = READERS[agent]();
      slot.error = null;
    } catch (err) {
      slot.error = err instanceof Error ? err.message : String(err);
    }
    slot.readAt = now;
  }
}

async function refreshQuotas(force = false) {
  if (force) {
    state.quotas.cline.fetchedAt = 0;
    state.quotas.opencode.fetchedAt = 0;
  }
  if (state.quotaFetchInFlight) return;
  state.quotaFetchInFlight = true;
  const now = Date.now();
  try {
    const [cline, opencode] = await Promise.all([fetchClineQuotas(), fetchOpenCodeQuotas()]);
    if (cline.limits !== null) state.quotas.cline = { limits: cline.limits, error: null, fetchedAt: now };
    else if (cline.error) state.quotas.cline = { ...state.quotas.cline, error: cline.error, fetchedAt: now };
    else state.quotas.cline = { ...state.quotas.cline, fetchedAt: now };
    if (opencode.limits !== null) state.quotas.opencode = { limits: opencode.limits, error: null, fetchedAt: now };
    else if (opencode.error) state.quotas.opencode = { ...state.quotas.opencode, error: opencode.error, fetchedAt: now };
    else state.quotas.opencode = { ...state.quotas.opencode, fetchedAt: now };
  } finally {
    state.quotaFetchInFlight = false;
  }
}

function quotasDue() {
  const now = Date.now();
  return ["cline", "opencode"].some((agent) => now - state.quotas[agent].fetchedAt >= QUOTA_TTL_MS);
}

function activeLimits(agent) {
  if (agent === "codex") return state.agents.codex.data.limits || [];
  return state.quotas[agent].limits || [];
}

function activeLimitsError(agent) {
  if (agent === "codex") return state.agents.codex.error;
  return state.quotas[agent].error;
}
// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

function clockStamp(date) {
  if (!date) return "never";
  const minutes = Math.max(0, Math.floor((Date.now() - date.getTime()) / 60000));
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  return hours < 24 ? `${hours}h ago` : `${Math.floor(hours / 24)}d ago`;
}

function sectionHeader(text, sub) {
  return color(text, ansi.bold + ansi.white) + (sub ? color(`  ·  ${sub}`, ansi.muted) : "");
}

// Build a limit card: label plus percent left tinted by the app's thresholds
// (red at 10 or less, yellow at 30 or less, green otherwise), a gauge, and a
// reset line with a live countdown and the reset clock time.
function buildLimitCard(limit, width, fallbackLabel = "Usage limit") {
  const inner = Math.max(2, width - 2);
  const lines = [color(`┌${"─".repeat(inner)}┐`, ansi.rule)];
  const body = [];

  if (!limit) {
    body.push(` ${color(fallbackLabel, ansi.bold + ansi.white)}`);
    body.push(` ${color("— unavailable", ansi.yellow)}`);
    body.push(` ${color("waiting for a local snapshot", ansi.muted)}`);
  } else {
    const left = remainingPercent(limit.usedPercent);
    const tint = leftColor(left);
    const labelText = ` ${limit.label}`;
    const gap = Math.max(1, inner - visibleLen(labelText) - `${left.toFixed(0)}% left`.length - 1);
    body.push(color(labelText, ansi.bold + ansi.white) + " ".repeat(gap) +
      color(`${left.toFixed(0)}%`, ansi.bold + tint) + color(" left", ansi.muted));
    const gaugeWidth = Math.max(4, inner - 18);
    body.push(` ${color(gauge(left, gaugeWidth), tint)}  ${color(`used ${Number(limit.usedPercent).toFixed(1)}%`, ansi.muted)}`);
    const clock = resetClock(limit.resetsAt);
    if (clock) {
      body.push(` ${color(`resets in ${countdown(limit.resetsAt)}`, ansi.muted)}${color(` · ${clock}`, ansi.white)}`);
    } else {
      body.push(` ${color("reset time unavailable", ansi.muted)}`);
    }
  }

  for (const line of body) {
    lines.push(color("│", ansi.rule) + padRight(truncate(line, inner), inner) + color("│", ansi.rule));
  }
  lines.push(color(`└${"─".repeat(inner)}┘`, ansi.rule));
  return lines;
}

function layoutCards(builders, cols) {
  const gap = 2;
  const count = builders.length;
  if (!count) return [];
  const perRow = cols >= 132 && count > 2 ? 3 : cols >= 88 && count > 1 ? 2 : 1;
  const width = Math.min(64, Math.floor((cols - gap * (perRow - 1)) / perRow));
  const cards = builders.map((build) => build(width));
  const lines = [];
  for (let i = 0; i < cards.length; i += perRow) {
    const row = cards.slice(i, i + perRow);
    const height = Math.max(...row.map((card) => card.length));
    for (let line = 0; line < height; line += 1) {
      lines.push(row.map((card) => padRight(card[line] || "", width)).join(" ".repeat(gap)));
    }
  }
  return lines;
}

function renderLimitSection(agent, cols) {
  const limits = activeLimits(agent);
  const error = activeLimitsError(agent);
  const lines = [];

  if (agent === "codex" && !limits.length) {
    lines.push(sectionHeader("Limits"));
    lines.push(...layoutCards([
      (width) => buildLimitCard(null, width, "5-hour limit"),
      (width) => buildLimitCard(null, width, "Weekly limit"),
    ], cols));
    return lines;
  }
  if (!limits.length) {
    if (error) {
      lines.push(sectionHeader("Limits"));
      lines.push(truncate(color(`  ${error}`, ansi.red), cols));
    }
    return lines;
  }

  lines.push(sectionHeader("Limits"));
  lines.push(...layoutCards(limits.map((limit) => (width) => buildLimitCard(limit, width)), cols));
  return lines;
}

function usageRows(agent) {
  const data = state.agents[agent].data;
  if (agent === "codex") {
    return [
      ["Tokens used today", `${fmt(data.todayTokens)} tokens`, ansi.green],
      ["Tokens used all time", `${fmt(data.totalTokens)} tokens`, ansi.cyan],
      ["Active threads", String(data.threadCount), ansi.white],
      ["Estimated cost today", fmtMoney(data.todayCost), ansi.magenta],
      ["Estimated cost all time", fmtMoney(data.cost), ansi.magenta],
    ];
  }
  if (agent === "opencode") {
    return [
      ["Tokens used today", `${fmt(data.todayTokens)} tokens`, ansi.green],
      ["Total tokens", `${fmt(data.totalTokens)} tokens`, ansi.cyan],
      ["Input tokens", `${fmt(data.input + data.cacheRead + data.cacheWrite)} tokens`, ansi.white],
      ["Output tokens", `${fmt(data.output + data.reasoning)} tokens`, ansi.white],
      ["Sessions", String(data.sessionCount), ansi.white],
      ["Estimated cost today", fmtMoney(data.todayCost), ansi.magenta],
      ["Estimated cost all time", fmtMoney(data.cost), ansi.magenta],
    ];
  }
  return [
    ["Tokens used today", `${fmt(data.todayTokens)} tokens`, ansi.green],
    ["Total tokens", `${fmt(data.totalTokens)} tokens`, ansi.cyan],
    ["Input tokens", `${fmt(data.input)} tokens`, ansi.white],
    ["Output tokens", `${fmt(data.output)} tokens`, ansi.white],
    ["Sessions", String(data.sessionCount), ansi.white],
    ["Estimated cost today", fmtMoney(data.todayCost), ansi.magenta],
    ["Estimated cost all time", fmtMoney(data.cost), ansi.magenta],
  ];
}

function renderUsageRows(rows) {
  const labelWidth = Math.max(...rows.map(([label]) => label.length));
  return rows.map(([label, value, tint]) =>
    `  ${color(padRight(label, labelWidth), ansi.muted)}  ${color(value, tint)}`
  );
}

function recentTotal(agent, row) {
  if (agent === "codex") return row.tokensUsed || 0;
  if (agent === "opencode") return (row.input || 0) + (row.output || 0) + (row.reasoning || 0) + (row.cacheRead || 0) + (row.cacheWrite || 0);
  return (row.input || 0) + (row.output || 0);
}

function renderRecent(agent, cols) {
  const data = state.agents[agent].data;
  const heading = agent === "codex" ? "Recent threads" : "Recent sessions";
  const lines = [sectionHeader(heading, agent === "codex" ? "latest activity" : "latest starts"), ""];
  const rows = data.recent || [];
  if (!rows.length) {
    lines.push(color("  none yet", ansi.muted));
    return lines;
  }

  const timeWidth = 10;
  const tokensWidth = 10;
  const modelWidth = Math.min(22, Math.max(8, cols - 46));
  lines.push(`  ${padRight(color(agent === "cline" ? "started" : "time", ansi.muted), timeWidth)} ${padLeft(color("tokens", ansi.muted), tokensWidth)} ${padRight(color("model", ansi.muted), modelWidth)} ${color("title", ansi.muted)}`);
  lines.push(color(`  ${"─".repeat(Math.max(0, cols - 4))}`, ansi.rule));

  for (const row of rows.slice(0, 6)) {
    const time = relativeTime(agent === "cline" ? row.startedAt : row.updatedAt);
    const maxTitle = Math.max(1, cols - 4 - timeWidth - tokensWidth - modelWidth - 3);
    lines.push(
      `  ${color(padRight(time, timeWidth), ansi.grey)} ` +
      `${color(padLeft(fmtCompact(recentTotal(agent, row)), tokensWidth), ansi.magenta)} ` +
      `${color(padRight(truncate(row.model || "—", modelWidth), modelWidth), ansi.accentSoft)} ` +
      `${color(truncate(row.title || "(untitled)", maxTitle), ansi.white)}`
    );
  }
  return lines;
}

const TAB_LABELS = { codex: "Codex", opencode: "OpenCode", cline: "Cline" };

function tabIsLive(agent) {
  return activeLimits(agent).length > 0;
}

function renderTabBar(cols) {
  const parts = AGENTS.map((agent, index) => {
    const dot = tabIsLive(agent) ? color("●", ansi.green) : color("○", ansi.greyDim);
    const text = `${index + 1} ${TAB_LABELS[agent]}`;
    return (agent === state.tab ? color(text, ansi.bold + ansi.accent) : color(text, ansi.muted)) + " " + dot;
  });
  const left = " " + parts.join("   ");
  const right = color("[1][2][3] switch · r refresh · q quit", ansi.greyDim) + " ";
  const gap = Math.max(2, cols - visibleLen(left) - visibleLen(right));
  return truncate(left + " ".repeat(gap) + right, cols);
}

function composeFrame(cols) {
  const tab = state.tab;
  const lines = [];

  const appName = color("AGENT USAGE MONITOR", ansi.bold + ansi.accent);
  const agentName = color(` ${TAB_LABELS[tab]}`, ansi.muted);
  const status = tabIsLive(tab) ? color("● live", ansi.green) : color("○ no quota", ansi.yellow);
  const spacer = " ".repeat(Math.max(2, cols - visibleLen(appName) - visibleLen(agentName) - visibleLen(status)));
  lines.push(truncate(`${appName}${agentName}${spacer}${status}`, cols));
  lines.push(renderTabBar(cols));
  lines.push(color("─".repeat(cols), ansi.rule));
  lines.push("");

  if (state.agents[tab].error) {
    lines.push(truncate(color(`Data error: ${String(state.agents[tab].error).replace(/\s+/g, " ")}`, ansi.red), cols));
    lines.push("");
  }

  const limitLines = renderLimitSection(tab, cols);
  if (limitLines.length) {
    lines.push(...limitLines);
    lines.push("");
  }

  lines.push(sectionHeader("Usage"));
  lines.push(...renderUsageRows(usageRows(tab)));
  lines.push("");

  lines.push(...renderRecent(tab, cols));
  lines.push("");

  const footerLeft = tab === "codex"
    ? color("quota from local snapshots", ansi.muted)
    : color(`quota checked ${state.quotas[tab].fetchedAt ? clockStamp(new Date(state.quotas[tab].fetchedAt)) : "—"}`, ansi.muted);
  const footerRight = color(`refresh ${Math.round(REFRESH_MS / 1000)}s · `, ansi.muted) +
    color(new Date().toLocaleTimeString("en-US", { hour12: false }), ansi.muted);
  const gap = Math.max(1, cols - visibleLen(footerLeft) - visibleLen(footerRight));
  lines.push(color("─".repeat(cols), ansi.rule));
  lines.push(truncate(`${footerLeft}${" ".repeat(gap)}${footerRight}`, cols));

  return lines;
}
// ---------------------------------------------------------------------------
// Rendering diff engine
// ---------------------------------------------------------------------------

class Frame {
  constructor() {
    this.lines = [];
    this.cols = 0;
    this.rows = 0;
  }

  set(lines, cols, rows = lines.length) {
    this.lines = lines;
    this.cols = cols;
    this.rows = rows;
  }
}

function diffAndDraw(prev, next) {
  let out = "";
  const maxRows = Math.max(prev.lines.length, next.lines.length);
  for (let i = 0; i < maxRows; i += 1) {
    const prevLine = prev.lines[i] ?? "";
    const nextLine = next.lines[i] ?? "";
    if (prevLine === nextLine) continue;
    out += goto(i + 1, 1);
    out += ansi.clearLine;
    if (nextLine) out += nextLine;
  }
  return out;
}

function renderKey() {
  return JSON.stringify({
    tab: state.tab,
    agents: AGENTS.map((agent) => ({ agent, data: state.agents[agent].data, error: state.agents[agent].error })),
    quotas: ["cline", "opencode"].map((agent) => ({
      agent,
      limits: state.quotas[agent].limits,
      error: state.quotas[agent].error,
      fetchedAt: state.quotas[agent].fetchedAt,
    })),
  });
}

function clockTickKey() {
  const now = new Date();
  return `${now.getHours()}:${now.getMinutes()}:${now.getSeconds()}`;
}

function cycleTab(step) {
  const index = AGENTS.indexOf(state.tab);
  state.tab = AGENTS[(index + step + AGENTS.length) % AGENTS.length];
}

let shutdownStarted = false;

function shutdown() {
  if (shutdownStarted) return;
  shutdownStarted = true;
  if (process.stdin.isTTY) {
    try {
      process.stdin.setRawMode(false);
    } catch {
      // ignore
    }
  }
  process.stdout.write(ansi.restore);
  process.stdout.write(ansi.show);
  process.stdout.write("\x1b[?1049l");
  process.stdout.write("\n");
  process.exit(0);
}

async function main() {
  let lastKey = "";
  let lastClockKey = "";
  const prevFrame = new Frame();
  const nextFrame = new Frame();

  const draw = () => {
    const { cols, rows } = terminalSize();
    const lines = composeFrame(cols).slice(0, rows);
    nextFrame.set(lines, cols, rows);

    const resized = prevFrame.cols && (prevFrame.cols !== cols || prevFrame.rows !== rows);
    if (resized) prevFrame.set([], 0, 0);
    const out = (resized ? ansi.clear + ansi.home : "") + diffAndDraw(prevFrame, nextFrame);
    if (out) process.stdout.write(out);
    prevFrame.set(lines, cols, rows);
  };

  const render = () => {
    const key = renderKey() + clockTickKey();
    if (key !== lastKey) {
      lastKey = key;
      draw();
    }
  };

  const tick = () => {
    refreshAgents();
    if (quotasDue() && !state.quotaFetchInFlight) {
      refreshQuotas().then(() => tick());
      return;
    }
    render();
  };

  process.stdout.write("\x1b[?1049h");
  process.stdout.write(ansi.save);
  process.stdout.write(ansi.hide);

  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.on("data", (chunk) => {
      const data = chunk.toString("utf8");
      if (data === "q" || data === "\u0003") {
        shutdown();
        return;
      }
      if (data === "1") state.tab = "codex";
      else if (data === "2") state.tab = "opencode";
      else if (data === "3") state.tab = "cline";
      else if (data === "\t" || data === "\u001b[C") cycleTab(1);
      else if (data === "\u001b[D") cycleTab(-1);
      else if (data === "r") {
        refreshAgents(true);
        refreshQuotas(true).then(() => tick());
      } else return;
      tick();
    });
  }

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
  process.on("exit", () => {
    process.stdout.write(ansi.show);
    process.stdout.write("\x1b[?1049l");
  });
  process.stdout.on("resize", () => {
    prevFrame.set([], 0, 0);
    draw();
  });

  await refreshQuotas();
  refreshAgents(true);
  lastClockKey = clockTickKey();
  tick();

  setInterval(tick, REFRESH_MS);
  setInterval(() => {
    const k = clockTickKey();
    if (k !== lastClockKey) {
      lastClockKey = k;
      render();
    }
  }, 1000);
}

// ---------------------------------------------------------------------------
// One-shot mode: print the frame(s) to stdout and exit (tests and automation)
// ---------------------------------------------------------------------------

function onceMode() {
  const requested = String(process.env.AGENT_USAGE_MONITOR_TAB || process.env.CODEX_USAGE_MONITOR_TAB || "").toLowerCase();
  const tabs = AGENTS.includes(requested) ? [requested] : AGENTS;
  const cols = frameCols();
  const chunks = [];
  for (const tab of tabs) {
    state.tab = tab;
    chunks.push(composeFrame(cols).map((line) => stripAnsi(line).trimEnd()).join("\n"));
  }
  process.stdout.write(chunks.join("\n\n"));
  process.stdout.write("\n");
}

// ---------------------------------------------------------------------------
// Self-test
// ---------------------------------------------------------------------------

function selfCheck() {
  assert.equal(limitLabel(300), "5-hour limit");
  assert.equal(limitLabel(10_080), "Weekly limit");
  assert.equal(limitLabel(43_200), "Monthly limit");
  assert.equal(remainingPercent(17), 83);
  assert.equal(leftColor(5), ansi.red);
  assert.equal(leftColor(20), ansi.yellow);
  assert.equal(leftColor(80), ansi.green);
  assert.equal(estimateCost("gpt-5.4", 1_000_000, 0, 0), 2.5);
  assert.ok(Math.abs(estimateCost("cline-pass/glm-5.2", 1_000_000, 1_000_000, 0) - 0.26) < 1e-9);
  assert.ok(/^\d\d:\d\d$/.test(resetClock(new Date())));

  const card = stripAnsi(buildLimitCard({ label: "Weekly limit", usedPercent: 10, resetsAt: null }, 40).join("\n"));
  assert.match(card, /90% left/);
  assert.match(card, /reset time unavailable/);
  const live = stripAnsi(buildLimitCard({ label: "5-hour limit", usedPercent: 17, resetsAt: new Date(Date.now() + 3_600_000) }, 40).join("\n"));
  assert.match(live, /83% left/);
  assert.match(live, /resets in /);

  for (const tab of AGENTS) {
    state.tab = tab;
    for (const cols of [44, 80, 120]) {
      const frame = composeFrame(cols);
      assert.ok(frame.every((line) => visibleLen(line) <= cols), `frame fits at ${cols} cols for ${tab}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

const SELF_TEST = process.env.AGENT_USAGE_MONITOR_SELF_TEST || process.env.CODEX_USAGE_MONITOR_SELF_TEST;
const ONCE = process.env.AGENT_USAGE_MONITOR_ONCE || process.env.CODEX_USAGE_MONITOR_ONCE;

if (SELF_TEST) {
  selfCheck();
} else if (ONCE) {
  (async () => {
    await refreshQuotas();
    refreshAgents(true);
    onceMode();
  })().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
} else {
  main().catch((err) => {
    process.stdout.write(ansi.show);
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
}
