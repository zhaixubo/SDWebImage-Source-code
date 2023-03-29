/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "UIView+WebCacheOperation.h"
#import "objc/runtime.h"

static char loadOperationKey;

// key is strong, value is weak because operation instance is retained by SDWebImageManager's runningOperations property
// we should use lock to keep thread-safe because these method may not be accessed from main queue
typedef NSMapTable<NSString *, id<SDWebImageOperation>> SDOperationsDictionary;

@implementation UIView (WebCacheOperation)

//获取关联对象：operations（用来存放操作的字典）
- (SDOperationsDictionary *)sd_operationDictionary {
    //创建一个互斥锁，保证此时没有其它线程对self对象进行修改，然后再获取这个字典
    @synchronized(self) {
        //获取存放操作的字典，objc_getAssociatedObject获取关联
        SDOperationsDictionary *operations = objc_getAssociatedObject(self, &loadOperationKey);
        //如果存在就直接返回
        if (operations) {
            return operations;
        }
        //如果没有，就新建一个
        operations = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsWeakMemory capacity:0];
        //objc_setAssociatedObject创建关联
        objc_setAssociatedObject(self, &loadOperationKey, operations, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return operations;
    }
}

- (nullable id<SDWebImageOperation>)sd_imageLoadOperationForKey:(nullable NSString *)key  {
    id<SDWebImageOperation> operation;
    if (key) {
        SDOperationsDictionary *operationDictionary = [self sd_operationDictionary];
        @synchronized (self) {
            operation = [operationDictionary objectForKey:key];
        }
    }
    return operation;
}

//设置图像加载操作，使用一个字典存储key和对应的操作
- (void)sd_setImageLoadOperation:(nullable id<SDWebImageOperation>)operation forKey:(nullable NSString *)key {
    //key存在
    if (key) {
        //取消当前UIView和key的所有操作，key——标识操作的键
        [self sd_cancelImageLoadOperationWithKey:key];
        //操作存在
        if (operation) {
            //获取operationDictionary字典
            SDOperationsDictionary *operationDictionary = [self sd_operationDictionary];
            //创建一个互斥锁，保证此时没有其它线程对self对象进行修改，然后再添加key和对应的operation（操作）
            @synchronized (self) {
                [operationDictionary setObject:operation forKey:key];
            }
        }
    }
}

- (void)sd_cancelImageLoadOperationWithKey:(nullable NSString *)key {
    if (key) {
        // Cancel in progress downloader from queue
        SDOperationsDictionary *operationDictionary = [self sd_operationDictionary];
        id<SDWebImageOperation> operation;
        
        @synchronized (self) {
            operation = [operationDictionary objectForKey:key];
        }
        if (operation) {
            if ([operation conformsToProtocol:@protocol(SDWebImageOperation)]) {
                [operation cancel];
            }
            @synchronized (self) {
                [operationDictionary removeObjectForKey:key];
            }
        }
    }
}

- (void)sd_removeImageLoadOperationWithKey:(nullable NSString *)key {
    if (key) {
        SDOperationsDictionary *operationDictionary = [self sd_operationDictionary];
        @synchronized (self) {
            [operationDictionary removeObjectForKey:key];
        }
    }
}

@end
