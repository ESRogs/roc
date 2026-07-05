const std = @import("std");
const collections = @import("collections");
const check = @import("check");
const layout = @import("layout");
const lir = @import("lir");
const postcheck = @import("postcheck");

const GuardedList = collections.GuardedList;
const Allocator = std.mem.Allocator;
const LIR = lir.LIR;
const Mono = postcheck.Monotype;
const Lifted = postcheck.MonotypeLifted;
const LambdaMono = postcheck.LambdaMono;

const MoveAllocator = struct {
    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *MoveAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        return std.heap.page_allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        std.heap.page_allocator.rawFree(memory, alignment, ret_addr);
    }
};

const TestList = GuardedList.List(u32, "guarded_list_violation_test.values");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.next();
    const case_name = args.next() orelse return error.MissingCaseName;

    if (std.mem.eql(u8, case_name, "span_append_move")) return spanAppendMove();
    if (std.mem.eql(u8, case_name, "ptr_append_move")) return ptrAppendMove();
    if (std.mem.eql(u8, case_name, "span_ensure_move")) return spanEnsureMove();
    if (std.mem.eql(u8, case_name, "span_append_slice_move")) return spanAppendSliceMove();
    if (std.mem.eql(u8, case_name, "span_restore_below_range")) return spanRestoreBelowRange();
    if (std.mem.eql(u8, case_name, "ptr_restore_below_index")) return ptrRestoreBelowIndex();
    if (std.mem.eql(u8, case_name, "span_clear")) return spanClear();
    if (std.mem.eql(u8, case_name, "span_ownership_transfer")) return spanOwnershipTransfer();
    if (std.mem.eql(u8, case_name, "lir_proc_specs")) return lirProcSpecs();
    if (std.mem.eql(u8, case_name, "lir_local_span")) return lirLocalSpan();
    if (std.mem.eql(u8, case_name, "lifted_fns")) return liftedFns();
    if (std.mem.eql(u8, case_name, "lifted_expr_ids")) return liftedExprIds();
    if (std.mem.eql(u8, case_name, "mono_exprs")) return monoExprs();
    if (std.mem.eql(u8, case_name, "mono_type_spans")) return monoTypeSpans();
    if (std.mem.eql(u8, case_name, "mono_type_fields")) return monoTypeFields();
    if (std.mem.eql(u8, case_name, "lambda_mono_expr_ids")) return lambdaMonoExprIds();
    if (std.mem.eql(u8, case_name, "lambda_mono_type_spans")) return lambdaMonoTypeSpans();

    return error.UnknownCaseName;
}

fn spanAppendMove() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var list = try TestList.initCapacity(allocator, 1);
    defer list.deinit(allocator);

    try list.append(allocator, 1);
    const borrow = list.borrowSpan(0, 1);
    try list.append(allocator, 2);
    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn ptrAppendMove() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var list = try TestList.initCapacity(allocator, 1);
    defer list.deinit(allocator);

    try list.append(allocator, 1);
    const borrow = list.borrowPtr(0);
    try list.append(allocator, 2);
    _ = GuardedList.ptrGet(borrow);
    return error.ExpectedGuardedListPanic;
}

fn spanEnsureMove() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var list = try TestList.initCapacity(allocator, 1);
    defer list.deinit(allocator);

    try list.append(allocator, 1);
    const borrow = list.borrowSpan(0, 1);
    try list.ensureUnusedCapacity(allocator, 1);
    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn spanAppendSliceMove() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var list = try TestList.initCapacity(allocator, 1);
    defer list.deinit(allocator);

    try list.append(allocator, 1);
    const borrow = list.borrowSpan(0, 1);
    try list.appendSlice(allocator, &.{ 2, 3 });
    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn spanRestoreBelowRange() !void {
    var list = try TestList.initCapacity(std.heap.page_allocator, 4);
    defer list.deinit(std.heap.page_allocator);

    try list.appendSlice(std.heap.page_allocator, &.{ 1, 2, 3, 4 });
    const borrow = list.borrowSpan(2, 2);
    list.restoreLen(2);
    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn ptrRestoreBelowIndex() !void {
    var list = try TestList.initCapacity(std.heap.page_allocator, 4);
    defer list.deinit(std.heap.page_allocator);

    try list.appendSlice(std.heap.page_allocator, &.{ 1, 2, 3, 4 });
    const borrow = list.borrowPtr(3);
    list.restoreLen(3);
    _ = GuardedList.ptrGet(borrow);
    return error.ExpectedGuardedListPanic;
}

fn spanClear() !void {
    var list = try TestList.initCapacity(std.heap.page_allocator, 4);
    defer list.deinit(std.heap.page_allocator);

    try list.appendSlice(std.heap.page_allocator, &.{ 1, 2, 3, 4 });
    const borrow = list.borrowSpan(0, 1);
    list.clearRetainingCapacity();
    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn spanOwnershipTransfer() !void {
    var list = try TestList.initCapacity(std.heap.page_allocator, 4);

    try list.appendSlice(std.heap.page_allocator, &.{ 1, 2, 3, 4 });
    const borrow = list.borrowSpan(0, 1);
    var moved = list.takeArrayList();
    defer moved.deinit(std.heap.page_allocator);

    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn lirProcSpecs() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var store = lir.LirStore.init(allocator);
    defer store.deinit();

    try store.proc_specs.ensureTotalCapacityPrecise(allocator, 1);
    _ = try store.addProcSpec(dummyProcSpec(1));
    const borrow = store.proc_specs.borrowPtr(0);
    _ = try store.addProcSpec(dummyProcSpec(2));
    _ = GuardedList.ptrGet(borrow);
    return error.ExpectedGuardedListPanic;
}

fn lirLocalSpan() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var store = lir.LirStore.init(allocator);
    defer store.deinit();

    try store.local_ids.ensureTotalCapacityPrecise(allocator, 1);
    const span = try store.addLocalSpan(&.{@as(LIR.LocalId, @enumFromInt(0))});
    const borrow = store.local_ids.borrowSpan(span.start, span.len);
    _ = try store.addLocalSpan(&.{@as(LIR.LocalId, @enumFromInt(1))});
    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn liftedFns() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var program = emptyLiftedProgram(allocator);
    defer program.deinit();

    try program.fns.ensureTotalCapacityPrecise(allocator, 1);
    _ = try program.addFn(dummyLiftedFn(1));
    const borrow = program.fns.borrowPtr(0);
    _ = try program.addFn(dummyLiftedFn(2));
    _ = GuardedList.ptrGet(borrow);
    return error.ExpectedGuardedListPanic;
}

fn liftedExprIds() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var program = emptyLiftedProgram(allocator);
    defer program.deinit();

    try program.expr_ids.ensureTotalCapacityPrecise(allocator, 1);
    const span = try program.addExprSpan(&.{@as(Lifted.Ast.ExprId, @enumFromInt(0))});
    const borrow = program.expr_ids.borrowSpan(span.start, span.len);
    _ = try program.addExprSpan(&.{@as(Lifted.Ast.ExprId, @enumFromInt(1))});
    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn monoExprs() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var program = Mono.Ast.ProgramBuilder.init(allocator);
    defer program.deinit();

    try program.exprs.ensureTotalCapacityPrecise(allocator, 1);
    _ = try program.addExpr(dummyMonoExpr());
    const borrow = program.exprs.borrowPtr(0);
    _ = try program.addExpr(dummyMonoExpr());
    _ = GuardedList.ptrGet(borrow);
    return error.ExpectedGuardedListPanic;
}

fn monoTypeSpans() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var store = Mono.Type.Store.init(allocator);
    defer store.deinit();

    try store.spans.ensureTotalCapacityPrecise(allocator, 1);
    const span = try store.addSpan(&.{@as(Mono.Type.TypeId, @enumFromInt(0))});
    const borrow = store.spans.borrowSpan(span.start, span.len);
    _ = try store.addSpan(&.{@as(Mono.Type.TypeId, @enumFromInt(1))});
    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn monoTypeFields() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var store = Mono.Type.Store.init(allocator);
    defer store.deinit();

    try store.fields.ensureTotalCapacityPrecise(allocator, 1);
    const span = try store.addFields(&.{dummyMonoTypeField(0)});
    const borrow = store.fields.borrowSpan(span.start, span.len);
    _ = try store.addFields(&.{dummyMonoTypeField(1)});
    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn lambdaMonoExprIds() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var program = LambdaMono.Ast.Program.init(allocator, check.CheckedNames.NameStore.init(allocator), .empty);
    defer program.deinit();

    try program.expr_ids.ensureTotalCapacityPrecise(allocator, 1);
    const span = try program.addExprSpan(&.{@as(LambdaMono.Ast.ExprId, @enumFromInt(0))});
    const borrow = program.expr_ids.borrowSpan(span.start, span.len);
    _ = try program.addExprSpan(&.{@as(LambdaMono.Ast.ExprId, @enumFromInt(1))});
    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn lambdaMonoTypeSpans() !void {
    var move_allocator = MoveAllocator{};
    const allocator = move_allocator.allocator();
    var store = LambdaMono.Type.Store.init(allocator);
    defer store.deinit();

    try store.spans.ensureTotalCapacityPrecise(allocator, 1);
    const span = try store.addSpan(&.{@as(LambdaMono.Type.TypeId, @enumFromInt(0))});
    const borrow = store.spans.borrowSpan(span.start, span.len);
    _ = try store.addSpan(&.{@as(LambdaMono.Type.TypeId, @enumFromInt(1))});
    _ = GuardedList.at(borrow, 0);
    return error.ExpectedGuardedListPanic;
}

fn emptyLiftedProgram(allocator: Allocator) Lifted.Ast.Program {
    return Lifted.Ast.Program.init(
        allocator,
        check.CheckedNames.NameStore.init(allocator),
        Mono.Type.Store.init(allocator),
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        Mono.Ast.ProcDebugNameMap.init(allocator),
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        .empty,
        0,
    );
}

fn dummyProcSpec(raw: u64) LIR.LirProcSpec {
    return .{
        .name = LIR.Symbol.fromRaw(raw),
        .args = LIR.LocalSpan.empty(),
        .ret_layout = layout.Idx.u8,
    };
}

fn dummyLiftedFn(raw: u32) Lifted.Ast.Fn {
    return .{
        .symbol = @enumFromInt(raw),
        .args = Lifted.Ast.Span(Lifted.Ast.TypedLocal).empty(),
        .captures = Lifted.Ast.Span(Lifted.Ast.TypedLocal).empty(),
        .body = .hosted,
        .ret = @enumFromInt(0),
    };
}

fn dummyMonoExpr() Mono.Ast.Expr {
    return .{
        .ty = @enumFromInt(0),
        .data = .unit,
    };
}

fn dummyMonoTypeField(raw: u32) Mono.Type.Field {
    return .{
        .name = @enumFromInt(raw),
        .ty = @enumFromInt(0),
    };
}
