#include "csearchfs.h"

#include <errno.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/fsgetpath.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/vnode.h>
#include <unistd.h>

// Maximum matches per searchfs() call before we loop.
#define MAX_MATCHES 20

// Maximum retries when the catalog changes mid-search (EBUSY).
#define MAX_EBUSY_RETRIES 5

// Packed structures matching the format searchfs() expects and returns.
// These must match the getattrlist(2) packed format exactly.

// Search parameter: name attribute packed for searchparams1.
struct packed_name_attr {
    u_int32_t               size;
    struct attrreference    ref;
    char                    name[PATH_MAX];
};

// Search parameter: empty attr ref for searchparams2.
struct packed_attr_ref {
    u_int32_t               size;
    struct attrreference    ref;
};

// Result entry: what searchfs() returns per match.
// We request ATTR_CMN_FSID | ATTR_CMN_OBJID.
struct packed_result {
    u_int32_t       size;
    struct fsid     fs_id;
    struct fsobj_id obj_id;
};
typedef struct packed_result packed_result;
typedef struct packed_result *packed_result_p;

bool csearchfs_volume_supports_searchfs(const char *volumePath) {
    // Buffer for volume capabilities query.
    struct vol_attr_buf {
        u_int32_t               size;
        vol_capabilities_attr_t vol_capabilities;
    } __attribute__((aligned(4), packed));

    struct attrlist attrList;
    memset(&attrList, 0, sizeof(attrList));
    attrList.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrList.volattr = ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES;

    struct vol_attr_buf attrBuf;
    memset(&attrBuf, 0, sizeof(attrBuf));

    if (getattrlist(volumePath, &attrList, &attrBuf, sizeof(attrBuf), 0) != 0) {
        return false;
    }

    if (attrBuf.size != sizeof(attrBuf)) {
        return false;
    }

    if ((attrBuf.vol_capabilities.valid[VOL_CAPABILITIES_INTERFACES] & VOL_CAP_INT_SEARCHFS) &&
        (attrBuf.vol_capabilities.capabilities[VOL_CAPABILITIES_INTERFACES] & VOL_CAP_INT_SEARCHFS)) {
        return true;
    }

    return false;
}

int csearchfs_search(
    const char *volumePath,
    const char *namePattern,
    uint32_t maxResults,
    bool matchFiles,
    bool matchDirs,
    csearchfs_callback callback,
    void *context
) {
    if (!volumePath || !namePattern || !callback) {
        errno = EINVAL;
        return -1;
    }

    int                     err = 0;
    int                     ebusy_count = 0;
    unsigned long           matches;
    unsigned int            search_options;
    struct fssearchblock    search_blk;
    struct attrlist         return_list;
    struct searchstate      search_state;
    struct packed_name_attr info1;
    struct packed_attr_ref  info2;
    packed_result           result_buffer[MAX_MATCHES];
    uint32_t                match_cnt = 0;

    size_t nameLen = strlen(namePattern);
    if (nameLen == 0 || nameLen >= PATH_MAX) {
        errno = EINVAL;
        return -1;
    }

catalog_changed:
    // Configure search attributes: search by name.
    search_blk.searchattrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    search_blk.searchattrs.reserved = 0;
    search_blk.searchattrs.commonattr = ATTR_CMN_NAME;
    search_blk.searchattrs.volattr = 0;
    search_blk.searchattrs.dirattr = 0;
    search_blk.searchattrs.fileattr = 0;
    search_blk.searchattrs.forkattr = 0;

    // Configure return attributes: fsid + objid for path resolution via fsgetpath().
    search_blk.returnattrs = &return_list;
    return_list.bitmapcount = ATTR_BIT_MAP_COUNT;
    return_list.reserved = 0;
    return_list.commonattr = ATTR_CMN_FSID | ATTR_CMN_OBJID;
    return_list.volattr = 0;
    return_list.dirattr = 0;
    return_list.fileattr = 0;
    return_list.forkattr = 0;

    // Result buffer: array of packed_result structs.
    search_blk.returnbuffer = result_buffer;
    search_blk.returnbuffersize = sizeof(result_buffer);

    // Pack searchparams1: the name to search for.
    strcpy(info1.name, namePattern);
    info1.ref.attr_dataoffset = sizeof(struct attrreference);
    info1.ref.attr_length = (u_int32_t)nameLen + 1;
    info1.size = sizeof(struct attrreference) + info1.ref.attr_length;
    search_blk.searchparams1 = &info1;
    search_blk.sizeofsearchparams1 = info1.size + sizeof(u_int32_t);

    // Pack searchparams2: unused for string matching but must be valid.
    info2.size = sizeof(struct attrreference);
    info2.ref.attr_dataoffset = sizeof(struct attrreference);
    info2.ref.attr_length = 0;
    search_blk.searchparams2 = &info2;
    search_blk.sizeofsearchparams2 = sizeof(info2);

    // Search configuration.
    search_blk.maxmatches = MAX_MATCHES;
    search_blk.timelimit.tv_sec = 1;
    search_blk.timelimit.tv_usec = 0;

    // Build options flags.
    search_options = SRCHFS_START | SRCHFS_MATCHPARTIALNAMES;
    if (matchFiles) search_options |= SRCHFS_MATCHFILES;
    if (matchDirs) search_options |= SRCHFS_MATCHDIRS;

    // If neither files nor dirs requested, match both.
    if (!matchFiles && !matchDirs) {
        search_options |= SRCHFS_MATCHFILES | SRCHFS_MATCHDIRS;
    }

    memset(&search_state, 0, sizeof(search_state));

    // Search loop: searchfs() returns EAGAIN when there are more results.
    do {
        matches = 0;
        err = searchfs(
            volumePath,
            &search_blk,
            &matches,
            0,               // Script code (ignored by modern kernels)
            search_options,
            &search_state
        );
        if (err == -1) {
            err = errno;
        }

        // After the first call, clear SRCHFS_START to resume.
        search_options &= ~SRCHFS_START;

        // Parse result buffer entries.
        if ((err == 0 || err == EAGAIN) && matches > 0) {
            char *ptr = (char *)&result_buffer[0];
            char *end_ptr = ptr + sizeof(result_buffer);

            for (unsigned long i = 0; i < matches; i++) {
                packed_result_p result_p = (packed_result_p)ptr;

                // Bounds check before reading.
                if (ptr + sizeof(packed_result) > end_ptr) {
                    break;
                }

                // Resolve the object ID to a full path via fsgetpath().
                // The object ID is packed as two 32-bit fields that must be
                // combined into a single 64-bit value for fsgetpath().
                char path_buf[PATH_MAX];
                ssize_t size = fsgetpath(
                    path_buf,
                    sizeof(path_buf),
                    &result_p->fs_id,
                    (uint64_t)result_p->obj_id.fid_objno |
                    ((uint64_t)result_p->obj_id.fid_generation << 32)
                );

                if (size > -1) {
                    if (!callback(path_buf, context)) {
                        // Caller requested early stop.
                        return 0;
                    }

                    match_cnt++;
                    if (maxResults > 0 && match_cnt >= maxResults) {
                        return 0;
                    }
                }
                // If fsgetpath fails (file deleted between search and lookup),
                // silently skip this result.

                // Advance to next entry.
                ptr += result_p->size;
                if (ptr > end_ptr) {
                    break;
                }
            }
        }

        // EBUSY: catalog changed mid-search. Restart up to MAX_EBUSY_RETRIES times.
        if (err == EBUSY && ebusy_count++ < MAX_EBUSY_RETRIES) {
            goto catalog_changed;
        }

        if (err != 0 && err != EAGAIN) {
            errno = err;
            return -1;
        }

    } while (err == EAGAIN);

    return 0;
}
