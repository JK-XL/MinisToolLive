//
//  MinisLiveOverlay.m
//  MinisToolLive
//

#import "MinisLiveOverlay.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - 常量

static const NSUInteger kMTLMaxLines     = 1500;   // 面板最多保留行数
static const NSTimeInterval kMTLFlushGap = 0.10;   // 批量刷新间隔（秒）
static const NSTimeInterval kMTLFadeOut  = 3.0;    // 结束后延迟淡出（秒）

static NSString * const kMTLEnabledKey = @"mtl_enabled";
static NSString * const kMTLFrameKey   = @"mtl_frame";
static NSString * const kMTLLockKey    = @"mtl_lock";

#pragma mark - ANSI 解析（自包含，不依赖宿主类）

static UIColor *MTLDefaultFG(void)    { return [UIColor colorWithWhite:0.93 alpha:1.0]; }
static UIColor *MTLDimFG(void)        { return [UIColor colorWithWhite:0.62 alpha:1.0]; }

static UIColor *MTLColor256(NSInteger n) {
    if (n < 0) n = 0;
    if (n < 16) {
        static const CGFloat tbl[16][3] = {
            {0.20,0.20,0.22},{0.86,0.30,0.28},{0.35,0.72,0.36},{0.83,0.68,0.30},
            {0.36,0.50,0.86},{0.74,0.42,0.82},{0.36,0.72,0.74},{0.80,0.80,0.82},
            {0.42,0.42,0.46},{0.94,0.42,0.40},{0.50,0.85,0.50},{0.94,0.80,0.44},
            {0.50,0.65,0.96},{0.87,0.58,0.94},{0.50,0.85,0.86},{0.96,0.96,0.98},
        };
        return [UIColor colorWithRed:tbl[n][0] green:tbl[n][1] blue:tbl[n][2] alpha:1.0];
    }
    if (n < 232) {
        NSInteger c = n - 16, r = c / 36, g = (c % 36) / 6, b = c % 6;
        CGFloat f[6] = {0.0, 0.37, 0.53, 0.69, 0.84, 1.0};
        return [UIColor colorWithRed:f[r] green:f[g] blue:f[b] alpha:1.0];
    }
    CGFloat w = (n - 232) / 23.0;
    return [UIColor colorWithWhite:(0.08 + w * 0.92) alpha:1.0];
}

/// 构造一段带属性的文本
static NSAttributedString *MTLRun(NSString *text, UIColor *fg, BOOL bold, UIFont *font) {
    UIFont *f = bold ? [UIFont monospacedSystemFontOfSize:font.pointSize weight:UIFontWeightSemibold] : font;
    return [[NSAttributedString alloc] initWithString:(text ?: @"")
                                          attributes:@{ NSFontAttributeName: f,
                                                        NSForegroundColorAttributeName: fg }];
}

/// 解析一行里的 ANSI SGR 转义，输出等价富文本
static NSAttributedString *MTLParseLine(NSString *line, BOOL isStdErr, UIFont *font) {
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSMutableString *plain = [NSMutableString new];
    UIColor *base = isStdErr ? [UIColor systemRedColor] : MTLDefaultFG();
    UIColor *fg = base;
    BOOL bold = NO;

    NSUInteger i = 0, n = line.length;
    while (i < n) {
        unichar c = [line characterAtIndex:i];
        if (c == 0x1B && i + 1 < n && [line characterAtIndex:i + 1] == '[') {
            if (plain.length) {
                [out appendAttributedString:MTLRun(plain, fg, bold, font)];
                [plain setString:@""];
            }
            NSUInteger j = i + 2;
            while (j < n && [line characterAtIndex:j] != 'm') j++;
            if (j >= n) { i = n; continue; }               // 未闭合，丢弃
            NSString *raw = [line substringWithRange:NSMakeRange(i + 2, j - (i + 2))];
            NSArray<NSString *> *parts = [raw length] ? [raw componentsSeparatedByString:@";"]
                                                      : @[@"0"];
            for (NSUInteger k = 0; k < parts.count; k++) {
                NSInteger v = [parts[k] integerValue];
                if (v == 0)        { fg = base; bold = NO; }
                else if (v == 1)   { bold = YES; }
                else if (v == 2)   { fg = MTLDimFG(); }
                else if (v == 22)  { bold = NO; }
                else if (v >= 30 && v <= 37) { fg = MTLColor256(v - 30); }
                else if (v == 39)  { fg = base; bold = NO; }
                else if (v >= 90 && v <= 97) { fg = MTLColor256(v - 90 + 8); }
                else if (v == 38 && k + 2 < parts.count) {
                    NSInteger mode = [parts[k + 1] integerValue];
                    if (mode == 5 && k + 2 < parts.count) {
                        fg = MTLColor256([parts[k + 2] integerValue]);
                        k += 2;
                    } else if (mode == 2 && k + 4 < parts.count) {
                        fg = [UIColor colorWithRed:[parts[k+2] integerValue] / 255.0
                                            green:[parts[k+3] integerValue] / 255.0
                                             blue:[parts[k+4] integerValue] / 255.0
                                            alpha:1.0];
                        k += 4;
                    }
                }
            }
            i = j + 1;
        } else {
            [plain appendFormat:@"%C", c];
            i++;
        }
    }
    if (plain.length) [out appendAttributedString:MTLRun(plain, fg, bold, font)];
    if (out.length == 0)  [out appendAttributedString:MTLRun(@"", base, NO, font)];
    return out;
}

#pragma mark - 穿透式根视图（面板外的手势交还给 App）

@interface MTLPassthroughView : UIView
@property (nonatomic, weak) UIView *panel;
@end

@implementation MTLPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (self.panel && ![self.panel pointInside:[self convertPoint:point toView:self.panel]
                                     withEvent:event]) {
        return nil;   // 面板之外 → 放行给 Minis 自己
    }
    return v;
}
@end

@interface MTLRootVC : UIViewController
@property (nonatomic, weak) UIView *panel;
@end

@implementation MTLRootVC
- (void)loadView {
    MTLPassthroughView *v = [[MTLPassthroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    v.backgroundColor = UIColor.clearColor;
    self.view = v;
}
@end

#pragma mark - 浮层主体

// UITextViewDelegate 已继承 UIScrollViewDelegate，声明一个即可
@interface MinisLiveOverlay () <UITextViewDelegate>

// ── 状态 ─────────────────────────────────────────────
@property (nonatomic, strong, nullable) UIWindow *window;
@property (nonatomic, strong, nullable) UIView *panel;
@property (nonatomic, strong, nullable) UIVisualEffectView *blur;
@property (nonatomic, strong, nullable) UILabel *titleLabel;
@property (nonatomic, strong, nullable) UILabel *metaLabel;
@property (nonatomic, strong, nullable) UIView *statusDot;
@property (nonatomic, strong, nullable) UITextView *textView;
@property (nonatomic, strong, nullable) UIButton *lockButton;

@property (nonatomic, strong) NSMutableAttributedString *buffer;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *lineLens;
@property (nonatomic, assign) NSUInteger lineCount;

@property (nonatomic, assign) BOOL userPinnedTail;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) NSTimeInterval startedAt;
@property (nonatomic, copy, nullable) NSString *currentCommand;

@property (nonatomic, strong, nullable) NSTimer *flushTimer;
@property (nonatomic, strong, nullable) NSTimer *elapsedTimer;
@property (nonatomic, strong, nullable) NSTimer *fadeTimer;
@property (nonatomic, assign) BOOL pendingFlush;

// ── 内部方法（必须在此声明，ObjC 要先声明后使用）────
- (void)ensureWindow;
- (void)buildPanelIfNeeded;
- (void)applyPanelFrame;
- (void)resetBuffer;
- (void)trimIfNeeded;
- (NSAttributedString *)newlineAttr;
- (void)flushNow;
- (void)scrollToBottom;
- (void)setStatusDotColor:(UIColor *)color;
- (void)refreshChrome;
- (void)refreshLockButton;
- (UIFont *)monospacedFont;
- (void)showPanelAnimated:(BOOL)animated;
- (void)hidePanelAnimated:(BOOL)animated;
- (void)startTimers;
- (void)stopFlushTimer;
- (void)stopElapsedTimer;
- (void)stopTimers;
- (void)handlePan:(UIPanGestureRecognizer *)g;
- (void)handleDoubleTap:(UITapGestureRecognizer *)g;
- (void)toggleLock;
- (void)hideTapped;

@end

@implementation MinisLiveOverlay

+ (instancetype)shared {
    static MinisLiveOverlay *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [MinisLiveOverlay new]; });
    return inst;
}

+ (BOOL)isEnabled {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:kMTLEnabledKey];
    return v ? v.boolValue : YES;          // 默认开启
}

+ (void)setEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kMTLEnabledKey];
}

- (instancetype)init {
    if ((self = [super init])) {
        _buffer   = [NSMutableAttributedString new];
        _lineLens = [NSMutableArray new];
        _userPinnedTail = YES;
    }
    return self;
}

#pragma mark - 公开 API

- (void)beginCommand:(NSString *)executable arguments:(NSArray<NSString *> *)arguments {
    if (![MinisLiveOverlay isEnabled]) return;

    NSString *base = executable.lastPathComponent ?: (executable ?: @"command");
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (NSString *a in arguments ?: @[]) {
        if ([a isEqualToString:@"-c"]) continue;         // /bin/sh -c 噪音
        [args addObject:(a.length > 60 ? [a substringToIndex:60] : a)];
    }
    NSString *shown = [args componentsJoinedByString:@" "];
    if (shown.length > 160) shown = [[shown substringToIndex:160] stringByAppendingString:@"…"];

    self.currentCommand = shown.length ? [NSString stringWithFormat:@"%@ · %@", base, shown] : base;
    self.running   = YES;
    self.startedAt = [NSDate timeIntervalSinceReferenceDate];

    [self resetBuffer];
    [self ensureWindow];
    [self refreshChrome];
    [self startTimers];
    [self showPanelAnimated:YES];
}

- (void)appendLine:(NSString *)line isStdErr:(BOOL)isStdErr {
    if (!self.window) return;
    if (line == nil) line = @"";

    NSAttributedString *rich = MTLParseLine(line, isStdErr, [self monospacedFont]);
    [self.buffer appendAttributedString:rich];
    [self.buffer appendAttributedString:[self newlineAttr]];
    [self.lineLens addObject:@(rich.length + 1)];
    self.lineCount++;

    [self trimIfNeeded];
    self.pendingFlush = YES;

    if (!self.flushTimer) [self flushNow];
}

- (void)endCommandExitCode:(NSInteger)exitCode duration:(NSTimeInterval)duration {
    self.running = NO;
    [self stopFlushTimer];
    [self flushNow];

    BOOL ok = (exitCode == 0);
    self.metaLabel.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    self.metaLabel.text = [NSString stringWithFormat:@"%@ 退出 %ld · %.1fs",
                           ok ? @"✓" : @"✗", (long)exitCode, duration];
    [self stopElapsedTimer];
    [self setStatusDotColor:ok ? [UIColor systemGreenColor] : [UIColor systemRedColor]];

    NSNumber *lock = [[NSUserDefaults standardUserDefaults] objectForKey:kMTLLockKey];
    if (lock.boolValue) return;                          // 锁定常显

    [self.fadeTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.fadeTimer = [NSTimer scheduledTimerWithTimeInterval:kMTLFadeOut
                                                     repeats:NO
                                                       block:^(NSTimer *t) {
        __strong typeof(weakSelf) s = weakSelf;
        if (s && !s.running) [s hidePanelAnimated:YES];
    }];
}

- (void)dismiss {
    self.running = NO;
    [self stopTimers];
    [self hidePanelAnimated:NO];
}

#pragma mark - 缓冲管理

- (void)resetBuffer {
    self.buffer = [NSMutableAttributedString new];       // ← 换新对象（不是 setString:）
    [self.lineLens removeAllObjects];
    self.lineCount = 0;
    self.textView.attributedText = [self.buffer copy];
    self.userPinnedTail = YES;
}

- (NSAttributedString *)newlineAttr {
    return [[NSAttributedString alloc] initWithString:@"\n"
                                          attributes:@{ NSFontAttributeName: [self monospacedFont] }];
}

- (void)trimIfNeeded {
    if (self.lineCount <= kMTLMaxLines) return;
    NSUInteger drop = self.lineCount - kMTLMaxLines;
    NSUInteger chars = 0;
    for (NSUInteger i = 0; i < drop && i < self.lineLens.count; i++) {
        chars += self.lineLens[i].unsignedIntegerValue;
    }
    if (chars > 0 && chars <= self.buffer.length) {
        [self.buffer deleteCharactersInRange:NSMakeRange(0, chars)];
    }
    NSUInteger n = MIN(drop, self.lineLens.count);
    [self.lineLens removeObjectsInRange:NSMakeRange(0, n)];
    self.lineCount -= n;
}

#pragma mark - 刷新

- (void)flushNow {
    if (!self.pendingFlush) return;
    self.pendingFlush = NO;
    self.textView.attributedText = [self.buffer copy];
    if (self.userPinnedTail) [self scrollToBottom];
}

- (void)scrollToBottom {
    if (self.buffer.length == 0) return;
    [self.textView scrollRangeToVisible:NSMakeRange(self.buffer.length - 1, 1)];
}

- (void)setStatusDotColor:(UIColor *)color {
    self.statusDot.backgroundColor = color;
}

- (void)refreshChrome {
    self.titleLabel.text = self.currentCommand.length ? self.currentCommand : @"工具输出";
    if (self.running) {
        [self setStatusDotColor:[UIColor systemBlueColor]];
        if (!self.metaLabel.text.length) self.metaLabel.text = @"执行中…";
    }
}

- (UIFont *)monospacedFont {
    return [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
}

@end

#pragma mark - 面板构建与显示

@implementation MinisLiveOverlay (UI)

- (void)ensureWindow {
    if (self.window) return;

    MTLRootVC *vc = [MTLRootVC new];
    UIWindow *w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.rootViewController = vc;
    w.windowLevel = UIWindowLevelAlert - 1.0;      // 高于 App 内容，低于系统弹窗
    w.backgroundColor = UIColor.clearColor;
    w.hidden = YES;
    self.window = w;

    [self buildPanelIfNeeded];
    vc.panel = self.panel;
}

- (void)buildPanelIfNeeded {
    if (self.panel) return;

    // ── 面板容器 ──────────────────────────────────────────
    UIView *panel = [UIView new];
    panel.layer.cornerRadius = 14;
    panel.layer.cornerCurve  = kCACornerCurveContinuous;
    panel.layer.masksToBounds = NO;
    panel.layer.shadowColor  = UIColor.blackColor.CGColor;
    panel.layer.shadowOpacity = 0.28;
    panel.layer.shadowRadius  = 16;
    panel.layer.shadowOffset  = CGSizeMake(0, 6);
    self.panel = panel;

    // ── 毛玻璃底 ──────────────────────────────────────────
    UIVisualEffectView *blur =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.layer.cornerRadius = 14;
    blur.layer.cornerCurve  = kCACornerCurveContinuous;
    blur.clipsToBounds = YES;
    [panel addSubview:blur];
    self.blur = blur;

    // ── 顶栏要素 ──────────────────────────────────────────
    UIView *dot = [UIView new];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = [UIColor systemBlueColor];
    dot.layer.cornerRadius = 4;
    [panel addSubview:dot];
    self.statusDot = dot;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    title.textColor = UIColor.labelColor;
    title.lineBreakMode = NSLineBreakByTruncatingMiddle;
    title.userInteractionEnabled = YES;
    [panel addSubview:title];
    self.titleLabel = title;

    UILabel *meta = [UILabel new];
    meta.translatesAutoresizingMaskIntoConstraints = NO;
    meta.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    meta.textColor = UIColor.secondaryLabelColor;
    [panel addSubview:meta];
    self.metaLabel = meta;

    UIButton *lock = [UIButton buttonWithType:UIButtonTypeSystem];
    lock.translatesAutoresizingMaskIntoConstraints = NO;
    [lock setImage:[UIImage systemImageNamed:@"pin"] forState:UIControlStateNormal];
    lock.tintColor = UIColor.secondaryLabelColor;
    [lock addTarget:self action:@selector(toggleLock) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:lock];
    self.lockButton = lock;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = UIColor.tertiaryLabelColor;
    [close addTarget:self action:@selector(hideTapped) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    // ── 输出区 ───────────────────────────────────────────
    UITextView *tv = [UITextView new];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.backgroundColor = UIColor.clearColor;
    tv.editable = NO;
    tv.selectable = YES;
    tv.textContainerInset = UIEdgeInsetsMake(6, 8, 6, 8);
    tv.textContainer.lineFragmentPadding = 0;
    tv.showsVerticalScrollIndicator = YES;
    tv.delegate = self;                              // 扩展已声明 UITextViewDelegate
    [panel addSubview:tv];
    self.textView = tv;

    // ── 约束 ─────────────────────────────────────────────
    [NSLayoutConstraint activateConstraints:@[
        [blur.topAnchor      constraintEqualToAnchor:panel.topAnchor],
        [blur.bottomAnchor   constraintEqualToAnchor:panel.bottomAnchor],
        [blur.leadingAnchor  constraintEqualToAnchor:panel.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],

        [dot.leadingAnchor    constraintEqualToAnchor:panel.leadingAnchor constant:12],
        [dot.topAnchor        constraintEqualToAnchor:panel.topAnchor constant:13],
        [dot.widthAnchor      constraintEqualToConstant:8],
        [dot.heightAnchor     constraintEqualToConstant:8],

        [title.leadingAnchor  constraintEqualToAnchor:dot.trailingAnchor constant:8],
        [title.topAnchor      constraintEqualToAnchor:panel.topAnchor constant:9],

        [meta.leadingAnchor   constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8],
        [meta.trailingAnchor  constraintLessThanOrEqualToAnchor:lock.leadingAnchor constant:-6],
        [meta.centerYAnchor   constraintEqualToAnchor:title.centerYAnchor],

        [lock.trailingAnchor  constraintEqualToAnchor:close.leadingAnchor constant:-4],
        [lock.centerYAnchor   constraintEqualToAnchor:title.centerYAnchor],
        [lock.widthAnchor     constraintEqualToConstant:26],
        [lock.heightAnchor    constraintEqualToConstant:26],

        [close.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-10],
        [close.centerYAnchor  constraintEqualToAnchor:title.centerYAnchor],
        [close.widthAnchor    constraintEqualToConstant:26],
        [close.heightAnchor   constraintEqualToConstant:26],

        [tv.topAnchor         constraintEqualToAnchor:title.bottomAnchor constant:4],
        [tv.leadingAnchor     constraintEqualToAnchor:panel.leadingAnchor],
        [tv.trailingAnchor    constraintEqualToAnchor:panel.trailingAnchor],
        [tv.bottomAnchor      constraintEqualToAnchor:panel.bottomAnchor constant:-6],
    ]];

    // ── 手势 ─────────────────────────────────────────────
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [title addGestureRecognizer:pan];

    UITapGestureRecognizer *dbl =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    dbl.numberOfTapsRequired = 2;
    [title addGestureRecognizer:dbl];

    // 顶栏细分隔线
    UIView *sep = [UIView new];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.backgroundColor = [UIColor.separatorColor colorWithAlphaComponent:0.5];
    [panel addSubview:sep];
    [NSLayoutConstraint activateConstraints:@[
        [sep.topAnchor      constraintEqualToAnchor:title.bottomAnchor constant:4],
        [sep.leadingAnchor  constraintEqualToAnchor:panel.leadingAnchor constant:10],
        [sep.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-10],
        [sep.heightAnchor   constraintEqualToConstant:0.5],
    ]];
}

- (void)applyPanelFrame {
    CGSize scr = UIScreen.mainScreen.bounds.size;
    CGFloat w = scr.width - 24;
    CGFloat h = self.expanded ? scr.height * 0.55 : 190;

    NSNumber *savedY = [[NSUserDefaults standardUserDefaults] objectForKey:kMTLFrameKey];
    CGFloat y = savedY ? savedY.doubleValue : (scr.height - h - 170);
    y = MAX(60, MIN(y, scr.height - h - 40));

    self.panel.frame = CGRectMake(12, y, w, h);
}

#pragma mark 交互

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.window];
    CGRect f = self.panel.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    self.panel.frame = f;
    [g setTranslation:CGPointZero inView:self.window];

    if (g.state == UIGestureRecognizerStateEnded) {
        CGSize scr = UIScreen.mainScreen.bounds.size;
        CGRect c = self.panel.frame;
        c.origin.x = MAX(4, MIN(c.origin.x, scr.width - c.size.width - 4));
        c.origin.y = MAX(40, MIN(c.origin.y, scr.height - c.size.height - 20));
        self.panel.frame = c;
        [[NSUserDefaults standardUserDefaults] setDouble:c.origin.y forKey:kMTLFrameKey];
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    self.expanded = !self.expanded;
    [UIView animateWithDuration:0.22
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ [self applyPanelFrame]; }
                     completion:nil];
}

- (void)toggleLock {
    BOOL now = ![[NSUserDefaults standardUserDefaults] boolForKey:kMTLLockKey];
    [[NSUserDefaults standardUserDefaults] setBool:now forKey:kMTLLockKey];
    [self refreshLockButton];
    if (now) { [self.fadeTimer invalidate]; self.fadeTimer = nil; }
}

- (void)refreshLockButton {
    BOOL on = [[NSUserDefaults standardUserDefaults] boolForKey:kMTLLockKey];
    self.lockButton.tintColor = on ? [UIColor systemOrangeColor] : UIColor.secondaryLabelColor;
}

- (void)hideTapped {
    [self hidePanelAnimated:YES];
}

#pragma mark 显示/隐藏

- (void)showPanelAnimated:(BOOL)animated {
    [self applyPanelFrame];
    [self refreshLockButton];
    self.window.hidden = NO;

    if (!animated) {
        self.panel.alpha = 1.0;
        self.panel.transform = CGAffineTransformIdentity;
        return;
    }
    self.panel.alpha = 0.0;
    self.panel.transform = CGAffineTransformMakeTranslation(0, 14);
    [UIView animateWithDuration:0.24
                          delay:0
         usingSpringWithDamping:0.9
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.panel.alpha = 1.0;
        self.panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)hidePanelAnimated:(BOOL)animated {
    [self stopTimers];
    if (!animated) { self.window.hidden = YES; return; }
    [UIView animateWithDuration:0.2 animations:^{
        self.panel.alpha = 0.0;
        self.panel.transform = CGAffineTransformMakeTranslation(0, 10);
    } completion:^(BOOL done) {
        self.window.hidden = YES;
    }];
}

#pragma mark 计时器

- (void)startTimers {
    [self stopTimers];
    __weak typeof(self) weakSelf = self;

    self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:kMTLFlushGap
                                                     repeats:YES
                                                       block:^(NSTimer *t) {
        __strong typeof(weakSelf) s = weakSelf;
        [s flushNow];
    }];

    self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       repeats:YES
                                                         block:^(NSTimer *t) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s.running) return;
        NSTimeInterval el = [NSDate timeIntervalSinceReferenceDate] - s.startedAt;
        s.metaLabel.text = [NSString stringWithFormat:@"执行中 · %.0fs", el];
    }];
}

- (void)stopFlushTimer   { [self.flushTimer invalidate];   self.flushTimer = nil; }
- (void)stopElapsedTimer { [self.elapsedTimer invalidate]; self.elapsedTimer = nil; }

- (void)stopTimers {
    [self stopFlushTimer];
    [self stopElapsedTimer];
    [self.fadeTimer invalidate]; self.fadeTimer = nil;
}

#pragma mark UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)sv {
    CGFloat gap = sv.contentSize.height - sv.contentOffset.y - sv.bounds.size.height;
    self.userPinnedTail = (gap < 24.0);
}

@end
