//
//  ImageQualityViewCon.h
//  Rdt-iOS
//
//  Created by Eric Chan Yee Choong on 10/6/18.
//  Copyright © 2018 Eric Chan Yee Choong. All rights reserved.
//

#import <opencv2/videoio/cap_ios.h>
#include <opencv2/imgproc/imgproc.hpp>
#include <opencv2/features2d.hpp>
#include <stdlib.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ImageQualityViewCon : UIViewController<AVCaptureVideoDataOutputSampleBufferDelegate>

@end

NS_ASSUME_NONNULL_END
