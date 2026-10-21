#ifndef CAD_CORE_H
#define CAD_CORE_H
#include <stddef.h>
#include <stdint.h>
// Each handle has one owner. Serialize all calls on its owning queue.
typedef struct CadEngine CadEngine;
typedef struct CadBatch CadBatch;
typedef struct { double ax,ay,bx,by; float color[4]; uint64_t entity; float line_weight; } CadSegment;
typedef struct { double ax,ay,bx,by,cx,cy; float color[4]; uint64_t entity; } CadTriangle;
CadEngine *cad_create(void);
void cad_destroy(CadEngine *engine);
// UTF-8 JSON request => owned UTF-8 JSON {ok,value|error}; free exactly once.
char *cad_request(CadEngine *engine,const char *request);
void cad_string_free(char *string);
// Binary arrays borrow from batch; copy before freeing batch.
CadBatch *cad_render(const CadEngine *engine,double min_x,double min_y,double max_x,double max_y,double tolerance);
CadBatch *cad_render_plain(const CadEngine *engine,double min_x,double min_y,double max_x,double max_y,double tolerance);
const CadSegment *cad_batch_segments(const CadBatch *batch,size_t *count);
const CadTriangle *cad_batch_triangles(const CadBatch *batch,size_t *count);
char *cad_batch_labels(const CadBatch *batch);
void cad_batch_free(CadBatch *batch);
#endif
