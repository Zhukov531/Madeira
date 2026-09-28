/* CI stand-in for the madeira-d3d12 shader-converter service.
 *
 * The real implementation (research/madeira-d3d12/src/unix/madeira_ir_unix.mm
 * and tests/native/msc_canary.mm) needs Apple's Metal Shader Converter
 * installer package, which upstream deliberately does not ship. Without it
 * build/dxmt-ios/build.sh skips those objects, yet winemetal_unix.c (unix call
 * slot 127) and ContentView.swift still reference their entry points, so the
 * app would not link. This file supplies them and reports the converter as
 * unavailable: D3D12 pipelines fail cleanly, D3D11 (DXMT) is unaffected. */
#include <stdint.h>
#include <string.h>
#include "madeira_ir_abi.h"

int madeira_ir_convert(void *args)
{
    struct madeira_ir_convert_args *a = args;
    static const char note[] = "Metal Shader Converter not bundled in this build";
    a->ret_len = 0;
    a->ret_status = MADEIRA_IR_NO_DYLIB;
    a->ret_error_code = 0;
    memcpy(a->ret_note, note, sizeof(note));
    return 0; /* the call itself succeeded; ret_status carries the outcome */
}

int madeira_d3d12_canary_run_log(const char *fixture_dir, const char *dylib_path,
                                 void (*sink)(const char *), const char *log_path,
                                 const char *build_id)
{
    (void)fixture_dir; (void)dylib_path; (void)log_path; (void)build_id;
    if (sink) sink("madeira-d3d12: canary not built (Metal Shader Converter package not supplied)");
    return 1; /* one failed check: the gate could not run */
}

int madeira_d3d12_canary_run(const char *fixture_dir, const char *dylib_path,
                             void (*sink)(const char *))
{
    return madeira_d3d12_canary_run_log(fixture_dir, dylib_path, sink, 0, 0);
}
