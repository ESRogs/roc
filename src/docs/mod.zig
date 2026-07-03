//! Documentation extraction for Roc modules.
//!
//! This module provides the data model and extraction logic for generating
//! documentation from compiled Roc modules. It extracts doc comments, type
//! signatures, and module structure into a stable format suitable for
//! rendering to HTML, Markdown, JSON, or other output formats.

pub const DocModel = @import("DocModel.zig");
pub const extract = @import("extract.zig");
pub const render_html = @import("render_html.zig");
pub const render_type = @import("render_type.zig");

test "docs tests" {
    std.testing.refAllDecls(@import("DocModel.zig"));
    std.testing.refAllDecls(@import("extract.zig"));
    std.testing.refAllDecls(@import("render_html.zig"));
    std.testing.refAllDecls(@import("render_type.zig"));
}

const std = @import("std");

test "doc refs to builtin types and type module children resolve to real links" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const utf8_entry = DocModel.DocEntry{
        .name = try gpa.dupe(u8, "Utf8"),
        .kind = .alias,
        .type_signature = null,
        .doc_comment = null,
        .children = try gpa.alloc(DocModel.DocEntry, 0),
    };

    // repro for https://github.com/roc-lang/roc/issues/9886: shorthand doc
    // refs to builtin types and same-module type-module children are valid.
    const doc_with_refs = try gpa.dupe(u8,
        \\Parse a [Str].
        \\Matches any [Utf8].
    );
    const any_thing_entry = DocModel.DocEntry{
        .name = try gpa.dupe(u8, "any_thing"),
        .kind = .value,
        .type_signature = null,
        .doc_comment = doc_with_refs,
        .children = try gpa.alloc(DocModel.DocEntry, 0),
        .doc_comment_start_line = 10,
    };

    const string_children = try gpa.alloc(DocModel.DocEntry, 2);
    string_children[0] = utf8_entry;
    string_children[1] = any_thing_entry;

    const string_entry = DocModel.DocEntry{
        .name = try gpa.dupe(u8, "String"),
        .kind = .@"opaque",
        .type_signature = null,
        .doc_comment = null,
        .children = string_children,
    };

    const entries = try gpa.alloc(DocModel.DocEntry, 1);
    entries[0] = string_entry;

    const modules = try gpa.alloc(DocModel.ModuleDocs, 1);
    modules[0] = .{
        .name = try gpa.dupe(u8, "String"),
        .package_name = try gpa.dupe(u8, "roc-parser"),
        .kind = .type_module,
        .module_doc = null,
        .entries = entries,
        .source_path = try gpa.dupe(u8, "/fake/roc-parser/package/String.roc"),
    };

    var package_docs = DocModel.PackageDocs{
        .name = try gpa.dupe(u8, "roc-parser"),
        .modules = modules,
    };
    defer package_docs.deinit(gpa);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(tmp_path);

    var broken_links: std.ArrayListUnmanaged(render_html.BrokenLink) = .empty;
    defer {
        for (broken_links.items) |bl| {
            gpa.free(bl.label);
            gpa.free(bl.resolved_anchor);
        }
        broken_links.deinit(gpa);
    }

    try render_html.renderPackageDocs(gpa, std.testing.io, &package_docs, tmp_path, &broken_links);

    if (broken_links.items.len != 0) {
        for (broken_links.items) |bl| {
            std.debug.print("broken doc link: {s}:{d}: [{s}] -> #{s}\n", .{
                bl.source_path,
                bl.source_line,
                bl.label,
                bl.resolved_anchor,
            });
        }
    }
    try testing.expectEqual(@as(usize, 0), broken_links.items.len);

    const html = try tmp.dir.readFileAlloc(testing.io, "index.html", gpa, .limited(1024 * 1024));
    defer gpa.free(html);
    try testing.expect(std.mem.containsAtLeast(u8, html, 1, "href=\"https://roc-lang.org/builtins/main/#Builtin.Str\""));
    try testing.expect(std.mem.containsAtLeast(u8, html, 1, "href=\"#String.Utf8\""));
}
