/* spu_native/ice_word_clear.inc against the lifted loop it shortens (ICE mesh, LS 0x04E4C),
 * whole state: all 128 registers and the 256 KiB local store after the loop, run from the
 * same random state once as lifted and once with the native fill in front of it.
 *
 *   cc -std=gnu11 -O2 -fno-strict-aliasing -fwrapv -I<ps3recomp>/runtime/spu -I<ps3recomp>/include \
 *      -I spu_native spu_native/tests/word_clear_test.c -o /tmp/word_clear_test && /tmp/word_clear_test
 *
 * Inputs: the game's own entry (r6 = 0, r7 = 0, r4 = 1280), random fill words, random and
 * unaligned bases, re-entry part way through (an interrupt continuation enters at 0x04E4C
 * with r7 > 0), spans at and below the native minimum, and spans that would wrap the top of
 * local store (lifted). Only spans that are multiples of 4 are run: any other makes the
 * lifted loop run until its 32-bit counter wraps, as it would on the SPU. */
#define PAIN_SPU_NATIVE_FIXTURE 1
#include "spu_helpers.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int g_spu_ls_watch_n;
SPU_THREAD_LOCAL void (*g_spu_trampoline_fn)(spu_context*);
void spu_ls_watch_slow(uint32_t lsa, int write, const uint8_t* data, uint32_t pc, uint32_t lr)
{
    (void)lsa; (void)write; (void)data; (void)pc; (void)lr;
    abort();
}
unsigned pain_fixture_interrupt_pc, pain_fixture_interrupt_after, pain_fixture_interrupt_checks;
unsigned long pain_fixture_native_units, pain_fixture_native_entries, pain_fixture_guard_exits;
#include "spu_native.h"
#include "ice_word_clear.inc"

/* The loop exactly as lifted (jobmod_ca71f23d7b11_e11B00_spu_func_00004E4C, up to its exit). */
static void lifted_loop(spu_context* ctx)
{
loc_00004E4C:
        ctx->gpr[2] = spu_ls_read128(ctx, ctx->gpr[7]._u32[0] + ctx->gpr[81]._u32[0]);
        ctx->gpr[3] = spu_cwx(ctx->gpr[7], ctx->gpr[81]);
        ctx->gpr[2] = spu_shufb(ctx->gpr[6], ctx->gpr[2], ctx->gpr[3]);
        spu_ls_write128(ctx, ctx->gpr[7]._u32[0] + ctx->gpr[81]._u32[0], ctx->gpr[2]);
        ctx->gpr[7] = spu_ai(ctx->gpr[7], 4);
        ctx->gpr[2] = spu_ceq(ctx->gpr[7], ctx->gpr[4]);
        if (ctx->gpr[2]._u32[0] == 0) goto loc_00004E4C;
}

static spu_context s_a, s_b;
static uint32_t s_rng = 0x4E4Cu * 2654435761u;
static uint32_t rnd(void) { s_rng ^= s_rng << 13; s_rng ^= s_rng >> 17; s_rng ^= s_rng << 5; return s_rng; }

int main(void)
{
    g_spu_ls_rdiag = g_spu_ls_wdiag = 0;
    __atomic_store_n(&pain_spu_native_cached, (int)PAIN_NATIVE_CLEAR, __ATOMIC_RELAXED);
    unsigned long cases = 0, bad = 0, native = 0;
    for (unsigned i = 0; i < 20000; i++) {
        for (int r = 0; r < 128; r++) for (int k = 0; k < 4; k++) s_a.gpr[r]._u32[k] = rnd();
        for (unsigned a = 0; a < SPU_LS_SIZE; a += 4) { const uint32_t w = rnd(); memcpy(&s_a.ls_store[a], &w, 4); }
        s_a.ls = s_a.ls_store;
        uint32_t r7, span, base;
        switch (i % 6) {
        case 0:  r7 = 0; span = 1280; base = (rnd() % 0x3F000u) & ~3u; break;          /* the game's entry */
        case 1:  r7 = 4 * (rnd() % 320); span = 1280 - r7; base = (rnd() % 0x3F000u) & ~3u; break;  /* re-entry */
        case 2:  r7 = rnd(); span = 4 * (rnd() % 1025); base = rnd(); break;           /* anything, unaligned */
        case 3:  r7 = rnd(); span = 4 * (1 + rnd() % 2); base = rnd() & ~3u; break;     /* 4, 8: at the guard */
        case 4:  r7 = 0; span = 1280; base = SPU_LS_SIZE - 1280 + 4 * (rnd() % 64); break;  /* wraps: lifted */
        default: r7 = 0; span = 1280; base = SPU_LS_SIZE - 1280 - (rnd() % 16); break;      /* ends at the top */
        }
        if (!span) span = 4;
        if (i % 3 == 0) for (int k = 0; k < 4; k++) s_a.gpr[6]._u32[k] = 0;                  /* r6 = 0, as entered */
        s_a.gpr[7]._u32[0] = r7;
        if (i % 2) for (int k = 1; k < 4; k++) s_a.gpr[7]._u32[k] = r7;                       /* as fsmbi/il leave it */
        s_a.gpr[4]._u32[0] = r7 + span;
        if (i % 2) for (int k = 1; k < 4; k++) s_a.gpr[4]._u32[k] = r7 + span;
        s_a.gpr[81]._u32[0] = base;
        memcpy(&s_b, &s_a, sizeof s_a);
        s_b.ls = s_b.ls_store;
        const unsigned long before = pain_fixture_native_entries;
        lifted_loop(&s_a);
        pain_native_word_clear(&s_b);
        native += pain_fixture_native_entries != before;
        lifted_loop(&s_b);
        cases++;
        if (memcmp(s_a.gpr, s_b.gpr, sizeof s_a.gpr) || memcmp(s_a.ls_store, s_b.ls_store, SPU_LS_SIZE)) {
            if (bad++ < 8) {
                fprintf(stderr, "FAIL case %u: r7 %08X span %u base %08X\n", i, r7, span, base);
                for (int r = 0; r < 128; r++)
                    if (memcmp(&s_a.gpr[r], &s_b.gpr[r], 16)) fprintf(stderr, "  r%d differs\n", r);
                for (unsigned a = 0; a < SPU_LS_SIZE; a++)
                    if (s_a.ls_store[a] != s_b.ls_store[a]) { fprintf(stderr, "  LS differs at %05X\n", a); break; }
            }
        }
    }
    printf("word clear: %lu cases, %lu took the native fill (%lu words), %lu mismatched\n",
           cases, native, pain_fixture_native_units, bad);
    return bad || !native;
}
