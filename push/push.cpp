#include <clocale>
#include <iostream>
#include <fstream>
#include "nlohmann/json.hpp"
#include "i18n.h"

using json = nlohmann::json;

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
    json js2;

    if (js1.is_discarded()) {
        std::cerr << "push: cannot parse input" << std::endl;
        return 1;
    }

    const json &message = obj_at(js1, "message");
    std::string mtype = str_at(message, "type");
    std::string room_name = str_at(message, "room_name");
    std::string sender = str_at(message, "sender_display_name");
    std::string room_id = str_at(message, "room_id");
    std::string content_body = str_at(obj_at(message, "content"), "body");

    std::string summary = "";
    std::string body = "";
    std::string icon = "";

    int unread_count = 0;
    bool alert = false;
    bool popup = false;

    if (!room_name.empty())
    {
        summary = room_name;
    }
    else if (!sender.empty())
    {
        summary = sender;
    }
    else
    {
        // event_id_only payloads name neither room nor sender.
        summary = "FluffyChat";
    }

    // No plaintext to show for encrypted rooms, and none either when the
    // payload carries no body at all.
    if (mtype == "m.room.encrypted" || content_body.empty()) {
        body = N_("New Message");
    }
    else {
        body = content_body;
    }
    if (!sender.empty() && summary != sender) {
        body = sender + ": " + body;
    }

    if (room_name.empty()) {
        icon = "contact";
    }
    else {
        icon = "contact-group";
    }

    const json &devices = array_at(message, "devices");
    if (!devices.empty() && devices[0].is_object()) {
        if (!str_at(obj_at(devices[0], "tweaks"), "sound").empty()) {
            alert = true;
        }
    }

    if(summary != "" && body != ""){
        popup = true;
    }

    const json &counts = obj_at(message, "counts");
    auto unread = counts.find("unread");
    if (unread != counts.end() && unread->is_number_integer()) {
        unread_count = unread->get<int>();
    }

    if (!room_id.empty()) {
        js2["notification"]["card"]["actions"] = {"fluffychat://" + room_id};
        // Tag by room so the app can dismiss a room's notifications once it is
        // read, via the postal service's ClearPersistentList.
        js2["notification"]["tag"] = room_id;
    }
    js2["notification"]["card"]["summary"] = summary;
    js2["notification"]["card"]["body"] = body;
    js2["notification"]["card"]["icon"] = icon;
    js2["notification"]["card"]["persist"] = popup;
    js2["notification"]["card"]["popup"] = popup;

    js2["notification"]["emblem-counter"]["count"] = unread_count;
    js2["notification"]["emblem-counter"]["visible"] = unread_count > 0;

    js2["notification"]["sound"] = alert;
    js2["notification"]["vibrate"] = alert;
    f2 << js2;

    return 0;
}
