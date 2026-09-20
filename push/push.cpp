#include <cerrno>
#include <clocale>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <iostream>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include "nlohmann/json.hpp"
#include "i18n.h"

using json = nlohmann::json;

// Click package name. The XDG directories AppArmor lets the helper write to
// are named after it.
static const char APP_PKGNAME[] = "fluffychat.notkit";

// At most one popup — and its sound and vibration — per conversation per this
// many seconds. The rest of a burst still reaches the messaging menu, but
// silently: every bubble sits on screen for several seconds and swallows the
// taps meant for whatever is underneath it.
static const long POPUP_INTERVAL_SECONDS = 30;

// And at most this many popups across all conversations per window. A phone
// that comes back online receives every push the server queued at once, from
// as many rooms; without a ceiling that is a minute of bubbles before the
// screen can be used. The rest are counted by the launcher emblem and listed
// in the messaging menu.
static const long BURST_WINDOW_SECONDS = 20;
static const int BURST_POPUP_BUDGET = 3;

// Forget a conversation this long after its last popup, so the state file
// cannot grow without bound.
static const long STATE_MAX_AGE_SECONDS = 24 * 60 * 60;

// Every field below is optional in the Matrix push gateway payload: the
// "event_id_only" pusher format omits nearly all of them, "tweaks" is absent
// unless a push rule sets one, and non-message events (reactions, membership,
// calls) carry no content.body. Reading them unguarded throws, and a helper
// that dies produces no notification at all — so look everything up defensively
// and fall back to a generic card.
static std::string str_at(const json &obj, const char *key)
{
    auto it = obj.find(key);
    if (it == obj.end() || !it->is_string())
        return "";
    return it->get<std::string>();
}

static const json &obj_at(const json &obj, const char *key)
{
    static const json empty = json::object();
    auto it = obj.find(key);
    if (it == obj.end() || !it->is_object())
        return empty;
    return *it;
}

static const json &array_at(const json &obj, const char *key)
{
    static const json empty = json::array();
    auto it = obj.find(key);
    if (it == obj.end() || !it->is_array())
        return empty;
    return *it;
}

static bool bool_at(const json &obj, const char *key)
{
    auto it = obj.find(key);
    return it != obj.end() && it->is_boolean() && it->get<bool>();
}

static std::string format_count(int count)
{
    char buf[64];
    snprintf(buf, sizeof(buf), P_("%d new message", "%d new messages", count),
             count);
    return buf;
}

// Where the popup bookkeeping lives. The runtime dir is on tmpfs and is wiped
// on reboot, which is all the lifetime this state needs; losing it only ever
// costs one extra popup.
static std::string state_path()
{
    std::string dir;
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    const char *cache = getenv("XDG_CACHE_HOME");
    const char *home = getenv("HOME");

    if (runtime && *runtime)
        dir = std::string(runtime) + "/" + APP_PKGNAME;
    else if (cache && *cache)
        dir = std::string(cache) + "/" + APP_PKGNAME;
    else if (home && *home)
        dir = std::string(home) + "/.cache/" + APP_PKGNAME;
    else
        return "";

    if (mkdir(dir.c_str(), 0700) != 0 && errno != EEXIST)
        return "";
    return dir + "/push-helper-state.json";
}

// Decides whether this notification may raise a bubble. When it may,
// *coalesced is how many notifications for the same conversation were silenced
// since the last one, so the card can say so.
static bool take_popup_slot(const std::string &tag, int *coalesced)
{
    *coalesced = 0;

    const std::string path = state_path();
    if (path.empty())
        return true;

    json state;
    {
        std::ifstream in(path.c_str());
        if (in)
            state = json::parse(in, nullptr, false);
    }
    if (!state.is_object())
        state = json::object();

    json &tags = state["tags"];
    if (!tags.is_object())
        tags = json::object();

    const long now = static_cast<long>(time(NULL));
    for (auto it = tags.begin(); it != tags.end();) {
        const long seen = it->is_object() ? it->value("seen", 0L) : 0L;
        // A clock that went backwards (now < seen) counts as stale too.
        if (now < seen || now - seen > STATE_MAX_AGE_SECONDS)
            it = tags.erase(it);
        else
            ++it;
    }

    json &burst = state["burst"];
    if (!burst.is_object())
        burst = json::object();
    const long burst_start = burst.value("start", 0L);
    int burst_popups = burst.value("popups", 0);
    if (now < burst_start || now - burst_start >= BURST_WINDOW_SECONDS) {
        burst_popups = 0;
        burst["start"] = now;
    }

    json &entry = tags[tag];
    if (!entry.is_object())
        entry = json::object();
    const long last = entry.value("last_popup", 0L);
    const int silenced = entry.value("silenced", 0);

    const bool popup = (now < last || now - last >= POPUP_INTERVAL_SECONDS) &&
                       burst_popups < BURST_POPUP_BUDGET;
    if (popup) {
        *coalesced = silenced;
        entry["last_popup"] = now;
        entry["silenced"] = 0;
        burst_popups += 1;
    } else {
        entry["silenced"] = silenced + 1;
    }
    entry["seen"] = now;
    burst["popups"] = burst_popups;

    // Helpers for several pushes can run at once, so swap the file in rather
    // than truncating it under another instance.
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp.c_str(), std::ios::trunc);
        if (!out)
            return popup;
        out << state;
        out.flush();
        if (!out) {
            out.close();
            remove(tmp.c_str());
            return popup;
        }
    }
    if (rename(tmp.c_str(), path.c_str()) != 0)
        remove(tmp.c_str());

    return popup;
}

// The gateway payload carries no plaintext for an encrypted room, and events
// that are not messages have no content.body at all, so name what happened
// where the type says it. *generic is set when the text says nothing about
// this particular event, which is when a count is worth showing instead.
static std::string describe_event(const std::string &mtype, const json &content,
                                  bool *generic)
{
    *generic = false;
    const std::string body = str_at(content, "body");

    if (mtype == "m.room.member") {
        if (str_at(content, "membership") == "invite")
            return N_("Invited you to a chat");
    }
    else if (mtype == "m.call.invite") {
        return N_("Incoming call");
    }
    else if (mtype == "m.sticker") {
        return N_("Sticker");
    }
    else if (mtype == "m.room.message") {
        const std::string msgtype = str_at(content, "msgtype");
        // A media event's body is its file name, which is rarely worth
        // reading; name the kind of attachment instead.
        if (msgtype == "m.image")
            return N_("Picture");
        if (msgtype == "m.video")
            return N_("Video");
        if (msgtype == "m.audio")
            return N_("Voice message");
        if (msgtype == "m.location")
            return N_("Location");
        if (msgtype == "m.file" && body.empty())
            return N_("File");
    }

    if (!body.empty())
        return body;

    *generic = true;
    return N_("New message");
}

static json notification_from_gateway(const json &message, bool popup,
                                      int coalesced)
{
    const std::string mtype = str_at(message, "type");
    const std::string room_name = str_at(message, "room_name");
    const std::string sender = str_at(message, "sender_display_name");
    const std::string room_id = str_at(message, "room_id");
    const json &content = obj_at(message, "content");

    std::string summary = room_name;
    if (summary.empty())
        summary = sender;
    if (summary.empty())
        // event_id_only payloads name neither room nor sender.
        summary = "FluffyChat";

    bool generic = false;
    std::string body = describe_event(mtype, content, &generic);
    if (generic && coalesced > 0) {
        // Nothing to say about any one of them, so say how many there are.
        body = format_count(coalesced + 1);
    }
    else if (!sender.empty() && summary != sender) {
        body = sender + ": " + body;
    }

    bool alert = false;
    const json &devices = array_at(message, "devices");
    if (!devices.empty() && devices[0].is_object()) {
        if (!str_at(obj_at(devices[0], "tweaks"), "sound").empty())
            alert = true;
    }

    json notification;
    json &card = notification["card"];
    card["summary"] = summary;
    card["body"] = body;
    card["icon"] = room_name.empty() ? "contact" : "contact-group";
    card["persist"] = true;
    card["popup"] = popup;
    if (!room_id.empty()) {
        card["actions"] = {"fluffychat://" + room_id};
        // Tag by room so the app can dismiss a room's notifications once it is
        // read, via the postal service's ClearPersistentList.
        notification["tag"] = room_id;
    }

    int unread_count = 0;
    const json &counts = obj_at(message, "counts");
    auto unread = counts.find("unread");
    if (unread != counts.end() && unread->is_number_integer())
        unread_count = unread->get<int>();
    notification["emblem-counter"]["count"] = unread_count;
    notification["emblem-counter"]["visible"] = unread_count > 0;

    notification["sound"] = alert && popup;
    notification["vibrate"] = alert && popup;

    return notification;
}

int main(int argc, char *argv[])
{
    setlocale(LC_ALL, "");
    textdomain(GETTEXT_DOMAIN.c_str());

    if (argc < 3) {
        std::cerr << "usage: push <input.json> <output.json>" << std::endl;
        return 1;
    }

    std::ifstream f1(argv[1]);
    std::ofstream f2(argv[2]);
    json js1 = json::parse(f1, nullptr, false);

    if (js1.is_discarded()) {
        std::cerr << "push: cannot parse input" << std::endl;
        return 1;
    }

    // The postal service runs this helper on everything it posts for us, not
    // just on pushes from the gateway: a notification the app raises itself
    // through lomiri_push_client arrives here as a ready-made "notification"
    // object. Those are the good ones — the app has decrypted the event — so
    // pass them through instead of rebuilding them from fields they do not
    // have.
    const json &message = obj_at(js1, "message");
    const json &posted = obj_at(js1, "notification");
    const bool from_app = message.empty() && !posted.empty();

    std::string tag;
    bool wants_popup = true;
    if (from_app) {
        tag = str_at(posted, "tag");
        wants_popup = bool_at(obj_at(posted, "card"), "popup");
    }
    else {
        tag = str_at(message, "room_id");
    }

    int coalesced = 0;
    const bool popup = wants_popup && take_popup_slot(tag, &coalesced);

    json js2;
    if (from_app) {
        json notification = posted;
        if (wants_popup && !popup) {
            notification["card"]["popup"] = false;
            notification["sound"] = false;
            notification["vibrate"] = false;
        }
        js2["notification"] = notification;
    }
    else {
        js2["notification"] = notification_from_gateway(message, popup,
                                                        coalesced);
    }
    f2 << js2;

    return 0;
}
