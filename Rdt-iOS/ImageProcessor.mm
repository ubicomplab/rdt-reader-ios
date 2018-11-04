//
//  ImageProcessor.m
//  Rdt-iOS
//
//  Created by Eric Chan Yee Choong on 11/2/18.
//  Copyright © 2018 Eric Chan Yee Choong. All rights reserved.
//

#import "ImageProcessor.h"
#import <opencv2/features2d.hpp>


using namespace cv;

Ptr<BRISK> detector;

@implementation ImageProcessor

// Singleton object
+ (ImageProcessor *)ImageProcessor {
    static ImageProcessor *sharedWrapper = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedWrapper = [[self alloc] init];
        detector = BRISK::create(60, 2, 1.0f);
    });
    return sharedWrapper;
}

// Get Mat from buffer
- (cv::Mat)matFromSampleBuffer:(CMSampleBufferRef)sampleBuffer withOrientation:(UIInterfaceOrientation)orientation {
    
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    size_t bufferWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t bufferHeight = CVPixelBufferGetHeight(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    unsigned char *pixel = (unsigned char *)CVPixelBufferGetBaseAddress(pixelBuffer);
    Mat mat = Mat((int)bufferHeight,(int)bufferWidth,CV_8UC4,pixel,(int)bytesPerRow); //put buffer in open cv, no memory copied
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    Mat orientedMat;
    if (orientation == UIInterfaceOrientationPortrait) {
        rotate(mat, orientedMat, cv::ROTATE_90_CLOCKWISE);
        mat.release();
    } else if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
        rotate(mat, orientedMat, cv::ROTATE_90_COUNTERCLOCKWISE);
        mat.release();
    } else if (orientation == UIInterfaceOrientationLandscapeLeft) {
        rotate(mat, orientedMat, cv::ROTATE_180);
        mat.release();
    } else {
        orientedMat = mat;
    }
    return orientedMat;
}


- (void)performBRISKSearchOnSampleBuffer:(CMSampleBufferRef)sampleBuffer withOrientation:(UIInterfaceOrientation)orientation withCompletion:(ImageProcessorBlock)completion {
    
}

@end
