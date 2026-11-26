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
// 时间戳是独立属性（微秒 double），不在 values 字典里——漏掉它会导致
// Swift 侧差分永远没有 dt，码率/解码/抖动缓冲/丢包全部恒 0
@property (nonatomic, readonly) double timestampUs;
@property (nonatomic, readonly) NSDictionary *values;
@end

// 记录分隔符：ASCII 31（Unit Separator），统计键值不会包含该控制字符
static NSString * const kRecordSep = @"\x1F";

@implementation LegacyStatsBridge

+ (void)collect:(id)peerConnection
     completion:(void (^)(NSArray *records))completion {
    if (!peerConnection || !completion) {
        if (completion) completion(@[]);
        return;
    }
    SEL sel = NSSelectorFromString(@"statisticsWithCompletionHandler:");
    if (![peerConnection respondsToSelector:sel]) {
        completion(@[]);
        return;
    }

    void (^block)(RTCStatisticsReport *) = ^(RTCStatisticsReport *report) {
        // 压平为字符串记录数组（无任何嵌套容器跨界，见头文件注释）
        NSMutableArray<NSString *> *records = [NSMutableArray array];
        @try {
            NSDictionary *stats = report.statistics;
            for (id keyObj in stats) {
                if (![keyObj isKindOfClass:[NSString class]]) continue;
                NSString *statId = keyObj;
                id st = stats[statId];
                if (![st isKindOfClass:[RTCStatistics class]]) continue;
                RTCStatistics *stat = st;
                NSString *type = stat.type ?: @"";
                // timestampUs：独立属性，压平为 timestamp_us 键
                [records addObject:[NSString stringWithFormat:
                    @"%@%@%@%@timestamp_us%@%.0f",
                    statId, kRecordSep, type, kRecordSep, kRecordSep, stat.timestampUs]];
                NSDictionary *values = stat.values;
                if (!values) continue;
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
                    }
                    // 其他容器类型（数组/字典）直接跳过：统计所需字段均为标量
                    if (s.length == 0) continue;
                    [records addObject:[NSString stringWithFormat:
                        @"%@%@%@%@%@%@",
                        statId, kRecordSep, type, kRecordSep, vk, s]];
                }
            }
        } @catch (NSException *exception) {
            // 转换异常：返回已转换的部分（或空），调用方降级
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            completion(records);
        });
    };

    // 运行时直调，绕开编译期类型系统（对应官方 statisticsWithCompletionHandler:）
    void (*msgSend)(id, SEL, void (^)(RTCStatisticsReport *)) =
        (void (*)(id, SEL, void (^)(RTCStatisticsReport *)))objc_msgSend;
    msgSend(peerConnection, sel, block);
}

@end
