#include "curl_bridge.h"
#include <curl/curl.h>

void curl_bridge_global_init(void) {
    curl_global_init(CURL_GLOBAL_ALL);
}

CurlHandle curl_bridge_init(void) {
    return curl_easy_init();
}

void curl_bridge_cleanup(CurlHandle h) {
    curl_easy_cleanup(h);
}

void curl_bridge_set_url(CurlHandle h, const char *url) {
    curl_easy_setopt(h, CURLOPT_URL, url);
}

void curl_bridge_set_ssl_noverify(CurlHandle h) {
    curl_easy_setopt(h, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(h, CURLOPT_SSL_VERIFYHOST, 0L);
}

void curl_bridge_set_follow_redirects(CurlHandle h) {
    curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(h, CURLOPT_MAXREDIRS, 10L);
}

void curl_bridge_set_timeout(CurlHandle h, long secs) {
    curl_easy_setopt(h, CURLOPT_TIMEOUT, secs);
}

void curl_bridge_set_write_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata) {
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, fn);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, userdata);
}

void curl_bridge_set_progress_fn(CurlHandle h, CurlBridgeProgressFn fn, void *clientp) {
    curl_easy_setopt(h, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, fn);
    curl_easy_setopt(h, CURLOPT_XFERINFODATA, clientp);
}

/* POSTFIELDSIZE must be set before COPYPOSTFIELDS so curl copies exactly len
   bytes (the body is not NUL-terminated). COPYPOSTFIELDS also switches the
   method to POST and takes its own copy, so the caller's buffer can be freed
   immediately after this call. */
void curl_bridge_set_post_body(CurlHandle h, const void *body, long len) {
    curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE, len);
    curl_easy_setopt(h, CURLOPT_COPYPOSTFIELDS, body);
}

void *curl_bridge_headers_append(void *list, const char *header) {
    return curl_slist_append((struct curl_slist *)list, header);
}

void curl_bridge_set_headers(CurlHandle h, void *list) {
    curl_easy_setopt(h, CURLOPT_HTTPHEADER, (struct curl_slist *)list);
}

void curl_bridge_headers_free(void *list) {
    curl_slist_free_all((struct curl_slist *)list);
}

int curl_bridge_perform(CurlHandle h) {
    return (int)curl_easy_perform(h);
}

long curl_bridge_response_code(CurlHandle h) {
    long code = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code);
    return code;
}

const char *curl_bridge_strerror(int code) {
    return curl_easy_strerror((CURLcode)code);
}
