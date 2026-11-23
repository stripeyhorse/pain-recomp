/* ICE mesh (jobmod_ca71f23d7b11_e11B00), function 0x04E4C: a loop that stores the word
 * r6.word0 at r81 + r7 for r7 = r7 .. r4 - 4 in steps of 4, one read-insert-write of a
 * quadword per word:
 *
 *   r2 = LS[r7 + r81]; r3 = cwx(r7, r81); r2 = shufb(r6, r2, r3); LS[r7 + r81] = r2
 *   r7 = ai(r7, 4); r2 = ceq(r7, r4); loop while r2.word0 == 0
 *
 * Entered from 0x04DF0 with r6 = 0, r7 = 0 and r4 = 1280: a 1,280-byte clear of local store,
 * 14% of each mesh lane at 60 FPS on the M4 Pro. cwx inserts at (r7 + r81) & 12 of the
 * quadword at (r7 + r81) & ~15, so iteration k writes the aligned word at (r81 + r7 + 4k) & ~3,
 * big-endian, and leaves the rest of that quadword as it was.
 *
 * The native form stores the words of every iteration but the last with plain stores, sets
 * r7, r3 and r2 to what the last of those iterations leaves (r2 is the ceq of every word of
 * r7 against r4, as the lifted loop computes it), and the lifted loop runs the final
 * iteration, so it also produces the exit state. This function's copy of the loop tests for
 * no interrupt inside it (the copy inside 0x04B60 does, and is not patched), so skipping
 * iterations skips no interrupt test.
 * Guards: r4 - r7 a multiple of 4 and at least 8 (so the loop ends where the lifted one
 * does, without wrapping the 32-bit counter), the words inside local store without
 * wrapping, private local store with diagnostics clear. */
static inline void pain_native_word_clear(spu_context* ctx)
{
    if (!(pain_spu_native_mask() & PAIN_NATIVE_CLEAR)) return;
    const uint32_t r7 = ctx->gpr[7]._u32[0], r4 = ctx->gpr[4]._u32[0];
    const uint32_t span = r4 - r7;
    if ((span & 3u) || span < 8 || span > SPU_LS_SIZE || !pain_native_ls_clear(ctx)) return;
    const uint32_t start = (ctx->gpr[81]._u32[0] + r7) & SPU_LS_MASK & ~3u;
    const uint32_t words = span / 4 - 1;               /* the last one is left to the lifted loop */
    if (start + words * 4u + 4u > SPU_LS_SIZE) return;  /* would wrap: lifted */
    const uint32_t be = SPU_BSWAP32(ctx->gpr[6]._u32[0]);
    uint8_t* p = ctx->ls_store + start;
    if (be == 0) memset(p, 0, (size_t)words * 4u);
    else for (uint32_t k = 0; k < words; k++) memcpy(p + 4u * k, &be, 4);
    /* The state after iteration `words` - 1, from the lifted helpers. */
    u128 last = ctx->gpr[7];
    for (int k = 0; k < 4; k++) last._u32[k] += 4u * (words - 1u);
    ctx->gpr[3] = spu_cwx(last, ctx->gpr[81]);
    ctx->gpr[7] = spu_ai(last, 4);
    ctx->gpr[2] = spu_ceq(ctx->gpr[7], ctx->gpr[4]);
    PAIN_NATIVE_COUNT(native_entries, 1);
    PAIN_NATIVE_COUNT(native_units, words);
}
