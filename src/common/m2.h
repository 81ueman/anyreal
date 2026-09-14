// Minimal relay protocol used by the M2 experiments (pre-controller).
// Byte order is host order; both ends run on the same machine/architecture.
#pragma once

#include <cstdint>

namespace anyreal {

enum M2Type : uint32_t {
    M2_REG_LISTENER = 1, // a=self_id, b=path_len; then path bytes
    M2_CONNECT = 2,      // a=self_id, b=peer_id
    M2_NEW_CONN = 3,     // a=cli_id, b=cli_port
    M2_ACCEPTED = 4,     // a=cli_port
    M2_REJECTED = 5,
};

struct M2Hdr {
    uint32_t type;
    uint32_t a;
    uint32_t b;
    uint32_t c;
};

} // namespace anyreal
