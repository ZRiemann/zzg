//! ZetaX components. Enable logging at the application build boundary.
pub const log = if (@import("options").log) @import("logging") else @compileError("enable zzg with .log = true to use z.log");
