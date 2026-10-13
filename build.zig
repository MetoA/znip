const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) !void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // Enables loading additional Tree-sitter grammars at runtime from WASM,
    // for languages outside the natively-compiled set above. On by default
    // so on-demand languages just work out of the box; pass -Dwasm=false to
    // opt out (e.g. for a smaller binary, or a target with no vendored
    // wasmtime dependency - see build.zig.zon).
    const wasm_enabled = b.option(bool, "wasm", "Enable on-demand WASM grammar loading (requires wasmtime)") orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "wasm_enabled", wasm_enabled);

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("znip", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    // Zig's self-hosted x86_64 ELF linker (the Debug default on Linux) can't
    // resolve symbols out of the large Rust-built libwasmtime.a, and crashes
    // when asked to hand off to LLD with its own backend, so use LLVM + LLD there.
    const use_lld: ?bool = if (target.result.os.tag == .linux) true else null;
    const use_llvm: ?bool = if (target.result.os.tag == .linux) true else null;

    const exe = b.addExecutable(.{
        .name = "znip",
        .use_lld = use_lld,
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "znip" is the name you will use in your source code to
                // import this module (e.g. `@import("znip")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "znip", .module = mod },
            },
        }),
    });

    mod.addImport("build_options", build_options.createModule());

    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("clap", clap.module("clap"));

    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("vaxis", vaxis.module("vaxis"));

    // Blend2D configuration
    //
    // Like Tree-sitter below, Blend2D is attached to `mod` only (and `exe`
    // inherits it by importing `mod`), so that `mod_tests` can link and test
    // the renderer and font code that calls into it.
    mod.link_libcpp = true;
    var b2d_flags = std.ArrayList([]const u8).empty;
    try b2d_flags.appendSlice(b.allocator, &.{
        "-std=c++17",
        "-DBL_STATIC",
        "-DASMJIT_STATIC",
        "-fno-math-errno",
    });
    const is_x86_64 = target.result.cpu.arch == .x86_64;
    if (is_x86_64) {
        // These only *enable* the AVX2/SSE code paths. The instruction-set
        // flags (-mavx2, ...) are applied per source file (see
        // addSourceFilesFromDir): passing them globally defines __AVX2__
        // everywhere, which makes Blend2D drop its runtime CPU dispatch and
        // call the AVX2 code unconditionally - SIGILL on CPUs without AVX2.
        try b2d_flags.append(b.allocator, "-DBL_BUILD_OPT_AVX2");
        try b2d_flags.append(b.allocator, "-DBL_BUILD_OPT_SSE2");
    } else if (target.result.cpu.arch.isAARCH64()) {
    } else if (target.result.cpu.arch.isArm()) {
        try b2d_flags.append(b.allocator, "-mfpu=neon");
    }
    mod.addIncludePath(b.path("vendor/blend2d"));
    mod.addIncludePath(b.path("vendor/blend2d/3rdparty/asmjit"));
    addSourceFilesFromDir(b, mod, "vendor/blend2d/blend2d", b2d_flags.items, is_x86_64);
    addSourceFilesFromDir(b, mod, "vendor/blend2d/3rdparty/asmjit/asmjit", b2d_flags.items, false);


    // Tree-sitter configuration
    //
    // All Tree-sitter/wasmtime sources and libraries are attached to `mod`
    // only, not `exe.root_module` - `exe` imports `mod` ("znip") and inherits
    // them transitively. Attaching to both would compile each C source twice
    // and produce duplicate-symbol link errors whenever a Compile step (like
    // exe_tests below) ends up depending on both. `mod` is the single source
    // of truth so that `mod`'s own test binary (`mod_tests`) can also link
    // and exercise tree_sitter.zig directly.
    mod.link_libc = true;
    var ts_flags = std.ArrayList([]const u8).empty;
    try ts_flags.appendSlice(b.allocator, &.{
        "-std=c11",
        "-D_GNU_SOURCE",             // Fixes le16toh/be16toh
        "-D_POSIX_C_SOURCE=200112L", // Fixes fdopen
        "-D_DEFAULT_SOURCE",         // General compatibility
    });
    mod.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    mod.addIncludePath(b.path("vendor/tree-sitter/lib/src"));

    if (wasm_enabled) {
        // wasmtime is a prebuilt binary (built from Rust; there is no C
        // source path), vendored per-host-triple as a lazy build.zig.zon
        // dependency: only the one matching the target is ever fetched, and
        // none is fetched with -Dwasm=false.
        const wasmtime_name: []const u8 = switch (target.result.os.tag) {
            .macos => switch (target.result.cpu.arch) {
                .aarch64 => "wasmtime_aarch64_macos",
                .x86_64 => "wasmtime_x86_64_macos",
                else => unsupportedWasmTarget(),
            },
            .linux => switch (target.result.cpu.arch) {
                .aarch64 => "wasmtime_aarch64_linux",
                .x86_64 => "wasmtime_x86_64_linux",
                else => unsupportedWasmTarget(),
            },
            else => unsupportedWasmTarget(),
        };
        // null on the first pass while the dependency is being fetched; the
        // build runner then re-runs this function with it available.
        if (b.lazyDependency(wasmtime_name, .{})) |wasmtime_dep| {
            mod.addIncludePath(wasmtime_dep.path("include"));
            mod.addLibraryPath(wasmtime_dep.path("lib"));
            // Prefer the static archive over the dylib: the dylib would only be
            // locatable at runtime via an rpath into Zig's global package cache,
            // which doesn't survive distributing the built binary elsewhere.
            // pkg-config is disabled so a system-wide wasmtime can't override
            // the vendored one (and its headers) found above.
            mod.linkSystemLibrary("wasmtime", .{ .preferred_link_mode = .static, .use_pkg_config = .no });
        }
        // wasm_store.c's `#include "./stdlib-symbols.txt"` is normally
        // satisfied by tree-sitter's Rust build.rs copying it into OUT_DIR;
        // here we just point the quoted-include fallback search at its real
        // vendored location instead.
        mod.addIncludePath(b.path("vendor/tree-sitter/lib/src/wasm"));
        try ts_flags.append(b.allocator, "-DTREE_SITTER_FEATURE_WASM");
    }

    mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/lib/src/lib.c"),
        .flags = ts_flags.items,
    });

    const languages = [_][]const u8{ "zig", "rust", "javascript", "typescript", "python", "c", "cpp", "go", "html", "css", "java", "ruby", "php", "json", "markdown", "sql" };

    // Some grammar repos nest the actual grammar source below the repo root
    // instead of directly under `src/` (e.g. because the repo hosts multiple
    // grammar variants side by side).
    const src_subdir_overrides = [_]struct { language: []const u8, subdir: []const u8 }{
        .{ .language = "typescript", .subdir = "typescript" },
        .{ .language = "php", .subdir = "php" },
        .{ .language = "markdown", .subdir = "tree-sitter-markdown" },
    };

    for (languages) |language| {
        const repo_path = b.fmt("src/deps/tree-sitter-{s}", .{language});

        var grammar_path = repo_path;
        for (src_subdir_overrides) |override| {
            if (std.mem.eql(u8, override.language, language)) {
                grammar_path = b.pathJoin(&.{ repo_path, override.subdir });
                break;
            }
        }

        const src_dir = b.pathJoin(&.{ grammar_path, "src" });
        const parser_c = b.pathJoin(&.{ src_dir, "parser.c" });

        if (b.build_root.handle.access(parser_c, .{})) |_| {
            mod.addCSourceFile(.{
                .file = b.path(parser_c),
                .flags = &.{ "-I", src_dir, "-std=c11", "-O3" },
            });

            const scanner_c = b.pathJoin(&.{ src_dir, "scanner.c" });
            const scanner_cc = b.pathJoin(&.{ src_dir, "scanner.cc" });

            if (hasScanner(b, scanner_c)) {
                mod.addCSourceFile(.{ .file = b.path(scanner_c), .flags = &.{ "-I", src_dir, "-std=c11", "-O3" } });
            }

            if (hasScanner(b, scanner_cc)) {
                mod.addCSourceFile(.{ .file = b.path(scanner_cc), .flags = &.{ "-I", src_dir, "-O3" } });
                mod.link_libcpp = true;
            }
        } else |err| {
            // Every language is referenced by the Zig sources, so skipping one
            // would only turn into a confusing link error later.
            std.debug.panic("tree-sitter grammar '{s}' is missing: {s} not found ({s}). Did you initialise the git submodules?", .{ language, parser_c, @errorName(err) });
        }
    }

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
        .use_lld = use_lld,
        .use_llvm = use_llvm,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .use_lld = use_lld,
        .use_llvm = use_llvm,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

fn unsupportedWasmTarget() noreturn {
    std.debug.panic("On-demand WASM grammars (-Dwasm=true, the default) need a wasmtime build for macOS or Linux on x86_64/aarch64. Pass -Dwasm=false for other targets.", .{});
}

fn hasScanner(b: *std.Build, scanner: []const u8) bool {
    _ = b.build_root.handle.access(scanner, .{}) catch return false;
    return true;
}

/// Compiler flags enabling the instruction set a Blend2D source file needs,
/// going by its `_<isa>` file-name suffix (e.g. `otglyf_avx2.cpp`). Applied per
/// file so the rest of the library stays baseline x86_64 and keeps its runtime
/// dispatch.
///
/// These are cc1 `-target-feature` flags rather than `-mavx2`: Zig already
/// passes `-target-feature -avx2` (etc.) for the target's CPU, and a driver-level
/// `-m` flag loses to it, leaving `__AVX2__` undefined and the file empty.
fn x86IsaFlags(file_name: []const u8) []const []const u8 {
    const stem = file_name[0 .. std.mem.lastIndexOfScalar(u8, file_name, '.') orelse file_name.len];
    const x = "-Xclang";
    const tf = "-target-feature";
    if (std.mem.endsWith(u8, stem, "_avx2")) return &.{
        x, tf, x, "+avx2", x, tf, x, "+avx", x, tf, x, "+sse4.2", x, tf, x, "+sse4.1", x, tf, x, "+ssse3", x, tf, x, "+popcnt",
    };
    if (std.mem.endsWith(u8, stem, "_avx")) return &.{
        x, tf, x, "+avx", x, tf, x, "+sse4.2", x, tf, x, "+sse4.1", x, tf, x, "+ssse3", x, tf, x, "+popcnt",
    };
    if (std.mem.endsWith(u8, stem, "_sse4_2")) return &.{
        x, tf, x, "+sse4.2", x, tf, x, "+sse4.1", x, tf, x, "+ssse3", x, tf, x, "+popcnt", x, tf, x, "+pclmul",
    };
    if (std.mem.endsWith(u8, stem, "_sse4_1")) return &.{
        x, tf, x, "+sse4.1", x, tf, x, "+ssse3",
    };
    if (std.mem.endsWith(u8, stem, "_ssse3")) return &.{
        x, tf, x, "+ssse3",
    };
    return &.{};
}

fn addSourceFilesFromDir(b: *std.Build, mod: *std.Build.Module, dir_path: []const u8, cpp_flags: []const []const u8, per_file_x86_isa: bool) void {
    var dir = b.build_root.handle.openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("'{s}' couldn't be opened ({s}). Did you initialise the git submodules?", .{ dir_path, @errorName(err) });
    };
    defer dir.close();

    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();

    while (walker.next() catch |err| std.debug.panic("couldn't scan '{s}': {s}", .{ dir_path, @errorName(err) })) |entry| {
        const name = entry.basename;
        const path = entry.path;

        // 1. Only .cpp and .c
        const ext = std.fs.path.extension(name);
        if (!std.mem.eql(u8, ext, ".cpp") and !std.mem.eql(u8, ext, ".c")) continue;

        // 2. Ignore tests/demos/samples
        if (std.mem.containsAtLeast(u8, path, 1, "test") or
            std.mem.containsAtLeast(u8, path, 1, "demo") or
            std.mem.containsAtLeast(u8, path, 1, "sample")) continue;

        var flags = cpp_flags;
        if (per_file_x86_isa) {
            const isa_flags = x86IsaFlags(name);
            if (isa_flags.len > 0) {
                const with_isa = b.allocator.alloc([]const u8, cpp_flags.len + isa_flags.len) catch @panic("OOM");
                @memcpy(with_isa[0..cpp_flags.len], cpp_flags);
                @memcpy(with_isa[cpp_flags.len..], isa_flags);
                flags = with_isa;
            }
        }

        const full_path = b.pathJoin(&.{ dir_path, path });
        mod.addCSourceFile(.{ .file = b.path(full_path), .flags = flags });
    }
}
