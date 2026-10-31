#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

int main() {
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open card0"); return 1; }

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("drmModeGetResources"); return 1; }

    printf("CRTCs: %d, Encoders: %d, Connectors: %d\n", res->count_crtcs, res->count_encoders, res->count_connectors);
    for (int i = 0; i < res->count_crtcs; i++) {
        drmModeCrtc *crtc = drmModeGetCrtc(fd, res->crtcs[i]);
        if (crtc) {
            printf("  CRTC id=%u, fb_id=%u, x=%u, y=%u, w=%u, h=%u, mode_valid=%d\n",
                crtc->crtc_id, crtc->buffer_id, crtc->x, crtc->y, crtc->width, crtc->height, crtc->mode_valid);
            drmModeFreeCrtc(crtc);
        }
    }

    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *conn = drmModeGetConnector(fd, res->connectors[i]);
        if (conn) {
            printf("  Connector id=%u, type=%u, conn=%d, modes=%d, encoder_id=%u\n",
                conn->connector_id, conn->connector_type, conn->connection, conn->count_modes, conn->encoder_id);
            drmModeFreeConnector(conn);
        }
    }

    drmModePlaneRes *pres = drmModeGetPlaneResources(fd);
    if (pres) {
        printf("Planes: %u\n", pres->count_planes);
        for (uint32_t i = 0; i < pres->count_planes; i++) {
            drmModePlane *p = drmModeGetPlane(fd, pres->planes[i]);
            if (p) {
                printf("  Plane id=%u, crtc_id=%u, fb_id=%u, crtc_x=%d, crtc_y=%d, formats=%u, possible_crtcs=0x%x\n",
                    p->plane_id, p->crtc_id, p->fb_id, p->crtc_x, p->crtc_y, p->count_formats, p->possible_crtcs);
                
                // Read properties to find type
                drmModeObjectProperties *props = drmModeObjectGetProperties(fd, p->plane_id, DRM_MODE_OBJECT_PLANE);
                if (props) {
                    for (uint32_t j = 0; j < props->count_props; j++) {
                        drmModePropertyRes *prop = drmModeGetProperty(fd, props->props[j]);
                        if (prop) {
                            if (strcmp(prop->name, "type") == 0) {
                                const char *t = "unknown";
                                if (props->prop_values[j] == 0) t = "OVERLAY";
                                else if (props->prop_values[j] == 1) t = "PRIMARY";
                                else if (props->prop_values[j] == 2) t = "CURSOR";
                                printf("    -> type: %s (%llu)\n", t, (unsigned long long)props->prop_values[j]);
                            }
                            drmModeFreeProperty(prop);
                        }
                    }
                    drmModeFreeObjectProperties(props);
                }
                drmModeFreePlane(p);
            }
        }
        drmModeFreePlaneResources(pres);
    }

    drmModeFreeResources(res);
    close(fd);
    return 0;
}
