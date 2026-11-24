#import "Policy.h"
NSTimeInterval BBInterval(id value){
    if(![value isKindOfClass:NSNumber.class])return 3600;
    NSTimeInterval n=[value doubleValue];return (n==300||n==1800||n==3600||n==7200||n==10800)?n:3600;
}
BOOL BBReadingFresh(NSTimeInterval sample,NSTimeInterval now,NSTimeInterval interval){
    return sample>0&&sample<=now&&now-sample<=BBInterval(@(interval))+180;
}
BOOL BBQueryDue(NSTimeInterval previous,NSTimeInterval now,NSTimeInterval interval,BOOL forced,BOOL newReceiver){
    return forced||newReceiver||previous<=0||now<previous||now-previous>=BBInterval(@(interval));
}
NSString *BBIntervalLabel(NSTimeInterval interval){
    switch((int)BBInterval(@(interval))){case 300:return @"5 分钟";case 1800:return @"30 分钟";case 7200:return @"2 小时";case 10800:return @"3 小时";default:return @"1 小时";}
}
