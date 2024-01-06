import std/os

--path:".."

const
  cfgPath = currentSourcePath.parentDir
  topPath = cfgPath.parentDir
  cacheSubdirHead = joinPath(topPath, "nimcache")
  cacheSubdirTail = joinPath(relativePath(projectDir(), topPath), projectName())
  cacheSubdir = joinPath(cacheSubdirHead,
    (if defined(release): "release" else: "debug"), cacheSubdirTail)

switch("nimcache", cacheSubdir)

--define:useMalloc
--hint:"XCannotRaiseY:off"
--panics:on
--tlsEmulation:off # default on|off varies by platform
--warning:"BareExcept:on"

when defined(release):
  --hints:off
  if not defined(coverage):
    --passC:"-flto=auto"
    --passL:"-flto=auto"
    --passL:"-s"
else:
  --debugger:native
  --define:debug
  --linetrace:on
  --stacktrace:on
when defined(coverage):
  if defined(release):
    --debugger:native
  --passC:"--coverage"
  --passL:"--coverage"

# with `--passL:"-s"` macOS Xcode's `ld` will report: "ld: warning: option -s
# is obsolete"; however, the resulting binary will still be smaller; supplying
# `--define:strip` or `switch("define", "strip")` in config.nims does not
# produce an equivalent binary, though manually passing the same
# `--define/-d:strip` as an option to `nim c` on the command-line does produce
# an equivalent binary
