//! CLI entry point for bottlebrush: eventually runs a JS file or a REPL.
//!
//! Phase 0: the lexer/parser/evaluator don't exist yet, so this is just a
//! banner confirming the engine builds and links. File-running and the REPL
//! arrive with the Phase 2 evaluator (and CLI arg parsing once the 0.16 args
//! API settles).

const std = @import("std");
const bottlebrush = @import("bottlebrush");

pub fn main() void {
    std.debug.print(
        \\bottlebrush {s} — a tier-2 JavaScript engine in Zig
        \\
        \\  Phase 0 scaffold: Value + GC + Test262 harness are in place.
        \\  Evaluation (files / REPL) arrives in Phase 2.
        \\
        \\  Run the conformance speedometer:  zig build test262
        \\  Run the unit tests:               zig build test
        \\
    , .{bottlebrush.version});
}
