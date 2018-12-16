//
//  ImageQualityViewCon.m
//  Rdt-iOS
//
//  Created by Eric Chan Yee Choong on 10/6/18.
//  Copyright © 2018 Eric Chan Yee Choong. All rights reserved.
//

#import "ImageQualityViewCon.h"
#import "AVCamPreviewView.h"
#import "ImageProcessor.h"


using namespace std;
using namespace cv;

AVCaptureSessionPreset GLOBAL_CAMERA_PRESET = AVCaptureSessionPresetPhoto;
BOOL HIGH_RESOLUTION_ENABLED = NO;
BOOL DEPTH_DATA_DELIVERY = NO;
AVCaptureExposureMode EXPOSURE_MODE = AVCaptureExposureModeContinuousAutoExposure;
AVCaptureFocusMode FOCUS_MODE = AVCaptureFocusModeContinuousAutoFocus;
CGFloat X = 0.5;
CGFloat Y = 0.5;
NSString *instruction_detected = @"RDT detected at the center!";
NSString *instruction_pos = @"Place RDT at the center.\nFit RDT to the rectangle.";
NSString *instruction_too_small = @"Place RDT at the center.\nFit RDT to the rectangle.\nMove closer.";
NSString *instruction_too_large = @"Place RDT at the center.\nFit RDT to the rectangle.\nMove further away.";
NSString *instruction_focusing = @"Place RDT at the center.\nFit RDT to the rectangle.\nCamera is focusing. \nStay still.";
NSString *instruction_unfocused = @"Place RDT at the center.\n Fit RDT to the rectangle.\nCamera is not focused. \nMove further away.";
int mMoveCloserCount = 0;
int MOVE_CLOSER_COUNT = 5;
typedef NS_ENUM( NSInteger, AVCamSetupResult ) {
    AVCamSetupResultSuccess,
    AVCamSetupResultCameraNotAuthorized,
    AVCamSetupResultSessionConfigurationFailed
};

@interface ImageQualityViewCon ()

//    CvVideoCamera* videoCamera;
//    UIImageView *cameraView;
//    __weak IBOutlet UIImageView *secondView;

//@property (nonatomic, retain) CvVideoCamera* videoCamera;
@property (nonatomic) dispatch_queue_t sessionQueue;
@property (nonatomic) dispatch_queue_t videoDataOutputQueue;
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic, weak) IBOutlet AVCamPreviewView *previewView;
@property (nonatomic) AVCamSetupResult setupResult;
@property (nonatomic) AVCaptureDeviceInput *videoDeviceInput;
@property (nonatomic) AVCapturePhotoOutput *photoOutput;
@property (nonatomic, getter=isSessionRunning) BOOL sessionRunning;
@property (nonatomic) AVCaptureVideoDataOutput *videoDataOutput;
@property (nonatomic) BOOL isProcessing;
@property (weak, nonatomic) IBOutlet UILabel *positionLabel;
@property (weak, nonatomic) IBOutlet UILabel *sharpnessLabel;
@property (weak, nonatomic) IBOutlet UILabel *brightnessLabel;
@property (weak, nonatomic) IBOutlet UILabel *shadowLabel;
@property (weak, nonatomic) IBOutlet UILabel *instructionsLabel;

@end


@implementation ImageQualityViewCon

- (void)viewDidLoad {
    [super viewDidLoad];
    // Create the AVCaptureSession.
    self.session = [[AVCaptureSession alloc] init];
    
    // Set up the preview view.
    self.previewView.session = self.session;
    
    // Communicate with the session and other session objects on this queue.
    self.sessionQueue = dispatch_queue_create( "session queue", DISPATCH_QUEUE_SERIAL );
    
    self.setupResult = AVCamSetupResultSuccess;
    
    /*
     Check video authorization status. Video access is required and audio
     access is optional. If audio access is denied, audio is not recorded
     during movie recording.
     */
    switch ( [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] )
    {
        case AVAuthorizationStatusAuthorized:
        {
            // The user has previously granted access to the camera.
            break;
        }
        case AVAuthorizationStatusNotDetermined:
        {
            /*
             The user has not yet been presented with the option to grant
             video access. We suspend the session queue to delay session
             setup until the access request has completed.
             
             Note that audio access will be implicitly requested when we
             create an AVCaptureDeviceInput for audio during session setup.
             */
            dispatch_suspend( self.sessionQueue );
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^( BOOL granted ) {
                if ( ! granted ) {
                    self.setupResult = AVCamSetupResultCameraNotAuthorized;
                }
                dispatch_resume( self.sessionQueue );
            }];
            break;
        }
        default:
        {
            // The user has previously denied access.
            self.setupResult = AVCamSetupResultCameraNotAuthorized;
            break;
        }
    }
    dispatch_async(self.sessionQueue, ^{
        [self configureSession];
    } );
    [self setUpGuidingView];
    //self.previewView.layer addSublayer:<#(nonnull CALayer *)#>
    
}

- (void) setUpGuidingView{
    double xPos = self.view.frame.size.width * 0.325;
    double yPos = self.view.frame.size.height * 0.25;
    double gWidth = self.view.frame.size.width * 0.35;
    double gHeight = self.view.frame.size.height * 0.5;
    UIBezierPath *insideBox = [UIBezierPath bezierPathWithRect:CGRectMake(xPos, yPos, gWidth, gHeight)];
    UIBezierPath *outerBox = [UIBezierPath bezierPathWithRect:self.view.frame];
    [insideBox appendPath:outerBox];
    insideBox.usesEvenOddFillRule = YES;
    
    CAShapeLayer *fillLayer = [CAShapeLayer layer];
    fillLayer.path = insideBox.CGPath;
    fillLayer.fillRule = kCAFillRuleEvenOdd;
    fillLayer.fillColor = [UIColor redColor].CGColor;
    fillLayer.opacity = 0.5;
    fillLayer.strokeColor = [UIColor whiteColor].CGColor;
    fillLayer.lineWidth = 5.0;
//    NSLog(@"%@", self.view.layer.sublayers);
//    NSLog(@"%@", self.previewView.layer);
//    NSLog(@"%@", self.positionLabel.layer);
//    NSLog(@"%@", self.sharpnessLabel.layer);
//    NSLog(@"%@", self.brightnessLabel.layer);
//    NSLog(@"%@", self.shadowLabel.layer);
//    NSLog(@"%@", self.instructionsLabel.layer);
    [self.view.layer insertSublayer:fillLayer above:self.view.layer.sublayers[0]];
    
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.isProcessing = false;
    dispatch_async( self.sessionQueue, ^{
        switch ( self.setupResult )
        {
            case AVCamSetupResultSuccess:
            {
                // Start the session running if setup succeeded.
                [self.session startRunning];
                self.sessionRunning = self.session.isRunning;
                break;
            }
            case AVCamSetupResultCameraNotAuthorized:
            {
                dispatch_async( dispatch_get_main_queue(), ^{
                    NSString *message = NSLocalizedString( @"AVCam doesn't have permission to use the camera, please change privacy settings", @"Alert message when the user has denied access to the camera" );
                    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
                    [alertController addAction:cancelAction];
                    // Provide quick access to Settings.
                    UIAlertAction *settingsAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"Settings", @"Alert button to open Settings" ) style:UIAlertActionStyleDefault handler:^( UIAlertAction *action ) {
                        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
                    }];
                    [alertController addAction:settingsAction];
                    [self presentViewController:alertController animated:YES completion:nil];
                } );
                break;
            }
            case AVCamSetupResultSessionConfigurationFailed:
            {
                dispatch_async( dispatch_get_main_queue(), ^{
                    NSString *message = NSLocalizedString( @"Unable to capture media", @"Alert message when something goes wrong during capture session configuration" );
                    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
                    [alertController addAction:cancelAction];
                    [self presentViewController:alertController animated:YES completion:nil];
                } );
                break;
            }
        }
    } );
}

-(void) viewDidAppear:(BOOL)animated {
    [self setUpAutoFocusAndExposure];
}

-(void) setUpAutoFocusAndExposure {
    dispatch_async( self.sessionQueue, ^{
        //Setting Autofocus and exposure
        AVCaptureDevice *device = self.videoDeviceInput.device;
        NSError *error = nil;
        if ( [device lockForConfiguration:&error] ) {
            /*
             Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
             Call set(Focus/Exposure)Mode() to apply the new point of interest.
             */
//            if ([device hasTorch] && [device isTorchAvailable]) {
//                [device setTorchMode:AVCaptureTorchModeOn];
//            }
            
            CGPoint focusPoint = CGPointMake(X, Y);
            NSLog(@"%f, %f",focusPoint.x,focusPoint.y);
            if (device.isFocusPointOfInterestSupported && [device isFocusModeSupported:FOCUS_MODE] ) {
                device.focusPointOfInterest = focusPoint;
                device.focusMode = FOCUS_MODE;
            }
            
            if (device.isExposurePointOfInterestSupported && [device isExposureModeSupported:EXPOSURE_MODE] ) {
                device.exposurePointOfInterest = focusPoint;
                device.exposureMode = EXPOSURE_MODE;
            }
            
            if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
                device.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
            }
            
            device.subjectAreaChangeMonitoringEnabled = YES;
            
            [device unlockForConfiguration];
        }
        else {
            NSLog( @"Could not lock device for configuration: %@", error );
        }
    });
}

#pragma mark Session Management
- (void)configureSession {
    
    NSError *error = nil;
    
    [self.session beginConfiguration];
    
    /*
     We do not create an AVCaptureMovieFileOutput when setting up the session because the
     AVCaptureMovieFileOutput does not support movie recording with AVCaptureSessionPresetPhoto.
     */
    // self.session.sessionPreset = GLOBAL_CAMERA_PRESET;
    
    // Add video input.
    
    // Choose the back dual camera if available, otherwise default to a wide angle camera.
    AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInDualCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
    if ( ! videoDevice ) {
        // If the back dual camera is not available, default to the back wide angle camera.
        videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
        
        // In some cases where users break their phones, the back wide angle camera is not available. In this case, we should default to the front wide angle camera.
        if ( ! videoDevice ) {
            videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionFront];
        }
    }
    AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
    if ( ! videoDeviceInput ) {
        NSLog( @"Could not create video device input: %@", error );
        self.setupResult = AVCamSetupResultSessionConfigurationFailed;
        [self.session commitConfiguration];
        return;
    }
    if ( [self.session canAddInput:videoDeviceInput] ) {
        [self.session addInput:videoDeviceInput];
        self.videoDeviceInput = videoDeviceInput;
        
        dispatch_async( dispatch_get_main_queue(), ^{
            /*
             Why are we dispatching this to the main queue?
             Because AVCaptureVideoPreviewLayer is the backing layer for AVCamPreviewView and UIView
             can only be manipulated on the main thread.
             Note: As an exception to the above rule, it is not necessary to serialize video orientation changes
             on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
             
             Use the status bar orientation as the initial video orientation. Subsequent orientation changes are
             handled by -[AVCamCameraViewController viewWillTransitionToSize:withTransitionCoordinator:].
             */
            UIInterfaceOrientation statusBarOrientation = [UIApplication sharedApplication].statusBarOrientation;
            AVCaptureVideoOrientation initialVideoOrientation = AVCaptureVideoOrientationPortrait;
            if ( statusBarOrientation != UIInterfaceOrientationUnknown ) {
                initialVideoOrientation = (AVCaptureVideoOrientation)statusBarOrientation;
            }
            
            self.previewView.videoPreviewLayer.connection.videoOrientation = initialVideoOrientation;
        } );
    }
    else {
        NSLog( @"Could not add video device input to the session" );
        self.setupResult = AVCamSetupResultSessionConfigurationFailed;
        [self.session commitConfiguration];
        return;
    }
    
    // Add photo output.
//    AVCapturePhotoOutput *photoOutput = [[AVCapturePhotoOutput alloc] init];
//
//    if ( [self.session canAddOutput:photoOutput] ) {
//        [self.session addOutput:photoOutput];
//        self.photoOutput = photoOutput;
//        self.photoOutput.highResolutionCaptureEnabled = HIGH_RESOLUTION_ENABLED;
//        self.photoOutput.livePhotoCaptureEnabled = NO;
//        self.photoOutput.depthDataDeliveryEnabled = DEPTH_DATA_DELIVERY;
//    }else {
//        NSLog( @"Could not add photo output to the session" );
//        self.setupResult = AVCamSetupResultSessionConfigurationFailed;
//        [self.session commitConfiguration];
//        return;
//    }
    
    // Add frame processor output
    self.videoDataOutput = [AVCaptureVideoDataOutput new];
    [self.videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
    self.videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);
    self.videoDataOutput.videoSettings = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA],(id)kCVPixelBufferPixelFormatTypeKey,
                                          nil];
    [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];

    
    if ([self.session canAddOutput:self.videoDataOutput]) {
        [self.session addOutput:self.videoDataOutput];
    } else {
        NSLog(@"Could not add video output to the session");
        self.setupResult = AVCamSetupResultSessionConfigurationFailed;
        [self.session commitConfiguration];
        return;
    }
    
    [self.session commitConfiguration];

}
//#pragma mark - Protocol CvVideoCameraDelegate
//- (void)processImage:(Mat&)image;
//{
//    //Do some OpenCV stuff with the image
//    //NSLog(@"Delegate Called");
//    Mat image_copy;
//    cvtColor(image, image_copy, CV_BGRA2BGR);
//
//    bitwise_not(image_copy, image_copy);
//    cvtColor(image_copy, image, CV_BGR2BGRA);
//}

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/
#pragma mark - Image Process
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection{
    if (!self.isProcessing) {
        self.isProcessing = true;
        [[ImageProcessor sharedProcessor] performBRISKSearchOnSampleBuffer:sampleBuffer withOrientation:UIInterfaceOrientationPortrait withCompletion:^(bool passed, UIImage *img, bool updatePos, bool sharpness, bool brightness, bool shadow, NSMutableArray *isCorrectPosSize) {
            NSLog(@"Found = %d, update Pos = %d, update Sharpness = %d, update Brightness = %d, update Shadow = %d", passed, updatePos, sharpness, brightness, shadow);

            NSString *instructions = instruction_pos;
            if (isCorrectPosSize != nil) {
                if (isCorrectPosSize[1] && isCorrectPosSize[0] && isCorrectPosSize[2]) {
                    instructions = instruction_detected;
                } else if (mMoveCloserCount > MOVE_CLOSER_COUNT) {
                    if (!isCorrectPosSize[5]) {
                        if (!isCorrectPosSize[0] || (!isCorrectPosSize[1] && isCorrectPosSize[3])) {
                            instructions = instruction_pos;
                        } else if (!isCorrectPosSize[1] && isCorrectPosSize[4]) {
                            instructions = instruction_too_small;
                            mMoveCloserCount = 0;
                        }
                    } else {
                        instructions = instruction_pos;
                    }
                } else {
                    instructions = instruction_too_small;
                    mMoveCloserCount++;
                }
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self.positionLabel.text = updatePos ? @"POSITION/SIZE: FAILED": @"POSITION/SIZE: PASSED";
                self.positionLabel.textColor = updatePos ? [UIColor redColor] : [UIColor greenColor];
                self.sharpnessLabel.text = sharpness ? @"SHARPNESS: FAILED" : @"SHARPNESS: PASSED";
                self.sharpnessLabel.textColor = sharpness ? [UIColor redColor] : [UIColor greenColor];
                self.brightnessLabel.text = brightness ? @"BRIGHTNESS: FAILED" : @"BRIGHTNESS: PASSED";
                self.brightnessLabel.textColor = brightness ? [UIColor redColor] : [UIColor greenColor];
                self.shadowLabel.text = shadow ? @"NO SHADOW: FAILED" : @"NO SHADOW: PASSED";
                self.shadowLabel.textColor = shadow ? [UIColor redColor] : [UIColor greenColor];
                self.instructionsLabel.text = instructions;
                self.isProcessing = false;
            });
        }];
    }
    
}


- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
    
    if ( UIDeviceOrientationIsPortrait( deviceOrientation ) || UIDeviceOrientationIsLandscape( deviceOrientation ) ) {
        self.previewView.videoPreviewLayer.connection.videoOrientation = (AVCaptureVideoOrientation)deviceOrientation;
    }
}


@end



