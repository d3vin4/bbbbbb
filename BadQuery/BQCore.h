#pragma once
#import <Foundation/Foundation.h>

/// BQCore — lõi truy cập container của bbbbbb.
///
/// App này chỉ dùng **một** kỹ thuật truy cập: **worse_query**
/// (Taj C — https://github.com/forcequitOS/worse_query, GPL-3.0-or-later),
/// cài đặt lại độc lập: thay `Library/Caches` của app group bằng symlink tới
/// đường dẫn đích rồi xin containermanagerd cấp sandbox token cho đích đó.
///
/// Phần liệt kê thư mục dùng **fsgetpath** (API kernel công khai): dò số inode
/// của volume để dựng lại đường dẫn khi không được phép `readdir` — tự
/// triển khai trong file này.
///
/// Định danh container đọc từ xattr `com.apple.containermanager.identifier`.
NS_ASSUME_NONNULL_BEGIN

@interface BQCore : NSObject

/// YES khi libsystem_containermanager có đủ ký hiệu cần dùng.
+ (BOOL)isAvailable;

/// Các app-group entitlement của app (có thể rỗng → không dùng được kỹ thuật).
+ (NSArray<NSString *> *)appGroupIdentifiers;

/// Mô tả ngắn đường truy cập hiện tại (để hiển thị trong Cài đặt).
+ (NSString *)routeDescription;

/// Lỗi gần nhất (chẩn đoán).
+ (nullable NSString *)lastErrorDescription;

/// Xin token sandbox cho `path` bằng worse_query. Trả handle >= 0 khi thành công.
+ (int64_t)grantForPath:(NSString *)path;

/// Đường dẫn đã được cấp token (chuẩn hoá `/private`).
+ (nullable NSString *)resolvedPathForHandle:(int64_t)handle;

/// Nhả token (vẫn nằm trong cache, chỉ bị thu hồi khi vượt hạn mức).
+ (void)releaseHandle:(int64_t)handle;

/// Nhả toàn bộ token đang giữ.
+ (void)releaseAll;

/// Định danh (bundle id / group id) của container tại `path`.
+ (nullable NSString *)containerIdentifierAtPath:(NSString *)path;

/// Dò tổ hợp query mạnh nhất trên máy này: quét class × part × flags và trả
/// về bảng kết quả (số định danh liệt kê được) để chọn đường tốt nhất.
+ (NSArray<NSString *> *)probeQueries;

/// Liệt kê thẻ con của `path` bằng fsgetpath.
+ (NSArray<NSString *> *)listDirectoryEntries:(NSString *)path maxInode:(uint64_t)maxInode;

/// Như trên nhưng quét từ `startInode` và báo inode cao nhất đã xét.
+ (NSArray<NSString *> *)listDirectoryEntries:(NSString *)path
                                    fromInode:(uint64_t)startInode
                                     maxInode:(uint64_t)maxInode
                                  scannedUpTo:(nullable uint64_t *)scannedUpTo;

@end

NS_ASSUME_NONNULL_END
