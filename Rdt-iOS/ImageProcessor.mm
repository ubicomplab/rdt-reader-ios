//
//  ImageProcessor.m
//  Rdt-iOS
//
//  Created by Eric Chan Yee Choong on 11/2/18.
//  Copyright © 2018 Eric Chan Yee Choong. All rights reserved.
//

#import "ImageProcessor.h"
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
cv::Size PREVIEW_SIZE = cv::Size(960, 720);
double SIZE_THRESHOLD = 0.2;
double POSITION_THRESHOLD = 0.1;
double VIEWPORT_SCALE = 0.50;
int GOOD_MATCH_COUNT = 7;
double minBlur = FLT_MIN;
double maxBlur = FLT_MAX; //this value is set to min because blur check is not needed.



typedef NS_ENUM(NSInteger, ExposureResult ) {
    UNDER_EXPOSED,
    NORMAL,
    OVER_EXPOSED
};

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

    mat.release();
    return greyMat;
}


- (void)performBRISKSearchOnSampleBuffer:(CMSampleBufferRef)sampleBuffer withOrientation:(UIInterfaceOrientation)orientation withCompletion:(ImageProcessorBlock)completion {
    Mat inputMat = [self matFromSampleBuffer:sampleBuffer withOrientation:orientation];
    // Check for Exposure and Sharpness here, size and pos are checked after the features are computed
    // If pass perform BRISK
    // else completion(false)
    // [self calculateBlurriness:inputMat];
    vector<float> histograms = [self calculateHistogram:inputMat]; // This might fail!
    
    int maxWhite = 0;
    float whiteCount = 0;
    
    for (int i = 0; i < histograms.size(); i++) {
        if (histograms[i] > 0) {
            maxWhite = i;
        }
        if (i == histograms.size() - 1) {
            whiteCount = histograms[i];
        }
    }
    
    ExposureResult exposureResult;
    if (maxWhite >= OVER_EXP_THRESHOLD && whiteCount > OVER_EXP_WHITE_COUNT) {
        exposureResult = OVER_EXPOSED;
    } else if (maxWhite < UNDER_EXP_THRESHOLD) {
        exposureResult = UNDER_EXPOSED;
    } else {
        exposureResult = NORMAL;
    }
    
    double blurVal = [self calculateBlurriness:inputMat];
    bool isBlur = blurVal < (maxBlur * BLUR_THRESHOLD);
    
    if (exposureResult == NORMAL && !isBlur) {
        [self performBRISKSearchOnMat:inputMat withCompletion:^(bool passed,UIImage *img, bool updatePos, bool sharpness, bool brightness, bool shadow){ // Determine return type
            completion(passed, img, updatePos, sharpness, brightness, shadow);
        }];
    } else {
        NSLog(@"Found = ENTERED");
        completion(false, nil, false, isBlur, !(exposureResult == NORMAL), false);
    }
    

}

- (void)performBRISKSearchOnMat:(Mat)inputMat withCompletion:(ImageProcessorBlock)completion {
    Mat inDescriptor;
    vector<KeyPoint> inKeypoints;
    UIImage *resultImg;
    detector->detectAndCompute(inputMat, noArray(), inKeypoints, inDescriptor);
    if (inDescriptor.cols < 1 || inDescriptor.rows < 1) { // No features found!
        NSLog(@"Found no features!");
        completion(false, nil, false, false, false, false);
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
    // result.push_back(Point2f(0,0));
    // Didn't push Point2f(0,0)
    
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
            
            //UIImage *debugImg = MatToUIImage(img_matches);
            //UIImageWriteToSavedPhotosAlbum(debugImg, nil, nil, nil);
            
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
            boundary.push_back(Point2f(sceneCorners.at<Vec2f>(0,0)[0], sceneCorners.at<Vec2f>(0,0)[1]));
            boundary.push_back(Point2f(sceneCorners.at<Vec2f>(1,0)[0], sceneCorners.at<Vec2f>(1,0)[1]));
            boundary.push_back(Point2f(sceneCorners.at<Vec2f>(2,0)[0], sceneCorners.at<Vec2f>(2,0)[1]));
            boundary.push_back(Point2f(sceneCorners.at<Vec2f>(3,0)[0], sceneCorners.at<Vec2f>(3,0)[1]));
            
            //sceneCorners.convertTo(result, CV_32F); // Not sure! Convert it to vector<point2f>
            
            objCorners.release();
            sceneCorners.release();
            
            NSLog(@"Average distance: %.2f", sum/count);
            if (sum / count < minDist) {
                minDist = sum / count;
                //minDistanceUpdated = true;  //What's this?
            }
            NSMutableArray * isCorrectPosSize = [self checkPositionAndSize:result isCropped:true];
            if(isCorrectPosSize[0] && isCorrectPosSize[1] && isCorrectPosSize[2]) {
                found = true;
                resultImg = MatToUIImage(inputMat);
            } else {
                found = false;
            }
        }
        H.release();
    }
    // RETURN SOMETHING!
    completion(found, resultImg, !found, false, false, false);
}


-(NSMutableArray *) checkPositionAndSize:(vector<Point2f>) approx isCropped:(bool) cropped {
    NSMutableArray *result = [[NSMutableArray alloc] init];
    for (int i = 0; i < 5; i++) {
        [result addObject:[NSNumber numberWithBool:false]];
    }
    if (approx.size() < 1) {
        return result;
    }
    
    RotatedRect rotatedRect = minAreaRect(approx);
    if (cropped) {
        rotatedRect.center = cv::Point(rotatedRect.center.x + PREVIEW_SIZE.width/4, rotatedRect.center.y + PREVIEW_SIZE.height/4);
    }
    
    cv::Point center = rotatedRect.center;
    cv::Point trueCenter = cv::Point(PREVIEW_SIZE.width/2, PREVIEW_SIZE.height/2);
    
    bool isUpright = rotatedRect.size.height > rotatedRect.size.width;
    double angle = 0;
    double height = 0;

    if (isUpright) {
        angle = 90 - abs(rotatedRect.angle);
        height = rotatedRect.size.height;
    } else {
        angle = abs(rotatedRect.angle);
        height = rotatedRect.size.width;
    }
    
    bool isCentered = center.x < trueCenter.x *(1+ POSITION_THRESHOLD) && center.x > trueCenter.x*(1- POSITION_THRESHOLD)
    && center.y < trueCenter.y *(1+ POSITION_THRESHOLD) && center.y > trueCenter.y*(1- POSITION_THRESHOLD);
    bool isRightSize = height < PREVIEW_SIZE.width*VIEWPORT_SCALE*(1+SIZE_THRESHOLD) && height > PREVIEW_SIZE.height*VIEWPORT_SCALE*(1-SIZE_THRESHOLD);
    bool isOriented = angle < 90.0*POSITION_THRESHOLD;

    result[0] = [NSNumber numberWithBool:isCentered];
    result[1] = [NSNumber numberWithBool:isRightSize];
    result[2] = [NSNumber numberWithBool:isOriented];
    result[3] = [NSNumber numberWithBool:(height > PREVIEW_SIZE.width*VIEWPORT_SCALE*(1+SIZE_THRESHOLD))]; // large
    result[4] = [NSNumber numberWithBool:(height < PREVIEW_SIZE.height*VIEWPORT_SCALE*(1-SIZE_THRESHOLD))];// small
    
    if (((NSNumber*)result[0]).boolValue && ((NSNumber *)result[1]).boolValue ) {
        NSLog(@"POS: %.2d, %.2d, Angle: %.2f, Height: %.2f", center.x, center.y, angle, height);
    }
    
    return result;
}

-(double) calculateBlurriness:(Mat) input{
    Mat des = Mat();
    Laplacian(input, des, CV_64F);
    
    vector<double> median;
    vector<double> std;
    
    meanStdDev(des, median, std);
    
    double blurriness = pow(std[0],2);
    des.release();
    return blurriness;
}


-(vector<float>) calculateHistogram:(Mat) gray {
    int mHistSizeNum =256;
    vector<int> mHistSize;
    mHistSize.push_back(mHistSizeNum);
    Mat hist = Mat();
    vector<float> mBuff;
    vector<float> histogramRanges;
    histogramRanges.push_back(0.0);
    histogramRanges.push_back(256.0);
    cv::Size sizeRgba = gray.size();
    vector<int> channel = {0};
    vector<Mat> allMat = {gray};
    calcHist(allMat, channel, Mat(), hist, mHistSize, histogramRanges);
    normalize(hist, hist, sizeRgba.height/2, 0, NORM_INF);
    mBuff.assign((float*)hist.datastart, (float*)hist.dataend);
    return mBuff;
}

@end
