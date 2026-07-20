//! Shared readonly data export records for native object emission.

const std = @import("std");
const layout = @import("layout");
const lir = @import("lir");

/// Immutable data symbol to emit into the target's readonly data section.
pub const StaticDataExport = struct {
    /// The exported symbol name, for example `roc__answer`.
    symbol_name: []const u8,
    /// Fully materialized Roc ABI bytes for the constant.
    bytes: []const u8,
    /// Offset inside `bytes` where `symbol_name` points.
    symbol_offset: u32 = 0,
    /// Required alignment of the symbol inside the readonly section.
    alignment: u32,
    /// Whether the object-file symbol should have global linker binding.
    ///
    /// Internal static constants referenced from a separately compiled LLVM
    /// object need this so the linker can resolve `roc__static_value_*`
    /// references across object files.
    is_global: bool = true,
    /// Whether this symbol is part of the host-visible ABI.
    ///
    /// Exported data symbols are rooted under section garbage collection and
    /// included in shared-library/module export lists. Internal static
    /// constants can be linker-global without being host-exported.
    is_exported: bool = true,
    /// Pointer relocations from this symbol's bytes to other symbols.
    relocations: []const StaticDataRelocation = &.{},
};

/// One pointer relocation inside a readonly static-data symbol.
pub const StaticDataRelocation = struct {
    pub const Kind = enum {
        address,
        function_pointer,
    };

    /// Byte offset inside `StaticDataExport.bytes` where the pointer is stored.
    offset: u64,
    /// Symbol whose address should be written at `offset`.
    target_symbol_name: []const u8,
    /// Addend applied to the target symbol address.
    addend: i64 = 0,
    /// Runtime meaning of the stored pointer.
    kind: Kind = .address,
    /// Exact generated RC helper required by this function-pointer relocation.
    ///
    /// Static erased-callable `on_drop` slots are always atomic: their
    /// construction site makes no thread-confinement claim. Backends consume
    /// this key directly to compile and publish that helper; they must not
    /// recover it from `target_symbol_name` or from a capture layout.
    rc_helper: ?layout.RcHelperKey = null,
    /// Whether `target_symbol_name` is owned by this relocation and must be freed
    /// with the static data graph.
    owns_target_symbol_name: bool = false,
};

/// Deterministic cross-object symbol for an atomic generated RC helper.
///
/// The helper identity remains the explicit `RcHelperKey`; this name is only
/// its linker representation at the backend boundary.
pub fn atomicRcHelperSymbolName(allocator: std.mem.Allocator, helper: layout.RcHelperKey) std.mem.Allocator.Error![]u8 {
    return try std.fmt.allocPrint(allocator, "roc__rc_helper_{x}", .{helper.encode()});
}

/// Collect the distinct explicit RC-helper requirements in a static-data graph.
pub fn collectRequiredRcHelpers(
    allocator: std.mem.Allocator,
    exports: []const StaticDataExport,
) std.mem.Allocator.Error![]layout.RcHelperKey {
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    var result = std.ArrayList(layout.RcHelperKey).empty;
    errdefer result.deinit(allocator);

    for (exports) |data_export| {
        for (data_export.relocations) |relocation| {
            const helper = relocation.rc_helper orelse continue;
            const gop = try seen.getOrPut(helper.encode());
            if (gop.found_existing) continue;
            try result.append(allocator, helper);
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Deterministic object-file symbol name for an internal LIR procedure.
///
/// These symbols are local text symbols. They exist so readonly data can point at
/// erased-callable wrappers using ordinary object relocations instead of backend
/// code-buffer offsets.
pub fn procSymbolName(allocator: std.mem.Allocator, proc_symbol: lir.Symbol) std.mem.Allocator.Error![]u8 {
    return try std.fmt.allocPrint(allocator, "roc__proc_{x}", .{proc_symbol.raw()});
}
