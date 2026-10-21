// Avahi installs its compatibility header in a subfolder (libavahi-compat-libdnssd-dev).
#if __has_include(<dns_sd.h>)
#include <dns_sd.h>
#else
#include <avahi-compat-libdns_sd/dns_sd.h>
#endif
