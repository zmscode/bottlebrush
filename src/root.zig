//! bottlebrush — a tier-2 JavaScript engine in Zig.
//!
//! Library root: re-exports the engine's public modules and, for the `test`
//! build step, references every module so `zig build test` runs their tests.
//! See ../plan.md and ../phase/ for the phased architecture.

const std = @import("std");

pub const version = "0.0.0";

// Public modules (grow with each phase).
pub const gc = @import("gc.zig");
pub const value = @import("value.zig");
pub const Value = value.Value;
pub const HandleScope = @import("handle.zig").HandleScope;
pub const token = @import("token.zig");
pub const Lexer = @import("lexer.zig").Lexer;
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");

test {
    // Pull in every module's tests. Add new modules here as phases land.
    _ = @import("gc.zig");
    _ = @import("value.zig");
    _ = @import("handle.zig");
    _ = @import("token.zig");
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("parser.zig");
}
