//
//  ImageProcessor.h
//  Rdt-iOS
//
//  Created by Eric Chan Yee Choong on 11/2/18.
//  Copyright © 2018 Eric Chan Yee Choong. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>


NS_ASSUME_NONNULL_BEGIN

@interface ImageProcessor : NSObject

+ (ImageProcessor *)sharedProcessor;
typedef void (^ImageProcessorBlock)(bool passed, UIImage *img, bool updatePos, bool sharpness, bool brightness, bool shadow, NSMutableArray *isCorrectPosSize); // Return hashmap features to client
- (void)performBRISKSearchOnSampleBuffer:(CMSampleBufferRef)sampleBuffer withOrientation:(UIInterfaceOrientation)orientation withCompletion:(ImageProcessorBlock)completion;
@end

NS_ASSUME_NONNULL_END
