# lua-iso

A portable lua distribution that is isolated from environment variables.

## Components

- luaiso
  The interpreter.

- luaisoc
  The bytecode compiler.

- lpeg
  The lpeg parsing library. (The re module is also included)

- lfs
  The luafilesystem library.

Further lua libraries may be installed into the share path (share/lua/5.4).
Further native modules may be installed into th lib path (lib/lua/5.4).

## Isolation

This distribution of lua should be self-contained within the directory structure. This folder
can reside anywhere on your computer. Environment variables are not consulted and consequently
luaiso will not run init scripts, or modify the configured path. On POSIX systems (assuming a procfs)
`/proc/self/exe` is used to determine where to point `package.path` and `package.cpath`, and on windows
executable relative paths are used by lua as a default. On macos this will break right now, so as soon as I know how to do that on macos I'll fix it.

It may be desirable to put the bin directory in your user path, optionally creating some shims for `lua` and `luac`.

