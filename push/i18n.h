#pragma once

#include <libintl.h>

#include <string>

const std::string GETTEXT_DOMAIN = "fluffychat.notkit";

#define _(value) gettext(value)
#define N_(value) gettext(value)
