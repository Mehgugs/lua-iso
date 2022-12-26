# lua-iso

A portable lua distribution that is isolated from environment variables.

## Components

- luaiso
  The interpreter.

- lpeg
  The lpeg parsing library. (The re module is also included)

- lfs
  The luafilesystem library.
  
- socket
  The luasocket library for networking.

- socket \[ -Dluasocket \]
  The luasocket networking library.

- ssl \[ -Dluasec \]
  The luasec library.

- lanes \[ -Dlanes \]
  The lanes multithreading library.


Further lua libraries may be installed into the share path (share/lua/5.4).
Further native modules may be installed into th lib path (lib/lua/5.4).

## Isolation

This distribution of lua should be self-contained within the directory structure. This folder
can reside anywhere on your computer. Environment variables are not consulted and consequently
luaiso will not run init scripts, or modify the configured path. On POSIX systems (assuming a procfs)
`/proc/self/exe` is used to determine where to point `package.path` and `package.cpath`, and on windows
executable relative paths are used by lua as a default.

It may be desirable to put the bin directory in your user path, optionally creating a shim for `lua`.

## How to use:

If you intend to build luasec you will need to install [`vcpkg`](https://github.com/microsoft/vcpkg).
This is used to build openssl across multiple platforms.


Example build which includes the optional libraries lanes and luasocket:
```
> zig build -p <where you want it to spit the build out> -Dlanes -Dluasocket
```

Full build of everything:
```
> zig build -p <where you want it to spit the build out> -Dall
```





