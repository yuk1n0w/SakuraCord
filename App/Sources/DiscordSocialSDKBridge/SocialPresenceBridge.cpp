#include "SocialPresenceBridge.h"

#if __has_include("discordpp.h")
#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"
#include <memory>
#include <string>

struct SakuraSocialPresence {
    uint64_t applicationID;
    void *context;
    SakuraSocialStatus status;
    SakuraSocialTokens tokens;
    SakuraSocialError error;
    std::shared_ptr<discordpp::Client> client;
    uint64_t generation = 0;

    void fail(const std::string &message) const {
        if (error) error(context, message.c_str());
    }

    void receivedTokens(discordpp::ClientResult result, std::string access,
                        std::string refresh, int32_t expires) {
        if (!result.Successful()) {
            fail(result.ToString());
            return;
        }
        if (tokens) tokens(context, access.c_str(), refresh.c_str(), expires);
        client->UpdateToken(discordpp::AuthorizationTokenType::Bearer,
                            std::move(access),
                            [this, expected = generation](auto update) {
            if (expected != generation) return;
            if (update.Successful()) client->Connect();
            else fail(update.ToString());
        });
    }
};

extern "C" int sakura_social_available(void) { return 1; }

extern "C" SakuraSocialPresence *sakura_social_create(
    uint64_t application_id, void *context, SakuraSocialStatus status,
    SakuraSocialTokens tokens, SakuraSocialError error) {
    auto *presence = new SakuraSocialPresence{
        application_id, context, status, tokens, error,
        std::make_shared<discordpp::Client>()
    };
    presence->client->SetApplicationId(application_id);
    presence->client->SetStatusChangedCallback(
        [presence](discordpp::Client::Status state, discordpp::Client::Error,
                   int32_t) {
            if (!presence->status) return;
            const bool ready = state == discordpp::Client::Status::Ready;
            uint64_t userID = 0;
            if (ready) {
                auto user = presence->client->GetCurrentUserV2();
                if (user) userID = user->Id();
            }
            presence->status(presence->context, ready ? 1 : 0, userID);
        });
    return presence;
}

extern "C" void sakura_social_destroy(SakuraSocialPresence *presence) {
    delete presence;
}

extern "C" void sakura_social_run_callbacks(void) {
    discordpp::RunCallbacks();
}

extern "C" void sakura_social_disconnect(SakuraSocialPresence *presence) {
    if (!presence) return;
    ++presence->generation;
    presence->client->ClearRichPresence();
    presence->client->Disconnect();
}

extern "C" void sakura_social_authorize(SakuraSocialPresence *presence) {
    if (!presence) return;
    const auto expected = ++presence->generation;
    auto verifier = presence->client->CreateAuthorizationCodeVerifier();
    discordpp::AuthorizationArgs args;
    args.SetClientId(presence->applicationID);
    args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
    args.SetCodeChallenge(verifier.Challenge());
    presence->client->Authorize(std::move(args),
        [presence, expected, verifier](auto result, auto code, auto redirectURI) {
            if (expected != presence->generation) return;
            if (!result.Successful()) {
                presence->fail(result.ToString());
                return;
            }
            presence->client->GetToken(
                presence->applicationID, code, verifier.Verifier(), redirectURI,
                [presence, expected](auto tokenResult, auto access, auto refresh,
                                     auto, auto expires, auto) {
                    if (expected != presence->generation) return;
                    presence->receivedTokens(tokenResult, access, refresh, expires);
                });
        });
}

extern "C" void sakura_social_connect(SakuraSocialPresence *presence,
                                        const char *access_token) {
    if (!presence || !access_token) return;
    const auto expected = ++presence->generation;
    presence->client->UpdateToken(discordpp::AuthorizationTokenType::Bearer,
                                  access_token, [presence, expected](auto result) {
        if (expected != presence->generation) return;
        if (result.Successful()) presence->client->Connect();
        else presence->fail(result.ToString());
    });
}

extern "C" void sakura_social_refresh(SakuraSocialPresence *presence,
                                        const char *refresh_token) {
    if (!presence || !refresh_token) return;
    const auto expected = ++presence->generation;
    presence->client->RefreshToken(presence->applicationID, refresh_token,
        [presence, expected](auto result, auto access, auto refresh,
                             auto, auto expires, auto) {
            if (expected != presence->generation) return;
            presence->receivedTokens(result, access, refresh, expires);
        });
}

extern "C" void sakura_social_update(SakuraSocialPresence *presence,
                                       const char *title, const char *artist,
                                       const char *artwork_url,
                                       const char *song_url,
                                       uint64_t started_at_ms,
                                       uint64_t ends_at_ms) {
    if (!presence || !title || !artist) return;
    discordpp::Activity activity;
    activity.SetType(discordpp::ActivityTypes::Listening);
    activity.SetName("YouTube Music");
    activity.SetStatusDisplayType(discordpp::StatusDisplayTypes::Details);
    activity.SetDetails(title);
    activity.SetState(artist);
    if (artwork_url && artwork_url[0]) {
        discordpp::ActivityAssets assets;
        assets.SetLargeImage(artwork_url);
        activity.SetAssets(assets);
    }
    if (song_url && song_url[0]) {
        discordpp::ActivityButton button;
        button.SetLabel("Open in YouTube Music");
        button.SetUrl(song_url);
        activity.AddButton(std::move(button));
    }
    if (started_at_ms && ends_at_ms > started_at_ms) {
        discordpp::ActivityTimestamps times;
        times.SetStart(started_at_ms);
        times.SetEnd(ends_at_ms);
        activity.SetTimestamps(times);
    }
    presence->client->UpdateRichPresence(std::move(activity),
        [presence, expected = presence->generation](auto result) {
            if (expected == presence->generation && !result.Successful())
                presence->fail(result.ToString());
        });
}

extern "C" void sakura_social_clear(SakuraSocialPresence *presence) {
    if (presence) presence->client->ClearRichPresence();
}

#else

struct SakuraSocialPresence {};
extern "C" int sakura_social_available(void) { return 0; }
extern "C" SakuraSocialPresence *sakura_social_create(
    uint64_t, void *, SakuraSocialStatus, SakuraSocialTokens, SakuraSocialError) {
    return nullptr;
}
extern "C" void sakura_social_destroy(SakuraSocialPresence *) {}
extern "C" void sakura_social_run_callbacks(void) {}
extern "C" void sakura_social_disconnect(SakuraSocialPresence *) {}
extern "C" void sakura_social_authorize(SakuraSocialPresence *) {}
extern "C" void sakura_social_connect(SakuraSocialPresence *, const char *) {}
extern "C" void sakura_social_refresh(SakuraSocialPresence *, const char *) {}
extern "C" void sakura_social_update(SakuraSocialPresence *, const char *,
                                       const char *, const char *, const char *, uint64_t,
                                       uint64_t) {}
extern "C" void sakura_social_clear(SakuraSocialPresence *) {}

#endif
