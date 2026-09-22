//
//  MinisLiveOverlay.h
//  MinisToolLive
//
//  独立浮层：在执行 shell 工具时并列显示逐行实时输出。
//  完全不触碰 Minis 自身的 SwiftUI 视图树 —— 只叠加一个独立 UIWindow。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MinisLiveOverlay : NSObject

/// 单例
+ (instancetype)shared;

/// 用开关控制是否显示（默认 YES）。键存在 Minis 的 NSUserDefaults 里。
+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)enabled;

/// 一条命令开始 —— 清空面板、淡入显示
- (void)beginCommand:(nullable NSString *)executable
           arguments:(nullable NSArray<NSString *> *)arguments;

/// 收到一行输出（主队列调用）
/// @param line 输出行（无换行符）
/// @param isStdErr YES = stderr（会标红）
- (void)appendLine:(nullable NSString *)line isStdErr:(BOOL)isStdErr;

/// 命令结束 —— 显示退出码/耗时，延迟淡出（除非锁定常显）
- (void)endCommandExitCode:(NSInteger)exitCode duration:(NSTimeInterval)duration;

/// 立即收起（不销毁，下次复用）
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END
