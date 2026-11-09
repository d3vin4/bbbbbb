#pragma once
//
//  IDeviceFFI.h
//  bbbbbb
//
//  C declarations for the idevice-ffi surface that is already compiled into
//  Vendor/AirliftFFI.xcframework (Rust static library, MIT © 2026 Jackson Coxson).
//  Only the subset used by bbbbbb is declared here; the implementations live in
//  the prebuilt library.
//

#include <stdint.h>
#include <stddef.h>
#include <sys/socket.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

typedef struct IdeviceFfiError {
    int32_t code;
    int32_t sub_code;
    const char *message;
} IdeviceFfiError;

/// Frees an error returned by any function below (NULL is a no-op).
void idevice_error_free(IdeviceFfiError *err);

/// Opaque plist node (libplist-compatible API implemented by plist_ffi).
typedef void *plist_t;

/// Frees data buffers allocated by this library (icons, AFC reads, …).
void idevice_data_free(uint8_t *data, uint64_t len);

/// Frees an array of plist nodes allocated by this library (frees each node).
void idevice_plist_array_free(plist_t *plists, uint64_t len);

/// Frees strings allocated by this library.
void idevice_string_free(char *string);

// ---------------------------------------------------------------------------
// Opaque handles
// ---------------------------------------------------------------------------

typedef struct AdapterHandle AdapterHandle;
typedef struct RsdHandshakeHandle RsdHandshakeHandle;
typedef struct RpPairingFileHandle RpPairingFileHandle;
typedef struct InstallationProxyClientHandle InstallationProxyClientHandle;
typedef struct SpringBoardServicesClientHandle SpringBoardServicesClientHandle;
typedef struct HouseArrestClientHandle HouseArrestClientHandle;
typedef struct AfcClientHandle AfcClientHandle;

// ---------------------------------------------------------------------------
// RPPairing file
// ---------------------------------------------------------------------------

/// Reads an RPPairing record from a plist file. Returns NULL on success and
/// sets *out to a handle the caller owns.
IdeviceFfiError *rp_pairing_file_read(const char *path, RpPairingFileHandle **out);

/// Frees a handle allocated by rp_pairing_file_read.
void rp_pairing_file_free(RpPairingFileHandle *handle);

// ---------------------------------------------------------------------------
// Tunnel (produces the adapter + RSD handshake used by every *_connect_rsd)
// ---------------------------------------------------------------------------

typedef const char *(*idv_pin_callback_t)(void *context);

/// addr must point to a sockaddr_in / sockaddr_in6 (10.7.0.1:49152 via the
/// loopback tunnel); the pairing file is borrowed, not consumed.
IdeviceFfiError *tunnel_create_remotexpc_multihost(
    const void *addr,
    socklen_t addr_len,
    const char *hostname,
    RpPairingFileHandle *pairing_file,
    idv_pin_callback_t pin_callback,
    void *pin_context,
    const char *const *extra_hosts,
    uint64_t extra_host_count,
    int32_t *out_failure_kind,
    AdapterHandle **out_adapter,
    RsdHandshakeHandle **out_handshake);

IdeviceFfiError *tunnel_create_rppairing_multihost(
    const void *addr,
    socklen_t addr_len,
    const char *hostname,
    RpPairingFileHandle *pairing_file,
    idv_pin_callback_t pin_callback,
    void *pin_context,
    const char *const *extra_hosts,
    uint64_t extra_host_count,
    int32_t *out_failure_kind,
    AdapterHandle **out_adapter,
    RsdHandshakeHandle **out_handshake);

/// Closes the adapter and releases its resources.
IdeviceFfiError *adapter_close(AdapterHandle *handle);

/// Frees an RSD handshake handle.
void rsd_handshake_free(RsdHandshakeHandle *handle);

// ---------------------------------------------------------------------------
// InstallationProxy
// ---------------------------------------------------------------------------

IdeviceFfiError *installation_proxy_connect_rsd(
    AdapterHandle *provider,
    RsdHandshakeHandle *handshake,
    InstallationProxyClientHandle **client);

/// Browses installed applications. On success *out_result receives an array of
/// `plist_t` dicts (free each with plist_free) and *out_result_len its count.
IdeviceFfiError *installation_proxy_browse(
    InstallationProxyClientHandle *client,
    plist_t options,
    void **out_result,
    uint64_t *out_result_len);

/// Uninstalls the application with the given bundle identifier.
IdeviceFfiError *installation_proxy_uninstall(
    InstallationProxyClientHandle *client,
    const char *bundle_id,
    plist_t options);

/// Install progress callback (percent, 0–100). Must be a valid function pointer.
typedef void (*idv_progress_callback_t)(uint64_t progress, void *context);

/// Installs a package staged in the AFC jail (e.g. "/PublicStaging/app.ipa").
IdeviceFfiError *installation_proxy_install_with_callback(
    InstallationProxyClientHandle *client,
    const char *package_path,
    plist_t options,
    idv_progress_callback_t callback,
    void *context);

void installation_proxy_client_free(InstallationProxyClientHandle *handle);

// ---------------------------------------------------------------------------
// plist (libplist-compatible subset)
// ---------------------------------------------------------------------------

int32_t plist_to_xml(plist_t plist, char **plist_xml, uint32_t *length);
void plist_mem_free(void *ptr);
void plist_free(plist_t plist);

// ---------------------------------------------------------------------------
// SpringBoardServices / HouseArrest / AFC (declared for later milestones)
// ---------------------------------------------------------------------------

IdeviceFfiError *springboard_services_connect_rsd(
    AdapterHandle *provider,
    RsdHandshakeHandle *handshake,
    SpringBoardServicesClientHandle **client);

IdeviceFfiError *springboard_services_get_icon(
    SpringBoardServicesClientHandle *client,
    const char *bundle_identifier,
    void **out_result,
    uint64_t *out_result_len);

void springboard_services_free(SpringBoardServicesClientHandle *handle);

IdeviceFfiError *house_arrest_client_connect_rsd(
    AdapterHandle *provider,
    RsdHandshakeHandle *handshake,
    HouseArrestClientHandle **client);

IdeviceFfiError *house_arrest_vend_container(
    HouseArrestClientHandle *client,
    const char *bundle_id,
    AfcClientHandle **out_client);

void house_arrest_client_free(HouseArrestClientHandle *handle);

IdeviceFfiError *afc_client_connect_rsd(
    AdapterHandle *provider,
    RsdHandshakeHandle *handshake,
    AfcClientHandle **client);

void afc_client_free(AfcClientHandle *handle);

typedef struct AfcFileHandle AfcFileHandle;

/// AFC open modes (AfcRdOnly = 1, AfcRw = 2, AfcWrOnly = 3, AfcWr = 4, …).
IdeviceFfiError *afc_file_open(
    AfcClientHandle *client,
    const char *path,
    int32_t mode,
    AfcFileHandle **handle);

IdeviceFfiError *afc_file_write(AfcFileHandle *handle, const uint8_t *data, uint64_t length);
IdeviceFfiError *afc_file_close(AfcFileHandle *handle);
IdeviceFfiError *afc_make_directory(AfcClientHandle *client, const char *path);
IdeviceFfiError *afc_remove_path_and_contents(AfcClientHandle *client, const char *path);

#ifdef __cplusplus
}
#endif
