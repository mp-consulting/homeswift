#include "hap_math.h"

typedef unsigned __int128 u128;

void hap_montgomery_multiply(uint64_t *out, const uint64_t *a, const uint64_t *b, const uint64_t *m,
                             size_t n, uint64_t inv, uint64_t *t) {
    for (size_t i = 0; i < n + 2; i++) t[i] = 0;
    for (size_t i = 0; i < n; i++) {
        uint64_t carry = 0;
        for (size_t j = 0; j < n; j++) {
            u128 sum = (u128)a[j] * b[i] + t[j] + carry;
            t[j] = (uint64_t)sum;
            carry = (uint64_t)(sum >> 64);
        }
        u128 top = (u128)t[n] + carry;
        t[n] = (uint64_t)top;
        t[n + 1] = (uint64_t)(top >> 64);

        uint64_t q = t[0] * inv;
        u128 sum = (u128)q * m[0] + t[0];
        carry = (uint64_t)(sum >> 64);
        for (size_t j = 1; j < n; j++) {
            sum = (u128)q * m[j] + t[j] + carry;
            t[j - 1] = (uint64_t)sum;
            carry = (uint64_t)(sum >> 64);
        }
        top = (u128)t[n] + carry;
        t[n - 1] = (uint64_t)top;
        t[n] = t[n + 1] + (uint64_t)(top >> 64);
    }

    int greater_or_equal = t[n] != 0;
    if (!greater_or_equal) {
        greater_or_equal = 1;
        for (size_t i = n; i-- > 0;) {
            if (t[i] != m[i]) {
                greater_or_equal = t[i] > m[i];
                break;
            }
        }
    }
    if (greater_or_equal) {
        uint64_t borrow = 0;
        for (size_t i = 0; i < n; i++) {
            u128 diff = (u128)t[i] - m[i] - borrow;
            out[i] = (uint64_t)diff;
            borrow = (uint64_t)(diff >> 64) & 1;
        }
    } else {
        for (size_t i = 0; i < n; i++) out[i] = t[i];
    }
}
