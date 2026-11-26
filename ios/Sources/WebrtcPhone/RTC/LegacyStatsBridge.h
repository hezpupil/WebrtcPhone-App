#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// getStats 的 ObjC 直调桥。
///
/// 背景：Swift 侧调用 pc.statistics { report in ... } 曾反复 SIGTRAP——trap 是
/// Swift 编译器为 Double→Int 转换 / 桥接插桩的 brk（extractVideo+1576 处反汇编
/// 确认），数值防御无法根除。本桥从结构上消灭该崩溃类：
/// 1. 通过 objc_msgSend 运行时调用 statisticsWithCompletionHandler:，不 import
///    WebRTC 头文件，不产生任何编译期类型依赖；
/// 2. 报告在 ObjC 内逐字段转成【纯字符串】字典（NSNumber.stringValue /
///    NSString 原样），全程无 Double→Int 转换、无 Swift 桥接插桩；
/// 3. 转换包裹在 @try 中，异常时返回空报告走降级。
@interface LegacyStatsBridge : NSObject

/// 拉取统计报告。
/// @param peerConnection RTCPeerConnection 实例（以 id 传入，避免头文件依赖）
/// @param completion 纯字符串报告：statsId -> { "type": ..., "values": {k: v} }
///                   在后台队列回调；失败/不可用时回传空字典。
+ (void)collect:(id)peerConnection
     completion:(void (^)(NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *stats))completion;

@end

NS_ASSUME_NONNULL_END
