const std = @import("std");

// Type helpers
const String     = []const u8;
const StringPair = [2]String;
const SourceList = std.ArrayList(String);
const FlagList   = std.ArrayList(String);
fn SliceOf(comptime t: type) type {
    return []const t;
}

//builder
const Builder = std.build.Builder;
const Step    = std.build.Step;
const InstallDir = std.build.InstallDir;
const Artifact = *std.build.LibExeObjStep;


fn walk_dir(b: *Builder, sources: *SourceList, folder: String, exclude: SliceOf(String)) !void {
    var dir = try std.fs.cwd().openIterableDir(folder, .{ });

    var walker = dir.iterate();

    while (try walker.next()) |entry| {
        if (entry.kind == .File) {
            var trapped = false;
            for (exclude) |ex| {
                if (std.mem.eql(u8, entry.name, ex)) {
                    trapped = true;
                    break;
                }
            }
            if(trapped) continue;
            const ext = std.fs.path.extension(entry.name);
            if (std.mem.eql(u8, ext, ".c")) {
                const joiner = [_]String{folder, entry.name};
                const src = b.pathJoin(&joiner);
                try sources.append(src);
            }
        }
    }
}

pub fn build(b: *Builder) !void {
    var liblua_sources  = SourceList.init(b.allocator);
    var lua_sources     = [_]String{"override/lua/lua.c"};
    var lpeg_sources    = SourceList.init(b.allocator);
    var lfs_sources     = [_]String{"luafilesystem/src/lfs.c"};

    var flags        = FlagList.init(b.allocator);
    var lib_flags    = FlagList.init(b.allocator);

    // File Exclusions
    const exclude_lua = [_]String{
        "lua.c",
        "luac.c",
        "onelua.c",
        "ltests.c"
    };
    const no_exclusions = [_]String{};

    //Artifacts
    const lua = b.addExecutable("luaiso", null);
    const liblua = b.addSharedLibrary("lua5.4.4", null, .unversioned);
    const lpeg = b.addSharedLibrary("lpeg", null, .unversioned);
    const lfs = b.addSharedLibrary("lfs", null, .unversioned);

    //Optional Extras
    const allextras = b.option(bool, "all", "Set this flag to build all the extras.") orelse false;
    const doluasec = b.option(bool, "luasec", "Set this flag to build luasec (also causes luasocket to be built).") orelse allextras;
    const doluasoc = (b.option(bool, "luasocket", "Set this flag to build luasocket.") orelse allextras) or doluasec;
    const dolanes  = b.option(bool, "lanes", "Set ths flag to build lanes,") orelse allextras;

    if (doluasoc) std.log.info("Building optional dependency luasocket.", .{});
    if (doluasec) std.log.info("Building optional dependency luasec.", .{});
    if (dolanes) std.log.info("Building optional dependency lanes.", .{});


    //Target & build mode
    const target = b.standardTargetOptions(.{.default_target = std.zig.CrossTarget.fromTarget(b.host.target)});
    const mode = std.builtin.Mode.ReleaseSmall; // NB. Hardcoded to ReleaseSmall to prevent errors on windows; investigate.

    //Configuration of artifacts:

    inline for ([_]Artifact{lua, liblua, lpeg, lfs}) |art| {
        art.setBuildMode(mode);
        art.setTarget(target);
        art.addIncludePath("lua");
        art.strip = true;
    }

    //Disovering C Sources:
    try walk_dir(b, &liblua_sources, "lua", &exclude_lua);
    try walk_dir(b, &lpeg_sources, "LPeg", &no_exclusions);

    //CFlags

    try flags.append("-O2");
    try lib_flags.append("-O2");

    //NB. Ideally we set std=c89 as the lowest common denominator; but lfs doesn't like that
    //  and the build seems to "work" if you leave the version unspecified.
    //  Future improvements would be to provide individual artifacts with additional flags for c version etc.

    if(target.os_tag == std.Target.Os.Tag.windows) {
        try flags.append("-DLUA_USE_WINDOWS");
        //NB. Windows doesn't need position independant code for DLLs
    }
    else if ((target.os_tag == std.Target.Os.Tag.linux) or (target.os_tag == std.Target.Os.Tag.macos)) {
        //NB. I've lumped "macos" in with linux because they're both broadly "POSIX compliant"
        //  but this is not verified.
        try flags.append("-DLUA_USE_POSIX");
        try flags.append("-DLUA_USE_DLOPEN");
        try lib_flags.append("-fPIC");
        lua.addRPath("$ORIGIN");
    }

    //Initialization of source files

    const c_flags = flags.toOwnedSlice();
    const lib_c_flags = lib_flags.toOwnedSlice();

    lua.addCSourceFiles(&lua_sources, c_flags);
    liblua.addCSourceFiles(liblua_sources.toOwnedSlice(), c_flags);
    lpeg.addCSourceFiles(lpeg_sources.toOwnedSlice(), lib_c_flags);
    lfs.addCSourceFiles(&lfs_sources, lib_c_flags);

    liblua.linkLibC();
    liblua.install();

    const postbuild = b.step("post-build", "");
    inline for ([_]Artifact{lua, lpeg, lfs}) |art| {
        art.linkLibrary(liblua);

        if (art == lpeg or art == lfs) {
            art.override_dest_dir = .{.custom = "lib/lua/5.4"};
        }


        if (art == lpeg or art == lfs) {
            if ((target.os_tag == std.Target.Os.Tag.linux) or (target.os_tag == std.Target.Os.Tag.macos)) {
                const pathb = [_]String{"lib/lua/5.4", art.out_filename[3..]};
                const redirect = b.addInstallFile(art.getOutputSource(), b.pathJoin(&pathb));
                redirect.step.dependOn(&art.step);
                postbuild.dependOn(&redirect.step);
            } else {
                art.install();
            }
        } else {
            art.install();
        }
    }

    b.getInstallStep().dependOn(postbuild);

    if (doluasoc) try buildLuasocket(b, mode, target, lib_c_flags, liblua);
    if (doluasec) try buildLuasec(b, mode, target, lib_c_flags, liblua);
    if (dolanes) try buildLanes(b, mode, target, lib_c_flags, liblua);



    //Lua development tools
    {
        const headers = [_][]const u8{
            "lua.h",
            "luaconf.h",
            "lualib.h",
            "lauxlib.h"
        };

        inline for (headers) |file| {
            b.installFile("lua/" ++ file, "include/" ++ file);
        }

        //Duplication of liblua in /lib and /bin
        //NB. may be unnecessary with this installation.
        const verbose_1 = [_][]const u8{
            b.install_path,
            "lib",
            liblua.out_filename
        };

        const verbose_2 = [_][]const u8{
            "bin", liblua.out_filename
        };

        b.installFile(b.pathJoin(&verbose_1), b.pathJoin(&verbose_2));
    }

    //Lpeg.re
    b.installFile("LPeg/re.lua", "share/lua/5.4/re.lua");

}

fn configureLuasocketArtifact(b: *Builder, step: *Step, name: String, parent: String, lib: Artifact, mode: std.builtin.Mode, target: std.zig.CrossTarget) !Artifact {
    const art =  b.addSharedLibrary(name, null, .unversioned);
    art.setBuildMode(mode);
    art.setTarget(target);
    art.strip = true;
    art.addIncludePath("lua");
    art.addIncludePath("luasocket/src");
    art.linkLibrary(lib);
    var pathb : String = undefined;

    if ((target.os_tag == std.Target.Os.Tag.linux) or (target.os_tag == std.Target.Os.Tag.macos)) {
        pathb = art.out_filename[3..];
    } else {
        pathb = art.out_filename;
    }

    const redirect = b.addInstallFile(art.getOutputSource(), b.pathJoin(&.{"lib/lua/5.4/", parent, pathb}));

    redirect.step.dependOn(&art.step);

    step.dependOn(&redirect.step);

    return art;
}

fn buildLuasocket (b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget, lib_flags: SliceOf(String), liblua: Artifact) !void {
    const luasocket = b.step("luasocket", "Step for building luasocket and associated dependencies.");
    var socketflags = FlagList.init(b.allocator);

    //Luasocket's socket.core module
    const socket_core = try configureLuasocketArtifact(b, luasocket, "core", "socket", liblua, mode, target);
    var socket_core_sources = SourceList.init(b.allocator);

    const mime_core = try configureLuasocketArtifact(b, luasocket, "core", "mime", liblua, mode, target);
    const mime_core_sources = [_]String{"luasocket/src/mime.c", "luasocket/src/compat.c"};

    const socket_core_common = [_]String{
          "luasocket/src/luasocket.c"
        , "luasocket/src/timeout.c"
        , "luasocket/src/buffer.c"
        , "luasocket/src/io.c"
        , "luasocket/src/auxiliar.c"
        , "luasocket/src/options.c"
        , "luasocket/src/inet.c"
        , "luasocket/src/except.c"
        , "luasocket/src/select.c"
        , "luasocket/src/tcp.c"
        , "luasocket/src/udp.c"
        , "luasocket/src/compat.c"
    };

    try socket_core_sources.appendSlice(&socket_core_common);

    try socketflags.appendSlice(lib_flags);
    try socketflags.append("-DLUASOCKET_DEBUG");
    var socket_cflags: SliceOf(String) = &socket_core_common;

    if(target.os_tag == std.Target.Os.Tag.windows) {
        try socketflags.append("-DWINVER=0x0501");
        socket_cflags = socketflags.toOwnedSlice();
        socket_core.linkSystemLibrary("ws2_32");
        try socket_core_sources.append("luasocket/src/wsocket.c");
        try socket_core_sources.append("override/luasocket/gai_strerrorA.c");
        try socket_core_sources.append("override/luasocket/gai_strerrorW.c");
    }
    else if (target.os_tag == std.Target.Os.Tag.macos) {
        try socketflags.append("-DUNIX_HAS_SUN_LEN");
    }

    if ((target.os_tag == std.Target.Os.Tag.macos) or (target.os_tag == std.Target.Os.Tag.linux)) {
        socket_cflags = socketflags.toOwnedSlice();
        try socket_core_sources.append("luasocket/src/usocket.c");

        const unix = try configureLuasocketArtifact(b, luasocket, "unix", "socket", liblua, mode, target);
        const unix_sources = [_]String{
            "luasocket/src/buffer.c"
            , "luasocket/src/compat.c"
            , "luasocket/src/auxiliar.c"
            , "luasocket/src/options.c"
            , "luasocket/src/timeout.c"
            , "luasocket/src/io.c"
            , "luasocket/src/usocket.c"
            , "luasocket/src/unix.c"
            , "luasocket/src/unixdgram.c"
            , "luasocket/src/unixstream.c"
        };

        unix.addCSourceFiles(&unix_sources, socket_cflags);

        const serial = try configureLuasocketArtifact(b, luasocket, "serial", "socket", liblua, mode, target);
        const serial_sources = [_]String{
            "luasocket/src/buffer.c"
            , "luasocket/src/compat.c"
            , "luasocket/src/auxiliar.c"
            , "luasocket/src/options.c"
            , "luasocket/src/timeout.c"
            , "luasocket/src/io.c"
            , "luasocket/src/usocket.c"
            , "luasocket/src/serial.c"
        };
        serial.addCSourceFiles(&serial_sources, socket_cflags);
    }

    socket_core.addCSourceFiles(socket_core_sources.toOwnedSlice(), socket_cflags);
    mime_core.addCSourceFiles(&mime_core_sources, socket_cflags);

    const luafiles = [_]StringPair{
        .{"socket/http.lua", "luasocket/src/http.lua"},
        .{"socket/tp.lua", "luasocket/src/tp.lua"},
        .{"socket/ftp.lua", "luasocket/src/ftp.lua"},
        .{"socket/headers.lua", "luasocket/src/headers.lua"},
        .{"socket/smtp.lua", "luasocket/src/smtp.lua"},
        .{"socket/url.lua", "luasocket/src/url.lua"},
        .{"ltn12.lua", "luasocket/src/ltn12.lua"},
        .{"socket.lua", "luasocket/src/socket.lua"},
        .{"mime.lua", "luasocket/src/mime.lua"}
    };

    inline for (luafiles) |pair| {
        const folder =  pair[0];
        const file =  pair[1];
        const pathb = [_]String{"share/lua/5.4/", folder};
        const step = b.addInstallFile(.{.path = file}, b.pathJoin(&pathb));
        luasocket.dependOn(&step.step);
    }

    b.getInstallStep().dependOn(luasocket);

    //return luasocket;
}

fn buildLuasec (b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget, lib_flags: SliceOf(String), liblua: Artifact) !void {
    const luasec = b.step("luasec", "Step for building luasec.");
    var secflags = FlagList.init(b.allocator);
    var sources = SourceList.init(b.allocator);
    const art = b.addSharedLibrary("ssl", null, .unversioned);

    art.setBuildMode(mode);
    art.setTarget(target);
    art.strip = true;
    art.addIncludePath("lua");
    art.addIncludePath("luasec/src");
    art.addIncludePath("luasec/src/luasocket");
    art.bundle_compiler_rt = false;

    var triplet = try target.vcpkgTriplet(b.allocator, .Dynamic);

    if ((target.os_tag == std.Target.Os.Tag.macos) or (target.os_tag == std.Target.Os.Tag.linux)) {
        triplet = try std.fmt.allocPrint(b.allocator, "{s}-dynamic", .{triplet});
        art.addRPath("$ORIGIN");
    }

    const run_vcpkg = b.addSystemCommand(&.{"vcpkg", "install", "--triplet", triplet});

    luasec.dependOn(&run_vcpkg.step);

    art.addIncludePath(b.pathJoin(&.{"vcpkg_installed", triplet, "include"}));
    art.addLibraryPath(b.pathJoin(&.{"vcpkg_installed", triplet, "lib"}));

    try sources.appendSlice(&.{
        "luasec/src/options.c", "luasec/src/config.c", "luasec/src/ec.c",
        "luasec/src/x509.c", "luasec/src/context.c", "luasec/src/ssl.c",
        "luasec/src/luasocket/buffer.c", "luasec/src/luasocket/io.c",
        "luasec/src/luasocket/timeout.c"
    });

    try secflags.appendSlice(lib_flags);

    if(target.os_tag == std.Target.Os.Tag.windows) {
        art.addLibraryPath(b.pathJoin(&.{"vcpkg_installed", triplet, "bin"}));
        art.linkSystemLibrary("ws2_32");
        try sources.append("luasec/src/luasocket/wsocket.c");
        try sources.append("override/luasocket/gai_strerrorA.c");
        try sources.append("override/luasocket/gai_strerrorW.c");
        try secflags.appendSlice(&.{
            "-DWIN32", "-DNDEBUG", "-D_WINDOWS", "-D_USRDLL", "-DLSEC_EXPORTS", "-DBUFFER_DEBUG", "-DLSEC_API=__declspec(dllexport)",
            "-DWITH_LUASOCKET", "-DLUASOCKET_DEBUG",
            "-DLUASEC_INET_NTOP", "-DWINVER=0x0501", "-D_WIN32_WINNT=0x0501", "-DNTDDI_VERSION=0x05010300"
        });
    } else if ((target.os_tag == std.Target.Os.Tag.macos) or (target.os_tag == std.Target.Os.Tag.linux)) {
        try secflags.appendSlice(&.{"-DWITH_LUASOCKET", "-DLUASOCKET_DEBUG"});
        try sources.append("luasec/src/luasocket/usocket.c");
    }

    art.addCSourceFiles(sources.toOwnedSlice(), secflags.toOwnedSlice());
    art.linkLibrary(liblua);
    art.linkSystemLibrary("libssl");
    art.linkSystemLibrary("libcrypto");

    {
        var pathb : [2]String = undefined;
        if ((target.os_tag == std.Target.Os.Tag.linux) or (target.os_tag == std.Target.Os.Tag.macos)) {
            pathb = [_]String{"lib/lua/5.4/", art.out_filename[3..]};
        } else {
            pathb = [_]String{"lib/lua/5.4/", art.out_filename};
        }

        const redirect = b.addInstallFile(art.getOutputSource(), b.pathJoin(&pathb));

        redirect.step.dependOn(&art.step);

        luasec.dependOn(&redirect.step);
    }

    const luafiles = [_]StringPair{
        .{"ssl/https.lua", "luasec/src/https.lua"},
        .{"ssl.lua", "luasec/src/ssl.lua"},
    };

    var vcitems1 : String = undefined;
    var vcdest1 : String = undefined;

    var vcitems2 : String = undefined;
    var vcdest2 : String = undefined;

    if (target.os_tag == std.Target.Os.Tag.windows) {
        vcitems1 = b.pathJoin(&.{"vcpkg_installed", triplet, "bin", "libssl-3-x64.dll"});
        vcdest1 = b.pathJoin(&.{"bin", "libssl-3-x64.dll"});

        vcitems2 = b.pathJoin(&.{"vcpkg_installed", triplet, "bin", "libcrypto-3-x64.dll"});
        vcdest2 = b.pathJoin(&.{"bin", "libcrypto-3-x64.dll"});
    } else {
        vcitems1 = b.pathJoin(&.{"vcpkg_installed", triplet, "lib", "libssl.so.3"});
        vcdest1 = b.pathJoin(&.{"lib/lua/5.4", "libssl.so.3"});

        vcitems2 = b.pathJoin(&.{"vcpkg_installed", triplet, "lib", "libcrypto.so.3"});
        vcdest2 = b.pathJoin(&.{"lib/lua/5.4", "libcrypto.so.3"});
    }

    const ssllib = b.addInstallFile(.{.path = vcitems1}, vcdest1);
    const cryptolib = b.addInstallFile(.{.path = vcitems2}, vcdest2);

    luasec.dependOn(&ssllib.step);
    luasec.dependOn(&cryptolib.step);

    inline for (luafiles) |pair| {
        const folder =  pair[0];
        const file =  pair[1];
        const pathb = [_]String{"share/lua/5.4/", folder};
        const step = b.addInstallFile(.{.path = file}, b.pathJoin(&pathb));
        luasec.dependOn(&step.step);
    }

    b.getInstallStep().dependOn(luasec);

    //return luasec;
}

fn buildLanes(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget, lib_flags: SliceOf(String), liblua: Artifact) !void {
    const lanes = b.step("lanes", "Step for building lanes.");
    const art = b.addSharedLibrary("core", null, .unversioned);

    art.setBuildMode(mode);
    art.setTarget(target);
    art.strip = true;
    art.addIncludePath("lua");
    art.addIncludePath("lanes/src");
    art.bundle_compiler_rt = false;

    art.addCSourceFiles(&.{
        "lanes/src/cancel.c",
        "lanes/src/compat.c",
        "lanes/src/deep.c",
        "lanes/src/keeper.c",
        "lanes/src/lanes.c",
        "lanes/src/linda.c",
        "lanes/src/tools.c",
        "lanes/src/state.c",
        "lanes/src/threading.c",
        "lanes/src/universe.c"
    }, lib_flags);

    art.linkLibrary(liblua);

    if ((target.os_tag == std.Target.Os.Tag.macos) or (target.os_tag == std.Target.Os.Tag.linux)) {
        art.linkSystemLibrary("pthread");
    }

    {
        var pathb : String = undefined;
        if ((target.os_tag == std.Target.Os.Tag.linux) or (target.os_tag == std.Target.Os.Tag.macos)) {
            pathb = art.out_filename[3..];
        } else {
            pathb = art.out_filename;
        }

        const redirect = b.addInstallFile(art.getOutputSource(), b.pathJoin(&.{"lib/lua/5.4/lanes/", pathb}));

        redirect.step.dependOn(&art.step);

        lanes.dependOn(&redirect.step);
    }

    const step = b.addInstallFile(.{.path = "lanes/src/lanes.lua"}, "share/lua/5.4/lanes.lua");
    lanes.dependOn(&step.step);

    b.getInstallStep().dependOn(lanes);

    //return lanes;
}