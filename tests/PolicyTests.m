#import "Policy.h"
static void check(BOOL ok,const char*name){if(!ok){fprintf(stderr,"FAIL: %s\n",name);exit(1);}}
int main(){@autoreleasepool{
check(BBInterval(nil)==3600,"one hour default");check(BBInterval(@5400)==3600,"only offered intervals accepted");check(BBInterval(@300)==300&&BBInterval(@1800)==1800&&BBInterval(@7200)==7200&&BBInterval(@10800)==10800,"all other offered intervals accepted");
check(!BBQueryDue(1000,1299,300,NO,NO)&&BBQueryDue(1000,1300,300,NO,NO),"five minute updates begin at 300 seconds");
check(BBReadingFresh(1000,8000,7200),"two hour sample remains visible between reports");check(!BBReadingFresh(1000,11981,10800),"stale sample disappears after three hour period plus grace");check(!BBReadingFresh(1000,999,3600),"clock rollback cannot make old reading fresh");
check(!BBQueryDue(1000,2799,1800,NO,NO),"no early periodic hardware query");check(BBQueryDue(1000,2800,1800,NO,NO),"query at selected boundary");check(BBQueryDue(1000,1001,10800,YES,NO),"manual refresh overrides long interval");check(BBQueryDue(1000,1001,10800,NO,YES),"hotplug discovery overrides interval");check(BBQueryDue(1000,999,3600,NO,NO),"clock rollback requests fresh sample");check(BBQueryDue(1000,3000,1800,NO,NO)&&!BBQueryDue(1000,3000,3600,NO,NO),"shortening interval respects elapsed time");
printf("PASS: 12 schedule and freshness checks\n");}}
