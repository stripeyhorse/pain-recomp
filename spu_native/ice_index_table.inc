/* ICE mesh (jobmod_ca71f23d7b11_e11B00), function 0x07D70: the loop at 0x07D9C writes the
 * big-endian halfword i * 16 at dst + 2i for i = 0 .. count-1 (dst = r8.word0, count =
 * r10.word0, a multiple of 8), one read-insert-write of a quadword per entry:
 *
 *   r5 = 2i; r9 = i << 4 (halfwords); r7 = i + 1; r4 = LS[r5 + r8]; r6 = chx(r5, r8)
 *   r2 = ceq(r10, r7); r4 = shufb(r9, r4, r6); LS[r5 + r8] = r4; loop while r2.word0 == 0
 *
 * The native form stores the first count - 8 entries eight at a time (16 bytes at dst + 2i
 * are exactly entries i .. i+7), sets r2, r4, r5, r6, r7 and r9 to what iteration count - 9
 * leaves (each is a function of r7, r8, r10 and the quadword stored, which holds the same
 * bytes), and the lifted loop runs the last eight iterations.
 *
 * Interrupts: the lifted loop tests for one at 0x07D9C each iteration. The native stores
 * skip those tests, so they run only when no event can be taken during them: interrupts
 * off, or none pending with only the tag (bit 0) and list-stall (bit 1) events enabled --
 * the two the SPU's own channel writes raise, and this loop makes none. Another thread can
 * raise reservation-lost (bit 10) at any time, so an enabled mask with any other bit keeps
 * the lifted loop, as does a pending interrupt restore (irq_saved). (Were an event to arrive
 * from elsewhere during the stores anyway -- an asynchronous MFC would do that -- it is taken
 * at the first lifted test after them, with the exact state of that point: the same as the
 * event arriving that much later, which an asynchronous event may.)
 * Guards: 16 <= count <= 4096 (i * 16 fits a halfword), dst even, the table inside local
 * store without wrapping, private local store with diagnostics clear. */
static inline void pain_native_index_table(spu_context* ctx)
{
#if defined(__aarch64__) && defined(__ARM_NEON) && !defined(SPU_SCALAR_HELPERS)
    if (!(pain_spu_native_mask() & PAIN_NATIVE_TABLE)) return;
    const uint32_t count = ctx->gpr[10]._u32[0];
    const uint32_t dst = ctx->gpr[8]._u32[0] & SPU_LS_MASK;
    if (count < 16 || count > 4096 || (count & 7u) || (dst & 1u) || dst + count * 2 > SPU_LS_SIZE ||
        ctx->gpr[7]._u32[0] != 0 || !pain_native_ls_clear(ctx) || ctx->irq_saved ||
        (ctx->int_enable && ((ctx->event_mask & ~3u) ||
                             (__atomic_load_n(&ctx->event_status, __ATOMIC_RELAXED) & ctx->event_mask))))
        return;
    const uint32_t fill = count - 8;
    uint16x8_t values = { 0, 16, 32, 48, 64, 80, 96, 112 };
    for (uint32_t i = 0; i < fill; i += 8) {
        vst1q_u8(ctx->ls_store + dst + i * 2, vrev16q_u8(vreinterpretq_u8_u16(values)));
        values = vaddq_u16(values, vdupq_n_u16(128));
    }
    /* The registers the last stored iteration (i = fill - 1) leaves, from the lifted helpers,
     * so an interrupt taken at the next 0x07D9C test sees exactly the lifted state. */
    const u128 last = spu_il((int32_t)(fill - 1));
    ctx->gpr[7] = spu_il((int32_t)fill);
    ctx->gpr[5] = spu_a(last, last);
    ctx->gpr[9] = spu_shlhi(last, 4);
    ctx->gpr[4] = spu_ls_read128(ctx, ctx->gpr[5]._u32[0] + ctx->gpr[8]._u32[0]);   /* as stored */
    ctx->gpr[6] = spu_chx(ctx->gpr[5], ctx->gpr[8]);
    ctx->gpr[2] = spu_ceq(ctx->gpr[10], ctx->gpr[7]);
    PAIN_NATIVE_COUNT(native_entries, 1);
    PAIN_NATIVE_COUNT(native_units, fill);
#else
    (void)ctx;
#endif
}
