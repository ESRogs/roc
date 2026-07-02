//! Canonical enumeration of a type scheme's static-dispatch constraints
//! ("evidence params").
//!
//! Every scheme with dispatch constraints gets one ordered param list: index
//! `k` in that list is the identity a dispatch plan's `constraint(k)`
//! resolution and a call edge's k-th evidence entry both refer to. The order
//! is defined purely by the scheme's type structure, so the definition's own
//! module and a caller holding a structural copy of the scheme (an import
//! copy, or the pristine root recorded by a `SchemeInstantiationRecord`)
//! enumerate identical lists without sharing var identities.
//!
//! Order contract: depth-first over the resolved type structure — function
//! args then return, alias/nominal args then backing, row fields/tags then
//! extension, all in store order — emitting each constrained var's
//! constraints in range order at its first occurrence; then the collected
//! constraints' fn types are walked the same way in emission order (they can
//! bind further constrained vars, e.g. `where [a.iter : a -> i, i.next : ..]`).

const std = @import("std");
const types_mod = @import("types");

const Allocator = std.mem.Allocator;
const Var = types_mod.Var;
const StaticDispatchConstraint = types_mod.StaticDispatchConstraint;

/// One (constrained scheme var, constraint) pair, at its canonical index.
pub const EvidenceParam = struct {
    /// Resolved root of the constrained scheme var.
    dispatcher_var: Var,
    constraint: StaticDispatchConstraint,
};

/// Reusable scratch state for `enumerateEvidenceParams`.
pub const Scratch = struct {
    visited: std.AutoHashMapUnmanaged(Var, void) = .{},
    stack: std.ArrayListUnmanaged(Var) = .empty,
    fn_var_queue: std.ArrayListUnmanaged(Var) = .empty,

    pub fn deinit(self: *Scratch, gpa: Allocator) void {
        self.visited.deinit(gpa);
        self.stack.deinit(gpa);
        self.fn_var_queue.deinit(gpa);
        self.* = .{};
    }

    fn clear(self: *Scratch) void {
        self.visited.clearRetainingCapacity();
        self.stack.clearRetainingCapacity();
        self.fn_var_queue.clearRetainingCapacity();
    }
};

/// Append the scheme's evidence params to `out` in canonical order.
pub fn enumerateEvidenceParams(
    gpa: Allocator,
    store: *const types_mod.Store,
    root: Var,
    scratch: *Scratch,
    out: *std.ArrayListUnmanaged(EvidenceParam),
) Allocator.Error!void {
    scratch.clear();

    try walk(gpa, store, root, scratch, out);
    // Constraint fn types can bind further constrained vars; the queue holds
    // every emitted constraint's fn var in emission order. `walk` may grow the
    // queue while we drain it — index-based drain keeps that sound.
    var queue_index: usize = 0;
    while (queue_index < scratch.fn_var_queue.items.len) : (queue_index += 1) {
        try walk(gpa, store, scratch.fn_var_queue.items[queue_index], scratch, out);
    }
}

/// The canonical index of `dispatcher_root`'s `fn_name` constraint within
/// `params`, or null.
pub fn paramIndex(
    params: []const EvidenceParam,
    dispatcher_root: Var,
    fn_name: anytype,
) ?u32 {
    for (params, 0..) |param, k| {
        if (param.dispatcher_var == dispatcher_root and param.constraint.fn_name.eql(fn_name)) {
            return @intCast(k);
        }
    }
    return null;
}

fn walk(
    gpa: Allocator,
    store: *const types_mod.Store,
    walk_root: Var,
    scratch: *Scratch,
    out: *std.ArrayListUnmanaged(EvidenceParam),
) Allocator.Error!void {
    const stack_base = scratch.stack.items.len;
    try scratch.stack.append(gpa, walk_root);

    while (scratch.stack.items.len > stack_base) {
        const var_ = scratch.stack.pop().?;
        const resolved = store.resolveVar(var_);
        const entry = try scratch.visited.getOrPut(gpa, resolved.var_);
        if (entry.found_existing) continue;

        switch (resolved.desc.content) {
            .flex => |flex| try emitConstraints(gpa, store, resolved.var_, flex.constraints, scratch, out),
            .rigid => |rigid| try emitConstraints(gpa, store, resolved.var_, rigid.constraints, scratch, out),
            .alias => |alias| {
                try pushChildrenReversed(gpa, scratch, store.sliceAliasArgs(alias), store.getAliasBackingVar(alias));
            },
            .structure => |flat_type| switch (flat_type) {
                .record => |record| {
                    try scratch.stack.append(gpa, record.ext);
                    const field_vars = store.getRecordFieldsSlice(record.fields).items(.var_);
                    try pushReversed(gpa, scratch, field_vars);
                },
                .record_unbound => |fields_range| {
                    const field_vars = store.getRecordFieldsSlice(fields_range).items(.var_);
                    try pushReversed(gpa, scratch, field_vars);
                },
                .tuple => |tuple| try pushReversed(gpa, scratch, store.sliceVars(tuple.elems)),
                .nominal_type => |nominal| {
                    try pushChildrenReversed(gpa, scratch, store.sliceNominalArgs(nominal), store.getNominalBackingVar(nominal));
                },
                .fn_pure, .fn_effectful, .fn_unbound => |func| {
                    try pushChildrenReversed(gpa, scratch, store.sliceVars(func.args), func.ret);
                },
                .tag_union => |tag_union| {
                    try scratch.stack.append(gpa, tag_union.ext);
                    const tag_args = store.getTagsSlice(tag_union.tags).items(.args);
                    var i = tag_args.len;
                    while (i > 0) {
                        i -= 1;
                        try pushReversed(gpa, scratch, store.sliceVars(tag_args[i]));
                    }
                },
                .empty_record, .empty_tag_union => {},
            },
            .err => {},
        }
    }
}

fn emitConstraints(
    gpa: Allocator,
    store: *const types_mod.Store,
    dispatcher_root: Var,
    constraints: StaticDispatchConstraint.SafeList.Range,
    scratch: *Scratch,
    out: *std.ArrayListUnmanaged(EvidenceParam),
) Allocator.Error!void {
    for (store.sliceStaticDispatchConstraints(constraints)) |constraint| {
        try out.append(gpa, .{
            .dispatcher_var = dispatcher_root,
            .constraint = constraint,
        });
        try scratch.fn_var_queue.append(gpa, constraint.fn_var);
    }
}

/// Push `first` children then `last` so pops visit them in declared order.
fn pushChildrenReversed(
    gpa: Allocator,
    scratch: *Scratch,
    first: []const Var,
    last: Var,
) Allocator.Error!void {
    try scratch.stack.append(gpa, last);
    var i = first.len;
    while (i > 0) {
        i -= 1;
        try scratch.stack.append(gpa, first[i]);
    }
}

fn pushReversed(gpa: Allocator, scratch: *Scratch, children: []const Var) Allocator.Error!void {
    var i = children.len;
    while (i > 0) {
        i -= 1;
        try scratch.stack.append(gpa, children[i]);
    }
}
