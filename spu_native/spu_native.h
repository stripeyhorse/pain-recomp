/* Native replacements for hot loops in PAIN's lifted SPU job modules.
 *
 * scripts/spu_native_patch.py copies a lifted image's spu_recomp.c into the build directory
 * with these loops attached (CMake PAIN_SPU_NATIVE_PATCHES). Each one keeps the lifted loop
 * in place and takes it whenever its guard fails, so the patched TU runs the original code
 * for every case the native form was not verified for:
 *   - the context uses its own local store (ctx->ls == ctx->ls_store) and no local-store
 *     diagnostic is armed (they must see every access);
 *   - for floating point, FPCR is round toward zero with flush-to-zero (spu__nv_rz);
 *   - interrupts are taken at the same pcs as in the lifted loop, through the same lifted
 *     continuation functions, or the native form is not entered.
 *
 * PAIN_SPU_NATIVE (read once): unset or 1 = every loop, 0 = none (the original lifted
 * path, same binary), or a comma list of names: table, cull, clear. The step and pc-sampling
 * diagnostics (SPU_STEPTRACE, SPU_PCSAMPLE, SPU_LOCKSTEP) and SPU_FLOATFIX_STATS turn every
 * loop off, since they count lifted instructions or float fix-ups the native forms skip. */
#ifndef PAIN_SPU_NATIVE_H
#define PAIN_SPU_NATIVE_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    PAIN_NATIVE_TABLE = 1u << 0,   /* ICE mesh: index-table fill at LS 0x07D70 */
    PAIN_NATIVE_CULL  = 1u << 1,   /* MainSpurs culling: plane loop at LS 0x046C0 */
    PAIN_NATIVE_CLEAR = 1u << 2,   /* ICE mesh: word clear at LS 0x04E4C */
};

/* One cache for every patched TU of the program (weak, like the SDK's diagnostic gates). */
SPU_GATE int pain_spu_native_cached = -1;

static SPU_NOINLINE_COLD unsigned pain_spu_native_parse(void)
{
    static const struct { const char* name; unsigned bit; } k_items[] = {
        { "table", PAIN_NATIVE_TABLE }, { "cull", PAIN_NATIVE_CULL }, { "clear", PAIN_NATIVE_CLEAR },
    };
    const unsigned all = PAIN_NATIVE_TABLE | PAIN_NATIVE_CULL | PAIN_NATIVE_CLEAR;
    const char* e = getenv("PAIN_SPU_NATIVE");
    unsigned mask = all;
    if (e && !strcmp(e, "0")) mask = 0;
    else if (e && *e && strcmp(e, "1")) {
        mask = 0;
        for (unsigned i = 0; i < sizeof k_items / sizeof k_items[0]; i++) {
            const size_t n = strlen(k_items[i].name);
            for (const char* p = e; (p = strstr(p, k_items[i].name)) != NULL; p += n)
                if ((p == e || p[-1] == ',') && (p[n] == ',' || !p[n])) { mask |= k_items[i].bit; break; }
        }
    }
    const char* ff = getenv("SPU_FLOATFIX_STATS");
    if (getenv("SPU_STEPTRACE") || getenv("SPU_PCSAMPLE") || getenv("SPU_LOCKSTEP") || (ff && ff[0] == '1'))
        mask = 0;
    fprintf(stderr, "[spu-native] PAIN_SPU_NATIVE=%s: table %s, cull %s, clear %s\n", e ? e : "(default)",
            (mask & PAIN_NATIVE_TABLE) ? "on" : "off", (mask & PAIN_NATIVE_CULL) ? "on" : "off",
            (mask & PAIN_NATIVE_CLEAR) ? "on" : "off");
    __atomic_store_n(&pain_spu_native_cached, (int)mask, __ATOMIC_RELAXED);
    return mask;
}

static inline unsigned pain_spu_native_mask(void)
{
    const int v = __atomic_load_n(&pain_spu_native_cached, __ATOMIC_RELAXED);
    return __builtin_expect(v >= 0, 1) ? (unsigned)v : pain_spu_native_parse();
}

/* The context's local store is private and nothing watches it. A TU built SPU_LS_NO_DIAG
 * does not run the diagnostics in its lifted code either, so only the ownership is checked;
 * otherwise the gates must be settled to zero (-1, unsettled, keeps the lifted loop). */
static inline int pain_native_ls_clear(const spu_context* ctx)
{
#if defined(SPU_LS_NO_DIAG)
    return ctx->ls == ctx->ls_store;
#else
    return ctx->ls == ctx->ls_store && !g_spu_ls_rdiag && !g_spu_ls_wdiag && !g_spu_ls_watch_n;
#endif
}

/* PAIN_SPU_NATIVE_FIXTURE: the fixture counts native work and injects an interrupt at the
 * n-th check of one pc; a game build reads the shared event word as the lifted code does. */
#if defined(PAIN_SPU_NATIVE_FIXTURE)
extern unsigned pain_fixture_interrupt_pc, pain_fixture_interrupt_after, pain_fixture_interrupt_checks;
extern unsigned long pain_fixture_native_units, pain_fixture_native_entries, pain_fixture_guard_exits;
#define PAIN_NATIVE_COUNT(field, n) (pain_fixture_##field += (n))
#else
#define PAIN_NATIVE_COUNT(field, n) ((void)0)
#endif
static inline int pain_native_interrupt(spu_context* ctx, unsigned pc)
{
#if defined(PAIN_SPU_NATIVE_FIXTURE)
    if (pc == pain_fixture_interrupt_pc && ++pain_fixture_interrupt_checks == pain_fixture_interrupt_after)
        ctx->event_status |= ctx->event_mask;
#else
    (void)pc;
#endif
    return ctx->int_enable && (__atomic_load_n(&ctx->event_status, __ATOMIC_RELAXED) & ctx->event_mask);
}

#endif
