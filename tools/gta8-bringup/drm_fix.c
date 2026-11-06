#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/eventfd.h>
#include <pthread.h>
#include <errno.h>

struct drmModePlaneRes {
    uint32_t count_planes;
    uint32_t *planes;
};

#define MAX_HANDLES 256
static struct {
    int fd;
    uint32_t handle;
} g_mappings[MAX_HANDLES];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static void add_mapping(int fd, uint32_t handle) {
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < MAX_HANDLES; i++) {
        if (g_mappings[i].fd == 0 || g_mappings[i].fd == fd) {
            g_mappings[i].fd = fd;
            g_mappings[i].handle = handle;
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
}

static uint32_t find_handle_by_fd(int fd) {
    pthread_mutex_lock(&g_lock);
    uint32_t h = 0;
    for (int i = 0; i < MAX_HANDLES; i++) {
        if (g_mappings[i].fd == fd) {
            h = g_mappings[i].handle;
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return h;
}

static bool is_mocked_handle(uint32_t handle) {
    pthread_mutex_lock(&g_lock);
    bool found = false;
    for (int i = 0; i < MAX_HANDLES; i++) {
        if (g_mappings[i].handle == handle) {
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return found;
}

/* Real drmIsMaster */
int drmIsMaster(int fd) {
    static int (*real_fn)(int) = NULL;
    if (!real_fn) real_fn = dlsym(RTLD_NEXT, "drmIsMaster");
    if (real_fn) return real_fn(fd);
    return 0;
}

/* Mock drmModeCreateLease to return a dup() with FD_CLOEXEC.
 * This shares file_priv with drm_fd, ensuring dumb buffers are in the same GEM namespace
 * while preventing leaked child processes from holding DRM buffers open! */
int drmModeCreateLease(int fd, const uint32_t *objects, int num_objects, int flags, uint32_t *lessee_id) {
    if (lessee_id) *lessee_id = 1;
    int dup_fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (dup_fd < 0) dup_fd = dup(fd);
    fprintf(stderr, "[drm_fix] drmModeCreateLease: returning cloexec dup fd %d for fd %d\n", dup_fd, fd);
    return dup_fd;
}

/* Mock drmAuthMagic */
int drmAuthMagic(int fd, uint32_t magic) {
    return 0;
}

/* Intercept drmPrimeHandleToFD */
int drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd) {
    static int (*real_fn)(int, uint32_t, uint32_t, int *) = NULL;
    if (!real_fn) real_fn = dlsym(RTLD_NEXT, "drmPrimeHandleToFD");

    if (real_fn) {
        int ret = real_fn(fd, handle, flags, prime_fd);
        if (ret == 0) return 0;
    }

    /* Fallback for dumb buffers without driver PRIME export */
    int pfd = eventfd(0, EFD_CLOEXEC);
    if (pfd < 0) return -1;

    add_mapping(pfd, handle);
    *prime_fd = pfd;
    fprintf(stderr, "[drm_fix] drmPrimeHandleToFD: handle=%u -> fd=%d\n", handle, pfd);
    return 0;
}

/* Intercept drmPrimeFDToHandle */
int drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle) {
    uint32_t h = find_handle_by_fd(prime_fd);
    if (h != 0) {
        *handle = h;
        fprintf(stderr, "[drm_fix] drmPrimeFDToHandle: fd=%d -> handle=%u\n", prime_fd, h);
        return 0;
    }

    static int (*real_fn)(int, int, uint32_t *) = NULL;
    if (!real_fn) real_fn = dlsym(RTLD_NEXT, "drmPrimeFDToHandle");
    if (real_fn) return real_fn(fd, prime_fd, handle);

    return -1;
}

/* Prevent premature GEM close of dumb buffer handles */
int drmCloseBufferHandle(int fd, uint32_t handle) {
    if (is_mocked_handle(handle)) {
        fprintf(stderr, "[drm_fix] drmCloseBufferHandle ignored for mocked handle %u\n", handle);
        return 0;
    }

    static int (*real_fn)(int, uint32_t) = NULL;
    if (!real_fn) real_fn = dlsym(RTLD_NEXT, "drmCloseBufferHandle");
    if (real_fn) return real_fn(fd, handle);

    return 0;
}

/* Plane 28 is primary on Unisoc ums512 */
struct drmModePlaneRes *drmModeGetPlaneResources(int fd) {
    static struct drmModePlaneRes *(*real_fn)(int) = NULL;
    if (!real_fn) real_fn = dlsym(RTLD_NEXT, "drmModeGetPlaneResources");
    struct drmModePlaneRes *res = real_fn(fd);
    if (res && res->count_planes > 0) {
        uint32_t primary = res->planes[0];
        for (uint32_t i = 0; i < res->count_planes; i++) {
            if (res->planes[i] == 28) {
                primary = 28;
                break;
            }
        }
        res->planes[0] = primary;
        res->count_planes = 1;
        fprintf(stderr, "[drm_fix] drmModeGetPlaneResources: selecting plane %u\n", primary);
    }
    return res;
}
