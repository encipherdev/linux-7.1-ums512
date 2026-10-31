#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

int main(int argc, char **argv) {
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open card0"); return 1; }

    drmSetMaster(fd);

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("drmModeGetResources"); return 1; }

    uint32_t conn_id = 85;
    uint32_t crtc_id = 80;

    drmModeConnector *conn = drmModeGetConnector(fd, conn_id);
    if (!conn) { perror("drmModeGetConnector"); return 1; }

    drmModeModeInfo mode = conn->modes[0];
    printf("Using mode %ux%u @ %uHz\n", mode.hdisplay, mode.vdisplay, mode.vrefresh);

    struct drm_mode_create_dumb creq;
    memset(&creq, 0, sizeof(creq));
    creq.width = mode.hdisplay;
    creq.height = mode.vdisplay;
    creq.bpp = 32;

    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0) {
        perror("CREATE_DUMB"); return 1;
    }

    uint32_t fb_id = 0;
    if (drmModeAddFB(fd, mode.hdisplay, mode.vdisplay, 24, 32, creq.pitch, creq.handle, &fb_id) < 0) {
        perror("AddFB"); return 1;
    }

    struct drm_mode_map_dumb mreq;
    memset(&mreq, 0, sizeof(mreq));
    mreq.handle = creq.handle;
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) {
        perror("MAP_DUMB"); return 1;
    }

    uint32_t *map = mmap(0, creq.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, mreq.offset);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }

    // Color: argv[1] or default RED (0x00FF0000)
    uint32_t color = 0x00FF0000;
    if (argc > 1 && strcmp(argv[1], "white") == 0) color = 0x00FFFFFF;
    if (argc > 1 && strcmp(argv[1], "green") == 0) color = 0x0000FF00;
    if (argc > 1 && strcmp(argv[1], "blue") == 0)  color = 0x000000FF;

    for (size_t i = 0; i < creq.size / 4; i++) {
        map[i] = color;
    }

    printf("Setting CRTC %u with FB %u (color 0x%08x)...\n", crtc_id, fb_id, color);
    int ret = drmModeSetCrtc(fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &mode);
    if (ret < 0) {
        perror("drmModeSetCrtc");
        return 1;
    }

    printf("CRTC set successful! Holding for 30 seconds...\n");
    sleep(30);

    drmModeFreeConnector(conn);
    drmModeFreeResources(res);
    close(fd);
    return 0;
}
