//
//  ImageProcessor.m
//  Rdt-iOS
//
//  Created by Eric Chan Yee Choong on 11/2/18.
//  Copyright © 2018 Eric Chan Yee Choong. All rights reserved.
//

#import "ImageProcessor.h"
#import <opencv2/features2d.hpp>
#import <opencv2/imgcodecs/ios.h> // For code to convert UIImage to Mat
#import <opencv2/calib3d/calib3d.hpp> // For calib3d


using namespace cv;
using namespace std;

float BLUR_THRESHOLD = 0.0;
float OVER_EXP_THRESHOLD = 255;
float UNDER_EXP_THRESHOLD = 120;
float OVER_EXP_WHITE_COUNT = 100;
int GOOD_MATCH_COUNT = 7;


Ptr<BRISK> detector;
Ptr<DescriptorMatcher> matcher;
Mat refImg;
Mat refDescriptor;
vector<KeyPoint> refKeypoints;

@implementation ImageProcessor

// Singleton object
+ (ImageProcessor *)sharedProcessor {
    static ImageProcessor *sharedWrapper = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedWrapper = [[self alloc] init];
        detector = BRISK::create(60, 2, 1.0f);
        matcher = DescriptorMatcher::create(4); // 4 indicates BF Hamming
        UIImage * image = [UIImage imageNamed:@"ref.jpg"];
        UIImageToMat(image, refImg); // Dereference the pointer
        detector->detectAndCompute(refImg, noArray(), refKeypoints, refDescriptor);
        NSLog(@"Successfully set up BRISK Detector and BFHamming matcher");
        NSLog(@"Successfully detect and compute reference RDT, currently there are %lu keypoints",refKeypoints.size());
    });
    return sharedWrapper;
}

- (void) releaseProcessor{
    refImg.release();
    refDescriptor.release();
    detector.release();
    matcher.release();
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
    return orientedMat;}


- (void)performBRISKSearchOnSampleBuffer:(CMSampleBufferRef)sampleBuffer withOrientation:(UIInterfaceOrientation)orientation withCompletion:(ImageProcessorBlock)completion {
    Mat refMat = [self matFromSampleBuffer:sampleBuffer withOrientation:orientation];
    [self performBRISKSearchOnMat:refMat withCompletion:^(NSDictionary* features){
        
    }];
}

- (void)performBRISKSearchOnMat:(Mat)referenceMat withCompletion:(ImageProcessorBlock)completion {

    Mat inDescriptor;
    vector<KeyPoint> inKeypoints;
    
    detector->detectAndCompute(referenceMat, noArray(), inKeypoints, inDescriptor);
    if (inDescriptor.cols < 1 || inDescriptor.rows < 1) { // No features found!
        NSLog(@"Found no features!");
        return;
    }
    NSLog(@"Found %lu keypoints from input image", inKeypoints.size());
    
    // Matching
    double currentTime = CACurrentMediaTime();
    vector<DMatch> matches;
    matcher->match(refDescriptor, inDescriptor, matches);
    NSLog(@"Time taken to match: %f", CACurrentMediaTime() - currentTime);
    
    double maxDist = FLT_MIN;
    double minDist = FLT_MAX;
    
    for (int i = 0; i < matches.size(); i++) {
        double dist = matches[i].distance;
        maxDist = MAX(maxDist, dist);
        minDist = MIN(minDist, dist);
    }
    
    double sum = 0;
    int count = 0;
    vector<DMatch> goodMatches;
    for (int i = 0; i < matches.size(); i++) {
        if (matches[i].distance <= (1.5 * minDist)) {
            goodMatches.push_back(matches[i]);
            sum += matches[i].distance;
            count++;
        }
    }
    
    vector<Point2f> srcPoints;
    vector<Point2f> dstPoints;
    
    for (int i = 0; i < goodMatches.size(); i++) {
        DMatch currentMatch = goodMatches[i];
        srcPoints.push_back(refKeypoints[currentMatch.queryIdx].pt);
        dstPoints.push_back(refKeypoints[currentMatch.trainIdx].pt);
    }
    
    // HOMOGRAPHY!
    if (goodMatches.size() > GOOD_MATCH_COUNT) {
        Mat H = findHomography(srcPoints, dstPoints, CV_RANSAC, 5);
        
        if (H.cols >= 3 && H.rows <= 3) {
//            Mat objCorners = new Mat(4, 1, CV_32FC2);
//            Mat sceneCorners = new Mat(4, 1, CV_32FC2);
        }
        
        
    }
    
    
}


@end
