//! LSP unit test root.
//!
//! Root lives at the src/lsp level so it can reference both the test-only
//! suites under test/ and the production files whose inline tests must be
//! collected into this binary (a module root under test/ cannot import them).

const std = @import("std");

test {
    std.testing.refAllDecls(@import("test/unit.zig"));
    std.testing.refAllDecls(@import("dependency_graph.zig"));
    std.testing.refAllDecls(@import("type_utils.zig"));
    std.testing.refAllDecls(@import("cir_visitor.zig"));
    std.testing.refAllDecls(@import("cir_queries.zig"));
    std.testing.refAllDecls(@import("module_lookup.zig"));
    std.testing.refAllDecls(@import("doc_comments.zig"));
    std.testing.refAllDecls(@import("completion/mod.zig"));
    std.testing.refAllDecls(@import("completion/context.zig"));
    std.testing.refAllDecls(@import("completion/builtins.zig"));
    std.testing.refAllDecls(@import("completion/builder.zig"));
}
