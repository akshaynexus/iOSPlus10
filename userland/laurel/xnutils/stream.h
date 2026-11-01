/* The helper as a stream of reports, and the one-shot verbs (stream.m). */
#import <Foundation/Foundation.h>

@interface XTRow : NSObject
@property (copy, nonatomic) NSString *key, *value;
@property (nonatomic) NSInteger age;            /* seconds since the kernel saw the line; -1 = read now */
@end

@interface XTSection : NSObject
@property (copy, nonatomic) NSString *title, *state, *reason;
@property (strong, nonatomic) NSMutableArray<XTRow *> *rows;
- (NSString *)value:(NSString *)key;
@end

@class XTStream;
@protocol XTStreamDelegate
/* both on the main queue */
- (void)stream:(XTStream *)stream gotSections:(NSArray<XTSection *> *)sections;
- (void)stream:(XTStream *)stream failed:(NSString *)why;
@end

@interface XTStream : NSObject
- (instancetype)initWithDelegate:(id<XTStreamDelegate>)delegate;
- (void)start;
- (void)ask;                    /* one report; no effect while one is on its way */
- (void)stop;                   /* closes the helper's stdin: it ends. No more calls to the delegate */
@end

/* VERB [ARG]: the exit code (or -errno when it did not start), stdout + stderr in *text */
int xt_run_helper(NSString *verb, NSString *arg, NSString **text);
NSString *xt_exit_text(int rc, NSString *text);
NSString *xt_report_text(NSArray<XTSection *> *sections);
