//! Caller-owned scan failure output and borrowed pipeline progress.
const std = @import("std");
const t = @import("../types.zig");

/// Initialize with `init` and release with `deinit`. Each diagnostic scan
/// clears this output. Failure text survives scan cleanup and remains valid
/// until the next scan using this diagnostic or `deinit`.
/// Move this owner; do not copy it and deinitialize it twice.
pub const Diagnostics = struct {
    gpa: std.mem.Allocator,
    /// Null after success; otherwise the first failure that aborted the scan.
    failure: ?Failure = null,

    pub const Phase = enum {
        /// Normalize and index the caller's selected paths.
        paths,
        /// Call the reader and record null results.
        read,
        /// Parse Go build constraints and select files.
        go_constraints,
        /// Read dependency declarations and Go module/workspace identities.
        manifests,
        /// Parse and inherit selected JS/TS resolution configs and read
        /// selected Nim search paths.
        configs,
        /// Index Rust test modules and propagate their test status.
        rust_tests,
        /// Index Python star reexports.
        python_exports,
        /// Index Java files by their declared packages.
        java_packages,
        /// Extract lexical source references.
        imports,
        /// Build resolution indexes, resolve references and collect edges.
        resolution,
        /// Recover and resolve Markdown links.
        links,
        /// Recover and resolve asset paths.
        assets,
        /// Sort, coalesce and finish the graph's owned results.
        graph,
    };
    pub const Failure = struct {
        /// The normalized selected path, or the raw input for a path failure.
        /// Null for work without a file or if copying the path ran out of memory.
        path: ?[]const u8,
        phase: Phase,
        /// Start of an unsupported import expression; null for other failures.
        offset: ?t.ByteOffset = null,
        /// The error the scan returned: a `ScanError` or one of the reader's.
        cause: anyerror,
    };

    /// This allocator owns only the diagnostic's copy of the failed path.
    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .gpa = gpa };
    }
    pub fn deinit(diagnostic: *Diagnostics) void {
        diagnostic.clear();
        diagnostic.* = undefined;
    }
    fn clear(diagnostic: *Diagnostics) void {
        if (diagnostic.failure) |failure| if (failure.path) |path| diagnostic.gpa.free(path);
        diagnostic.failure = null;
    }
};

/// What makes a selected file unreadable as its format. A scan records the
/// file in `Graph.invalid` and goes on without what that file would have
/// given; the single-file readers (`imports`, `manifests.parse`) return these.
pub const FileError = error{
    /// Dependency declarations or a Go module or workspace file that are not
    /// well formed.
    InvalidManifest,
    /// A JS/TS config that is not JSON with comments.
    SyntaxError,
    /// A JS/TS config whose `extends`, `compilerOptions`, `baseUrl` or
    /// `paths` has the wrong shape.
    InvalidConfig,
    /// A JS/TS config that extends itself through its parents.
    ConfigCycle,
    /// A string literal with an escape its language does not define.
    InvalidEscape,
    /// A Zig string literal that does not parse.
    InvalidLiteral,
    /// A source file past the size its language's frontend reads.
    SourceTooLarge,
    /// A Go `//go:build` line that is not a constraint, or a second one.
    InvalidBuildConstraint,
    /// An import of a dependency that two Go workspace modules replace with
    /// different places, and that `go.work` does not replace itself.
    ConflictingReplacement,
};

/// What a scan fails with besides its reader's own errors: a selected path
/// `path.normalize` refuses, a pattern in the options sweep refuses
/// (`InvalidPattern`, `PatternTooLong`: a test path, a named module's
/// `from` or a token), a construct recovery cannot read under
/// `Options.strict_imports`, a selected path in a language whose frontend
/// `Options.frontends` lacks (`FrontendMissing`), more edges between two
/// files than a count holds, or memory. Nothing a file's bytes hold is
/// among them.
pub const ScanError = error{ InvalidPath, InvalidPattern, PatternTooLong, UnsupportedImport, FrontendMissing, CountOverflow, OutOfMemory };

/// The errors a scan's `read` function returns, from its signature.
pub fn ReadError(comptime read: anytype) type {
    const returned = @typeInfo(@TypeOf(read)).@"fn".return_type orelse return anyerror;
    return switch (@typeInfo(returned)) {
        .error_union => |u| u.error_set,
        else => error{},
    };
}

/// A selected file the scan read but could not use, and why.
pub const InvalidFile = struct {
    path: []const u8,
    phase: Diagnostics.Phase,
    /// The import a `ConflictingReplacement` is about; null otherwise.
    offset: ?t.ByteOffset = null,
    cause: FileError,
};

/// The `FileError` an error is, or null for any other error.
fn fileError(comptime err: anyerror) ?FileError {
    inline for (@typeInfo(FileError).error_set.error_names.?) |name| {
        if (std.mem.eql(u8, @errorName(err), name)) return @field(FileError, name);
    }
    return null;
}

pub fn reset(diagnostic: ?*Diagnostics) void {
    if (diagnostic) |d| d.clear();
}

/// Progress borrows the current path; only Diagnostics owns output.
/// Capture failure before releasing graph and resolution workspace storage.
// aegis: no danger there; docs/design.md: progress is borrowed by one synchronous scan and failure paths are copied before cleanup.
pub const Progress = struct {
    diagnostic: ?*Diagnostics,
    phase: Diagnostics.Phase = .paths,
    path: ?[]const u8 = null,
    offset: ?t.ByteOffset = null,
    /// The graph's allocator, which owns `invalid` and its paths; set once
    /// the graph exists.
    records: ?std.mem.Allocator = null,
    invalid: std.ArrayList(InvalidFile) = .empty,
    /// Each record once, though more than one pass reads a file.
    recorded: std.StringHashMapUnmanaged(void) = .empty,

    /// Records a `FileError` against the current path, phase and offset,
    /// so the caller can go on without the file; returns any other error.
    /// The switch is per error, so a `FileError` is never in the error set
    /// this returns, nor in a scan's.
    pub fn tolerate(progress: *Progress, err: anytype) !void {
        switch (err) {
            inline else => |e| if (comptime fileError(e)) |cause| try progress.record(cause) else return e,
        }
    }
    fn record(progress: *Progress, cause: FileError) error{OutOfMemory}!void {
        const a = progress.records.?;
        const path = progress.path.?;
        const key = try a.print("{s}\x00{s}\x00{?d}", .{ path, @errorName(cause), if (progress.offset) |offset| offset.raw() else null });
        if ((try progress.recorded.getOrPut(a, key)).found_existing) return;
        try progress.invalid.append(a, .{ .path = try a.dupe(u8, path), .phase = progress.phase, .offset = progress.offset, .cause = cause });
    }

    pub fn at(progress: *Progress, phase: Diagnostics.Phase, path: ?[]const u8) void {
        progress.phase = phase;
        progress.path = path;
        progress.offset = null;
    }
    pub fn fail(progress: *const Progress, cause: anyerror) void {
        const d = progress.diagnostic orelse return;
        std.debug.assert(d.failure == null);
        // Reporting must preserve the original cause even if its allocator fails.
        const owned = if (progress.path) |path| d.gpa.dupe(u8, path) catch null else null;
        d.failure = .{ .path = owned, .phase = progress.phase, .cause = cause, .offset = progress.offset };
    }
};
