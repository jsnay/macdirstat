/* =============================================================================
 * FILE: Sources/CDirstatCore/shim.c
 * =============================================================================
 *
 * PURPOSE
 *   Intentionally empty. SwiftPM only builds a target — and only exposes
 *   its include/ directory as a Clang module importable from Swift — if the
 *   target contains at least one source file. This file is that one source
 *   file: it exists so `import CDirstatCore` works and the pinned
 *   include/dirstat_core.h header (generated upstream by cbindgen in the
 *   dirstat-core repo — never edit it here) is visible to the Swift code.
 *
 * UPSTREAM DEPENDENCIES
 *   - none (must stay empty: any code here would shadow or duplicate the
 *     real engine)
 *
 * DOWNSTREAM CONSUMERS
 *   - Sources/MacDirStat/Engine/Engine.swift imports CDirstatCore for every
 *     ds_* declaration. The actual symbols come from libdirstat_core.a,
 *     staged into .lib/ by Scripts/build-engine.sh and linked by the
 *     MacDirStat executable target (see Package.swift linkerSettings).
 * ============================================================================= */
