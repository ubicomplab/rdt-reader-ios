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
#include <iostream>
#include <opencv2/imgproc/imgproc.hpp>

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
        UIImageToMat(image, refImg);
        cvtColor(refImg, refImg, CV_BGRA2GRAY); // Dereference the pointer
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
    Mat mat = Mat((int)bufferHeight,(int)bufferWidth,CV_8UC4, pixel,(int)bytesPerRow); //put buffer in open cv, no memory copied
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    Mat greyMat;
    cvtColor(mat, greyMat, CV_BGRA2GRAY);
    
//    Mat orientedMat;
//    if (orientation == UIInterfaceOrientationPortrait) {
//        rotate(mat, orientedMat, cv::ROTATE_90_CLOCKWISE);
//        mat.release();
//    } else if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
//        rotate(mat, orientedMat, cv::ROTATE_90_COUNTERCLOCKWISE);
//        mat.release();
//    } else if (orientation == UIInterfaceOrientationLandscapeLeft) {
//        rotate(mat, orientedMat, cv::ROTATE_180);
//        mat.release();
//    } else {
//        orientedMat = mat;
//    }

//    cv::Rect rect(0,0,2,2);
//    Mat submat = mat(rect);
//    cout << submat << endl;
//    cout << mat.at<double>(0,1) << endl;
//    cout << mat.at<double>(0,2) << endl;
//    cout << mat.at<double>(0,3) << endl;
//    cout << mat.at<double>(0,4) << endl;
//    cout << mat.at<double>(0,5) << endl;
//    cout << mat.at<double>(0,6) << endl;
    mat.release();
    return greyMat;
}


- (void)performBRISKSearchOnSampleBuffer:(CMSampleBufferRef)sampleBuffer withOrientation:(UIInterfaceOrientation)orientation withCompletion:(ImageProcessorBlock)completion {
    Mat inputMat = [self matFromSampleBuffer:sampleBuffer withOrientation:orientation];
    [self performBRISKSearchOnMat:inputMat withCompletion:^(bool features){ // Determine return type
        completion(features);
    }];
}

- (void)performBRISKSearchOnMat:(Mat)inputMat withCompletion:(ImageProcessorBlock)completion {
    Mat inDescriptor;
    vector<KeyPoint> inKeypoints;
    
    detector->detectAndCompute(inputMat, noArray(), inKeypoints, inDescriptor);
    if (inDescriptor.cols < 1 || inDescriptor.rows < 1) { // No features found!
        NSLog(@"Found no features!");
        completion(false);
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
    
    vector<Point2f> srcPoints; // Works without allocating space?
    vector<Point2f> dstPoints;
    
    for (int i = 0; i < goodMatches.size(); i++) {
        DMatch currentMatch = goodMatches[i];
        srcPoints.push_back(refKeypoints[currentMatch.queryIdx].pt);
        dstPoints.push_back(inKeypoints[currentMatch.trainIdx].pt);
    }
    
//    for (auto i: srcPoints)
//        std::cout << i << ' ';
//    cout << endl;
//    for (auto i: dstPoints)
//        std::cout << i << ' ';
    
    vector<Point2f> result;
    result.push_back(Point2f(0,0));
    
    bool found = false;
    // HOMOGRAPHY!
    NSLog(@"GoodMatches size %lu", goodMatches.size());
    if (goodMatches.size() > GOOD_MATCH_COUNT) {
        Mat H = findHomography(srcPoints, dstPoints, CV_RANSAC, 5);
        
        if (H.cols >= 3 && H.rows >= 3) {
            Mat objCorners = Mat(4, 1, CV_32FC2);
            Mat sceneCorners = Mat(4, 1, CV_32FC2);
            
            Mat img_matches;
            drawMatches(refImg, refKeypoints, inputMat, inKeypoints, goodMatches, img_matches, Scalar::all(-1),
                        Scalar::all(-1), std::vector<char>(), DrawMatchesFlags::NOT_DRAW_SINGLE_POINTS);
            
            UIImage *debugImg = MatToUIImage(img_matches);
            UIImageWriteToSavedPhotosAlbum(debugImg, nil, nil, nil);
            
//            vector<double> a,b,c,d;
//            a.push_back(0);
//            a.push_back(0);
//
//            b.push_back(refImg.cols - 1);
//            b.push_back(0);
//
//            c.push_back(refImg.cols - 1);
//            c.push_back(refImg.rows - 1);
//
//            d.push_back(0);
//            d.push_back(refImg.rows - 1);
            
            // Get corner from object
            // If matrix is of type CV_32F then use Mat.at<float>(y,x).
            
            objCorners.at<Vec2f>(0, 0)[0] = 0;
            objCorners.at<Vec2f>(0, 0)[1] = 0;
            
            objCorners.at<Vec2f>(1, 0)[0] = refImg.cols - 1;
            objCorners.at<Vec2f>(1, 0)[1] = 0;
            
            objCorners.at<Vec2f>(2, 0)[0] = refImg.cols - 1;
            objCorners.at<Vec2f>(2, 0)[1] = refImg.rows - 1;
            
            objCorners.at<Vec2f>(3, 0)[0] = 0;
            objCorners.at<Vec2f>(3, 0)[1] = refImg.rows - 1;
            
//            objCorners.at<vector<double>>(1, 0) = b;
//            objCorners.at<vector<double>>(2, 0) = c;
//            objCorners.at<vector<double>>(3, 0) = d;
            perspectiveTransform(objCorners, sceneCorners, H); // Not sure! if I'm suppose to dereference

            NSLog(@"Transformed:  (%.2f, %.2f) (%.2f, %.2f) (%.2f, %.2f) (%.2f, %.2f)",
                  sceneCorners.at<Vec2f>(0, 0)[0], sceneCorners.at<Vec2f>(0, 0)[1],
                  sceneCorners.at<Vec2f>(1, 0)[0], sceneCorners.at<Vec2f>(1, 0)[1],
                  sceneCorners.at<Vec2f>(2, 0)[0], sceneCorners.at<Vec2f>(2, 0)[1],
                  sceneCorners.at<Vec2f>(3, 0)[0], sceneCorners.at<Vec2f>(3, 0)[1]);
            
            vector<cv::Point2f> boundary;
            sceneCorners.convertTo(result, CV_32F); // Not sure! Convert it to vector<point2f>
            
            objCorners.release();
            sceneCorners.release();
            
            NSLog(@"Average distance: %.2f", sum/count);
            if (sum / count < minDist) {
                minDist = sum / count;
                //minDistanceUpdated = true;  //What's this?
            }
            found = true;
        }
        H.release();
    }
    // RETURN SOMETHING!
    completion(found);
}


@end
