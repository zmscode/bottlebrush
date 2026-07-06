//! Test262 scoreboard — the project's conformance speedometer.
//! Pure data + arithmetic; the runner does the I/O and formatting.

const std = @import("std");

pub const Outcome = enum { pass, fail, skip };

/// Why a test was skipped rather than run. As phases land, fewer tests skip.
pub const SkipReason = enum {
    no_lexer, // Phase 1 not yet: cannot even tokenize
    no_parser, // Phase 1 not yet: cannot check parse-phase negatives
    no_evaluator, // Phase 2 not yet: cannot execute
    unsupported_feature, // feature not implemented / intentionally excluded
    harness_missing, // a required includes: helper is unavailable
    other,
};

pub const Scoreboard = struct {
    pass: usize = 0,
    fail: usize = 0,
    skip: usize = 0,
    /// Total test files discovered (excludes _FIXTURE.js helpers).
    files: usize = 0,

    pub fn record(self: *Scoreboard, o: Outcome) void {
        switch (o) {
            .pass => self.pass += 1,
            .fail => self.fail += 1,
            .skip => self.skip += 1,
        }
    }

    /// Tests actually executed (pass or fail).
    pub fn ran(self: Scoreboard) usize {
        return self.pass + self.fail;
    }

    pub fn total(self: Scoreboard) usize {
        return self.pass + self.fail + self.skip;
    }

    /// Pass rate over *executed* tests, as a percentage. 0 when nothing ran.
    pub fn passRate(self: Scoreboard) f64 {
        const r = self.ran();
        if (r == 0) return 0;
        return @as(f64, @floatFromInt(self.pass)) / @as(f64, @floatFromInt(r)) * 100.0;
    }
};

// ---- Tests -----------------------------------------------------------------

test "empty scoreboard is zero" {
    const b: Scoreboard = .{};
    try std.testing.expectEqual(@as(usize, 0), b.total());
    try std.testing.expectEqual(@as(usize, 0), b.ran());
    try std.testing.expectEqual(@as(f64, 0), b.passRate());
}

test "records and rates" {
    var b: Scoreboard = .{};
    b.record(.pass);
    b.record(.pass);
    b.record(.pass);
    b.record(.fail);
    b.record(.skip);
    try std.testing.expectEqual(@as(usize, 5), b.total());
    try std.testing.expectEqual(@as(usize, 4), b.ran());
    try std.testing.expectEqual(@as(f64, 75), b.passRate());
}

test "all-skip yields zero percent, not divide-by-zero" {
    var b: Scoreboard = .{};
    b.record(.skip);
    b.record(.skip);
    try std.testing.expectEqual(@as(f64, 0), b.passRate());
    try std.testing.expectEqual(@as(usize, 0), b.ran());
}
