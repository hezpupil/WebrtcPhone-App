#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// getStats 的 ObjC 直调桥。
///
/// 背景：Swift 侧调用 pc.statistics 曾反复崩溃——第一轮是 Swift 编译器为
/// Double→Int 转换插桩的 brk（SIGTRAP）；第二轮是回调字典的泛型声明与运行时
/// 内容不符导致 swift_dynamicCast 强制桥接 abort（SIGABRT）。
/// 本桥从结构上消除跨 ObjC/Swift 边界的字典桥接：
/// 1. 通过 objc_msgSend 运行时调用 statisticsWithCompletionHandler:，不 import
///    WebRTC 头文件；
/// 2. 报告在 ObjC 内压平成【字符串记录数组】，每条 = "statId\x1Ftype\x1Fkey\x1Fvalue"；
/// 3. completion 参数为无泛型 NSArray —— Swift 侧拿到 [Any]，全部用条件转换
///    （as? String）解析，任何元素类型不符都不会触发强制桥接 abort。
@interface LegacyStatsBridge : NSObject

/// 拉取统计报告。
/// @param peerConnection RTCPeerConnection 实例（以 id 传入，避免头文件依赖）
/// @param records 扁平记录数组，元素为 "statId\x1Ftype\x1Fkey\x1Fvalue" 字符串，
///                在后台队列回调；失败/不可用时回传空数组。
+ (void)collect:(id)peerConnection
     completion:(void (^)(NSArray *records))completion;

@end

NS_ASSUME_NONNULL_END
