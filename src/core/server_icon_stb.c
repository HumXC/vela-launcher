/* Private PNG decoder. Compile with the pinned vendor/stb include directory.
 * All stb symbols are static: UI stb settings and allocator state are unrelated.
 * The call-scoped allocator owns all memory; individual frees are unnecessary.
 */
#include <stddef.h>
#include <string.h>
typedef void *(*vela_icon_alloc_fn)(void *, size_t);
struct vela_icon_allocator { void *context; vela_icon_alloc_fn alloc; };
static _Thread_local struct vela_icon_allocator *vela_icon_current;
static void *vela_icon_alloc(size_t n) {
    return vela_icon_current->alloc(vela_icon_current->context, n);
}
static void *vela_icon_realloc(void *p, size_t old_n, size_t new_n) {
    void *q = vela_icon_alloc(new_n);
    if (q && p) memcpy(q, p, old_n < new_n ? old_n : new_n);
    return q;
}
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_NO_FAILURE_STRINGS
#define STBI_MAX_DIMENSIONS 64
#define STBI_MALLOC(n) vela_icon_alloc(n)
#define STBI_REALLOC_SIZED(p,o,n) vela_icon_realloc(p,o,n)
#define STBI_FREE(p) ((void)(p))
#include "stb_image.h"

/* Returns 1 on complete decode, 0 on malformed data or allocation failure.
 * Caller distinguishes its allocator failure. No native pointer escapes.
 */
int vela_server_icon_decode(const unsigned char *png, int png_len,
                           const unsigned char *idat, int idat_len,
                           unsigned char *rgba, void *context,
                           vela_icon_alloc_fn alloc) {
    struct vela_icon_allocator state = {context, alloc};
    struct vela_icon_allocator *previous = vela_icon_current;
    vela_icon_current = &state;
    int ok = 0;
    /* 64x64 RGBA16 plus Adam7 filter bytes fits in this bound. stb otherwise
     * accepts a bad Adler checksum; validate it independently before decoding. */
    char raw[33000];
    if (idat_len < 6) goto done;
    int raw_len = stbi_zlib_decode_buffer(raw, sizeof(raw), (const char *)idat, idat_len);
    if (raw_len < 0 || png_len < 33) goto done;
    int channels_in;
    switch (png[25]) {
        case 0: case 3: channels_in = 1; break;
        case 2: channels_in = 3; break;
        case 4: channels_in = 2; break;
        case 6: channels_in = 4; break;
        default: goto done;
    }
    if (png[24] != 1 && png[24] != 2 && png[24] != 4 && png[24] != 8 && png[24] != 16) goto done;
    if (png[28] > 1) goto done;
    int expected_raw = 0;
    if (png[28] == 0) {
        expected_raw = 64 * (1 + (64 * channels_in * png[24] + 7) / 8);
    } else {
        static const int x0[7] = {0,4,0,2,0,1,0}, y0[7] = {0,0,4,0,2,0,1};
        static const int dx[7] = {8,8,4,4,2,2,1}, dy[7] = {8,8,8,4,4,2,2};
        for (int pass = 0; pass < 7; ++pass) {
            int w = (64 - x0[pass] + dx[pass] - 1) / dx[pass];
            int h = (64 - y0[pass] + dy[pass] - 1) / dy[pass];
            expected_raw += h * (1 + (w * channels_in * png[24] + 7) / 8);
        }
    }
    if (raw_len != expected_raw) goto done;
    unsigned int s1 = 1, s2 = 0;
    for (int i = 0; i < raw_len; ++i) {
        s1 = (s1 + (unsigned char)raw[i]) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    const unsigned char *tail = idat + idat_len - 4;
    unsigned int expected = ((unsigned int)tail[0] << 24) | ((unsigned int)tail[1] << 16) |
                            ((unsigned int)tail[2] << 8) | tail[3];
    if (((s2 << 16) | s1) != expected) goto done;
    int w = 0, h = 0, channels = 0;
    unsigned char *pixels = stbi_load_from_memory(png, png_len, &w, &h, &channels, 4);
    if (pixels && w == 64 && h == 64) {
        memcpy(rgba, pixels, 64 * 64 * 4);
        ok = 1;
    }
done:
    vela_icon_current = previous;
    return ok;
}
