//
// miniupnpc_stub.c
// VisionRemotePS5
//
// UPnP port mapping is not available on visionOS. libchiaki_full.a (remote/holepunch.c)
// references these miniupnpc symbols; here they resolve to "no gateway found", which
// holepunch.c treats as non-fatal (chiaki_holepunch_upnp_discover -> GATEWAY_STATUS_NOT_FOUND).
// Only the return values matter: no struct is ever dereferenced here.
//

#include <stddef.h>

struct UPNPDev;
struct UPNPUrls;
struct IGDdatas;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"

struct UPNPDev *upnpDiscover(int delay, const char *multicastif,
                             const char *minissdpdsock, int localport, int ipv6,
                             unsigned char ttl, int *error) {
  if (error)
    *error = -1; // UPNPDISCOVER_UNKNOWN_ERROR
  return NULL;
}

void freeUPNPDevlist(struct UPNPDev *devlist) {}

int UPNP_GetValidIGD(struct UPNPDev *devlist, struct UPNPUrls *urls,
                     struct IGDdatas *data, char *lanaddr, int lanaddrlen,
                     char *wanaddr, int wanaddrlen) {
  return 0; // no IGD found
}

int UPNP_GetExternalIPAddress(const char *controlURL, const char *servicetype,
                              char *extIpAdd) {
  return 1; // UPNPCOMMAND_UNKNOWN_ERROR
}

int UPNP_AddPortMapping(const char *controlURL, const char *servicetype,
                        const char *extPort, const char *inPort,
                        const char *inClient, const char *desc,
                        const char *proto, const char *remoteHost,
                        const char *leaseDuration) {
  return 1;
}

int UPNP_DeletePortMapping(const char *controlURL, const char *servicetype,
                           const char *extPort, const char *proto,
                           const char *remoteHost) {
  return 1;
}

const char *strupnperror(int err) { return "UPnP unavailable on visionOS"; }

#pragma clang diagnostic pop
