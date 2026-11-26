#import "LegacyStatsBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>

// 最小接口声明：与 WebRTC.framework 的 ObjC 类同名（仅声明、不实现，不参与链接）。
// 字段类型与官方 sdk/objc/api/peerconnection/RTCStatisticsReport.h 一致。
// 官方头里 statistics / values 均为无泛型 NSDictionary。
@interface RTCStatisticsReport : NSObject
@property (nonatomic, readonly) NSDictionary *statistics;
@end

@interface RTCStatistics : NSObject
@property (nonatomic, readonly) NSString *id;
@property (nonatomic, readonly) NSString *type;
@property (nonatomic, readonly) NSDictionary *values;
@end

@implementation LegacyStatsBridge

+ (void)collect:(id)peerConnection
     completion:(void (^)(NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *stats))completion {
    if (!peerConnection || !completion) {
        if (completion) completion(@{});
        return;
    }
    SEL sel = NSSelectorFromString(@"statisticsWithCompletionHandler:");
    if (![peerConnection respondsToSelector:sel]) {
        completion(@{});
        return;
    }

    void (^block)(RTCStatisticsReport *) = ^(RTCStatisticsReport *report) {
        NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *out =
            [NSMutableDictionary dictionary];
        @try {
            NSDictionary *stats = report.statistics;
            for (id keyObj in stats) {
                // 键必须是 NSString，否则进入 Swift 桥接 [String: ...] 会有转换风险
                if (![keyObj isKindOfClass:[NSString class]]) continue;
                NSString *key = keyObj;
                id st = stats[key];
                if (![st isKindOfClass:[RTCStatistics class]]) continue;
                RTCStatistics *stat = st;
                NSMutableDictionary<NSString *, NSString *> *vv =
                    [NSMutableDictionary dictionary];
                NSDictionary *values = stat.values;
                if (values) {
                    for (id vkObj in values) {
                        if (![vkObj isKindOfClass:[NSString class]]) continue;
                        NSString *vk = vkObj;
                        id v = values[vk];
                        NSString *s = nil;
                        if ([v isKindOfClass:[NSString class]]) {
                            s = v;
                        } else if ([v isKindOfClass:[NSNumber class]]) {
                            // 统一走 stringValue：不做任何数值转换语义
                            s = [(NSNumber *)v stringValue];
                        } else if ([v isKindOfClass:[NSArray class]]) {
                            s = [v description];
                        } else if ([v isKindOfClass:[NSDictionary class]]) {
                            s = [v description];
                        }
                        if (s.length > 0) vv[vk] = s;
                    }
                }
                NSString *type = stat.type ?: @"";
                out[key] = @{@"type": type, @"values": [vv copy]};
            }
        } @catch (NSException *exception) {
            // 转换异常：返回已转换的部分（或空），调用方降级
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            completion(out);
        });
    };

    // 运行时直调，绕开编译期类型系统（对应官方 statisticsWithCompletionHandler:）
    void (*msgSend)(id, SEL, void (^)(RTCStatisticsReport *)) =
        (void (*)(id, SEL, void (^)(RTCStatisticsReport *)))objc_msgSend;
    msgSend(peerConnection, sel, block);
}

@end
