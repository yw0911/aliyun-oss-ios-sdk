// Software License Agreement (BSD License)
//
// Copyright (c) 2010-2016, Deusty, LLC
// All rights reserved.
//
// Redistribution and use of this software in source and binary forms,
// with or without modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice,
//   this list of conditions and the following disclaimer.
//
// * Neither the name of Deusty nor the names of its contributors may be used
//   to endorse or promote products derived from this software without specific
//   prior written permission of Deusty, LLC.

// Disable legacy macros
#ifndef OSSDD_LEGACY_MACROS
    #define OSSDD_LEGACY_MACROS 0
#endif

#import "OSSDDLog.h"

#import <pthread.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <mach/mach_host.h>
#import <mach/host_info.h>
#import <libkern/OSAtomic.h>
#import <Availability.h>
#if TARGET_OS_IOS
    #import <UIKit/UIDevice.h>
#endif


#if !__has_feature(objc_arc)
#error This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

// We probably shouldn't be using DDLog() statements within the DDLog implementation.
// But we still want to leave our log statements for any future debugging,
// and to allow other developers to trace the implementation (which is a great learning tool).
//
// So we use a primitive logging macro around NSLog.
// We maintain the NS prefix on the macros to be explicit about the fact that we're using NSLog.

#ifndef OSSDD_DEBUG
    #define OSSDD_DEBUG NO
#endif

#define OSSNSLogDebug(frmt, ...) do{ if(OSSDD_DEBUG) NSLog((frmt), ##__VA_ARGS__); } while(0)

// Specifies the maximum queue size of the logging thread.
//
// Since most logging is asynchronous, its possible for rogue threads to flood the logging queue.
// That is, to issue an abundance of log statements faster than the logging thread can keepup.
// Typically such a scenario occurs when log statements are added haphazardly within large loops,
// but may also be possible if relatively slow loggers are being used.
//
// This property caps the queue size at a given number of outstanding log statements.
// If a thread attempts to issue a log statement when the queue is already maxed out,
// the issuing thread will block until the queue size drops below the max again.

#ifndef OSSDDLOG_MAX_QUEUE_SIZE
    #define OSSDDLOG_MAX_QUEUE_SIZE 1000 // Should not exceed INT32_MAX
#endif

// The "global logging queue" refers to [DDLog loggingQueue].
// It is the queue that all log statements go through.
//
// The logging queue sets a flag via dispatch_queue_set_specific using this key.
// We can check for this key via dispatch_get_specific() to see if we're on the "global logging queue".

static void *const GlobalLoggingQueueIdentityKey = (void *)&GlobalLoggingQueueIdentityKey;

@interface OSSLoggerNode : NSObject
{
    // Direct accessors to be used only for performance
    @public
    id <OSSDDLogger> _logger;
    OSSDDLogLevel _level;
    dispatch_queue_t _loggerQueue;
}

@property (nonatomic, readonly) id <OSSDDLogger> logger;
@property (nonatomic, readonly) OSSDDLogLevel level;
@property (nonatomic, readonly) dispatch_queue_t loggerQueue;

+ (OSSLoggerNode *)nodeWithLogger:(id <OSSDDLogger>)logger
                     loggerQueue:(dispatch_queue_t)loggerQueue
                           level:(OSSDDLogLevel)level;

@end


////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface OSSDDLog ()

// An array used to manage all the individual loggers.
// The array is only modified on the loggingQueue/loggingThread.
@property (nonatomic, strong) NSMutableArray *_loggers;

@end

@implementation OSSDDLog

// All logging statements are added to the same queue to ensure FIFO operation.
static dispatch_queue_t _loggingQueue;

// Individual loggers are executed concurrently per log statement.
// Each logger has it's own associated queue, and a dispatch group is used for synchrnoization.
static dispatch_group_t _loggingGroup;

// In order to prevent to queue from growing infinitely large,
// a maximum size is enforced (DDLOG_MAX_QUEUE_SIZE).
static dispatch_semaphore_t _queueSemaphore;

// Minor optimization for uniprocessor machines
static NSUInteger _numProcessors;

/**
 *  Returns the singleton `DDLog`.
 *  The instance is used by `DDLog` class methods.
 *
 *  @return The singleton `DDLog`.
 */
+ (instancetype)sharedInstance {
    static id sharedInstance = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    
    return sharedInstance;
}

/**
 * The runtime sends initialize to each class in a program exactly one time just before the class,
 * or any class that inherits from it, is sent its first message from within the program. (Thus the
 * method may never be invoked if the class is not used.) The runtime sends the initialize message to
 * classes in a thread-safe manner. Superclasses receive this message before their subclasses.
 *
 * This method may also be called directly (assumably by accident), hence the safety mechanism.
 **/
+ (void)initialize {
    static dispatch_once_t OSSDDLogOnceToken;
    
    dispatch_once(&OSSDDLogOnceToken, ^{
        OSSNSLogDebug(@"OSSDDLog: Using grand central dispatch");
        
        _loggingQueue = dispatch_queue_create("oss.cocoa.lumberjack", NULL);
        _loggingGroup = dispatch_group_create();
        
        void *nonNullValue = GlobalLoggingQueueIdentityKey; // Whatever, just not null
        dispatch_queue_set_specific(_loggingQueue, GlobalLoggingQueueIdentityKey, nonNullValue, NULL);
        
        _queueSemaphore = dispatch_semaphore_create(OSSDDLOG_MAX_QUEUE_SIZE);
        
        // Figure out how many processors are available.
        // This may be used later for an optimization on uniprocessor machines.
        
        _numProcessors = MAX([NSProcessInfo processInfo].processorCount, (NSUInteger) 1);
        
        OSSNSLogDebug(@"DDLog: numProcessors = %@", @(_numProcessors));
    });
}

/**
 *  The `DDLog` initializer.
 *  Static variables are set only once.
 *
 *  @return An initialized `DDLog` instance.
 */
- (id)init {
    self = [super init];
    
    if (self) {
        self._loggers = [[NSMutableArray alloc] initWithCapacity:4];
        
#if TARGET_OS_IOS
        NSString *notificationName = @"UIApplicationWillTerminateNotification";
#else
        NSString *notificationName = nil;
        
        // On Command Line Tool apps AppKit may not be avaliable
#ifdef NSAppKitVersionNumber10_0
        
        if (NSApp) {
            notificationName = @"NSApplicationWillTerminateNotification";
        }
        
#endif
        
        if (!notificationName) {
            // If there is no NSApp -> we are running Command Line Tool app.
            // In this case terminate notification wouldn't be fired, so we use workaround.
            atexit_b (^{
                [self applicationWillTerminate:nil];
            });
        }
        
#endif /* if TARGET_OS_IOS */
        
        if (notificationName) {
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(applicationWillTerminate:)
                                                         name:notificationName
                                                       object:nil];
        }
    }
    
    return self;
}

/**
 * Provides access to the logging queue.
 **/
+ (dispatch_queue_t)loggingQueue {
    return _loggingQueue;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Notifications
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)applicationWillTerminate:(NSNotification * __attribute__((unused)))notification {
    [self flushLog];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Logger Management
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

+ (void)addLogger:(id <OSSDDLogger>)logger {
    [self.sharedInstance addLogger:logger];
}

- (void)addLogger:(id <OSSDDLogger>)logger {
    [self addLogger:logger withLevel:OSSDDLogLevelAll]; // DDLogLevelAll has all bits set
}

+ (void)addLogger:(id <OSSDDLogger>)logger withLevel:(OSSDDLogLevel)level {
    [self.sharedInstance addLogger:logger withLevel:level];
}

- (void)addLogger:(id <OSSDDLogger>)logger withLevel:(OSSDDLogLevel)level {
    if (!logger) {
        return;
    }
    
    dispatch_async(_loggingQueue, ^{ @autoreleasepool {
        [self lt_addLogger:logger level:level];
    } });
}

+ (void)removeLogger:(id <OSSDDLogger>)logger {
    [self.sharedInstance removeLogger:logger];
}

- (void)removeLogger:(id <OSSDDLogger>)logger {
    if (!logger) {
        return;
    }
    
    dispatch_async(_loggingQueue, ^{ @autoreleasepool {
        [self lt_removeLogger:logger];
    } });
}

+ (void)removeAllLoggers {
    [self.sharedInstance removeAllLoggers];
}

- (void)removeAllLoggers {
    dispatch_async(_loggingQueue, ^{ @autoreleasepool {
        [self lt_removeAllLoggers];
    } });
}

+ (NSArray<id<OSSDDLogger>> *)allLoggers {
    return [self.sharedInstance allLoggers];
}

- (NSArray<id<OSSDDLogger>> *)allLoggers {
    __block NSArray *theLoggers;
    
    dispatch_sync(_loggingQueue, ^{ @autoreleasepool {
        theLoggers = [self lt_allLoggers];
    } });
    
    return theLoggers;
}

+ (NSArray<OSSDDLoggerInformation *> *)allLoggersWithLevel {
    return [self.sharedInstance allLoggersWithLevel];
}

- (NSArray<OSSDDLoggerInformation *> *)allLoggersWithLevel {
    __block NSArray *theLoggersWithLevel;
    
    dispatch_sync(_loggingQueue, ^{ @autoreleasepool {
        theLoggersWithLevel = [self lt_allLoggersWithLevel];
    } });
    
    return theLoggersWithLevel;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Master Logging
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)queueLogMessage:(OSSDDLogMessage *)logMessage asynchronously:(BOOL)asyncFlag {
    // We have a tricky situation here...
    //
    // In the common case, when the queueSize is below the maximumQueueSize,
    // we want to simply enqueue the logMessage. And we want to do this as fast as possible,
    // which means we don't want to block and we don't want to use any locks.
    //
    // However, if the queueSize gets too big, we want to block.
    // But we have very strict requirements as to when we block, and how long we block.
    //
    // The following example should help illustrate our requirements:
    //
    // Imagine that the maximum queue size is configured to be 5,
    // and that there are already 5 log messages queued.
    // Let us call these 5 queued log messages A, B, C, D, and E. (A is next to be executed)
    //
    // Now if our thread issues a log statement (let us call the log message F),
    // it should block before the message is added to the queue.
    // Furthermore, it should be unblocked immediately after A has been unqueued.
    //
    // The requirements are strict in this manner so that we block only as long as necessary,
    // and so that blocked threads are unblocked in the order in which they were blocked.
    //
    // Returning to our previous example, let us assume that log messages A through E are still queued.
    // Our aforementioned thread is blocked attempting to queue log message F.
    // Now assume we have another separate thread that attempts to issue log message G.
    // It should block until log messages A and B have been unqueued.


    // We are using a counting semaphore provided by GCD.
    // The semaphore is initialized with our DDLOG_MAX_QUEUE_SIZE value.
    // Everytime we want to queue a log message we decrement this value.
    // If the resulting value is less than zero,
    // the semaphore function waits in FIFO order for a signal to occur before returning.
    //
    // A dispatch semaphore is an efficient implementation of a traditional counting semaphore.
    // Dispatch semaphores call down to the kernel only when the calling thread needs to be blocked.
    // If the calling semaphore does not need to block, no kernel call is made.

    dispatch_semaphore_wait(_queueSemaphore, DISPATCH_TIME_FOREVER);

    // We've now sure we won't overflow the queue.
    // It is time to queue our log message.

    dispatch_block_t logBlock = ^{
        @autoreleasepool {
            [self lt_log:logMessage];
        }
    };

    if (asyncFlag) {
        dispatch_async(_loggingQueue, logBlock);
    } else {
        dispatch_sync(_loggingQueue, logBlock);
    }
}

+ (void)log:(BOOL)asynchronous
      level:(OSSDDLogLevel)level
       flag:(OSSDDLogFlag)flag
    context:(NSInteger)context
       file:(const char *)file
   function:(const char *)function
       line:(NSUInteger)line
        tag:(id)tag
     format:(NSString *)format, ... {
    va_list args;
    
    if (format) {
        va_start(args, format);
        
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        
        va_end(args);
        
        va_start(args, format);
        
        [self log:asynchronous
          message:message
            level:level
             flag:flag
          context:context
             file:file
         function:function
             line:line
              tag:tag];
        
        va_end(args);
    }
}

- (void)log:(BOOL)asynchronous
      level:(OSSDDLogLevel)level
       flag:(OSSDDLogFlag)flag
    context:(NSInteger)context
       file:(const char *)file
   function:(const char *)function
       line:(NSUInteger)line
        tag:(id)tag
     format:(NSString *)format, ... {
    va_list args;
    
    if (format) {
        va_start(args, format);
        
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        
        va_end(args);
        
        va_start(args, format);
        
        [self log:asynchronous
          message:message
            level:level
             flag:flag
          context:context
             file:file
         function:function
             line:line
              tag:tag];
        
        va_end(args);
    }
}

+ (void)log:(BOOL)asynchronous
    message:(NSString *)message
      level:(OSSDDLogLevel)level
       flag:(OSSDDLogFlag)flag
    context:(NSInteger)context
       file:(const char *)file
   function:(const char *)function
       line:(NSUInteger)line
        tag:(id)tag {
    [self.sharedInstance log:asynchronous message:message level:level flag:flag context:context file:file function:function line:line tag:tag];
}

- (void)log:(BOOL)asynchronous
    message:(NSString *)message
      level:(OSSDDLogLevel)level
       flag:(OSSDDLogFlag)flag
    context:(NSInteger)context
       file:(const char *)file
   function:(const char *)function
       line:(NSUInteger)line
        tag:(id)tag {
    OSSDDLogMessage *logMessage = [[OSSDDLogMessage alloc] initWithMessage:message
                                                               level:level
                                                                flag:flag
                                                             context:context
                                                                file:[NSString stringWithFormat:@"%s", file]
                                                            function:[NSString stringWithFormat:@"%s", function]
                                                                line:line
                                                                 tag:tag
                                                             options:(OSSDDLogMessageOptions)0
                                                           timestamp:nil];
    
    [self queueLogMessage:logMessage asynchronously:asynchronous];
}

- (void)flushLog {
    dispatch_sync(_loggingQueue, ^{ @autoreleasepool {
        [self lt_flush];
    } });
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Logging Thread
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)lt_addLogger:(id <OSSDDLogger>)logger level:(OSSDDLogLevel)level {
    // Add to loggers array.
    // Need to create loggerQueue if loggerNode doesn't provide one.

    for (OSSLoggerNode* node in self._loggers) {
        if (node->_logger == logger
            && node->_level == level) {
            // Exactly same logger already added, exit
            return;
        }
    }

    NSAssert(dispatch_get_specific(GlobalLoggingQueueIdentityKey),
             @"This method should only be run on the logging thread/queue");

    dispatch_queue_t loggerQueue = NULL;

    if ([logger respondsToSelector:@selector(loggerQueue)]) {
        // Logger may be providing its own queue

        loggerQueue = [logger loggerQueue];
    }

    if (loggerQueue == nil) {
        // Automatically create queue for the logger.
        // Use the logger name as the queue name if possible.

        const char *loggerQueueName = NULL;

        if ([logger respondsToSelector:@selector(loggerName)]) {
            loggerQueueName = [[logger loggerName] UTF8String];
        }

        loggerQueue = dispatch_queue_create(loggerQueueName, NULL);
    }

    OSSLoggerNode *loggerNode = [OSSLoggerNode nodeWithLogger:logger loggerQueue:loggerQueue level:level];
    [self._loggers addObject:loggerNode];

    if ([logger respondsToSelector:@selector(didAddLoggerInQueue:)]) {
        dispatch_async(loggerNode->_loggerQueue, ^{ @autoreleasepool {
            [logger didAddLoggerInQueue:loggerNode->_loggerQueue];
        } });
    } else if ([logger respondsToSelector:@selector(didAddLogger)]) {
        dispatch_async(loggerNode->_loggerQueue, ^{ @autoreleasepool {
            [logger didAddLogger];
        } });
    }
}

- (void)lt_removeLogger:(id <OSSDDLogger>)logger {
    // Find associated loggerNode in list of added loggers

    NSAssert(dispatch_get_specific(GlobalLoggingQueueIdentityKey),
             @"This method should only be run on the logging thread/queue");

    OSSLoggerNode *loggerNode = nil;

    for (OSSLoggerNode *node in self._loggers) {
        if (node->_logger == logger) {
            loggerNode = node;
            break;
        }
    }
    
    if (loggerNode == nil) {
        OSSNSLogDebug(@"DDLog: Request to remove logger which wasn't added");
        return;
    }
    
    // Notify logger
    if ([logger respondsToSelector:@selector(willRemoveLogger)]) {
        dispatch_async(loggerNode->_loggerQueue, ^{ @autoreleasepool {
            [logger willRemoveLogger];
        } });
    }
    
    // Remove from loggers array
    [self._loggers removeObject:loggerNode];
}

- (void)lt_removeAllLoggers {
    NSAssert(dispatch_get_specific(GlobalLoggingQueueIdentityKey),
             @"This method should only be run on the logging thread/queue");
    
    // Notify all loggers
    for (OSSLoggerNode *loggerNode in self._loggers) {
        if ([loggerNode->_logger respondsToSelector:@selector(willRemoveLogger)]) {
            dispatch_async(loggerNode->_loggerQueue, ^{ @autoreleasepool {
                [loggerNode->_logger willRemoveLogger];
            } });
        }
    }
    
    // Remove all loggers from array

    [self._loggers removeAllObjects];
}

- (NSArray *)lt_allLoggers {
    NSAssert(dispatch_get_specific(GlobalLoggingQueueIdentityKey),
             @"This method should only be run on the logging thread/queue");

    NSMutableArray *theLoggers = [NSMutableArray new];

    for (OSSLoggerNode *loggerNode in self._loggers) {
        [theLoggers addObject:loggerNode->_logger];
    }

    return [theLoggers copy];
}

- (NSArray *)lt_allLoggersWithLevel {
    NSAssert(dispatch_get_specific(GlobalLoggingQueueIdentityKey),
             @"This method should only be run on the logging thread/queue");
    
    NSMutableArray *theLoggersWithLevel = [NSMutableArray new];
    
    for (OSSLoggerNode *loggerNode in self._loggers) {
        [theLoggersWithLevel addObject:[OSSDDLoggerInformation informationWithLogger:loggerNode->_logger
                                                                         andLevel:loggerNode->_level]];
    }
    
    return [theLoggersWithLevel copy];
}

- (void)lt_log:(OSSDDLogMessage *)logMessage {
    // Execute the given log message on each of our loggers.

    NSAssert(dispatch_get_specific(GlobalLoggingQueueIdentityKey),
             @"This method should only be run on the logging thread/queue");

    if (_numProcessors > 1) {
        // Execute each logger concurrently, each within its own queue.
        // All blocks are added to same group.
        // After each block has been queued, wait on group.
        //
        // The waiting ensures that a slow logger doesn't end up with a large queue of pending log messages.
        // This would defeat the purpose of the efforts we made earlier to restrict the max queue size.

        for (OSSLoggerNode *loggerNode in self._loggers) {
            // skip the loggers that shouldn't write this message based on the log level

            if (!(logMessage->_flag & loggerNode->_level)) {
                continue;
            }
            
            dispatch_group_async(_loggingGroup, loggerNode->_loggerQueue, ^{ @autoreleasepool {
                [loggerNode->_logger logMessage:logMessage];
            } });
        }
        
        dispatch_group_wait(_loggingGroup, DISPATCH_TIME_FOREVER);
    } else {
        // Execute each logger serialy, each within its own queue.
        
        for (OSSLoggerNode *loggerNode in self._loggers) {
            // skip the loggers that shouldn't write this message based on the log level

            if (!(logMessage->_flag & loggerNode->_level)) {
                continue;
            }
            
            dispatch_sync(loggerNode->_loggerQueue, ^{ @autoreleasepool {
                [loggerNode->_logger logMessage:logMessage];
            } });
        }
    }

    // If our queue got too big, there may be blocked threads waiting to add log messages to the queue.
    // Since we've now dequeued an item from the log, we may need to unblock the next thread.

    // We are using a counting semaphore provided by GCD.
    // The semaphore is initialized with our DDLOG_MAX_QUEUE_SIZE value.
    // When a log message is queued this value is decremented.
    // When a log message is dequeued this value is incremented.
    // If the value ever drops below zero,
    // the queueing thread blocks and waits in FIFO order for us to signal it.
    //
    // A dispatch semaphore is an efficient implementation of a traditional counting semaphore.
    // Dispatch semaphores call down to the kernel only when the calling thread needs to be blocked.
    // If the calling semaphore does not need to block, no kernel call is made.

    dispatch_semaphore_signal(_queueSemaphore);
}

- (void)lt_flush {
    // All log statements issued before the flush method was invoked have now been executed.
    //
    // Now we need to propogate the flush request to any loggers that implement the flush method.
    // This is designed for loggers that buffer IO.
    
    NSAssert(dispatch_get_specific(GlobalLoggingQueueIdentityKey),
             @"This method should only be run on the logging thread/queue");
    
    for (OSSLoggerNode *loggerNode in self._loggers) {
        if ([loggerNode->_logger respondsToSelector:@selector(flush)]) {
            dispatch_group_async(_loggingGroup, loggerNode->_loggerQueue, ^{ @autoreleasepool {
                [loggerNode->_logger flush];
            } });
        }
    }
    
    dispatch_group_wait(_loggingGroup, DISPATCH_TIME_FOREVER);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

NSString * __nullable OSSDDExtractFileNameWithoutExtension(const char *filePath, BOOL copy) {
    if (filePath == NULL) {
        return nil;
    }

    char *lastSlash = NULL;
    char *lastDot = NULL;

    char *p = (char *)filePath;

    while (*p != '\0') {
        if (*p == '/') {
            lastSlash = p;
        } else if (*p == '.') {
            lastDot = p;
        }

        p++;
    }

    char *subStr;
    NSUInteger subLen;

    if (lastSlash) {
        if (lastDot) {
            // lastSlash -> lastDot
            subStr = lastSlash + 1;
            subLen = (NSUInteger)(lastDot - subStr);
        } else {
            // lastSlash -> endOfString
            subStr = lastSlash + 1;
            subLen = (NSUInteger)(p - subStr);
        }
    } else {
        if (lastDot) {
            // startOfString -> lastDot
            subStr = (char *)filePath;
            subLen = (NSUInteger)(lastDot - subStr);
        } else {
            // startOfString -> endOfString
            subStr = (char *)filePath;
            subLen = (NSUInteger)(p - subStr);
        }
    }

    if (copy) {
        return [[NSString alloc] initWithBytes:subStr
                                        length:subLen
                                      encoding:NSUTF8StringEncoding];
    } else {
        // We can take advantage of the fact that __FILE__ is a string literal.
        // Specifically, we don't need to waste time copying the string.
        // We can just tell NSString to point to a range within the string literal.

        return [[NSString alloc] initWithBytesNoCopy:subStr
                                              length:subLen
                                            encoding:NSUTF8StringEncoding
                                        freeWhenDone:NO];
    }
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation OSSLoggerNode

- (instancetype)initWithLogger:(id <OSSDDLogger>)logger loggerQueue:(dispatch_queue_t)loggerQueue level:(OSSDDLogLevel)level {
    if ((self = [super init])) {
        _logger = logger;

        if (loggerQueue) {
            _loggerQueue = loggerQueue;
            #if !OS_OBJECT_USE_OBJC
            dispatch_retain(loggerQueue);
            #endif
        }

        _level = level;
    }
    return self;
}

+ (OSSLoggerNode *)nodeWithLogger:(id <OSSDDLogger>)logger loggerQueue:(dispatch_queue_t)loggerQueue level:(OSSDDLogLevel)level {
    return [[OSSLoggerNode alloc] initWithLogger:logger loggerQueue:loggerQueue level:level];
}

- (void)dealloc {
    #if !OS_OBJECT_USE_OBJC
    if (_loggerQueue) {
        dispatch_release(_loggerQueue);
    }
    #endif
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation OSSDDLogMessage

// Can we use DISPATCH_CURRENT_QUEUE_LABEL ?
// Can we use dispatch_get_current_queue (without it crashing) ?
//
// a) Compiling against newer SDK's (iOS 7+/OS X 10.9+) where DISPATCH_CURRENT_QUEUE_LABEL is defined
//    on a (iOS 7.0+/OS X 10.9+) runtime version
//
// b) Systems where dispatch_get_current_queue is not yet deprecated and won't crash (< iOS 6.0/OS X 10.9)
//
//    dispatch_get_current_queue(void);
//      __OSX_AVAILABLE_BUT_DEPRECATED(__MAC_10_6,__MAC_10_9,__IPHONE_4_0,__IPHONE_6_0)

#if TARGET_OS_IOS

// Compiling for iOS

static BOOL _use_dispatch_current_queue_label;
static BOOL _use_dispatch_get_current_queue;

static void _dispatch_queue_label_init_once(void * __attribute__((unused)) context)
{
    _use_dispatch_current_queue_label = (UIDevice.currentDevice.systemVersion.floatValue >= 7.0f);
    _use_dispatch_get_current_queue = (!_use_dispatch_current_queue_label && UIDevice.currentDevice.systemVersion.floatValue >= 6.1f);
}

static __inline__ __attribute__((__always_inline__)) void _dispatch_queue_label_init()
{
    static dispatch_once_t onceToken;
    dispatch_once_f(&onceToken, NULL, _dispatch_queue_label_init_once);
}

  #define USE_DISPATCH_CURRENT_QUEUE_LABEL (_dispatch_queue_label_init(), _use_dispatch_current_queue_label)
  #define USE_DISPATCH_GET_CURRENT_QUEUE   (_dispatch_queue_label_init(), _use_dispatch_get_current_queue)

#elif TARGET_OS_WATCH || TARGET_OS_TV

// Compiling for watchOS, tvOS

  #define USE_DISPATCH_CURRENT_QUEUE_LABEL YES
  #define USE_DISPATCH_GET_CURRENT_QUEUE   NO

#else

// Compiling for Mac OS X

  #ifndef MAC_OS_X_VERSION_10_9
    #define MAC_OS_X_VERSION_10_9            1090
  #endif

  #if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_9 // Mac OS X 10.9 or later required

    #define USE_DISPATCH_CURRENT_QUEUE_LABEL YES
    #define USE_DISPATCH_GET_CURRENT_QUEUE   NO

  #else

static BOOL _use_dispatch_current_queue_label;
static BOOL _use_dispatch_get_current_queue;

static void _dispatch_queue_label_init_once(void * __attribute__((unused)) context)
{
    _use_dispatch_current_queue_label = [NSTimer instancesRespondToSelector : @selector(tolerance)]; // OS X 10.9+
    _use_dispatch_get_current_queue = !_use_dispatch_current_queue_label;                            // < OS X 10.9
}

static __inline__ __attribute__((__always_inline__)) void _dispatch_queue_label_init()
{
    static dispatch_once_t onceToken;
    dispatch_once_f(&onceToken, NULL, _dispatch_queue_label_init_once);
}

    #define USE_DISPATCH_CURRENT_QUEUE_LABEL (_dispatch_queue_label_init(), _use_dispatch_current_queue_label)
    #define USE_DISPATCH_GET_CURRENT_QUEUE   (_dispatch_queue_label_init(), _use_dispatch_get_current_queue)

  #endif

#endif /* if TARGET_OS_IOS */

// Should we use pthread_threadid_np ?
// With iOS 8+/OSX 10.10+ NSLog uses pthread_threadid_np instead of pthread_mach_thread_np

#if TARGET_OS_IOS

// Compiling for iOS

  #ifndef kCFCoreFoundationVersionNumber_iOS_8_0
    #define kCFCoreFoundationVersionNumber_iOS_8_0 1140.10
  #endif

  #define USE_PTHREAD_THREADID_NP                (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_8_0)

#elif TARGET_OS_WATCH || TARGET_OS_TV

// Compiling for watchOS, tvOS

  #define USE_PTHREAD_THREADID_NP                YES

#else

// Compiling for Mac OS X

  #ifndef kCFCoreFoundationVersionNumber10_10
    #define kCFCoreFoundationVersionNumber10_10    1151.16
  #endif

  #define USE_PTHREAD_THREADID_NP                (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber10_10)

#endif /* if TARGET_OS_IOS */

- (instancetype)init {
    self = [super init];
    return self;
}

- (instancetype)initWithMessage:(NSString *)message
                          level:(OSSDDLogLevel)level
                           flag:(OSSDDLogFlag)flag
                        context:(NSInteger)context
                           file:(NSString *)file
                       function:(NSString *)function
                           line:(NSUInteger)line
                            tag:(id)tag
                        options:(OSSDDLogMessageOptions)options
                      timestamp:(NSDate *)timestamp {
    if ((self = [super init])) {
        BOOL copyMessage = (options & OSSDDLogMessageDontCopyMessage) == 0;
        _message      = copyMessage ? [message copy] : message;
        _level        = level;
        _flag         = flag;
        _context      = context;

        BOOL copyFile = (options & OSSDDLogMessageCopyFile) != 0;
        _file = copyFile ? [file copy] : file;

        BOOL copyFunction = (options & OSSDDLogMessageCopyFunction) != 0;
        _function = copyFunction ? [function copy] : function;

        _line         = line;
        _tag          = tag;
        _options      = options;
        _timestamp    = timestamp ?: [NSDate new];

        if (USE_PTHREAD_THREADID_NP) {
            __uint64_t tid;
            pthread_threadid_np(NULL, &tid);
            _threadID = [[NSString alloc] initWithFormat:@"%llu", tid];
        } else {
            _threadID = [[NSString alloc] initWithFormat:@"%x", pthread_mach_thread_np(pthread_self())];
        }
        _threadName   = NSThread.currentThread.name;

        // Get the file name without extension
        _fileName = [_file lastPathComponent];
        NSUInteger dotLocation = [_fileName rangeOfString:@"." options:NSBackwardsSearch].location;
        if (dotLocation != NSNotFound)
        {
            _fileName = [_fileName substringToIndex:dotLocation];
        }
        
        // Try to get the current queue's label
        if (USE_DISPATCH_CURRENT_QUEUE_LABEL) {
            _queueLabel = [[NSString alloc] initWithFormat:@"%s", dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)];
        } else if (USE_DISPATCH_GET_CURRENT_QUEUE) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            dispatch_queue_t currentQueue = dispatch_get_current_queue();
            #pragma clang diagnostic pop
            _queueLabel = [[NSString alloc] initWithFormat:@"%s", dispatch_queue_get_label(currentQueue)];
        } else {
            _queueLabel = @""; // iOS 6.x only
        }
    }
    return self;
}

- (id)copyWithZone:(NSZone * __attribute__((unused)))zone {
    OSSDDLogMessage *newMessage = [OSSDDLogMessage new];
    
    newMessage->_message = _message;
    newMessage->_level = _level;
    newMessage->_flag = _flag;
    newMessage->_context = _context;
    newMessage->_file = _file;
    newMessage->_fileName = _fileName;
    newMessage->_function = _function;
    newMessage->_line = _line;
    newMessage->_tag = _tag;
    newMessage->_options = _options;
    newMessage->_timestamp = _timestamp;
    newMessage->_threadID = _threadID;
    newMessage->_threadName = _threadName;
    newMessage->_queueLabel = _queueLabel;

    return newMessage;
}

@end


////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation OSSDDAbstractLogger

- (instancetype)init {
    if ((self = [super init])) {
        const char *loggerQueueName = NULL;

        if ([self respondsToSelector:@selector(loggerName)]) {
            loggerQueueName = [[self loggerName] UTF8String];
        }

        _loggerQueue = dispatch_queue_create(loggerQueueName, NULL);

        // We're going to use dispatch_queue_set_specific() to "mark" our loggerQueue.
        // Later we can use dispatch_get_specific() to determine if we're executing on our loggerQueue.
        // The documentation states:
        //
        // > Keys are only compared as pointers and are never dereferenced.
        // > Thus, you can use a pointer to a static variable for a specific subsystem or
        // > any other value that allows you to identify the value uniquely.
        // > Specifying a pointer to a string constant is not recommended.
        //
        // So we're going to use the very convenient key of "self",
        // which also works when multiple logger classes extend this class, as each will have a different "self" key.
        //
        // This is used primarily for thread-safety assertions (via the isOnInternalLoggerQueue method below).

        void *key = (__bridge void *)self;
        void *nonNullValue = (__bridge void *)self;

        dispatch_queue_set_specific(_loggerQueue, key, nonNullValue, NULL);
    }

    return self;
}

- (void)dealloc {
    #if !OS_OBJECT_USE_OBJC

    if (_loggerQueue) {
        dispatch_release(_loggerQueue);
    }

    #endif
}

- (void)logMessage:(OSSDDLogMessage * __attribute__((unused)))logMessage {
    // Override me
}

- (id <OSSDDLogFormatter>)logFormatter {
    // This method must be thread safe and intuitive.
    // Therefore if somebody executes the following code:
    //
    // [logger setLogFormatter:myFormatter];
    // formatter = [logger logFormatter];
    //
    // They would expect formatter to equal myFormatter.
    // This functionality must be ensured by the getter and setter method.
    //
    // The thread safety must not come at a cost to the performance of the logMessage method.
    // This method is likely called sporadically, while the logMessage method is called repeatedly.
    // This means, the implementation of this method:
    // - Must NOT require the logMessage method to acquire a lock.
    // - Must NOT require the logMessage method to access an atomic property (also a lock of sorts).
    //
    // Thread safety is ensured by executing access to the formatter variable on the loggerQueue.
    // This is the same queue that the logMessage method operates on.
    //
    // Note: The last time I benchmarked the performance of direct access vs atomic property access,
    // direct access was over twice as fast on the desktop and over 6 times as fast on the iPhone.
    //
    // Furthermore, consider the following code:
    //
    // DDLogVerbose(@"log msg 1");
    // DDLogVerbose(@"log msg 2");
    // [logger setFormatter:myFormatter];
    // DDLogVerbose(@"log msg 3");
    //
    // Our intuitive requirement means that the new formatter will only apply to the 3rd log message.
    // This must remain true even when using asynchronous logging.
    // We must keep in mind the various queue's that are in play here:
    //
    // loggerQueue : Our own private internal queue that the logMessage method runs on.
    //               Operations are added to this queue from the global loggingQueue.
    //
    // globalLoggingQueue : The queue that all log messages go through before they arrive in our loggerQueue.
    //
    // All log statements go through the serial gloabalLoggingQueue before they arrive at our loggerQueue.
    // Thus this method also goes through the serial globalLoggingQueue to ensure intuitive operation.

    // IMPORTANT NOTE:
    //
    // Methods within the DDLogger implementation MUST access the formatter ivar directly.
    // This method is designed explicitly for external access.
    //
    // Using "self." syntax to go through this method will cause immediate deadlock.
    // This is the intended result. Fix it by accessing the ivar directly.
    // Great strides have been take to ensure this is safe to do. Plus it's MUCH faster.

    NSAssert(![self isOnGlobalLoggingQueue], @"Core architecture requirement failure");
    NSAssert(![self isOnInternalLoggerQueue], @"MUST access ivar directly, NOT via self.* syntax.");

    dispatch_queue_t globalLoggingQueue = [OSSDDLog loggingQueue];

    __block id <OSSDDLogFormatter> result;

    dispatch_sync(globalLoggingQueue, ^{
        dispatch_sync(_loggerQueue, ^{
            result = _logFormatter;
        });
    });

    return result;
}

- (void)setLogFormatter:(id <OSSDDLogFormatter>)logFormatter {
    // The design of this method is documented extensively in the logFormatter message (above in code).

    NSAssert(![self isOnGlobalLoggingQueue], @"Core architecture requirement failure");
    NSAssert(![self isOnInternalLoggerQueue], @"MUST access ivar directly, NOT via self.* syntax.");

    dispatch_block_t block = ^{
        @autoreleasepool {
            if (_logFormatter != logFormatter) {
                if ([_logFormatter respondsToSelector:@selector(willRemoveFromLogger:)]) {
                    [_logFormatter willRemoveFromLogger:self];
                }

                _logFormatter = logFormatter;
 
                if ([_logFormatter respondsToSelector:@selector(didAddToLogger:inQueue:)]) {
                    [_logFormatter didAddToLogger:self inQueue:_loggerQueue];
                } else if ([_logFormatter respondsToSelector:@selector(didAddToLogger:)]) {
                    [_logFormatter didAddToLogger:self];
                }
            }
        }
    };

    dispatch_queue_t globalLoggingQueue = [OSSDDLog loggingQueue];

    dispatch_async(globalLoggingQueue, ^{
        dispatch_async(_loggerQueue, block);
    });
}

- (dispatch_queue_t)loggerQueue {
    return _loggerQueue;
}

- (NSString *)loggerName {
    return NSStringFromClass([self class]);
}

- (BOOL)isOnGlobalLoggingQueue {
    return (dispatch_get_specific(GlobalLoggingQueueIdentityKey) != NULL);
}

- (BOOL)isOnInternalLoggerQueue {
    void *key = (__bridge void *)self;

    return (dispatch_get_specific(key) != NULL);
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface OSSDDLoggerInformation()
{
    // Direct accessors to be used only for performance
    @public
    id <OSSDDLogger> _logger;
    OSSDDLogLevel _level;
}

@end

@implementation OSSDDLoggerInformation

- (instancetype)initWithLogger:(id <OSSDDLogger>)logger andLevel:(OSSDDLogLevel)level {
    if ((self = [super init])) {
        _logger = logger;
        _level = level;
    }
    return self;
}

+ (OSSDDLoggerInformation *)informationWithLogger:(id <OSSDDLogger>)logger andLevel:(OSSDDLogLevel)level {
    return [[OSSDDLoggerInformation alloc] initWithLogger:logger andLevel:level];
}

@end
