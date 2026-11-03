// Original UIKit smoke guest for iContainer; no third-party application/data.
#import <UIKit/UIKit.h>
@interface DemoDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation DemoDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc=[UIViewController new];vc.view.backgroundColor=UIColor.systemBackgroundColor;
    NSString *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
    NSString *file=[documents stringByAppendingPathComponent:@"demo-visits.txt"];
    NSInteger visits=[[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] integerValue]+1;
    [[NSString stringWithFormat:@"%ld",(long)visits] writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    UILabel *label=[[UILabel alloc] initWithFrame:CGRectInset(vc.view.bounds,28,140)];label.numberOfLines=0;label.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    label.text=[NSString stringWithFormat:@"iContainer Demo\n\nApp khách đã chạy.\n\nBundle: %@\n\nSố lần mở: %ld\n\nDữ liệu: %@\n\nĐóng và mở lại app để kiểm tra dữ liệu được giữ. Dùng nút ↩ iContainer để về danh sách.",NSBundle.mainBundle.bundleIdentifier,(long)visits,documents];
    [vc.view addSubview:label];self.window.rootViewController=vc;[self.window makeKeyAndVisible];return YES;
}
@end
int main(int argc,char**argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(DemoDelegate.class));}}
