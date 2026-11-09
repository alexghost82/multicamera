#ifndef CAMERA_WALL_VIDEO_BRIDGE_H
#define CAMERA_WALL_VIDEO_BRIDGE_H
#include <CoreVideo/CoreVideo.h>

typedef struct CWDecoder CWDecoder;
CWDecoder *cw_create(void);
int cw_open(CWDecoder *decoder, const char *url, int timeout_ms);
int cw_open_file(CWDecoder *decoder, const char *path, int timeout_ms);
int cw_is_eof(int error);
CVPixelBufferRef cw_next(CWDecoder *decoder, int *error);
void cw_stop(CWDecoder *decoder);
void cw_destroy(CWDecoder *decoder);
void cw_error(int error, char *buffer, int size);
#endif