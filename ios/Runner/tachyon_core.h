#ifndef TACHYON_CORE_H
#define TACHYON_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *tachyon_core_version(void);
char *tachyon_core_last_error(void);
void tachyon_core_string_free(char *ptr);
int32_t tachyon_core_check(const char *config_json);
int32_t tachyon_core_start(const char *config_json, int32_t tun_fd);
int32_t tachyon_core_reload(const char *config_json);
int32_t tachyon_core_stop(void);
int32_t tachyon_core_is_running(void);

#ifdef __cplusplus
}
#endif

#endif /* TACHYON_CORE_H */
