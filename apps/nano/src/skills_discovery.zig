//! On-disk skill discovery, ported from `crates/harness/src/skills.rs` and the
//! `Skill`/`SkillCommand` wire shape of `harness_proto::invocation`:
//!
//! - `discover` (`skills::discover`/`discover_at`): every search root per
//!   harness (global under HOME, provider-specific config roots, Claude's
//!   installed plugins, then the project's ancestors up to the nearest `.git`
//!   or HOME), scanned depth-first with a shared 4096-entry budget. A later
//!   root replaces an earlier skill of the same name (project over global,
//!   nested over ancestors); the result is ordered by name.
//! - `readSkill`: a `SKILL.md` (or flat `*.md`) with optional YAML frontmatter
//!   (`name`, `description`, `user-invocable`). Malformed frontmatter,
//!   invalid UTF-8, files over 256 KiB and special files are skipped.
//! - `isSharedSkill`, `attachAdvertisedCommands`, and the name validators.
//!
//! Std-only (plus `catalog_core.zig` for HOME), so it tests standalone with
//! `zig test skills_discovery.zig`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const catalog_core = @import("catalog_core.zig");

pub const max_discovery_entries: usize = 4096;
const max_skill_bytes: usize = 256 * 1024;

// ── wire types ─────────────────────────────────────────────────────────────

/// `harness_proto::HarnessId` (serde kebab-case).
pub const HarnessId = enum {
    claude_code,
    codex,
    cursor,
    devin,
    grok,
    hermes,
    graff,
    pi,
    opencode,
    antigravity,
    exo,
    mock,

    pub fn wire(h: HarnessId) []const u8 {
        return switch (h) {
            .claude_code => "claude-code",
            else => @tagName(h),
        };
    }

    pub fn fromWire(text: []const u8) ?HarnessId {
        if (std.mem.eql(u8, text, "claude-code")) return .claude_code;
        if (std.mem.eql(u8, text, "claude_code")) return null;
        return std.meta.stringToEnum(HarnessId, text);
    }
};

/// `harness_proto::invocation::SkillCommand`.
pub const SkillCommand = struct {
    name: []const u8,
    harness: HarnessId,
};

/// `harness_proto::invocation::Skill`.
pub const Skill = struct {
    name: []const u8,
    path: []const u8,
    description: []const u8 = "",
    enabled: bool = true,
    command: ?SkillCommand = null,

    /// serde's field order; `command` is skipped when `None`.
    pub fn write(s: Skill, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{{\"name\":{f},\"path\":{f},\"description\":{f},\"enabled\":{s}", .{
            json.fmt(s.name, .{}),
            json.fmt(s.path, .{}),
            json.fmt(s.description, .{}),
            if (s.enabled) "true" else "false",
        });
        if (s.command) |c| try w.print(",\"command\":{{\"name\":{f},\"harness\":{f}}}", .{ json.fmt(c.name, .{}), json.fmt(c.harness.wire(), .{}) });
        try w.writeByte('}');
    }
};

/// `harness_proto::SlashCommand`.
pub const SlashCommand = struct {
    name: []const u8,
    description: []const u8 = "",
    input_hint: ?[]const u8 = null,
};

/// `Option<Vec<Skill>>` as the RPC serializes it: `null` for `None`.
pub fn skillsJson(gpa: Allocator, skills: ?[]const Skill) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const list = skills orelse {
        try aw.writer.writeAll("null");
        return aw.toOwnedSlice();
    };
    try aw.writer.writeByte('[');
    for (list, 0..) |s, i| {
        if (i > 0) try aw.writer.writeByte(',');
        try s.write(&aw.writer);
    }
    try aw.writer.writeByte(']');
    return aw.toOwnedSlice();
}

// ── Unicode helpers (Rust `char` predicates) ───────────────────────────────

/// `char::is_control` (general category Cc).
fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp <= 0x9f);
}

/// `char::is_whitespace` (the White_Space property).
fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// `char::is_alphanumeric`: exact for ASCII; outside ASCII every code point
/// counts except controls, whitespace and the common punctuation, symbol,
/// private-use and emoji blocks (the full Alphabetic/Numeric tables are not
/// carried here).
fn isAlphanumeric(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp));
    if (isControl(cp) or isWhitespace(cp)) return false;
    return switch (cp) {
        0xa1...0xa9, 0xab...0xb1, 0xb4, 0xb6...0xb8, 0xbb, 0xbf, 0xd7, 0xf7 => false,
        0x2000...0x206f, 0x20a0...0x20cf, 0x2190...0x245f, 0x2500...0x2bff, 0x2e00...0x2e7f => false,
        0x3000...0x3004, 0x3008...0x3020, 0x3030, 0x303d...0x303f => false,
        0xd800...0xf8ff, 0xfe10...0xfe1f, 0xfe30...0xfe6f => false,
        0xff00...0xff0f, 0xff1a...0xff20, 0xff3b...0xff40, 0xff5b...0xff65 => false,
        0xfff0...0xffff, 0x1f000...0x1faff, 0xf0000...0x10ffff => false,
        else => true,
    };
}

fn utf8Iter(text: []const u8) ?std.unicode.Utf8Iterator {
    const view = std.unicode.Utf8View.init(text) catch return null;
    return view.iterator();
}

/// `valid_invocation_name`: non-empty, no control or whitespace characters.
pub fn validInvocationName(name: []const u8) bool {
    if (name.len == 0) return false;
    var it = utf8Iter(name) orelse return false;
    while (it.nextCodepoint()) |cp| if (isControl(cp) or isWhitespace(cp)) return false;
    return true;
}

/// `valid_skill_path`: non-empty, no control characters.
pub fn validSkillPath(path: []const u8) bool {
    if (path.len == 0) return false;
    var it = utf8Iter(path) orelse return false;
    while (it.nextCodepoint()) |cp| if (isControl(cp)) return false;
    return true;
}

/// `valid_skill_command_name`: alphanumerics and `-_:.` only.
pub fn validSkillCommandName(name: []const u8) bool {
    if (name.len == 0) return false;
    var it = utf8Iter(name) orelse return false;
    while (it.nextCodepoint()) |cp| {
        if (!(isAlphanumeric(cp) or cp == '-' or cp == '_' or cp == ':' or cp == '.')) return false;
    }
    return true;
}

/// `str::trim` (Unicode White_Space on both ends).
pub fn trimUnicode(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[start]) catch break;
        if (start + n > text.len) break;
        const cp = std.unicode.utf8Decode(text[start .. start + n]) catch break;
        if (!isWhitespace(cp)) break;
        start += n;
    }
    var end: usize = text.len;
    while (end > start) {
        var b = end - 1;
        while (b > start and (text[b] & 0xc0) == 0x80) b -= 1;
        const cp = std.unicode.utf8Decode(text[b..end]) catch break;
        if (!isWhitespace(cp)) break;
        end = b;
    }
    return text[start..end];
}

/// `String::from_utf8_lossy`: invalid sequences become U+FFFD.
pub fn lossy(arena: Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(arena, "\u{fffd}");
            i += 1;
            continue;
        };
        const ok = i + n <= bytes.len and if (std.unicode.utf8Decode(bytes[i .. i + n])) |_| true else |_| false;
        if (ok) {
            try out.appendSlice(arena, bytes[i .. i + n]);
            i += n;
            continue;
        }
        try out.appendSlice(arena, "\u{fffd}");
        i += 1;
    }
    return out.items;
}

// ── shared skills and advertised commands ──────────────────────────────────

/// `is_shared_skill`: some ancestor is a `skills` folder inside `.agents`.
pub fn isSharedSkill(path: []const u8) bool {
    var prev: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, path, if (builtin.os.tag == .windows) "/\\" else "/");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "skills")) if (prev) |p| if (std.mem.eql(u8, p, ".agents")) return true;
        prev = comp;
    }
    return false;
}

/// `attach_advertised_commands`: Pi labels its skill commands `skill:<name>`
/// (and a labelled command without a file becomes a `harness-skill:pi:`
/// row); other agents bind a discovered skill only to a same-named command,
/// and never a shared skill. Strings borrow `commands`/`arena`.
pub fn attachAdvertisedCommands(arena: Allocator, harness: HarnessId, skills: *std.ArrayList(Skill), commands: []const SlashCommand) !void {
    for (commands) |command| {
        if (!validSkillCommandName(command.name)) continue;
        const name = if (harness == .pi) blk: {
            if (!std.mem.startsWith(u8, command.name, "skill:")) continue;
            break :blk command.name["skill:".len..];
        } else command.name;
        var found: ?*Skill = null;
        for (skills.items) |*s| if (std.mem.eql(u8, s.name, name)) {
            found = s;
            break;
        };
        if (found) |skill| {
            // A shared skill named `compact` is not evidence that the
            // provider's built-in /compact invokes that file.
            if (harness != .pi and isSharedSkill(skill.path)) continue;
            skill.command = .{ .name = command.name, .harness = harness };
        } else if (harness == .pi and name.len > 0) {
            try skills.append(arena, .{
                .name = name,
                .path = try std.fmt.allocPrint(arena, "harness-skill:pi:{s}", .{name}),
                .description = command.description,
                .enabled = true,
                .command = .{ .name = command.name, .harness = harness },
            });
        }
    }
}

// ── frontmatter (the subset of YAML `serde_yaml_ng` reads here) ────────────

pub const Scalar = union(enum) {
    string: []const u8,
    boolean: bool,
    /// null, numbers, sequences, mappings, aliases.
    other,
};

/// The frontmatter keys skill discovery reads.
pub const Meta = struct {
    name: ?Scalar = null,
    description: ?Scalar = null,
    user_invocable: ?Scalar = null,

    fn str(s: ?Scalar) ?[]const u8 {
        const v = s orelse return null;
        return if (v == .string) v.string else null;
    }
};

const YamlError = error{ Malformed, OutOfMemory };

const Yaml = struct {
    arena: Allocator,
    lines: []const []const u8,
    i: usize = 0,
};

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn isSkippable(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return t.len == 0 or t[0] == '#';
}

fn trimLeftWs(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, " \t");
}

fn trimWs(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

const KeyRest = struct { key: []const u8, rest: []const u8 };

/// `key: rest` (or `key:` at the end of the line), with plain or quoted keys.
fn tryKey(arena: Allocator, s: []const u8) YamlError!?KeyRest {
    if (s.len == 0) return null;
    var key: []const u8 = undefined;
    var after: usize = undefined;
    if (s[0] == '"' or s[0] == '\'') {
        const q = s[0];
        var out: std.ArrayList(u8) = .empty;
        var j: usize = 1;
        var closed = false;
        while (j < s.len) : (j += 1) {
            const c = s[j];
            if (q == '\'' and c == '\'') {
                if (j + 1 < s.len and s[j + 1] == '\'') {
                    try out.append(arena, '\'');
                    j += 1;
                    continue;
                }
                closed = true;
                break;
            }
            if (q == '"' and c == '\\' and j + 1 < s.len) {
                try out.append(arena, s[j + 1]);
                j += 1;
                continue;
            }
            if (q == '"' and c == '"') {
                closed = true;
                break;
            }
            try out.append(arena, c);
        }
        if (!closed) return null;
        var k = j + 1;
        while (k < s.len and (s[k] == ' ' or s[k] == '\t')) k += 1;
        if (k >= s.len or s[k] != ':') return null;
        if (k + 1 < s.len and s[k + 1] != ' ' and s[k + 1] != '\t') return null;
        key = out.items;
        after = k + 1;
    } else {
        switch (s[0]) {
            '[', '{', ']', '}', ',', '#', '&', '*', '!', '|', '>', '%', '@', '`' => return null,
            '-', '?' => if (s.len == 1 or s[1] == ' ' or s[1] == '\t') return null,
            else => {},
        }
        var j: usize = 0;
        while (j < s.len) : (j += 1) {
            if (s[j] == '#' and j > 0 and (s[j - 1] == ' ' or s[j - 1] == '\t')) return null;
            if (s[j] == ':' and (j + 1 == s.len or s[j + 1] == ' ' or s[j + 1] == '\t')) break;
        } else return null;
        key = std.mem.trimEnd(u8, s[0..j], " \t");
        after = j + 1;
    }
    return .{ .key = key, .rest = trimLeftWs(s[after..]) };
}

fn isNullText(t: []const u8) bool {
    for ([_][]const u8{ "", "~", "null", "Null", "NULL" }) |n| if (std.mem.eql(u8, t, n)) return true;
    return false;
}

fn boolText(t: []const u8) ?bool {
    for ([_][]const u8{ "true", "True", "TRUE" }) |n| if (std.mem.eql(u8, t, n)) return true;
    for ([_][]const u8{ "false", "False", "FALSE" }) |n| if (std.mem.eql(u8, t, n)) return false;
    return null;
}

fn allDigits(t: []const u8, comptime pred: fn (u8) bool) bool {
    if (t.len == 0) return false;
    for (t) |c| if (!pred(c)) return false;
    return true;
}

fn isOct(c: u8) bool {
    return c >= '0' and c <= '7';
}
fn isBin(c: u8) bool {
    return c == '0' or c == '1';
}

/// serde_yaml_ng's untagged number resolution (ints with 0x/0o/0b, finite floats).
fn isNumberText(text: []const u8) bool {
    var t = text;
    if (t.len > 0 and (t[0] == '+' or t[0] == '-')) t = t[1..];
    if (t.len == 0) return false;
    if (std.mem.startsWith(u8, t, "0x")) return allDigits(t[2..], std.ascii.isHex);
    if (std.mem.startsWith(u8, t, "0o")) return allDigits(t[2..], isOct);
    if (std.mem.startsWith(u8, t, "0b")) return allDigits(t[2..], isBin);
    for ([_][]const u8{ ".inf", ".Inf", ".INF" }) |n| if (std.mem.eql(u8, t, n)) return true;
    if (text.len == t.len) for ([_][]const u8{ ".nan", ".NaN", ".NAN" }) |n| if (std.mem.eql(u8, t, n)) return true;
    var i: usize = 0;
    var digits: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) digits += 1;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        i += 1;
        if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
        const exp_start = i;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        if (i == exp_start) return false;
    }
    return i == t.len;
}

fn resolvePlain(text: []const u8) Scalar {
    if (isNullText(text)) return .other;
    if (boolText(text)) |b| return .{ .boolean = b };
    if (isNumberText(text)) return .other;
    return .{ .string = text };
}

/// Cut a plain scalar's trailing comment; error on an embedded `key: value`.
fn plainLine(s: []const u8) YamlError!struct { text: []const u8, comment: bool } {
    var end = s.len;
    var comment = false;
    for (s, 0..) |c, j| if (c == '#' and j > 0 and (s[j - 1] == ' ' or s[j - 1] == '\t')) {
        end = j;
        comment = true;
        break;
    };
    const text = trimWs(s[0..end]);
    for (text, 0..) |c, j| if (c == ':' and (j + 1 == text.len or text[j + 1] == ' ' or text[j + 1] == '\t')) return error.Malformed;
    return .{ .text = text, .comment = comment };
}

/// A plain (possibly multi-line, folded) scalar.
fn plainScalar(y: *Yaml, first: []const u8, base: usize) YamlError!Scalar {
    var out: std.ArrayList(u8) = .empty;
    var comment = false;
    var have = false;
    if (first.len > 0) {
        const p = try plainLine(first);
        try out.appendSlice(y.arena, p.text);
        comment = p.comment;
        have = true;
    }
    while (y.i < y.lines.len and !comment) {
        // Blank lines fold into newlines only when the scalar continues.
        var j = y.i;
        var blanks: usize = 0;
        while (j < y.lines.len and isBlank(y.lines[j])) : (j += 1) blanks += 1;
        if (j >= y.lines.len) break;
        const line = y.lines[j];
        if (indentOf(line) <= base) break;
        const content = trimWs(line);
        if (content[0] == '#') break;
        const p = try plainLine(content);
        if (have) {
            if (blanks > 0) {
                try out.appendNTimes(y.arena, '\n', blanks);
            } else try out.append(y.arena, ' ');
        }
        try out.appendSlice(y.arena, p.text);
        comment = p.comment;
        have = true;
        y.i = j + 1;
    }
    return resolvePlain(out.items);
}

/// A value that starts on the next line: a nested block, a plain scalar, or null.
fn nestedOrNull(y: *Yaml, base: usize) YamlError!Scalar {
    var j = y.i;
    while (j < y.lines.len and isSkippable(y.lines[j])) j += 1;
    if (j >= y.lines.len) return .other;
    const line = y.lines[j];
    const ind = indentOf(line);
    const content = line[ind..];
    const is_seq = std.mem.eql(u8, content, "-") or std.mem.startsWith(u8, content, "- ");
    if (ind > base) {
        if (is_seq or (try tryKey(y.arena, content)) != null or content[0] == '[' or content[0] == '{' or content[0] == '"' or content[0] == '\'' or content[0] == '|' or content[0] == '>') {
            y.i = j;
            while (y.i < y.lines.len and (isSkippable(y.lines[y.i]) or indentOf(y.lines[y.i]) > base)) y.i += 1;
            return .other;
        }
        y.i = j;
        return plainScalar(y, "", base);
    }
    if (ind == base and is_seq) {
        y.i = j;
        while (y.i < y.lines.len) {
            const l = y.lines[y.i];
            if (isSkippable(l) or indentOf(l) > base) {
                y.i += 1;
                continue;
            }
            const c = l[indentOf(l)..];
            if (indentOf(l) == base and (std.mem.eql(u8, c, "-") or std.mem.startsWith(u8, c, "- "))) {
                y.i += 1;
                continue;
            }
            break;
        }
    }
    return .other;
}

/// `|` / `>` block scalars with chomping and indentation indicators.
fn blockScalar(y: *Yaml, header: []const u8, base: usize) YamlError!Scalar {
    const folded = header[0] == '>';
    var chomp: enum { clip, strip, keep } = .clip;
    var explicit: ?usize = null;
    var k: usize = 1;
    while (k < header.len and k <= 2) : (k += 1) {
        const c = header[k];
        if (c == '-' and chomp == .clip) {
            chomp = .strip;
        } else if (c == '+' and chomp == .clip) {
            chomp = .keep;
        } else if (c >= '1' and c <= '9' and explicit == null) {
            explicit = c - '0';
        } else break;
    }
    const tail = header[k..];
    if (tail.len > 0 and tail[0] != ' ' and tail[0] != '\t') return error.Malformed;
    const t = trimWs(tail);
    if (t.len > 0 and t[0] != '#') return error.Malformed;

    var block_indent: usize = if (explicit) |e| base + e else blk: {
        var j = y.i;
        while (j < y.lines.len and isBlank(y.lines[j])) j += 1;
        if (j >= y.lines.len) break :blk std.math.maxInt(usize);
        break :blk indentOf(y.lines[j]);
    };
    if (block_indent <= base) block_indent = std.math.maxInt(usize);

    var lines: std.ArrayList(?[]const u8) = .empty; // null = blank
    while (y.i < y.lines.len) {
        const line = y.lines[y.i];
        if (isBlank(line) and indentOf(line) < block_indent) {
            try lines.append(y.arena, null);
            y.i += 1;
            continue;
        }
        if (indentOf(line) < block_indent) break;
        try lines.append(y.arena, line[block_indent..]);
        y.i += 1;
    }
    var last: usize = lines.items.len;
    while (last > 0 and lines.items[last - 1] == null) last -= 1;
    const trailing = lines.items.len - last;

    var out: std.ArrayList(u8) = .empty;
    if (!folded) {
        for (lines.items[0..last], 0..) |l, idx| {
            if (idx > 0) try out.append(y.arena, '\n');
            if (l) |text| try out.appendSlice(y.arena, text);
        }
    } else {
        var pending: usize = 0;
        var prev_more = false;
        var started = false;
        for (lines.items[0..last]) |l| {
            const text = l orelse {
                pending += 1;
                continue;
            };
            const more = text.len > 0 and (text[0] == ' ' or text[0] == '\t');
            if (started) {
                if (pending > 0) {
                    try out.appendNTimes(y.arena, '\n', pending + @as(usize, if (more or prev_more) 1 else 0));
                } else if (more or prev_more) {
                    try out.append(y.arena, '\n');
                } else try out.append(y.arena, ' ');
            } else if (pending > 0) try out.appendNTimes(y.arena, '\n', pending);
            try out.appendSlice(y.arena, text);
            started = true;
            prev_more = more;
            pending = 0;
        }
    }
    switch (chomp) {
        .strip => {},
        .clip => if (last > 0) try out.append(y.arena, '\n'),
        .keep => {
            if (last > 0) try out.append(y.arena, '\n');
            try out.appendNTimes(y.arena, '\n', trailing);
        },
    }
    return .{ .string = out.items };
}

fn appendUtf8(arena: Allocator, out: *std.ArrayList(u8), cp: u21) YamlError!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return error.Malformed;
    try out.appendSlice(arena, buf[0..n]);
}

/// A double- or single-quoted scalar, possibly spanning lines.
fn quotedScalar(y: *Yaml, rest: []const u8) YamlError!Scalar {
    const q = rest[0];
    var out: std.ArrayList(u8) = .empty;
    var cur = rest[1..];
    while (true) {
        var j: usize = 0;
        var escaped_break = false;
        while (j < cur.len) : (j += 1) {
            const c = cur[j];
            if (q == '\'' and c == '\'') {
                if (j + 1 < cur.len and cur[j + 1] == '\'') {
                    try out.append(y.arena, '\'');
                    j += 1;
                    continue;
                }
                return finishQuoted(out.items, cur[j + 1 ..]);
            }
            if (q == '"' and c == '"') return finishQuoted(out.items, cur[j + 1 ..]);
            if (q == '"' and c == '\\') {
                if (j + 1 >= cur.len) {
                    escaped_break = true;
                    break;
                }
                j += 1;
                const e = cur[j];
                const simple: ?u8 = switch (e) {
                    '0' => 0,
                    'a' => 7,
                    'b' => 8,
                    't', '\t' => '\t',
                    'n' => '\n',
                    'v' => 11,
                    'f' => 12,
                    'r' => '\r',
                    'e' => 0x1b,
                    ' ' => ' ',
                    '"' => '"',
                    '/' => '/',
                    '\\' => '\\',
                    else => null,
                };
                if (simple) |b| {
                    try out.append(y.arena, b);
                    continue;
                }
                const width: usize = switch (e) {
                    'x' => 2,
                    'u' => 4,
                    'U' => 8,
                    'N' => {
                        try appendUtf8(y.arena, &out, 0x85);
                        continue;
                    },
                    '_' => {
                        try appendUtf8(y.arena, &out, 0xa0);
                        continue;
                    },
                    'L' => {
                        try appendUtf8(y.arena, &out, 0x2028);
                        continue;
                    },
                    'P' => {
                        try appendUtf8(y.arena, &out, 0x2029);
                        continue;
                    },
                    else => return error.Malformed,
                };
                if (j + width >= cur.len) return error.Malformed;
                const hex = cur[j + 1 .. j + 1 + width];
                const cp = std.fmt.parseInt(u21, hex, 16) catch return error.Malformed;
                try appendUtf8(y.arena, &out, cp);
                j += width;
                continue;
            }
            try out.append(y.arena, c);
        }
        // The line ended inside the quotes: fold into the next line.
        if (!escaped_break) {
            const trimmed = std.mem.trimEnd(u8, out.items, " \t");
            out.items.len = trimmed.len;
        }
        var blanks: usize = 0;
        while (y.i < y.lines.len and isBlank(y.lines[y.i])) : (y.i += 1) blanks += 1;
        if (y.i >= y.lines.len) return error.Malformed;
        const next = y.lines[y.i];
        y.i += 1;
        if (escaped_break) {
            // `\` at the end of a line joins without a space.
        } else if (blanks > 0) {
            try out.appendNTimes(y.arena, '\n', blanks);
        } else try out.append(y.arena, ' ');
        cur = trimLeftWs(next);
    }
}

fn finishQuoted(text: []const u8, after: []const u8) YamlError!Scalar {
    const t = trimWs(after);
    if (t.len > 0 and t[0] != '#') return error.Malformed;
    if (t.len > 0 and after.len > 0 and after[0] == '#') return error.Malformed;
    return .{ .string = text };
}

/// A flow collection (`[...]`, `{...}`): balanced across lines, else malformed.
fn flowCollection(y: *Yaml, rest: []const u8) YamlError!Scalar {
    var depth: usize = 0;
    var quote: u8 = 0;
    var cur = rest;
    while (true) {
        var j: usize = 0;
        while (j < cur.len) : (j += 1) {
            const c = cur[j];
            if (quote != 0) {
                if (quote == '"' and c == '\\') {
                    j += 1;
                } else if (c == quote) {
                    if (quote == '\'' and j + 1 < cur.len and cur[j + 1] == '\'') {
                        j += 1;
                    } else quote = 0;
                }
                continue;
            }
            switch (c) {
                '"', '\'' => quote = c,
                '[', '{' => depth += 1,
                ']', '}' => {
                    if (depth == 0) return error.Malformed;
                    depth -= 1;
                    if (depth == 0) {
                        const t = trimWs(cur[j + 1 ..]);
                        if (t.len > 0 and t[0] != '#') return error.Malformed;
                        return .other;
                    }
                },
                '#' => if (j > 0 and (cur[j - 1] == ' ' or cur[j - 1] == '\t')) break,
                else => {},
            }
        }
        if (y.i >= y.lines.len) return error.Malformed;
        cur = y.lines[y.i];
        y.i += 1;
    }
}

fn parseValue(y: *Yaml, rest: []const u8, base: usize) YamlError!Scalar {
    if (rest.len == 0 or rest[0] == '#') return nestedOrNull(y, base);
    switch (rest[0]) {
        '|', '>' => return blockScalar(y, rest, base),
        '"', '\'' => return quotedScalar(y, rest),
        '[', '{' => return flowCollection(y, rest),
        '&' => {
            const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            if (end == 1) return error.Malformed;
            return parseValue(y, trimLeftWs(rest[end..]), base);
        },
        '!' => {
            const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            return parseValue(y, trimLeftWs(rest[end..]), base);
        },
        '*' => {
            const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            const t = trimWs(rest[end..]);
            if (t.len > 0 and t[0] != '#') return error.Malformed;
            return .other;
        },
        '@', '`', '%', ',', ']', '}' => return error.Malformed,
        '-', '?', ':' => if (rest.len == 1 or rest[1] == ' ' or rest[1] == '\t') return error.Malformed,
        else => {},
    }
    return plainScalar(y, rest, base);
}

/// The frontmatter between the `---` lines: `error.Malformed` where
/// `serde_yaml_ng` would fail (skipping the skill); a document that is not
/// a mapping carries no keys.
pub fn parseFrontmatter(arena: Allocator, text: []const u8) YamlError!Meta {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(arena, std.mem.trimEnd(u8, l, "\r"));
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) lines.items.len -= 1;
    var y: Yaml = .{ .arena = arena, .lines = lines.items };
    var meta: Meta = .{};
    while (y.i < y.lines.len and isSkippable(y.lines[y.i])) y.i += 1;
    if (y.i >= y.lines.len) return meta;
    const base = indentOf(y.lines[y.i]);
    if ((try tryKey(arena, y.lines[y.i][base..])) == null) return meta;
    while (y.i < y.lines.len) {
        const line = y.lines[y.i];
        if (isSkippable(line)) {
            y.i += 1;
            continue;
        }
        const ind = indentOf(line);
        if (ind < line.len and line[ind] == '\t') return error.Malformed;
        if (ind != base) return error.Malformed;
        const kr = (try tryKey(arena, line[ind..])) orelse return error.Malformed;
        y.i += 1;
        const value = try parseValue(&y, kr.rest, base);
        if (std.mem.eql(u8, kr.key, "name")) meta.name = value;
        if (std.mem.eql(u8, kr.key, "description")) meta.description = value;
        if (std.mem.eql(u8, kr.key, "user-invocable")) meta.user_invocable = value;
    }
    return meta;
}

// ── reading one skill (`read_skill`) ───────────────────────────────────────

fn extensionIs(name: []const u8, ext: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (dot == 0) return false;
    return std.mem.eql(u8, name[dot + 1 ..], ext);
}

/// `Path::file_stem`.
fn fileStem(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    if (dot == 0) return name;
    return name[0..dot];
}

/// Read up to `limit` bytes of a regular file without ever blocking on a
/// FIFO or device; null when `path` is not a regular file.
fn readRegular(arena: Allocator, io: Io, path: []const u8, limit: usize) !?[]u8 {
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    if (st.kind != .file) return null;
    const file: Io.File = if (comptime builtin.os.tag == .windows)
        try Io.Dir.cwd().openFile(io, path, .{})
    else blk: {
        // A regular file can be replaced with a FIFO after the stat.
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .NONBLOCK = true, .NOCTTY = true, .CLOEXEC = true }, 0);
        break :blk .{ .handle = fd, .flags = .{ .nonblocking = true } };
    };
    defer file.close(io);
    const fst = try file.stat(io);
    if (fst.kind != .file) return null;
    const buf = try arena.alloc(u8, limit);
    var n: usize = 0;
    while (n < limit) {
        const got = if (comptime builtin.os.tag == .windows)
            try file.readStreaming(io, &.{buf[n..]})
        else
            try std.posix.read(file.handle, buf[n..]);
        if (got == 0) break;
        n += got;
    }
    return buf[0..n];
}

/// `read_skill`: null for anything that is not a usable skill file.
pub fn readSkill(arena: Allocator, io: Io, path: []const u8) !?Skill {
    const bytes = (try readRegular(arena, io, path, max_skill_bytes + 1)) orelse return null;
    if (bytes.len > max_skill_bytes) return null;
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var meta: Meta = .{};
    const first = lines.next();
    const has_front = if (first) |l| std.mem.eql(u8, trimUnicode(std.mem.trimEnd(u8, l, "\r")), "---") else false;
    if (has_front) {
        var yaml: std.ArrayList(u8) = .empty;
        var closed = false;
        while (lines.next()) |raw| {
            if (raw.len == 0 and lines.peek() == null) break; // `lines()` drops the final empty line
            const l = std.mem.trimEnd(u8, raw, "\r");
            if (std.mem.eql(u8, trimUnicode(l), "---")) {
                closed = true;
                break;
            }
            try yaml.appendSlice(arena, l);
            try yaml.append(arena, '\n');
        }
        if (!closed) return null;
        meta = parseFrontmatter(arena, yaml.items) catch |e| switch (e) {
            error.Malformed => return null,
            else => |x| return x,
        };
    }
    const base = std.fs.path.basename(path);
    const fallback_raw = if (std.mem.eql(u8, base, "SKILL.md"))
        std.fs.path.basename(std.fs.path.dirname(path) orelse "")
    else
        fileStem(base);
    const fallback = if (std.unicode.utf8ValidateSlice(fallback_raw)) fallback_raw else "";
    const name = Meta.str(meta.name) orelse fallback;
    const path_text = try lossy(arena, path);
    if (!validInvocationName(name) or !validSkillPath(path_text)) return null;
    const enabled = if (meta.user_invocable) |v| (if (v == .boolean) v.boolean else true) else true;
    return .{
        .name = try arena.dupe(u8, name),
        .path = try arena.dupe(u8, path_text),
        .description = try arena.dupe(u8, trimUnicode(Meta.str(meta.description) orelse "")),
        .enabled = enabled,
    };
}

// ── scanning roots (`scan_root`) ───────────────────────────────────────────

pub const Found = std.StringArrayHashMapUnmanaged(Skill);

fn trimTrailingSep(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and (p[end - 1] == '/' or (builtin.os.tag == .windows and p[end - 1] == '\\'))) end -= 1;
    return p[0..end];
}

/// `scan_root`: depth-first (a stack, so sibling folders are visited in
/// reverse name order), at most 12 levels, each canonical folder once,
/// every directory entry charged to `remaining`.
pub fn scanRoot(arena: Allocator, io: Io, root_in: []const u8, namespace: []const u8, harness: HarnessId, found: *Found, remaining: *usize) !void {
    const root = trimTrailingSep(root_in);
    const Pending = struct { path: []const u8, depth: usize };
    var pending: std.ArrayList(Pending) = .empty;
    try pending.append(arena, .{ .path = root, .depth = 0 });
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const legacy_commands = std.mem.eql(u8, std.fs.path.basename(root), "commands");
    while (pending.pop()) |item| {
        if (remaining.* == 0) break;
        if (item.depth > 12) continue;
        const canonical = Io.Dir.cwd().realPathFileAlloc(io, item.path, arena) catch continue;
        const gop = try seen.getOrPut(arena, canonical);
        if (gop.found_existing) continue;
        var dir = Io.Dir.cwd().openDir(io, item.path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var iter = dir.iterate();
        while (remaining.* > 0) {
            const entry = (iter.next(io) catch break) orelse break;
            remaining.* -= 1;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |name| {
            const path = try std.fs.path.join(arena, &.{ item.path, name });
            const is_dir = if (Io.Dir.cwd().statFile(io, path, .{})) |st| st.kind == .directory else |_| false;
            if (is_dir) {
                try pending.append(arena, .{ .path = path, .depth = item.depth + 1 });
                continue;
            }
            const flat = legacy_commands or ((harness == .opencode or harness == .pi) and item.depth == 0);
            if (!std.mem.eql(u8, name, "SKILL.md") and !(flat and extensionIs(name, "md"))) continue;
            // One stale symlink or unreadable file must not hide the rest.
            var skill = (readSkill(arena, io, path) catch continue) orelse continue;
            if (legacy_commands) {
                var relative = path[root.len..];
                while (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\')) relative = relative[1..];
                const base = std.fs.path.basename(relative);
                const stem_len = relative.len - base.len + fileStem(base).len;
                const text = try lossy(arena, relative[0..stem_len]);
                const renamed = try arena.dupe(u8, text);
                for (renamed) |*c| if (c.* == '/' or c.* == '\\') {
                    c.* = ':';
                };
                skill.name = renamed;
            }
            skill.name = try std.fmt.allocPrint(arena, "{s}{s}", .{ namespace, skill.name });
            if (validInvocationName(skill.name)) try found.put(arena, skill.name, skill);
        }
    }
}

// ── roots per harness (`discover_at`) ──────────────────────────────────────

fn projectDirs(h: HarnessId) []const []const u8 {
    return switch (h) {
        .claude_code => &.{ ".agents/skills", ".claude/commands", ".claude/skills" },
        .cursor => &.{ ".claude/skills", ".codex/skills", ".agents/skills", ".cursor/skills" },
        .opencode => &.{ ".claude/skills", ".agents/skills", ".opencode/skills" },
        .grok => &.{ ".agents/skills", ".claude/skills", ".grok/skills" },
        .hermes => &.{".agents/skills"},
        .graff => &.{ ".agents/skills", ".claude/skills" },
        .pi => &.{ ".agents/skills", ".pi/skills" },
        .devin => &.{".agents/skills"},
        .antigravity => &.{ ".agents/skills", ".gemini/skills" },
        .codex => &.{ ".agents/skills", ".codex/skills" },
        // Exo works inside its own sandbox and loads its own tools.
        .exo, .mock => &.{},
    };
}

/// `std::env::var_os(name).map(PathBuf::from)` (an empty value is kept).
fn envPath(env: *const Environ.Map, name: []const u8) ?[]const u8 {
    return env.get(name);
}

/// `antigravity_paths::home()`: GEMINI_HOME (`~` expanded) or `~/.gemini`,
/// anchored at HOME. Errors (an empty GEMINI_HOME, an unresolvable `~`)
/// carry the message Rust's launch reports.
pub const GeminiHome = union(enum) { ok: []const u8, err: []const u8 };

pub fn antigravityHome(arena: Allocator, io: Io, env: *const Environ.Map) !GeminiHome {
    const proc_cwd: []const u8 = if (Io.Dir.cwd().realPathFileAlloc(io, ".", arena)) |z| z else |_| "/";
    const home = env.get("HOME");
    const child_cwd = if (home) |h| (if (std.fs.path.isAbsolute(h)) h else try std.fs.path.join(arena, &.{ proc_cwd, h })) else proc_cwd;
    const raw = env.get("GEMINI_HOME");
    if (raw) |r| if (r.len == 0) return .{ .err = "GEMINI_HOME is empty; unset it or set an absolute path before signing in" };
    const path = raw orelse "~/.gemini";
    var expanded: []const u8 = path;
    if (path.len > 0 and path[0] == '~') {
        const sep = std.mem.indexOfAny(u8, path, "/\\") orelse path.len;
        const first = path[0..sep];
        if (!std.mem.eql(u8, first, "~")) return .{ .err = "cannot resolve a named home in GEMINI_HOME; set an absolute path" };
        const h = home orelse "";
        if (h.len == 0) return .{ .err = "cannot resolve ~ in GEMINI_HOME; set an absolute path" };
        const rest = std.mem.trimStart(u8, path[sep..], "/\\");
        expanded = if (rest.len == 0) h else try std.fs.path.join(arena, &.{ h, rest });
    }
    const resolved = if (std.fs.path.isAbsolute(expanded)) expanded else try std.fs.path.join(arena, &.{ child_cwd, expanded });
    if (!std.fs.path.isAbsolute(resolved)) return .{ .err = "cannot resolve GEMINI_HOME to an absolute directory; set an absolute path" };
    return .{ .ok = resolved };
}

/// `antigravity_skill_dirs`: the user-global folders the server loads.
pub fn antigravitySkillDirs(arena: Allocator, io: Io, env: *const Environ.Map) ![]const []const u8 {
    const home = switch (try antigravityHome(arena, io, env)) {
        .ok => |h| h,
        .err => return &.{},
    };
    const dirs = try arena.alloc([]const u8, 2);
    dirs[0] = try std.fs.path.join(arena, &.{ home, "config", "skills" });
    dirs[1] = try std.fs.path.join(arena, &.{ home, "antigravity-cli", "skills" });
    return dirs;
}

/// `Path::starts_with` (whole components).
fn pathStartsWith(path: []const u8, prefix_in: []const u8) bool {
    const prefix = trimTrailingSep(prefix_in);
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    if (prefix.len > 0 and prefix[prefix.len - 1] == '/') return true;
    return path[prefix.len] == '/' or (builtin.os.tag == .windows and path[prefix.len] == '\\');
}

const Root = struct { path: []const u8, namespace: []const u8 = "" };

/// Claude's installed plugins: only their install paths, never caches or
/// marketplaces; project-scoped installs only inside their project.
fn claudePluginRoots(arena: Allocator, io: Io, config: []const u8, cwd: []const u8, roots: *std.ArrayList(Root)) !void {
    const file = try std.fs.path.join(arena, &.{ config, "plugins", "installed_plugins.json" });
    const bytes = Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(64 * 1024 * 1024)) catch return;
    const value = json.parseFromSliceLeaky(json.Value, arena, bytes, .{}) catch return;
    if (value != .object) return;
    const plugins = value.object.get("plugins") orelse return;
    if (plugins != .object) return;
    // serde_json's map iterates in key order.
    const keys = try arena.dupe([]const u8, plugins.object.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (keys) |id| {
        const installs = plugins.object.get(id).?;
        const at = std.mem.indexOfScalar(u8, id, '@') orelse id.len;
        const namespace = try std.fmt.allocPrint(arena, "{s}:", .{id[0..at]});
        if (installs != .array) continue;
        for (installs.array.items) |install| {
            if (install != .object) continue;
            if (install.object.get("projectPath")) |p| if (p == .string) {
                if (!pathStartsWith(cwd, p.string)) continue;
            };
            const ip = install.object.get("installPath") orelse continue;
            if (ip != .string) continue;
            try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ ip.string, "skills" }), .namespace = namespace });
            try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ ip.string, "commands" }), .namespace = namespace });
        }
    }
}

fn exists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// `discover_at(harness, cwd, home)`: every skill visible to `harness` in
/// `cwd`, ordered by name. Strings live in `arena`.
pub fn discoverAt(arena: Allocator, io: Io, harness: HarnessId, cwd_in: []const u8, home_in: []const u8, env: *const Environ.Map) ![]Skill {
    return discoverAtBudget(arena, io, harness, cwd_in, home_in, env, max_discovery_entries);
}

pub fn discoverAtBudget(arena: Allocator, io: Io, harness: HarnessId, cwd_in: []const u8, home_in: []const u8, env: *const Environ.Map, budget: usize) ![]Skill {
    const cwd = trimTrailingSep(cwd_in);
    const home = trimTrailingSep(home_in);
    var roots: std.ArrayList(Root) = .empty;
    for (projectDirs(harness)) |dir| try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ home, dir }) });
    switch (harness) {
        .antigravity => for (try antigravitySkillDirs(arena, io, env)) |d| try roots.append(arena, .{ .path = d }),
        .pi => {
            const base = envPath(env, "PI_CODING_AGENT_DIR") orelse try std.fs.path.join(arena, &.{ home, ".pi/agent" });
            try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ base, "skills" }) });
        },
        .hermes => {
            const base = envPath(env, "HERMES_HOME") orelse try std.fs.path.join(arena, &.{ home, ".hermes" });
            try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ base, "skills" }) });
        },
        .opencode => {
            const base = envPath(env, "XDG_CONFIG_HOME") orelse try std.fs.path.join(arena, &.{ home, ".config" });
            try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ base, "opencode/skills" }) });
        },
        .claude_code => {
            const config = envPath(env, "CLAUDE_CONFIG_DIR") orelse try std.fs.path.join(arena, &.{ home, ".claude" });
            try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ config, "commands" }) });
            try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ config, "skills" }) });
            try claudePluginRoots(arena, io, config, cwd, &roots);
        },
        else => {},
    }
    // Project scope stops at the nearest worktree root (or HOME); nested
    // directories override ancestors, and project skills override global ones.
    var ancestors: std.ArrayList([]const u8) = .empty;
    var dir: ?[]const u8 = cwd;
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        try ancestors.append(arena, d);
        const git = try std.fs.path.join(arena, &.{ d, ".git" });
        if (exists(io, git) or std.mem.eql(u8, d, home)) break;
    }
    var k = ancestors.items.len;
    while (k > 0) {
        k -= 1;
        for (projectDirs(harness)) |suffix| try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ ancestors.items[k], suffix }) });
    }
    var found: Found = .empty;
    var remaining = budget;
    for (roots.items) |r| {
        if (remaining == 0) break;
        try scanRoot(arena, io, r.path, r.namespace, harness, &found, &remaining);
    }
    const skills = try arena.dupe(Skill, found.values());
    std.mem.sort(Skill, skills, {}, struct {
        fn lt(_: void, a: Skill, b: Skill) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return skills;
}

/// `skills::discover(harness, cwd)`: HOME from the (overridable) environment.
pub fn discover(arena: Allocator, io: Io, harness: HarnessId, cwd: []const u8) ![]Skill {
    var env = try catalog_core.currentEnv(arena);
    const home = try catalog_core.homeOrCwd(arena, io, &env);
    return discoverAt(arena, io, harness, cwd, home, &env);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn writeTree(io: Io, dir: Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = rel, .data = body });
}

const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    base: []const u8,
    env: Environ.Map,

    fn init() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .tmp = testing.tmpDir(.{}), .arena_state = .init(testing.allocator), .base = undefined, .env = .init(testing.allocator) };
        const z = try f.tmp.dir.realPathFileAlloc(testing.io, ".", f.arena_state.allocator());
        f.base = z;
        try f.tmp.dir.createDirPath(testing.io, "home");
        try f.tmp.dir.createDirPath(testing.io, "repo/.git");
        try f.env.put("HOME", try f.path("home"));
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.env.deinit();
        f.arena_state.deinit();
        f.tmp.cleanup();
        testing.allocator.destroy(f);
    }

    fn a(f: *Fixture) Allocator {
        return f.arena_state.allocator();
    }

    fn path(f: *Fixture, rel: []const u8) ![]const u8 {
        return std.fs.path.join(f.a(), &.{ f.base, rel });
    }

    fn write(f: *Fixture, rel: []const u8, body: []const u8) !void {
        try writeTree(testing.io, f.tmp.dir, rel, body);
    }

    fn discoverIn(f: *Fixture, h: HarnessId, cwd_rel: []const u8) ![]Skill {
        return discoverAt(f.a(), testing.io, h, try f.path(cwd_rel), try f.path("home"), &f.env);
    }
};

fn findSkill(skills: []const Skill, name: []const u8) ?Skill {
    for (skills) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

test "skills_discovery: frontmatter reads strings, folded text and booleans; malformed YAML fails" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    {
        const m = try parseFrontmatter(a, "name: review\ndescription: >-\n  Native multiline\n  description\ndisable-model-invocation: true\n");
        try testing.expectEqualStrings("review", Meta.str(m.name).?);
        try testing.expectEqualStrings("Native multiline description", Meta.str(m.description).?);
        try testing.expect(m.user_invocable == null);
    }
    {
        const m = try parseFrontmatter(a, "# comment\nname: 'it''s'\ndescription: \"tab\\there \\u00e9\"\nuser-invocable: false\n");
        try testing.expectEqualStrings("it's", Meta.str(m.name).?);
        try testing.expectEqualStrings("tab\there é", Meta.str(m.description).?);
        try testing.expectEqual(false, m.user_invocable.?.boolean);
    }
    {
        const m = try parseFrontmatter(a, "name: 123\ndescription: |\n  line one\n  line two\ntags: [a, b]\nnested:\n  key: value\nlist:\n- x\n- y\n");
        try testing.expect(Meta.str(m.name) == null);
        try testing.expectEqualStrings("line one\nline two\n", Meta.str(m.description).?);
    }
    {
        const m = try parseFrontmatter(a, "description: first line\n  continues here # comment\nname: ~\n");
        try testing.expectEqualStrings("first line continues here", Meta.str(m.description).?);
        try testing.expect(Meta.str(m.name) == null);
    }
    try testing.expect((try parseFrontmatter(a, "")).name == null);
    try testing.expect((try parseFrontmatter(a, "just a sentence\n")).name == null);
    for ([_][]const u8{
        "name: [broken\n",
        "name: x\ndescription: Use this: for things\n",
        "name: \"unterminated\n",
        "name: x\n  bad: nested\n",
        "name: x\nnot a key\n",
        "name: @reserved\n",
        "description: |x\n",
    }) |bad| try testing.expectError(error.Malformed, parseFrontmatter(a, bad));
}

test "skills_discovery: invocation and command names follow the proto grammar" {
    for ([_][]const u8{ "two words", " padded", "padded ", "tab\tname", "non\u{a0}breaking", "", "bad\x01" }) |n| try testing.expect(!validInvocationName(n));
    try testing.expect(validInvocationName("审查[ui]`"));
    try testing.expect(validSkillPath("/é skill/SKILL.md"));
    try testing.expect(!validSkillPath("/bad\npath/SKILL.md"));
    try testing.expect(validSkillCommandName("审查-é:ui.v2_test"));
    for ([_][]const u8{ "", "two words", "review[ui]", "bad\nname", "bad\x00name", "a/b" }) |n| try testing.expect(!validSkillCommandName(n));
    try testing.expect(isSharedSkill("/repo/.agents/skills/compact/SKILL.md"));
    try testing.expect(!isSharedSkill("/repo/.claude/skills/compact/SKILL.md"));
    try testing.expect(!isSharedSkill("/repo/agents/skills/x/SKILL.md"));
}

test "skills_discovery: advertised commands bind by name; Pi's skill: namespace adds rows; shared skills keep their identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    {
        var skills: std.ArrayList(Skill) = .empty;
        const cmds = [_]SlashCommand{ .{ .name = "skill:review", .description = "Review" }, .{ .name = "compact" } };
        try attachAdvertisedCommands(a, .pi, &skills, &cmds);
        try testing.expectEqual(@as(usize, 1), skills.items.len);
        try testing.expectEqualStrings("review", skills.items[0].name);
        try testing.expectEqualStrings("harness-skill:pi:review", skills.items[0].path);
        try testing.expectEqualStrings("skill:review", skills.items[0].command.?.name);
        try testing.expectEqualStrings("Review", skills.items[0].description);
    }
    {
        var skills: std.ArrayList(Skill) = .empty;
        const cmds = [_]SlashCommand{ .{ .name = "skill:" }, .{ .name = "skill:two words" }, .{ .name = "skill:bad\nname" }, .{ .name = "skill:review[ui]" }, .{ .name = "skill:审查-é:ui.v2_test" } };
        try attachAdvertisedCommands(a, .pi, &skills, &cmds);
        try testing.expectEqual(@as(usize, 1), skills.items.len);
        try testing.expectEqualStrings("审查-é:ui.v2_test", skills.items[0].name);
    }
    for ([_]HarnessId{ .devin, .grok, .hermes, .graff }) |h| {
        var skills: std.ArrayList(Skill) = .empty;
        try skills.append(a, .{ .name = "review", .path = "/repo/SKILL.md" });
        try attachAdvertisedCommands(a, h, &skills, &.{.{ .name = "review" }});
        try testing.expectEqual(h, skills.items[0].command.?.harness);
    }
    for ([_]HarnessId{ .devin, .grok, .hermes, .antigravity, .pi }) |h| {
        var skills: std.ArrayList(Skill) = .empty;
        try skills.append(a, .{ .name = "compact", .path = "/repo/.agents/skills/compact/SKILL.md" });
        try attachAdvertisedCommands(a, h, &skills, &.{.{ .name = "compact" }});
        try testing.expect(skills.items[0].command == null);
        if (h == .pi) {
            try attachAdvertisedCommands(a, h, &skills, &.{.{ .name = "skill:compact" }});
            try testing.expectEqualStrings("skill:compact", skills.items[0].command.?.name);
        }
    }
}

test "skills_discovery: every production harness sees shared project skills; Mock and Exo see none" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.write("repo/.agents/skills/portable/SKILL.md", "---\nname: portable\ndescription: Shared skill\n---\nBody");
    for ([_]HarnessId{ .claude_code, .codex, .cursor, .devin, .grok, .hermes, .pi, .antigravity, .opencode, .graff }) |h| {
        const skills = try f.discoverIn(h, "repo");
        const s = findSkill(skills, "portable") orelse return error.TestExpectedSkill;
        try testing.expectEqualStrings("Shared skill", s.description);
        try testing.expect(s.enabled and s.command == null);
    }
    try testing.expectEqual(@as(usize, 0), (try f.discoverIn(.exo, "repo")).len);
    try testing.expectEqual(@as(usize, 0), (try f.discoverIn(.mock, "repo")).len);
}

test "skills_discovery: native roots beat shared and global ones; user-invocable is kept" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.write("home/.agents/skills/review/SKILL.md", "---\nname: review\ndescription: Global\n---\nBody");
    try f.write("repo/.agents/skills/review/SKILL.md", "---\nname: review\ndescription: Project\n---\nBody");
    const natives = [_]struct { HarnessId, []const u8 }{ .{ .claude_code, ".claude" }, .{ .cursor, ".cursor" }, .{ .grok, ".grok" }, .{ .pi, ".pi" }, .{ .opencode, ".opencode" } };
    for (natives) |n| {
        const rel = try std.fmt.allocPrint(f.a(), "repo/{s}/skills/review/SKILL.md", .{n[1]});
        try f.write(rel, "---\nname: review\ndescription: >-\n  Native multiline\n  description\ndisable-model-invocation: true\n---\nBody");
        const skills = try f.discoverIn(n[0], "repo");
        const s = findSkill(skills, "review").?;
        try testing.expectEqualStrings(try f.path(rel), s.path);
        try testing.expectEqualStrings("Native multiline description", s.description);
        try testing.expect(s.enabled);
    }
    try f.write("repo/.agents/skills/hidden/SKILL.md", "---\nname: hidden\nuser-invocable: false\n---\nBody");
    try f.write("repo/.agents/skills/broken/SKILL.md", "---\nname: [broken\n---\nBody");
    const skills = try f.discoverIn(.devin, "repo");
    try testing.expectEqual(@as(usize, 2), skills.len);
    try testing.expectEqualStrings("hidden", skills[0].name);
    try testing.expect(!skills[0].enabled);
    try testing.expectEqualStrings("Project", findSkill(skills, "review").?.description);
}

test "skills_discovery: nested workspaces stop at .git; legacy commands keep namespaces; duplicates resolve like Rust's stack" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, "repo/packages/web");
    try f.write(".agents/skills/outside/SKILL.md", "Body");
    try f.write("repo/.agents/skills/root/SKILL.md", "Body");
    try f.write("repo/packages/web/.claude/commands/team/review.md", "---\ndescription: Legacy\n---\nBody");
    // Two folders claim `dup`: the stack visits `b` before `a`, so `a` wins.
    try f.write("repo/.agents/skills/a/SKILL.md", "---\nname: dup\ndescription: from a\n---\n");
    try f.write("repo/.agents/skills/b/SKILL.md", "---\nname: dup\ndescription: from b\n---\n");
    const skills = try f.discoverIn(.claude_code, "repo/packages/web");
    try testing.expect(findSkill(skills, "root") != null);
    try testing.expectEqualStrings("Legacy", findSkill(skills, "team:review").?.description);
    try testing.expect(findSkill(skills, "outside") == null);
    try testing.expectEqualStrings("from a", findSkill(skills, "dup").?.description);
    // Sorted by name.
    for (skills[1..], 0..) |s, i| try testing.expect(std.mem.lessThan(u8, skills[i].name, s.name));
}

test "skills_discovery: malformed, oversized, invalid UTF-8 and special files never hide valid skills" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    try f.write("skills/valid/SKILL.md", "---\nname: valid\n---\nBody");
    try f.write("skills/invalid/SKILL.md", "\xff\xfe");
    const big = try f.a().alloc(u8, max_skill_bytes + 2);
    @memset(big, 'x');
    @memcpy(big[big.len - 2 ..], "é");
    try f.write("skills/oversized/SKILL.md", big);
    try f.write("skills/unclosed/SKILL.md", "---\nname: unclosed\n");
    try f.tmp.dir.createDirPath(testing.io, "skills/device");
    try f.tmp.dir.symLink(testing.io, "/dev/zero", "skills/device/SKILL.md", .{});
    try f.tmp.dir.createDirPath(testing.io, "skills/missing");
    try f.tmp.dir.symLink(testing.io, "/nonexistent-skill-target.md", "skills/missing/SKILL.md", .{});
    for ([_]HarnessId{ .claude_code, .codex, .cursor, .devin, .grok, .hermes, .pi, .antigravity, .opencode }) |h| {
        var found: Found = .empty;
        var remaining = max_discovery_entries;
        try scanRoot(f.a(), testing.io, try f.path("skills"), "", h, &found, &remaining);
        try testing.expectEqual(@as(usize, 1), found.count());
        try testing.expect(found.get("valid") != null);
    }
}

test "skills_discovery: symlinked skill folders work and cycles are visited once; namespaces are validated" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    try f.write("source/review/SKILL.md", "---\nname: review\n---\nBody");
    try f.tmp.dir.createDirPath(testing.io, "skills");
    try f.tmp.dir.symLink(testing.io, try f.path("source/review"), "skills/review", .{ .is_directory = true });
    try f.tmp.dir.symLink(testing.io, try f.path("skills"), "skills/cycle", .{ .is_directory = true });
    var found: Found = .empty;
    var remaining = max_discovery_entries;
    try scanRoot(f.a(), testing.io, try f.path("skills"), "plugin:", .claude_code, &found, &remaining);
    try testing.expectEqual(@as(usize, 1), found.count());
    try testing.expect(found.get("plugin:review") != null);

    try f.write("commands/bad folder/review.md", "---\nname: valid\n---\nBody");
    try f.write("commands/good/review.md", "Body");
    found = .empty;
    try scanRoot(f.a(), testing.io, try f.path("commands"), "", .claude_code, &found, &remaining);
    try testing.expectEqual(@as(usize, 1), found.count());
    try testing.expect(found.get("good:review") != null);
    found = .empty;
    try scanRoot(f.a(), testing.io, try f.path("commands"), "bad namespace:", .claude_code, &found, &remaining);
    try testing.expectEqual(@as(usize, 0), found.count());
    try scanRoot(f.a(), testing.io, try f.path("commands"), "é-plugin:", .claude_code, &found, &remaining);
    try testing.expect(found.get("é-plugin:good:review") != null);
}

test "skills_discovery: the entry budget is shared across roots and charges directories" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.write("home/.agents/skills/global.md", "Global");
    for (0..40) |i| try f.write(try std.fmt.allocPrint(f.a(), "repo/.pi/skills/skill-{d:0>2}.md", .{i}), "Body");
    // The global root charges one entry; the project's flat root gets the rest.
    const skills = try discoverAtBudget(f.a(), testing.io, .pi, try f.path("repo"), try f.path("home"), &f.env, 30);
    try testing.expectEqual(@as(usize, 30), skills.len);
    try testing.expect(findSkill(skills, "global") != null);
    var found: Found = .empty;
    var remaining: usize = 1;
    try scanRoot(f.a(), testing.io, try f.path("repo"), "", .pi, &found, &remaining);
    try testing.expectEqual(@as(usize, 0), remaining);
    try testing.expectEqual(@as(usize, 0), found.count());
}

test "skills_discovery: provider roots: Claude plugins, Pi, Hermes, OpenCode flat files, Antigravity's GEMINI_HOME" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.write("plugin-a/skills/lint/SKILL.md", "---\ndescription: Lint\n---\n");
    try f.write("plugin-b/commands/deploy.md", "Deploy");
    try f.write("plugin-c/skills/elsewhere/SKILL.md", "Body");
    const plugins = try std.fmt.allocPrint(f.a(),
        \\{{"plugins":{{"tools@market":[{{"installPath":"{s}"}}],"ops@m":[{{"installPath":"{s}","projectPath":"{s}"}}],"far@m":[{{"installPath":"{s}","projectPath":"{s}"}}]}}}}
    , .{ try f.path("plugin-a"), try f.path("plugin-b"), try f.path("repo"), try f.path("plugin-c"), try f.path("other") });
    try f.write("home/.claude/plugins/installed_plugins.json", plugins);
    const claude = try f.discoverIn(.claude_code, "repo");
    try testing.expectEqualStrings("Lint", findSkill(claude, "tools:lint").?.description);
    try testing.expect(findSkill(claude, "ops:deploy") != null);
    try testing.expect(findSkill(claude, "far:elsewhere") == null);

    try f.write("pi-agent/skills/pi-flat.md", "Pi flat");
    try f.env.put("PI_CODING_AGENT_DIR", try f.path("pi-agent"));
    try testing.expect(findSkill(try f.discoverIn(.pi, "repo"), "pi-flat") != null);

    try f.write("hermes/skills/h/SKILL.md", "Body");
    try f.env.put("HERMES_HOME", try f.path("hermes"));
    try testing.expect(findSkill(try f.discoverIn(.hermes, "repo"), "h") != null);

    try f.write("xdg/opencode/skills/oc.md", "Body");
    try f.write("xdg/opencode/skills/deep/nested.md", "not flat below depth 0");
    try f.env.put("XDG_CONFIG_HOME", try f.path("xdg"));
    const oc = try f.discoverIn(.opencode, "repo");
    try testing.expect(findSkill(oc, "oc") != null);
    try testing.expect(findSkill(oc, "nested") == null);

    try f.write("gemini/config/skills/g1/SKILL.md", "Body");
    try f.write("gemini/antigravity-cli/skills/g2/SKILL.md", "Body");
    try f.env.put("GEMINI_HOME", try f.path("gemini"));
    const ag = try f.discoverIn(.antigravity, "repo");
    try testing.expect(findSkill(ag, "g1") != null and findSkill(ag, "g2") != null);
    try f.env.put("GEMINI_HOME", "");
    try testing.expect(findSkill(try f.discoverIn(.antigravity, "repo"), "g1") == null);
    try testing.expect((try antigravityHome(f.a(), testing.io, &f.env)) == .err);
    try f.env.put("GEMINI_HOME", "~/gem");
    try testing.expectEqualStrings(try f.path("home/gem"), (try antigravityHome(f.a(), testing.io, &f.env)).ok);
}

test "skills_discovery: the wire shape matches serde (command skipped when absent; None is null)" {
    const gpa = testing.allocator;
    const rows = [_]Skill{
        .{ .name = "review", .path = "/r/SKILL.md", .description = "Re\"view", .enabled = false },
        .{ .name = "x", .path = "/x.md", .command = .{ .name = "x", .harness = .claude_code } },
    };
    const text = try skillsJson(gpa, &rows);
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\[{"name":"review","path":"/r/SKILL.md","description":"Re\"view","enabled":false},{"name":"x","path":"/x.md","description":"","enabled":true,"command":{"name":"x","harness":"claude-code"}}]
    , text);
    const none = try skillsJson(gpa, null);
    defer gpa.free(none);
    try testing.expectEqualStrings("null", none);
    try testing.expectEqual(HarnessId.claude_code, HarnessId.fromWire("claude-code").?);
    try testing.expect(HarnessId.fromWire("nope") == null);
}
