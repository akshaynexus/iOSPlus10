/* XNUtils' one screen (main.m: live data and controls; list.m: the rows). */
#import <UIKit/UIKit.h>
#import "stream.h"

#define NUM_ACTIONS 7

@interface ViewController : UITableViewController <XTStreamDelegate>
@property (strong, nonatomic) XTStream *stream;
@property (strong, nonatomic) NSTimer *timer;
@property (strong, nonatomic) NSArray<XTSection *> *sections;
@property (strong, nonatomic) NSMutableSet<NSString *> *open;
@property (strong, nonatomic) UISegmentedControl *metal;
@property (strong, nonatomic) UISwitch *gl;
@property (strong, nonatomic) UITableViewCell *metalCell;
@property (copy, nonatomic) NSString *note;
- (void)action:(NSInteger)n;
@end

@interface ViewController (List)
@end

