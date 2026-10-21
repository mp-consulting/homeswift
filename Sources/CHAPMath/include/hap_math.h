#ifndef HAP_MATH_H
#define HAP_MATH_H

#include <stddef.h>
#include <stdint.h>

/// out = a * b * R^-1 mod m (Montgomery, CIOS). All numbers have `n` little-endian 64-bit limbs.
/// `inv` is -m^-1 mod 2^64 and `t` is scratch space of n + 2 limbs. `out` must not alias `a` or `b`.
void hap_montgomery_multiply(uint64_t *out, const uint64_t *a, const uint64_t *b, const uint64_t *m,
                             size_t n, uint64_t inv, uint64_t *t);

#endif
