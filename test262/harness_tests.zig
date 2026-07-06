//! Test aggregator for the Test262 harness modules, run via `zig build test`.
test {
    _ = @import("frontmatter.zig");
    _ = @import("report.zig");
}
