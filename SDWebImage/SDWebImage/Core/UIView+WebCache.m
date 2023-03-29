/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "UIView+WebCache.h"
#import "objc/runtime.h"
#import "UIView+WebCacheOperation.h"
#import "SDWebImageError.h"
#import "SDInternalMacros.h"
#import "SDWebImageTransitionInternal.h"

const int64_t SDWebImageProgressUnitCountUnknown = 1LL;

@implementation UIView (WebCache)

- (nullable NSURL *)sd_imageURL {
    return objc_getAssociatedObject(self, @selector(sd_imageURL));
}

- (void)setSd_imageURL:(NSURL * _Nullable)sd_imageURL {
    objc_setAssociatedObject(self, @selector(sd_imageURL), sd_imageURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (nullable NSString *)sd_latestOperationKey {
    return objc_getAssociatedObject(self, @selector(sd_latestOperationKey));
}

- (void)setSd_latestOperationKey:(NSString * _Nullable)sd_latestOperationKey {
    objc_setAssociatedObject(self, @selector(sd_latestOperationKey), sd_latestOperationKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (NSProgress *)sd_imageProgress {
    NSProgress *progress = objc_getAssociatedObject(self, @selector(sd_imageProgress));
    if (!progress) {
        progress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
        self.sd_imageProgress = progress;
    }
    return progress;
}

- (void)setSd_imageProgress:(NSProgress *)sd_imageProgress {
    objc_setAssociatedObject(self, @selector(sd_imageProgress), sd_imageProgress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)sd_internalSetImageWithURL:(nullable NSURL *)url
                  placeholderImage:(nullable UIImage *)placeholder
                           options:(SDWebImageOptions)options
                           context:(nullable SDWebImageContext *)context
                     setImageBlock:(nullable SDSetImageBlock)setImageBlock
                          progress:(nullable SDImageLoaderProgressBlock)progressBlock
                         completed:(nullable SDInternalCompletionBlock)completedBlock {
    //参数一：url            图像的url。
    //参数二：placeholder    最初要设置的图像，直到图像请求完成。
    //参数三：options        下载图像时要使用的选项。
    //参数四：context        上下文包含用于执行指定更改或过程的不同选项
    //参数五：setImageBlock  块用于自定义设置图像代码。
    //参数六：progressBlock  下载图像时调用的块。进度块是在后台队列上执行的。
    /*这个块没有返回值，并以请求的UIImage作为第一个参数，NSData表示作为第二个参数。
    如果发生错误，image参数为nil，第三个参数可能包含一个NSError。
    第四个参数是一个“SDImageCacheType”enum，表示图像是从本地缓存、内存缓存还是网络检索到的。
    第五个参数通常总是“YES”。但是，如果你提供SDWebImageAvoidAutoSetImage与SDWebImageProgressiveLoad选项，以启用渐进下载和设置自己的映像。因此，对部分图像重复调用该块。当图像完全下载后，最后一次调用该块，并将最后一个参数设置为YES。
    最后一个参数是原始图像URL。*/
    
    //1.取消之前下载操作
    if (context) {
        //获取枚举选项
        // copy to avoid mutable object
        // 复制以避免可变对象
        context = [context copy];
    } else {
        context = [NSDictionary dictionary];
    }
    //获取一个有效的操作的对应键值，这里获取的是"设置图片操作的键"
    NSString *validOperationKey = context[SDWebImageContextSetImageOperationKey];
    //如果传递的context中没有该图片操作键，就新建一个该类的操作键赋给context
    if (!validOperationKey) {
        // pass through the operation key to downstream, which can used for tracing operation or image view class
        // 将操作键传递给下游，可用于跟踪操作或图像视图类
        validOperationKey = NSStringFromClass([self class]);
        SDWebImageMutableContext *mutableContext = [context mutableCopy];
        mutableContext[SDWebImageContextSetImageOperationKey] = validOperationKey;
        context = [mutableContext copy];
    }
    
    //将当前操作键赋值给 sd_latestOperationKey属性，操作键用于标识一个视图实例的不同查询(如UIButton)。
    self.sd_latestOperationKey = validOperationKey;
    //下面这行代码是保证没有当前正在进行的异步下载操作, 使它不会与即将进行的操作发生冲突
    [self sd_cancelImageLoadOperationWithKey:validOperationKey];
    
    
    
    //2.设置占位图
    //将传递过来的url赋值给 sd_imageURL属性
    //注意，由于类别的限制，如果直接使用setImage:，这个属性可能会不同步。
    self.sd_imageURL = url;
    
    //添加临时的占位图（在不延迟添加占位图的option下）
    if (!(options & SDWebImageDelayPlaceholder)) {
        dispatch_main_async_safe(^{
            [self sd_setImage:placeholder imageData:nil basedOnClassOrViaCustomSetImageBlock:setImageBlock cacheType:SDImageCacheTypeNone imageURL:url];
        });
    }
    
    
    
    //3.判断URL是否合法
    if (url) {
        // reset the progress
        //重置进程
        NSProgress *imageProgress = objc_getAssociatedObject(self, @selector(sd_imageProgress));
        if (imageProgress) {
            imageProgress.totalUnitCount = 0;
            imageProgress.completedUnitCount = 0;
        }
        
#if SD_UIKIT || SD_MAC     //环境判断
        // check and start image indicator
        // 检查并启动图像指示灯
        [self sd_startImageIndicator]; //开启图像指示器
        
        id<SDWebImageIndicator> imageIndicator = self.sd_imageIndicator;
        //self.sd_imageIndicator
        //图像加载期间的图像指示器。如果你不需要指示器，请指定nil。默认为零
        //这个设置将移除旧的指示器视图，并将新的指示器视图添加到当前视图的子视图中。
        //@注意，因为这是UI相关的，你应该只从主队列访问。

#endif  //环境判断
        //从context字典中获取该键对应的数据
        //SDWebImageContextOption const SDWebImageContextCustomManager = @"customManager";
        SDWebImageManager *manager = context[SDWebImageContextCustomManager];
        //如果不存在，就新创建一个单例
        if (!manager) {
            manager = [SDWebImageManager sharedManager];
        } else {
            // remove this manager to avoid retain cycle (manger -> loader -> operation -> context -> manager)
            // 删除manager以避免循环引用(manger -> loader -> operation -> context -> manager)
            SDWebImageMutableContext *mutableContext = [context mutableCopy];
            mutableContext[SDWebImageContextCustomManager] = nil;
            context = [mutableContext copy];
        }
        
        //--------------SDImageLoaderProgressBlock-----------------//
        SDImageLoaderProgressBlock combinedProgressBlock = ^(NSInteger receivedSize, NSInteger expectedSize, NSURL * _Nullable targetURL) {
            if (imageProgress) {
                //项目总数
                imageProgress.totalUnitCount = expectedSize;
                //已完成数
                imageProgress.completedUnitCount = receivedSize;
            }
#if SD_UIKIT || SD_MAC//环境判断
            //重写并更新进度
            if ([imageIndicator respondsToSelector:@selector(updateIndicatorProgress:)]) {
                double progress = 0;
                if (expectedSize != 0) {
                    progress = (double)receivedSize / expectedSize;
                }
                progress = MAX(MIN(progress, 1), 0); // 0.0 - 1.0
                //在主线程不等待执行
                dispatch_async(dispatch_get_main_queue(), ^{
                    [imageIndicator updateIndicatorProgress:progress];
                });
            }
#endif      //环境判断
            if (progressBlock) {
                progressBlock(receivedSize, expectedSize, targetURL);
            }
        };
        //--------------SDImageLoaderProgressBlock-----------------//
        @weakify(self);
        //SDWebImageManager下载图片
        id <SDWebImageOperation> operation = [manager loadImageWithURL:url options:options context:context progress:combinedProgressBlock completed:^(UIImage *image, NSData *data, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
            @strongify(self);
            //如果不存在就直接，结束函数了。
            if (!self) { return; }
            // if the progress not been updated, mark it to complete state
            // 如果进度没有更新，将其标记为完成状态
            if (imageProgress && finished && !error && imageProgress.totalUnitCount == 0 && imageProgress.completedUnitCount == 0) {
                imageProgress.totalUnitCount = SDWebImageProgressUnitCountUnknown;
                imageProgress.completedUnitCount = SDWebImageProgressUnitCountUnknown;
            }
            
#if SD_UIKIT || SD_MAC
            // check and stop image indicator
            // 检查和停止图像指示灯，如果完成了就停止
            if (finished) {
                [self sd_stopImageIndicator];
            }
#endif
            //是否应该调用CompletedBlock，通过options和状态的&运算决定
            BOOL shouldCallCompletedBlock = finished || (options & SDWebImageAvoidAutoSetImage);
            //是否应该不设置Image，通过options和状态的&运算决定
            BOOL shouldNotSetImage = ((image && (options & SDWebImageAvoidAutoSetImage)) ||
                                      (!image && !(options & SDWebImageDelayPlaceholder)));
            //调用CompletedBlock的Block
            SDWebImageNoParamsBlock callCompletedBlockClojure = ^{
                if (!self) { return; }
                if (!shouldNotSetImage) {
                    [self sd_setNeedsLayout];
                }
                //判断是否需要调用completedBlock
                if (completedBlock && shouldCallCompletedBlock) {
                    //调用completedBlock，image，而且不自动替换 placeholder image
                    completedBlock(image, data, error, cacheType, finished, url);
                }
            };
            
            // case 1a: we got an image, but the SDWebImageAvoidAutoSetImage flag is set;我们得到了一个图像，但是SDWebImageAvoidAutoSetImage标志被设置了
            // OR
            // case 1b: we got no image and the SDWebImageDelayPlaceholder is not set;我们没有得到图像，SDWebImageDelayPlaceholder没有设置
            if (shouldNotSetImage) {     //如果应该不设置图像
                //主线程不等待安全的调用上述创建的callCompletedBlockClojure
                dispatch_main_async_safe(callCompletedBlockClojure);
                return;//结束函数
            }
            
            UIImage *targetImage = nil;//目标图像
            NSData *targetData = nil;//目标数据
            if (image) {
                // case 2a: we got an image and the SDWebImageAvoidAutoSetImage is not set
                //我们得到一个图像，SDWebImageAvoidAutoSetImage没有设置
                targetImage = image;
                targetData = data;
            } else if (options & SDWebImageDelayPlaceholder) {
                // case 2b: we got no image and the SDWebImageDelayPlaceholder flag is set
                //我们没有图像，并且设置了SDWebImageDelayPlaceholder标志
                targetImage = placeholder;
                targetData = nil;
            }
            
#if SD_UIKIT || SD_MAC
            // 检查是否使用图像过渡
            SDWebImageTransition *transition = nil;
            BOOL shouldUseTransition = NO;//是否使用过滤属性
            if (options & SDWebImageForceTransition) {//强制转换
                // 总是
                shouldUseTransition = YES;
            } else if (cacheType == SDImageCacheTypeNone) { //类型不可用
                // 从网络
                shouldUseTransition = YES;
            } else {
                // From disk (and, user don't use sync query)
                // 从磁盘(并且，用户不使用同步查询)
                if (cacheType == SDImageCacheTypeMemory) { //内存
                    shouldUseTransition = NO;
                } else if (cacheType == SDImageCacheTypeDisk) { //磁盘
                    if (options & SDWebImageQueryMemoryDataSync || options & SDWebImageQueryDiskDataSync) {
                        shouldUseTransition = NO;
                    } else {
                        shouldUseTransition = YES;
                    }
                } else {
                    // Not valid cache type, fallback
                    // 缓存类型无效，请回退
                    shouldUseTransition = NO;
                }
            }
            //完成并且应该使用转换
            if (finished && shouldUseTransition) {
                transition = self.sd_imageTransition;   //转换属性，图片加载完成后的图片转换
            }
#endif
            //dispatch_main_async_safe : 保证block能在主线程安全进行，不等待
            dispatch_main_async_safe(^{
#if SD_UIKIT || SD_MAC
                //马上替换 placeholder image
                [self sd_setImage:targetImage imageData:targetData basedOnClassOrViaCustomSetImageBlock:setImageBlock transition:transition cacheType:cacheType imageURL:imageURL];
#else
                //马上替换 placeholder image
                [self sd_setImage:targetImage imageData:targetData basedOnClassOrViaCustomSetImageBlock:setImageBlock cacheType:cacheType imageURL:imageURL];
#endif
                //使用上述创建的block变量，调用CompletedBlock
                callCompletedBlockClojure();
            });
        }];
        //----------operation----------//
        //在操作缓存字典（operationDictionary）里添加operation，表示当前的操作正在进行
        [self sd_setImageLoadOperation:operation forKey:validOperationKey];
        //-------------------------url存在---------------------------//
    } else {
//-------------------------url不存在---------------------------//
#if SD_UIKIT || SD_MAC
        //url不存在立马停止图像指示器
        [self sd_stopImageIndicator];
#endif
        //如果url不存在，就在completedBlock里传入error（url为空）
        dispatch_main_async_safe(^{
            if (completedBlock) {
                NSError *error = [NSError errorWithDomain:SDWebImageErrorDomain code:SDWebImageErrorInvalidURL userInfo:@{NSLocalizedDescriptionKey : @"Image url is nil"}];
                completedBlock(nil, nil, error, SDImageCacheTypeNone, YES, url);
            }
        });
    }
    //-------------------------url不存在---------------------------//
}

- (void)sd_cancelCurrentImageLoad {
    [self sd_cancelImageLoadOperationWithKey:self.sd_latestOperationKey];
    self.sd_latestOperationKey = nil;
}

- (void)sd_setImage:(UIImage *)image imageData:(NSData *)imageData basedOnClassOrViaCustomSetImageBlock:(SDSetImageBlock)setImageBlock cacheType:(SDImageCacheType)cacheType imageURL:(NSURL *)imageURL {
#if SD_UIKIT || SD_MAC
    [self sd_setImage:image imageData:imageData basedOnClassOrViaCustomSetImageBlock:setImageBlock transition:nil cacheType:cacheType imageURL:imageURL];
#else
    // watchOS does not support view transition. Simplify the logic
    if (setImageBlock) {
        setImageBlock(image, imageData, cacheType, imageURL);
    } else if ([self isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)self;
        [imageView setImage:image];
    }
#endif
}

#if SD_UIKIT || SD_MAC
- (void)sd_setImage:(UIImage *)image imageData:(NSData *)imageData basedOnClassOrViaCustomSetImageBlock:(SDSetImageBlock)setImageBlock transition:(SDWebImageTransition *)transition cacheType:(SDImageCacheType)cacheType imageURL:(NSURL *)imageURL {
    UIView *view = self;
    SDSetImageBlock finalSetImageBlock;
    if (setImageBlock) {
        finalSetImageBlock = setImageBlock;
    } else if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)view;
        finalSetImageBlock = ^(UIImage *setImage, NSData *setImageData, SDImageCacheType setCacheType, NSURL *setImageURL) {
            imageView.image = setImage;
        };
    }
#if SD_UIKIT
    else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        finalSetImageBlock = ^(UIImage *setImage, NSData *setImageData, SDImageCacheType setCacheType, NSURL *setImageURL) {
            [button setImage:setImage forState:UIControlStateNormal];
        };
    }
#endif
#if SD_MAC
    else if ([view isKindOfClass:[NSButton class]]) {
        NSButton *button = (NSButton *)view;
        finalSetImageBlock = ^(UIImage *setImage, NSData *setImageData, SDImageCacheType setCacheType, NSURL *setImageURL) {
            button.image = setImage;
        };
    }
#endif
    
    if (transition) {
        NSString *originalOperationKey = view.sd_latestOperationKey;

#if SD_UIKIT
        [UIView transitionWithView:view duration:0 options:0 animations:^{
            if (!view.sd_latestOperationKey || ![originalOperationKey isEqualToString:view.sd_latestOperationKey]) {
                return;
            }
            // 0 duration to let UIKit render placeholder and prepares block
            if (transition.prepares) {
                transition.prepares(view, image, imageData, cacheType, imageURL);
            }
        } completion:^(BOOL finished) {
            [UIView transitionWithView:view duration:transition.duration options:transition.animationOptions animations:^{
                if (!view.sd_latestOperationKey || ![originalOperationKey isEqualToString:view.sd_latestOperationKey]) {
                    return;
                }
                if (finalSetImageBlock && !transition.avoidAutoSetImage) {
                    finalSetImageBlock(image, imageData, cacheType, imageURL);
                }
                if (transition.animations) {
                    transition.animations(view, image);
                }
            } completion:^(BOOL finished) {
                if (!view.sd_latestOperationKey || ![originalOperationKey isEqualToString:view.sd_latestOperationKey]) {
                    return;
                }
                if (transition.completion) {
                    transition.completion(finished);
                }
            }];
        }];
#elif SD_MAC
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull prepareContext) {
            if (!view.sd_latestOperationKey || ![originalOperationKey isEqualToString:view.sd_latestOperationKey]) {
                return;
            }
            // 0 duration to let AppKit render placeholder and prepares block
            prepareContext.duration = 0;
            if (transition.prepares) {
                transition.prepares(view, image, imageData, cacheType, imageURL);
            }
        } completionHandler:^{
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
                if (!view.sd_latestOperationKey || ![originalOperationKey isEqualToString:view.sd_latestOperationKey]) {
                    return;
                }
                context.duration = transition.duration;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                CAMediaTimingFunction *timingFunction = transition.timingFunction;
#pragma clang diagnostic pop
                if (!timingFunction) {
                    timingFunction = SDTimingFunctionFromAnimationOptions(transition.animationOptions);
                }
                context.timingFunction = timingFunction;
                context.allowsImplicitAnimation = SD_OPTIONS_CONTAINS(transition.animationOptions, SDWebImageAnimationOptionAllowsImplicitAnimation);
                if (finalSetImageBlock && !transition.avoidAutoSetImage) {
                    finalSetImageBlock(image, imageData, cacheType, imageURL);
                }
                CATransition *trans = SDTransitionFromAnimationOptions(transition.animationOptions);
                if (trans) {
                    [view.layer addAnimation:trans forKey:kCATransition];
                }
                if (transition.animations) {
                    transition.animations(view, image);
                }
            } completionHandler:^{
                if (!view.sd_latestOperationKey || ![originalOperationKey isEqualToString:view.sd_latestOperationKey]) {
                    return;
                }
                if (transition.completion) {
                    transition.completion(YES);
                }
            }];
        }];
#endif
    } else {
        if (finalSetImageBlock) {
            finalSetImageBlock(image, imageData, cacheType, imageURL);
        }
    }
}
#endif

- (void)sd_setNeedsLayout {
#if SD_UIKIT
    [self setNeedsLayout];
#elif SD_MAC
    [self setNeedsLayout:YES];
#elif SD_WATCH
    // Do nothing because WatchKit automatically layout the view after property change
#endif
}

#if SD_UIKIT || SD_MAC

#pragma mark - Image Transition
- (SDWebImageTransition *)sd_imageTransition {
    return objc_getAssociatedObject(self, @selector(sd_imageTransition));
}

- (void)setSd_imageTransition:(SDWebImageTransition *)sd_imageTransition {
    objc_setAssociatedObject(self, @selector(sd_imageTransition), sd_imageTransition, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Indicator
- (id<SDWebImageIndicator>)sd_imageIndicator {
    return objc_getAssociatedObject(self, @selector(sd_imageIndicator));
}

- (void)setSd_imageIndicator:(id<SDWebImageIndicator>)sd_imageIndicator {
    // Remove the old indicator view
    id<SDWebImageIndicator> previousIndicator = self.sd_imageIndicator;
    [previousIndicator.indicatorView removeFromSuperview];
    
    objc_setAssociatedObject(self, @selector(sd_imageIndicator), sd_imageIndicator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Add the new indicator view
    UIView *view = sd_imageIndicator.indicatorView;
    if (CGRectEqualToRect(view.frame, CGRectZero)) {
        view.frame = self.bounds;
    }
    // Center the indicator view
#if SD_MAC
    [view setFrameOrigin:CGPointMake(round((NSWidth(self.bounds) - NSWidth(view.frame)) / 2), round((NSHeight(self.bounds) - NSHeight(view.frame)) / 2))];
#else
    view.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
#endif
    view.hidden = NO;
    [self addSubview:view];
}

- (void)sd_startImageIndicator {
    id<SDWebImageIndicator> imageIndicator = self.sd_imageIndicator;
    if (!imageIndicator) {
        return;
    }
    dispatch_main_async_safe(^{
        [imageIndicator startAnimatingIndicator];
    });
}

- (void)sd_stopImageIndicator {
    id<SDWebImageIndicator> imageIndicator = self.sd_imageIndicator;
    if (!imageIndicator) {
        return;
    }
    dispatch_main_async_safe(^{
        [imageIndicator stopAnimatingIndicator];
    });
}

#endif

@end
