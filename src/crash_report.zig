//! Overrides the panics to provide more information
//! Slightly stolen from the Zig Compiler :P
const std = @import("std");
const CodeObject = @import("compiler/CodeObject.zig");
const print_co = @import("print_co.zig");

const builtin = @import("builtin");
const build_options = @import("options");
const debug = std.debug;
const posix = std.posix;
const io = std.io;

const native_os = builtin.os.tag;

const trace_depth_limit: usize = 5;

pub const panic = if (build_options.enable_debug_extensions) compilerPanic else std.builtin.default_panic;

/// Install signal handlers to identify crashes and report diagnostics.
pub fn initialize() void {
    if (build_options.enable_debug_extensions and debug.have_segfault_handling_support) {
        attachSegfaultHandler();
    }
}

pub fn compilerPanic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, maybe_ret_addr: ?usize) noreturn {
    PanicSwitch.preDispatch();
    @setCold(true);
    const ret_addr = maybe_ret_addr orelse @returnAddress();
    const stack_ctx: StackContext = .{ .current = .{ .ret_addr = ret_addr } };
    PanicSwitch.dispatch(error_return_trace, stack_ctx, msg);
}

/// Attaches a global SIGSEGV handler
pub fn attachSegfaultHandler() void {
    if (!debug.have_segfault_handling_support) {
        @compileError("segfault handler not supported for this target");
    }
    if (native_os == .windows) @compileLog("later");
    var act: posix.Sigaction = .{
        .handler = .{ .sigaction = handleSegfaultPosix },
        .mask = posix.empty_sigset,
        .flags = (posix.SA.SIGINFO | posix.SA.RESTART | posix.SA.RESETHAND),
    };
    debug.updateSegfaultHandler(&act) catch {
        @panic("unable to install segfault handler, maybe adjust have_segfault_handling_support in std/debug.zig");
    };
}

fn handleSegfaultPosix(sig: i32, info: *const posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.C) noreturn {
    // TODO: use alarm() here to prevent infinite loops
    PanicSwitch.preDispatch();

    const addr = switch (native_os) {
        .linux => @intFromPtr(info.fields.sigfault.addr),
        .freebsd, .macos => @intFromPtr(info.addr),
        .netbsd => @intFromPtr(info.info.reason.fault.addr),
        .openbsd => @intFromPtr(info.data.fault.addr),
        .solaris, .illumos => @intFromPtr(info.reason.fault.addr),
        else => @compileError("TODO implement handleSegfaultPosix for new POSIX OS"),
    };

    var err_buffer: [128]u8 = undefined;
    const error_msg = switch (sig) {
        posix.SIG.SEGV => std.fmt.bufPrint(&err_buffer, "Segmentation fault at address 0x{x}", .{addr}) catch "Segmentation fault",
        posix.SIG.ILL => std.fmt.bufPrint(&err_buffer, "Illegal instruction at address 0x{x}", .{addr}) catch "Illegal instruction",
        posix.SIG.BUS => std.fmt.bufPrint(&err_buffer, "Bus error at address 0x{x}", .{addr}) catch "Bus error",
        else => std.fmt.bufPrint(&err_buffer, "Unknown error (signal {}) at address 0x{x}", .{ sig, addr }) catch "Unknown error",
    };

    const stack_ctx: StackContext = switch (builtin.cpu.arch) {
        .x86,
        .x86_64,
        .arm,
        .aarch64,
        => StackContext{ .exception = @ptrCast(@alignCast(ctx_ptr)) },
        else => .not_supported,
    };

    PanicSwitch.dispatch(null, stack_ctx, error_msg);
}

threadlocal var vm_state: ?*VmContext = if (build_options.enable_debug_extensions) null else @compileError("Cannot use vm_state without debug extensions.");

pub const VmContext = if (build_options.enable_debug_extensions) struct {
    parent: ?*VmContext,
    current_co: *const CodeObject,
    index: usize,

    pub fn push(context: *VmContext) void {
        const head = &vm_state;
        std.debug.assert(context.parent == null);
        context.parent = head.*;
        head.* = context;
    }

    pub fn pop(context: *VmContext) void {
        const head = &vm_state;
        const old = head.*.?;
        debug.assert(old == context);
        head.* = old.parent;
    }

    pub fn setIndex(context: *VmContext, index: usize) void {
        context.index = index;
    }
} else struct {
    pub inline fn push(_: @This()) void {}
    pub inline fn pop(_: @This()) void {}
    pub inline fn setIndex(_: VmContext, _: usize) void {}
};

pub fn prepVmContext(current_co: *const CodeObject) VmContext {
    return if (build_options.enable_debug_extensions) .{
        .parent = null,
        .current_co = current_co,
        .index = 0,
    } else .{};
}

fn dumpStatusReport() !void {
    const state = vm_state orelse return;
    const stderr = io.getStdErr().writer();
    const current_co = state.current_co;

    try print_co.print_co(stderr, .{
        .co = current_co.*,
        .index = state.index,
    });

    var depth: usize = 0;
    var temp_state: VmContext = state.*;
    while (temp_state.parent != null) : (depth += 1) {
        if (depth > trace_depth_limit) break;

        const co = temp_state.current_co;
        try stderr.print("CodeObject #{d}:\n{}\n", .{ depth, co.* });

        temp_state = temp_state.parent.?.*;
    }
}

const StackContext = union(enum) {
    current: struct {
        ret_addr: ?usize,
    },
    exception: *const debug.ThreadContext,
    not_supported: void,

    pub fn dumpStackTrace(ctx: @This()) void {
        switch (ctx) {
            .current => |ct| {
                debug.dumpCurrentStackTrace(ct.ret_addr);
            },
            .exception => |context| {
                debug.dumpStackTraceFromBase(context);
            },
            .not_supported => {
                const stderr = io.getStdErr().writer();
                stderr.writeAll("Stack trace not supported on this platform.\n") catch {};
            },
        }
    }
};

const PanicSwitch = struct {
    const RecoverStage = enum {
        initialize,
        report_stack,
        release_mutex,
        release_ref_count,
        abort,
        silent_abort,
    };

    const RecoverVerbosity = enum {
        message_and_stack,
        message_only,
        silent,
    };

    const PanicState = struct {
        recover_stage: RecoverStage = .initialize,
        recover_verbosity: RecoverVerbosity = .message_and_stack,
        panic_ctx: StackContext = undefined,
        panic_trace: ?*const std.builtin.StackTrace = null,
        awaiting_dispatch: bool = false,
    };

    /// Counter for the number of threads currently panicking.
    /// Updated atomically before taking the panic_mutex.
    /// In recoverable cases, the program will not abort
    /// until all panicking threads have dumped their traces.
    var panicking = std.atomic.Value(u8).init(0);

    // Locked to avoid interleaving panic messages from multiple threads.
    var panic_mutex = std.Thread.Mutex{};

    /// Tracks the state of the current panic.  If the code within the
    /// panic triggers a secondary panic, this allows us to recover.
    threadlocal var panic_state_raw: PanicState = .{};

    /// The segfault handlers above need to do some work before they can dispatch
    /// this switch.  Calling preDispatch() first makes that work fault tolerant.
    pub fn preDispatch() void {
        // TODO: We want segfaults to trigger the panic recursively here,
        // but if there is a segfault accessing this TLS slot it will cause an
        // infinite loop.  We should use `alarm()` to prevent the infinite
        // loop and maybe also use a non-thread-local global to detect if
        // it's happening and print a message.
        var panic_state: *volatile PanicState = &panic_state_raw;
        if (panic_state.awaiting_dispatch) {
            dispatch(null, .{ .current = .{ .ret_addr = null } }, "Panic while preparing callstack");
        }
        panic_state.awaiting_dispatch = true;
    }

    /// This is the entry point to a panic-tolerant panic handler.
    /// preDispatch() *MUST* be called exactly once before calling this.
    /// A threadlocal "recover_stage" is updated throughout the process.
    /// If a panic happens during the panic, the recover_stage will be
    /// used to select a recover* function to call to resume the panic.
    /// The recover_verbosity field is used to handle panics while reporting
    /// panics within panics.  If the panic handler triggers a panic, it will
    /// attempt to log an additional stack trace for the secondary panic.  If
    /// that panics, it will fall back to just logging the panic message.  If
    /// it can't even do that witout panicing, it will recover without logging
    /// anything about the internal panic.  Depending on the state, "recover"
    /// here may just mean "call abort".
    pub fn dispatch(
        trace: ?*const std.builtin.StackTrace,
        stack_ctx: StackContext,
        msg: []const u8,
    ) noreturn {
        var panic_state: *volatile PanicState = &panic_state_raw;
        debug.assert(panic_state.awaiting_dispatch);
        panic_state.awaiting_dispatch = false;
        nosuspend switch (panic_state.recover_stage) {
            .initialize => goTo(initPanic, .{ panic_state, trace, stack_ctx, msg }),
            .report_stack => goTo(recoverReportStack, .{ panic_state, trace, stack_ctx, msg }),
            .release_mutex => goTo(recoverReleaseMutex, .{ panic_state, trace, stack_ctx, msg }),
            .release_ref_count => goTo(recoverReleaseRefCount, .{ panic_state, trace, stack_ctx, msg }),
            .abort => goTo(recoverAbort, .{ panic_state, trace, stack_ctx, msg }),
            .silent_abort => goTo(abort, .{}),
        };
    }

    noinline fn initPanic(
        state: *volatile PanicState,
        trace: ?*const std.builtin.StackTrace,
        stack: StackContext,
        msg: []const u8,
    ) noreturn {
        // use a temporary so there's only one volatile store
        const new_state = PanicState{
            .recover_stage = .abort,
            .panic_ctx = stack,
            .panic_trace = trace,
        };
        state.* = new_state;

        _ = panicking.fetchAdd(1, .seq_cst);

        state.recover_stage = .release_ref_count;

        panic_mutex.lock();

        state.recover_stage = .release_mutex;

        const stderr = io.getStdErr().writer();
        if (builtin.single_threaded) {
            stderr.print("panic: ", .{}) catch goTo(releaseMutex, .{state});
        } else {
            const current_thread_id = std.Thread.getCurrentId();
            stderr.print("thread {} panic: ", .{current_thread_id}) catch goTo(releaseMutex, .{state});
        }
        stderr.print("{s}\n", .{msg}) catch goTo(releaseMutex, .{state});

        state.recover_stage = .report_stack;

        dumpStatusReport() catch |err| {
            stderr.print("\nIntercepted error.{} while dumping current state.  Continuing...\n", .{err}) catch {};
        };

        goTo(reportStack, .{state});
    }

    noinline fn recoverReportStack(
        state: *volatile PanicState,
        trace: ?*const std.builtin.StackTrace,
        stack: StackContext,
        msg: []const u8,
    ) noreturn {
        recover(state, trace, stack, msg);

        state.recover_stage = .release_mutex;
        const stderr = io.getStdErr().writer();
        stderr.writeAll("\nOriginal Error:\n") catch {};
        goTo(reportStack, .{state});
    }

    noinline fn reportStack(state: *volatile PanicState) noreturn {
        state.recover_stage = .release_mutex;

        if (state.panic_trace) |t| {
            debug.dumpStackTrace(t.*);
        }
        state.panic_ctx.dumpStackTrace();

        goTo(releaseMutex, .{state});
    }

    noinline fn recoverReleaseMutex(
        state: *volatile PanicState,
        trace: ?*const std.builtin.StackTrace,
        stack: StackContext,
        msg: []const u8,
    ) noreturn {
        recover(state, trace, stack, msg);
        goTo(releaseMutex, .{state});
    }

    noinline fn releaseMutex(state: *volatile PanicState) noreturn {
        state.recover_stage = .abort;

        panic_mutex.unlock();

        goTo(releaseRefCount, .{state});
    }

    noinline fn recoverReleaseRefCount(
        state: *volatile PanicState,
        trace: ?*const std.builtin.StackTrace,
        stack: StackContext,
        msg: []const u8,
    ) noreturn {
        recover(state, trace, stack, msg);
        goTo(releaseRefCount, .{state});
    }

    noinline fn releaseRefCount(state: *volatile PanicState) noreturn {
        state.recover_stage = .abort;

        if (panicking.fetchSub(1, .seq_cst) != 1) {
            // Another thread is panicking, wait for the last one to finish
            // and call abort()

            // Sleep forever without hammering the CPU
            var futex = std.atomic.Value(u32).init(0);
            while (true) std.Thread.Futex.wait(&futex, 0);

            // This should be unreachable, recurse into recoverAbort.
            @panic("event.wait() returned");
        }

        goTo(abort, .{});
    }

    noinline fn recoverAbort(
        state: *volatile PanicState,
        trace: ?*const std.builtin.StackTrace,
        stack: StackContext,
        msg: []const u8,
    ) noreturn {
        recover(state, trace, stack, msg);

        state.recover_stage = .silent_abort;
        const stderr = io.getStdErr().writer();
        stderr.writeAll("Aborting...\n") catch {};
        goTo(abort, .{});
    }

    noinline fn abort() noreturn {
        std.process.abort();
    }

    inline fn goTo(comptime func: anytype, args: anytype) noreturn {
        // TODO: Tailcall is broken right now, but eventually this should be used
        // to avoid blowing up the stack.  It's ok for now though, there are no
        // cycles in the state machine so the max stack usage is bounded.
        //@call(.always_tail, func, args);
        @call(.auto, func, args);
    }

    fn recover(
        state: *volatile PanicState,
        trace: ?*const std.builtin.StackTrace,
        stack: StackContext,
        msg: []const u8,
    ) void {
        switch (state.recover_verbosity) {
            .message_and_stack => {
                // lower the verbosity, and restore it at the end if we don't panic.
                state.recover_verbosity = .message_only;

                const stderr = io.getStdErr().writer();
                stderr.writeAll("\nPanicked during a panic: ") catch {};
                stderr.writeAll(msg) catch {};
                stderr.writeAll("\nInner panic stack:\n") catch {};
                if (trace) |t| {
                    debug.dumpStackTrace(t.*);
                }
                stack.dumpStackTrace();

                state.recover_verbosity = .message_and_stack;
            },
            .message_only => {
                state.recover_verbosity = .silent;

                const stderr = io.getStdErr().writer();
                stderr.writeAll("\nPanicked while dumping inner panic stack: ") catch {};
                stderr.writeAll(msg) catch {};
                stderr.writeAll("\n") catch {};

                // If we succeed, restore all the way to dumping the stack.
                state.recover_verbosity = .message_and_stack;
            },
            .silent => {},
        }
    }
};
