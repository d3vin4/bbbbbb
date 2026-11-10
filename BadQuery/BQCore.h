#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// BadQueryCore — container access engine for bbbbbb.
///
/// Direct path (MHA-C2): MCM container queries + sandbox-extension activation,
/// following the public FilzaSlop / 3105 technique. Fallback strategies follow
/// the KAMUI (MIT) technique set: class-13 traversal, class-12 geod,
/// class-7 app-group part-directory symlink, class-2 swap/stage.
///
/// Hardening ideas (path normalisation, flag memory, xattr identifier,
/// containermanager path→identifier map, bounded token set) are informed by
/// the public WQ Files project (kolbicz/WQFiles, GPL-3.0-or-later) and the
/// worse_query technique by Taj C (forcequitOS, GPL-3.0-or-later);
/// this file is an independent implementation, not a copy.
@interface BQCore : NSObject

/// YES when libsystem_containermanager.dylib exposes everything required.
+ (BOOL)isAvailable;

/// YES when the running bundle identity matches com.apple.mobile.MobileHouseArrest.
+ (BOOL)hasMHAIdentity;

/// The app's own application-groups entitlement values (may be empty).
+ (NSArray<NSString *> *)appGroupIdentifiers;

/// Human-readable description of the most recent failure (for diagnostics).
+ (nullable NSString *)lastErrorDescription;

/// Đường escape chính theo phiên bản iOS hiện tại (worse_query / bad_query / class-2)
/// và tình trạng App Group entitlement.
+ (NSString *)preferredRouteDescription;

/// Tóm tắt đường truy cập hiện tại, 1 từ (ví dụ: "MHA-C2", "worse_query").
+ (NSString *)routeSummary;

/// Identifier (bundle/group id) của container tại `path` — đọc qua xattr,
/// map của containermanager, rồi metadata plist. nil khi không đọc được.
+ (nullable NSString *)containerIdentifierAtPath:(NSString *)path;

#pragma mark - MCM direct queries (MHA-C2)

/// Enumerate container identifiers for an MCM class (2 = app data, 7 = app group).
/// Returns an empty array when enumeration is denied (see +lastErrorDescription).
+ (NSArray<NSString *> *)enumerateIdentifiersForClass:(uint64_t)cls
                                                limit:(NSUInteger)limit;

/// Resolve the on-disk path of a container. Returns nil on failure
/// (see +lastErrorDescription).
+ (nullable NSString *)containerPathForClass:(uint64_t)cls
                                  identifier:(NSString *)identifier
                                       group:(BOOL)group;

/// Activate a retained sandbox-extension lease for a container and return its
/// path. Leases stay alive until +releaseLeases is called. Returns nil on
/// failure (see +lastErrorDescription).
+ (nullable NSString *)activateContainerForClass:(uint64_t)cls
                                      identifier:(NSString *)identifier
                                           group:(BOOL)group;

/// Release all activated container leases.
+ (void)releaseLeases;

#pragma mark - Escape strategies (fallbacks)

/// Try every strategy to obtain a sandbox extension for `target`.
/// Returns a handle >= 0 on success; the resolved path is available through
/// +escapedPathForHandle:. Returns a negative code on failure.
+ (int64_t)escapeTarget:(NSString *)target;

/// Path resolved by a successful +escapeTarget: call (may differ from target).
+ (nullable NSString *)escapedPathForHandle:(int64_t)handle;

/// Release an escape handle and restore any temporary symlinks safely.
+ (void)endEscape:(int64_t)handle;

#pragma mark - fsgetpath enumeration

/// List direct children of `path` by scanning inodes. Useful inside containers
/// where readdir is denied but the path is visible through fsgetpath.
+ (NSArray<NSString *> *)listDirectoryEntries:(NSString *)path maxInode:(uint64_t)maxInode;

@end

NS_ASSUME_NONNULL_END
