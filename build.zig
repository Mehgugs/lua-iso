const std = @import("std");

// Type helpers
const String     = []const u8;
const SourceList = std.ArrayList(String);
const FlagList   = std.ArrayList(String);
fn SliceOf(comptime t: type) type {
    return []const t;
}

//builder
const Builder = std.build.Builder;
const InstallDir = std.build.InstallDir;
const Artifact = *std.build.LibExeObjStep;


fn walk_dir(b: *Builder, sources: *SourceList, folder: String, exclude: SliceOf(String)) !void {
    var dir = try std.fs.cwd().openIterableDir(folder, .{ });

    var walker = dir.iterate();

    while (try walker.next()) |entry| {
        //std.log.info("Found: {s}", .{entry.name});
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
    std.log.info("Starting.", .{});

    var liblua_sources  = SourceList.init(b.allocator);
    var lua_sources     = [_]String{"override/lua/lua.c"};
    var luac_sources    = [_]String{"luac/luac.c"};
    var lpeg_sources    = SourceList.init(b.allocator);
    var lfs_sources     = [_]String{"luafilesystem/src/lfs.c"};

    var flags        = FlagList.init(b.allocator);
    var lib_flags    = FlagList.init(b.allocator);

    // File Exclusions
    const exclude_lua = [_]String{
        "lua.c",
        "luac.c",
        "onelua.c"
    };
    const no_exclusions = [_]String{};

    //Artifacts
    const lua = b.addExecutable("luaiso", null);
    const luac= b.addExecutable("luaisoc", null);
    const liblua = b.addSharedLibrary("lua5.4.4", null, .unversioned);
    const lpeg = b.addSharedLibrary("lpeg", null, .unversioned);
    const lfs = b.addSharedLibrary("lfs", null, .unversioned);

    //Target & build mode
    const target = b.standardTargetOptions(.{.default_target = std.zig.CrossTarget.fromTarget(b.host.target)});
    const mode = std.builtin.Mode.ReleaseSmall; // NB. Hardcoded to ReleaseSmall to prevent errors on windows; investigate.

    //Configuration of artifacts:

    inline for ([_]Artifact{lua, luac, liblua, lpeg, lfs}) |art| {
        art.setBuildMode(mode);
        art.setTarget(target);
        art.strip = true;
        // NB. Fixed errors when compiling LFS / LPeg; investigate.

        if (art != liblua) {
            art.addIncludePath("lua");
            art.bundle_compiler_rt = false;
        }
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
        luac.addRPath("$ORIGIN");
    }

    //Initialization of source files

    const c_flags = flags.toOwnedSlice();
    const lib_c_flags = lib_flags.toOwnedSlice();


    lua.addCSourceFiles(&lua_sources, c_flags);
    luac.addCSourceFiles(&luac_sources, c_flags);
    liblua.addCSourceFiles(liblua_sources.toOwnedSlice(), c_flags);
    lpeg.addCSourceFiles(lpeg_sources.toOwnedSlice(), lib_c_flags);
    lfs.addCSourceFiles(&lfs_sources, lib_c_flags);


    liblua.linkLibC();
    liblua.install();


    inline for ([_]Artifact{lua, luac, lpeg, lfs}) |art| {
        art.linkLibrary(liblua);

        if (art == lpeg or art == lfs) {
            art.override_dest_dir = .{.custom = "lib/lua/5.4"};
        }

        art.install();
    }

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