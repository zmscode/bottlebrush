//! bilby — public API surface.
//!
//! A small, fast, dependency-free JavaScript-flavoured regular-expression
//! engine. Import this module (`bilby`) and use `Regex`:
//!
//! ```zig
//! var re = try bilby.Regex.compileUtf8(gpa, "(\\w+)@(\\w+)", "i");
//! defer re.deinit(gpa);
//! const units = try bilby.utf8ToUtf16(gpa, "user@host");
//! defer gpa.free(units);
//! if (try re.find(gpa, units, 0)) |m| { defer m.deinit(gpa); ... }
//! ```

const regex = @import("regex.zig");

pub const Regex = regex.Regex;
pub const Flags = regex.Flags;
pub const Match = regex.Match;
pub const Span = regex.Span;
pub const Error = regex.Error;
pub const utf8ToUtf16 = regex.utf8ToUtf16;
pub const utf16ToUtf8 = regex.utf16ToUtf8;

test {
    _ = regex; // pull the engine's tests into `zig build test`
}
