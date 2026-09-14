// REAL wire protocol structs, mirrored from upstream REAL
// (commit 52f440cfb597fe9440ed3e862f98bd5bbf9171c4):
//   controller/const.hpp, preload/preload.h
// Kept layout-compatible so this broker can talk to the unmodified controller.
#pragma once

#include <cstdint>

namespace anyreal {

constexpr const char *MNG_SOCKET_PATH = "/ripc/msg_manager_socket";
constexpr int BGP_PORT = 179;

enum RealMsgType {
    REAL_SYN = 1,
    REAL_SYNACK,
    REAL_PAYLOAD,
    REAL_ACK,
    REAL_ENDOFSTAGE,
    REAL_KEEPBUSY,
    REAL_MAX_MSGTYPE,
};

typedef struct {
    int32_t msg_type;
    int32_t msg_len;
    int64_t seq;
} real_hdr_t;

typedef struct {
    real_hdr_t hdr;
    int32_t cli_id;
    int32_t svr_id;
    uint16_t cli_port;
} real_syn_t;

typedef struct {
    real_hdr_t hdr;
    uint16_t cli_port;
} real_synack_t;

typedef struct {
    real_hdr_t hdr;
    int32_t src_id;
    int32_t dst_id;
} real_pld_t;

constexpr int hdrsiz = sizeof(real_hdr_t);
constexpr int synsiz = sizeof(real_syn_t);
constexpr int synacksiz = sizeof(real_synack_t);
constexpr int pldhdrsiz = sizeof(real_pld_t);

} // namespace anyreal
