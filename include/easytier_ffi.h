// C interface of EasyTier's `easytier-contrib/easytier-ffi` crate.
// Mirrors easytier-contrib/easytier-ffi/src/lib.rs at the pinned EasyTier version.
// All functions return 0 on success and -1 on failure unless noted otherwise;
// call `get_error_msg` to read the last error.

#ifndef EASYTIER_FFI_H
#define EASYTIER_FFI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KeyValuePair {
  const char *key;
  const char *value;
} KeyValuePair;

// Validate a TOML config without starting anything.
int parse_config(const char *cfg_str);

// Start a network instance from a TOML config. `inst_name` in the config is
// the handle used by the other functions.
int run_network_instance(const char *cfg_str);

// Keep only the named instances running; pass length 0 to stop all of them.
int retain_network_instance(const char *const *inst_names, size_t length);

// Fill `infos` with up to `max_length` (instance name, JSON status) pairs.
// Returns the number of pairs written, or -1. Free every key/value with free_string.
int collect_network_infos(KeyValuePair *infos, size_t max_length);

// Hand a TUN file descriptor to a running instance (unused in no_tun mode).
int set_tun_fd(const char *inst_name, int fd);

// Write the last error message to `out` (NULL if none). Free it with free_string.
void get_error_msg(const char **out);

void free_string(const char *s);

#ifdef __cplusplus
}
#endif

#endif
