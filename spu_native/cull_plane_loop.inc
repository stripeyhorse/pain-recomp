/* MainSpurs culling (jobmod_fee160dc063c_e0F78), function 0x04630: the plane loop at 0x046C0
 * tests a sphere (centre r12, r13 = centre rotated one word, radius r10, r14 = -radius)
 * against count = r11.word0 planes read from LS[r5], r5 += 16 each:
 *
 *   046C0: r7 += 1; r3 = LS[r5]; r5 += 16; r9 = cgt(r11, r7); r4 = fm(r3, r12)
 *          r3 = fma(rotqbyi(r3, 4), r13, r4); r2 = rotqbyi(r3, 8); r3 = fa(r2, r3)
 *          r2 = fcgt(r14, r3); r4 = fcgt(r8, r3); if r2.word0 -> reject (r2 = 2 ...)
 *   046B0: r8 = selb(r8, r3, r4); if !r9.word0 -> 04664 (finish) else -> 046C0
 *
 * Four lanes in NEON at a time, the same operations in the same order. It requires FPCR
 * round toward zero with flush-to-zero (spu__nv_rz), where the host's single-precision
 * multiply, fused multiply-add and add truncate like the SPU and read a denormal as zero;
 * each result is then canonicalised to the SPU's +0 (spu__nv_flush). Every operand is
 * bounded by 2^62 in magnitude (centre and radius once, each plane as it is read), so no
 * product, fma or sum can reach exponent 255 or lose the SPU's extended range, and the
 * host compares agree with fcgt (zeros equal, a denormal is zero under FZ). r8 starts as
 * 2 * radius and only takes sums, so it is bounded too. A plane outside the bound stores
 * the state reached so far and resumes the lifted loop at 0x046C0. Interrupts are tested
 * at 0x046C0 and 0x046B0 exactly where the lifted loop tests them and leave through the
 * same lifted continuations with the same registers. */
enum pain_cull_exit {
    PAIN_CULL_LIFTED_LOOP,           /* not entered, or a plane out of range: lifted 0x046C0 */
    PAIN_CULL_LIFTED_FINISH,         /* last plane done: lifted 0x04664 */
    PAIN_CULL_LIFTED_REJECT,         /* outside a plane: the lifted reject tail */
    PAIN_CULL_INTERRUPT_BEFORE_PLANE,/* interrupt pending at 0x046C0 */
    PAIN_CULL_INTERRUPT_BEFORE_SELECT/* interrupt pending at 0x046B0 */
};
#if defined(__aarch64__) && defined(__ARM_NEON) && !defined(SPU_SCALAR_HELPERS)
SPU__NV_INLINE int pain_cull_in_range(uint32x4_t words)
{
    return vmaxvq_u32(vandq_u32(words, vdupq_n_u32(0x7FFFFFFFu))) <= 0x5E800000u;   /* |x| <= 2^62 */
}

static inline enum pain_cull_exit pain_native_cull_loop(spu_context* ctx)
{
    if (!(pain_spu_native_mask() & PAIN_NATIVE_CULL) || !pain_native_ls_clear(ctx) || !spu__nv_rz())
        return PAIN_CULL_LIFTED_LOOP;
    const uint32x4_t center = vld1q_u32(ctx->gpr[12]._u32);
    const uint32x4_t negative_radius = vld1q_u32(ctx->gpr[14]._u32);
    const uint32x4_t minimum0 = vld1q_u32(ctx->gpr[8]._u32);
    if (!pain_cull_in_range(center) || !pain_cull_in_range(negative_radius) || !pain_cull_in_range(minimum0))
        return PAIN_CULL_LIFTED_LOOP;
    PAIN_NATIVE_COUNT(native_entries, 1);

    const float32x4_t rotated_center = spu__nv_f(vld1q_u32(ctx->gpr[13]._u32));
    const int32x4_t counts = vld1q_s32(ctx->gpr[11]._s32);
    uint32x4_t addr = vld1q_u32(ctx->gpr[5]._u32);
    uint32x4_t iter = vld1q_u32(ctx->gpr[7]._u32);
    uint32x4_t minimum = minimum0;
    uint32x4_t sum = vld1q_u32(ctx->gpr[3]._u32);
    uint32x4_t reject = vld1q_u32(ctx->gpr[2]._u32);
    uint32x4_t lower = vld1q_u32(ctx->gpr[4]._u32);
    uint32x4_t again = vld1q_u32(ctx->gpr[9]._u32);
    enum pain_cull_exit exit;
    for (;;) {
        if (pain_native_interrupt(ctx, 0x46C0)) { exit = PAIN_CULL_INTERRUPT_BEFORE_PLANE; break; }
        const uint32_t offset = vgetq_lane_u32(addr, 0) & (SPU_LS_MASK & ~15u);
        const uint32x4_t plane = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(ctx->ls_store + offset)));
        if (!pain_cull_in_range(plane)) {
            PAIN_NATIVE_COUNT(guard_exits, 1);
            exit = PAIN_CULL_LIFTED_LOOP;
            break;
        }
        addr = vaddq_u32(addr, vdupq_n_u32(16));
        iter = vaddq_u32(iter, vdupq_n_u32(1));
        again = vcgtq_s32(counts, vreinterpretq_s32_u32(iter));
        const uint32x4_t product = spu__nv_flush(spu__nv_u(vmulq_f32(spu__nv_f(plane), spu__nv_f(center))));
        const float32x4_t rotated_plane = spu__nv_f(vextq_u32(plane, plane, 1));
        const uint32x4_t pairs = spu__nv_flush(spu__nv_u(vfmaq_f32(spu__nv_f(product), rotated_plane, rotated_center)));
        sum = spu__nv_flush(spu__nv_u(vaddq_f32(spu__nv_f(vextq_u32(pairs, pairs, 2)), spu__nv_f(pairs))));
        reject = vcgtq_f32(spu__nv_f(negative_radius), spu__nv_f(sum));
        lower = vcgtq_f32(spu__nv_f(minimum), spu__nv_f(sum));
        PAIN_NATIVE_COUNT(native_units, 1);
        if (vgetq_lane_u32(reject, 0)) { exit = PAIN_CULL_LIFTED_REJECT; break; }
        if (pain_native_interrupt(ctx, 0x46B0)) { exit = PAIN_CULL_INTERRUPT_BEFORE_SELECT; break; }
        minimum = vbslq_u32(lower, sum, minimum);
        if (!vgetq_lane_u32(again, 0)) { exit = PAIN_CULL_LIFTED_FINISH; break; }
    }
    vst1q_u32(ctx->gpr[2]._u32, reject);
    vst1q_u32(ctx->gpr[3]._u32, sum);
    vst1q_u32(ctx->gpr[4]._u32, lower);
    vst1q_u32(ctx->gpr[5]._u32, addr);
    vst1q_u32(ctx->gpr[7]._u32, iter);
    vst1q_u32(ctx->gpr[8]._u32, minimum);
    vst1q_u32(ctx->gpr[9]._u32, again);
    return exit;
}
#endif
