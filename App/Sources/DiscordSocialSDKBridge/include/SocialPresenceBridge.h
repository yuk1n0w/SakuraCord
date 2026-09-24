#ifndef SAKURACORD_SOCIAL_PRESENCE_BRIDGE_H
#define SAKURACORD_SOCIAL_PRESENCE_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SakuraSocialPresence SakuraSocialPresence;
typedef void (*SakuraSocialStatus)(void *context, int ready, uint64_t user_id);
typedef void (*SakuraSocialTokens)(void *context, const char *access_token,
                                   const char *refresh_token, int expires_in);
typedef void (*SakuraSocialError)(void *context, const char *message);

int sakura_social_available(void);
SakuraSocialPresence *sakura_social_create(uint64_t application_id, void *context,
                                           SakuraSocialStatus status,
                                           SakuraSocialTokens tokens,
                                           SakuraSocialError error);
void sakura_social_destroy(SakuraSocialPresence *presence);
void sakura_social_run_callbacks(void);
void sakura_social_disconnect(SakuraSocialPresence *presence);
void sakura_social_authorize(SakuraSocialPresence *presence);
void sakura_social_connect(SakuraSocialPresence *presence, const char *access_token);
void sakura_social_refresh(SakuraSocialPresence *presence, const char *refresh_token);
void sakura_social_update(SakuraSocialPresence *presence, const char *title,
                          const char *artist, const char *artwork_url,
                          const char *song_url,
                          uint64_t started_at_ms, uint64_t ends_at_ms);
void sakura_social_clear(SakuraSocialPresence *presence);

#ifdef __cplusplus
}
#endif
#endif
