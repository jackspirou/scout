#ifndef CSEARCHFS_H
#define CSEARCHFS_H

#include <stdbool.h>
#include <stdint.h>

/// Callback invoked for each matching file path.
/// Return true to continue searching, false to stop early.
typedef bool (*csearchfs_callback)(const char *path, void *context);

/// Search a volume's catalog for files whose names contain the given pattern
/// (case-insensitive substring match). For each match, resolves the full path
/// via fsgetpath() and invokes the callback.
///
/// @param volumePath  Mount point of the volume to search (e.g., "/").
/// @param namePattern Substring to match against filenames (case-insensitive).
/// @param maxResults  Maximum number of results to return (0 = unlimited).
/// @param matchFiles  Include regular files in results.
/// @param matchDirs   Include directories in results.
/// @param callback    Called for each matching path. Return false to stop.
/// @param context     Opaque pointer passed through to the callback.
/// @return 0 on success, -1 on error (errno set).
///         ENOTSUP if the volume does not support searchfs().
int csearchfs_search(
    const char *volumePath,
    const char *namePattern,
    uint32_t maxResults,
    bool matchFiles,
    bool matchDirs,
    csearchfs_callback callback,
    void *context
);

/// Check whether a volume supports the searchfs() syscall.
///
/// @param volumePath Mount point of the volume to check.
/// @return true if searchfs() is supported, false otherwise.
bool csearchfs_volume_supports_searchfs(const char *volumePath);

#endif /* CSEARCHFS_H */
