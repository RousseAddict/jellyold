#ifndef curl_bridge_h
#define curl_bridge_h

#include <stddef.h>

typedef void *CurlHandle;

/* Write callback: return number of bytes processed (must equal size*nmemb or curl aborts) */
typedef size_t (*CurlBridgeWriteFn)(const void *ptr, size_t size, size_t nmemb, void *userdata);

/* Progress callback (xferinfo style, curl_off_t = long long).
   Return 0 to continue, non-zero to abort. */
typedef int (*CurlBridgeProgressFn)(void *clientp,
                                    long long dltotal, long long dlnow,
                                    long long ultotal, long long ulnow);

void        curl_bridge_global_init(void);
CurlHandle  curl_bridge_init(void);
void        curl_bridge_cleanup(CurlHandle h);
void        curl_bridge_set_url(CurlHandle h, const char *url);
void        curl_bridge_set_ssl_noverify(CurlHandle h);
void        curl_bridge_set_follow_redirects(CurlHandle h);
void        curl_bridge_set_timeout(CurlHandle h, long secs);
void        curl_bridge_set_write_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata);
/* Raw response header lines (status line + each header), one call per line —
   used by the streaming proxy to pass upstream's real status/headers through
   to the player instead of hardcoding them. */
void        curl_bridge_set_header_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata);
void        curl_bridge_set_progress_fn(CurlHandle h, CurlBridgeProgressFn fn, void *clientp);

/* POST + custom headers (used by the login path) */
void        curl_bridge_set_post_body(CurlHandle h, const void *body, long len);
void       *curl_bridge_headers_append(void *list, const char *header);
void        curl_bridge_set_headers(CurlHandle h, void *list);
void        curl_bridge_headers_free(void *list);

/* Raw TLS socket mode (used by the Chromecast CASTV2 session).
   connect_only does DNS + TCP + TLS and then stops, exposing the socket for
   curl_easy_send/recv — iOS 6's Secure Transport can't negotiate with a
   Chromecast, so OpenSSL has to own this connection too. Returns a CURLcode. */
int         curl_bridge_connect_only(CurlHandle h, const char *host, long port);
/* Blocking write of the whole buffer. Returns len, or -1 on error. */
long        curl_bridge_send(CurlHandle h, const void *buf, long len);
/* Returns bytes read, 0 on timeout (no data), -1 on error or peer close. */
long        curl_bridge_recv(CurlHandle h, void *buf, long len, long timeout_ms);

int         curl_bridge_perform(CurlHandle h);
long        curl_bridge_response_code(CurlHandle h);
const char *curl_bridge_strerror(int code);

#endif /* curl_bridge_h */
