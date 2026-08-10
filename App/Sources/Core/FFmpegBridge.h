//  Cabeçalho-ponte: expõe a API C do FFmpeg para o Swift.
//
//  O FFmpeg é C puro, sem módulo Clang. Sem esta ponte o Swift não enxerga
//  nada da biblioteca. Os caminhos resolvem porque HEADER_SEARCH_PATHS aponta
//  recursivamente para dentro do FFmpeg.xcframework (ver project.yml).

#ifndef FFmpegBridge_h
#define FFmpegBridge_h

#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/time.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

// --- Ponte para o que o Swift não enxerga ------------------------------------
//
// Boa parte da API de erro do FFmpeg são macros (AVERROR, AVERROR_EOF,
// AV_NOPTS_VALUE, av_err2str). O Swift não importa macros com expressões, então
// sem estes invólucros não há como comparar o retorno de avcodec_receive_frame
// com EAGAIN — que é o caso normal do laço de decodificação, não um erro.
// `static inline` é importado pelo Swift como função comum.

static inline int labp_averror(int errnum) { return AVERROR(errnum); }
static inline int labp_averror_eof(void)   { return AVERROR_EOF; }
static inline int labp_averror_eagain(void){ return AVERROR(EAGAIN); }
static inline int labp_averror_einval(void){ return AVERROR(EINVAL); }
static inline int labp_averror_enomem(void){ return AVERROR(ENOMEM); }

static inline int64_t labp_nopts_value(void) { return AV_NOPTS_VALUE; }
static inline AVRational labp_time_base_q(void) { return AV_TIME_BASE_Q; }

/// Descrição textual de um código de erro. `av_err2str` é macro com buffer
/// temporário na pilha — inutilizável a partir do Swift.
static inline void labp_strerror(int errnum, char *buf, size_t buflen) {
    av_strerror(errnum, buf, buflen);
}

#endif /* FFmpegBridge_h */
