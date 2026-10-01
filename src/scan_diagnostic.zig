//! Caller-owned scan failure output and borrowed pipeline progress.
const std = @import("std");

/// Initialize with `init` and release with `deinit`. Each diagnostic scan
/// clears this output. Failure text survives scan cleanup and remains valid
/// until the next scan using this diagnostic or `deinit`.
/// Move this owner; do not copy it and deinitialize it twice.
pub const ScanDiagnostic = struct {
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
        /// Parse and inherit selected JS/TS resolution configs.
        configs,
        /// Index Rust test modules and propagate their test status.
        rust_tests,
        /// Index Python star reexports.
        python_exports,
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
        /// The original error returned by the scan, including reader errors.
        cause: anyerror,
    };

    /// This allocator owns only the diagnostic's copy of the failed path.
    pub fn init(gpa: std.mem.Allocator) ScanDiagnostic {
        return .{ .gpa = gpa };
    }
    pub fn deinit(diagnostic: *ScanDiagnostic) void {
        diagnostic.clear();
    }
    fn clear(diagnostic: *ScanDiagnostic) void {
        if (diagnostic.failure) |failure| if (failure.path) |path| diagnostic.gpa.free(path);
        diagnostic.failure = null;
    }
};

pub fn reset(diagnostic: ?*ScanDiagnostic) void {
    if (diagnostic) |d| d.clear();
}

/// Progress borrows the current path; only ScanDiagnostic owns output.
/// Capture failure before releasing graph and resolution workspace storage.
pub const Progress = struct {
    diagnostic: ?*ScanDiagnostic,
    phase: ScanDiagnostic.Phase = .paths,
    path: ?[]const u8 = null,

    pub fn at(progress: *Progress, phase: ScanDiagnostic.Phase, path: ?[]const u8) void {
        progress.phase = phase;
        progress.path = path;
    }
    pub fn fail(progress: *const Progress, cause: anyerror) void {
        const d = progress.diagnostic orelse return;
        // Reporting must preserve the original cause even if its allocator fails.
        const owned = if (progress.path) |path| d.gpa.dupe(u8, path) catch null else null;
        d.failure = .{ .path = owned, .phase = progress.phase, .cause = cause };
    }
};
