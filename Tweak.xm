//
//  Tweak.xm
//  MinisToolLive
//
//  挂载点：ISHShellExecutor（纯 ObjC 类，Minis 所有 shell 输出的唯一咽喉）
//  依据：OpenMinis 开源仓库权威头文件 src/ios/iSH/ISHShellExecutor.h
//        + 实现 ISHShellExecutor.m L1156-1190（回调派发到 main queue）
//
//  安全原则：%orig 原样转发 —— 原生卡片逻辑一字不改，我们只是"搭便车"再抄一份。
//

#import <UIKit/UIKit.h>
#import "MinisLiveOverlay.h"

// ── 权威类型（照抄 ISHShellExecutor.h）─────────────────────
// 前置声明结果类，保持签名与真实一致（ABI 相同，仅需 NSObject 基类）
@interface ISHShellExecutionResult : NSObject
@end

typedef void (^ISHShellLineCallback)(NSString *line, BOOL isStdErr);
typedef void (^ISHShellCompletionCallback)(ISHShellExecutionResult *result);

#pragma mark - 统一的包装逻辑

/// 把外部 lineCallback 包一层：先原样转发，再喂浮层
static ISHShellLineCallback MTLWrapLine(ISHShellLineCallback original) {
    return ^(NSString *line, BOOL isStdErr) {
        if (original) {
            original(line, isStdErr);                    // ← 原逻辑，零改动
        }
        @try {
            [[MinisLiveOverlay shared] appendLine:line isStdErr:isStdErr];
        } @catch (__unused NSException *e) {
            // 浮层异常绝不能影响 Minis 主流程
        }
    };
}

/// 把 completion 包一层：先原样转发，再收尾浮层。
/// 注意：浮层收尾必须 dispatch_async 到下一轮 runloop —— completion 本身
/// 就在主队列上被调用，若同步收尾会与 Minis 正在进行的 SwiftUI 视图更新
/// 撞在同一轮事务里（0x8BADF00D / 视图更新期改状态）。隔一轮是零风险的。
static ISHShellCompletionCallback MTLWrapDone(ISHShellCompletionCallback original) {
    return ^(id result) {
        if (original) {
            original(result);                            // ← 原逻辑，零改动
        }
        @try {
            NSInteger code = 0;
            NSTimeInterval dur = 0;
            @try {
                id c = [result valueForKey:@"exitCode"];
                if (c) code = [c integerValue];
                id d = [result valueForKey:@"duration"];
                if (d) dur = [d doubleValue];
            } @catch (__unused NSException *e) {}
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    [[MinisLiveOverlay shared] endCommandExitCode:code duration:dur];
                } @catch (__unused NSException *e) {}
            });
        } @catch (__unused NSException *e) {}
    };
}

/// 开始新命令：同样隔一轮，避免在 Minis 视图更新中同步建窗口
static void MTLBegin(NSString *exe, NSArray *args) {
    NSString *e = [exe copy];
    NSArray *a = [args copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [[MinisLiveOverlay shared] beginCommand:e arguments:a];
        } @catch (__unused NSException *e2) {}
    });
}

#pragma mark - Hook 主体

%hook ISHShellExecutor

// ① /bin/sh -c "<command>"（AIChatViewModel+ISHCommand 走的这条）
+ (int)executeCommand:(NSString *)command
         lineCallback:(ISHShellLineCallback)lineCallback
           completion:(ISHShellCompletionCallback)completion {

    MTLBegin(@"/bin/sh", @[@"-c", command ?: @""]);
    return %orig(command, MTLWrapLine(lineCallback), MTLWrapDone(completion));
}

// ② 无 stdin / 无 fsContext 的变体
+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray *)arguments
             environment:(NSDictionary *)environment
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {

    MTLBegin(executable, arguments);
    return %orig(executable, arguments, environment,
                 MTLWrapLine(lineCallback), MTLWrapDone(completion));
}

// ③ 带 stdinData
+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray *)arguments
             environment:(NSDictionary *)environment
               stdinData:(NSData *)stdinData
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {

    MTLBegin(executable, arguments);
    return %orig(executable, arguments, environment, stdinData,
                 MTLWrapLine(lineCallback), MTLWrapDone(completion));
}

// ④ 带 stdinData + fsContext —— 【实际唯一调用点】
//    ISHExecutionCoordinator.swift L342 走的正是这一条
+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray *)arguments
             environment:(NSDictionary *)environment
               stdinData:(NSData *)stdinData
               fsContext:(uint64_t)fsContext
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {

    MTLBegin(executable, arguments);
    return %orig(executable, arguments, environment, stdinData, fsContext,
                 MTLWrapLine(lineCallback), MTLWrapDone(completion));
}

%end

#pragma mark - 构造函数

%ctor {
    // 只在 Minis 进程生效（plist Filter 已限定 Executables = Minis）
    // 首帧不做任何重活：浮层 window 是懒加载的，第一次执行工具才创建。
    NSLog(@"[MinisToolLive] loaded, enabled=%d", (int)[MinisLiveOverlay isEnabled]);
}
