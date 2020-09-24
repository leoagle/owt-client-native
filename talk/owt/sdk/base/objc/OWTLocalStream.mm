// Copyright (C) <2018> Intel Corporation
//
// SPDX-License-Identifier: Apache-2.0
#include <string>
#include <unordered_map>
#import <Foundation/Foundation.h>
#import <WebRTC/RTCCameraVideoCapturer.h>
#import <WebRTC/RTCVideoSource.h>
#import "talk/owt/sdk/base/objc/OWTLocalStream+Private.h"
#import "talk/owt/sdk/base/objc/OWTMediaFormat+Private.h"
#import "talk/owt/sdk/include/objc/OWT/RTCPeerConnectionFactory+OWT.h"
#import "talk/owt/sdk/include/objc/OWT/OWTLocalStream.h"
#import "talk/owt/sdk/include/objc/OWT/OWTErrors.h"
#import "talk/owt/sdk/include/objc/OWT/OWTMediaFormat.h"
#import "webrtc/sdk/objc/Framework/Classes/Common/NSString+StdString.h"
#import "webrtc/sdk/objc/api/peerconnection/RTCMediaStream+Private.h"
#include "webrtc/rtc_base/helpers.h"
@interface OWTLocalStream ()
- (NSString*)createRandomUuid;
@property(nonatomic, retain) NSArray<AVCaptureDevice*>* currentDevices;
@property(nonatomic, retain) AVCaptureDeviceFormat* currentFormat;
@property NSUInteger currentFPS;
@property NSInteger currentPosition;
@end
@implementation OWTLocalStream
- (instancetype)initWithMediaStream:(RTCMediaStream*)mediaStream
                             source:(OWTStreamSourceInfo*)source {
  self = [super initWithMediaStream:mediaStream source:source];
  std::shared_ptr<owt::base::LocalStream> nativeStream =
      std::make_shared<owt::base::LocalStream>(
          [mediaStream nativeMediaStream].get(),
          [source nativeStreamSourceInfo]);
  [self setNativeStream:nativeStream];
  return self;
}
- (instancetype)initWithConstratins:(OWTStreamConstraints*)constraints
                              error:(NSError**)outError {
  RTCPeerConnectionFactory* factory = [RTCPeerConnectionFactory sharedInstance];
  RTCMediaStream* stream =
      [factory mediaStreamWithStreamId:[self createRandomUuid]];
  if (constraints.audio) {
    RTCAudioSource* source = [factory audioSourceWithConstraints:nil];
    RTCAudioTrack* track =
        [factory audioTrackWithSource:source trackId:[self createRandomUuid]];
    [stream addAudioTrack:track];
  }
  if (constraints.video) {
    // Reference: ARDCaptureController.m.
    RTCVideoSource* source = [factory videoSource];
    RTCCameraVideoCapturer* capturer =
        [[RTCCameraVideoCapturer alloc] initWithDelegate:source];
    // Configure capturer position.
    NSArray<AVCaptureDevice*>* captureDevices =
        [RTCCameraVideoCapturer captureDevices];
    if (captureDevices == 0) {
      if (outError) {
        *outError = [[NSError alloc]
            initWithDomain:OWTErrorDomain
                      code:OWTStreamErrorLocalInvalidOption
                  userInfo:
                      [[NSDictionary alloc]
                          initWithObjectsAndKeys:
                              @"Cannot find capture device on current device.",
                              NSLocalizedDescriptionKey, nil]];
      }
      return nil;
    }
    AVCaptureDevice* device = captureDevices[0];
    if (constraints.video.devicePosition) {
      for (AVCaptureDevice* d in captureDevices) {
        if (d.position == constraints.video.devicePosition) {
          device = d;
          break;
        }
      }
    }
    // Configure FPS.
    NSUInteger fps =
        constraints.video.frameRate ? constraints.video.frameRate : 24;
    // Configure resolution.
    NSArray<AVCaptureDeviceFormat*>* formats =
        [RTCCameraVideoCapturer supportedFormatsForDevice:device];
    AVCaptureDeviceFormat* selectedFormat = nil;
    if (constraints.video.resolution.width == 0 &&
        constraints.video.resolution.height == 0) {
      selectedFormat = formats[0];
    } else {
      for (AVCaptureDeviceFormat* format in formats) {
        CMVideoDimensions dimension =
            CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        if (dimension.width == constraints.video.resolution.width &&
            dimension.height == constraints.video.resolution.height) {
          for (AVFrameRateRange* frameRateRange in
               [format videoSupportedFrameRateRanges]) {
            if (frameRateRange.minFrameRate <= fps &&
                fps <= frameRateRange.maxFrameRate) {
              selectedFormat = format;
              break;
            }
          }
        }
        if(selectedFormat){
          break;
        }
      }
    }
    if (selectedFormat == nil) {
      if (outError) {
        *outError = [[NSError alloc]
            initWithDomain:OWTErrorDomain
                      code:OWTStreamErrorLocalInvalidOption
                  userInfo:[[NSDictionary alloc]
                               initWithObjectsAndKeys:
                                   @"Resolution or frame rate specified cannot "
                                   @"be satisfied.",
                                   NSLocalizedDescriptionKey, nil]];
      }
      return nil;
    }
    [capturer startCaptureWithDevice:device format:selectedFormat fps:fps 
      completionHandler:^(NSError* error) {
        if (error) {
            NSLog(@"capture camera error: %@", [error localizedDescription]);
            [capturer stopCapture];
        } else {
          self.currentFormat = selectedFormat;
          self.currentFPS = fps;
          self.currentPosition = constraints.video.devicePosition;
          self.currentDevices = captureDevices;
        }
    }];
    RTCVideoTrack* track =
        [factory videoTrackWithSource:source trackId:[self createRandomUuid]];
    [stream addVideoTrack:track];
    _capturer = capturer;
  }
  OWTStreamSourceInfo* sourceInfo = [[OWTStreamSourceInfo alloc] init];
  sourceInfo.audio = OWTAudioSourceInfoMic;
  sourceInfo.video = OWTVideoSourceInfoCamera;
  self = [self initWithMediaStream:stream source:sourceInfo];
  return self;
}
- (void)setAttributes:(NSDictionary<NSString*, NSString*>*)attributes {
  auto localStream = [self nativeLocalStream];
  std::unordered_map<std::string, std::string> attributes_map;
  for (NSString* key in attributes) {
    NSString* value = [attributes objectForKey:key];
    attributes_map[[NSString stdStringForString:key]] =
        [NSString stdStringForString:value];
  }
  localStream->Attributes(attributes_map);
}
- (std::shared_ptr<owt::base::LocalStream>)nativeLocalStream {
  std::shared_ptr<owt::base::Stream> stream = [super nativeStream];
  return std::static_pointer_cast<owt::base::LocalStream>(stream);
}
- (NSString*)streamId {
  auto nativeStream = [self nativeStream];
  return [NSString stringForStdString:nativeStream->Id()];
}
- (NSString*)createRandomUuid{
  return [NSString stringForStdString:rtc::CreateRandomUuid()];
}
- (void)dealloc {
  if (_capturer && [_capturer isKindOfClass:[RTCCameraVideoCapturer class]]) {
    RTCCameraVideoCapturer* cameraVideoCapturer =
        (RTCCameraVideoCapturer*)_capturer;
    [cameraVideoCapturer stopCapture];
  }
  _capturer = nil;
}
-(void)stopCapture {
  if (_capturer && [_capturer isKindOfClass:[RTCCameraVideoCapturer class]]) {
    RTCCameraVideoCapturer* rtcCapture = (RTCCameraVideoCapturer*)_capturer;
    [rtcCapture stopCaptureWithCompletionHandler:^(void) {
      NSLog(@"camera capture stopped");
    }];
  }
  _capturer = nil;
}
-(void)close {
  auto localStream = [self nativeLocalStream];
  localStream->DisableVideo();
  localStream->DisableAudio();
  localStream->Close();
}
-(void)switchCamera {
  if (_capturer && [_capturer isKindOfClass:[RTCCameraVideoCapturer class]]) {
    RTCCameraVideoCapturer* rtcCapture = (RTCCameraVideoCapturer*)_capturer;
    [rtcCapture stopCaptureWithCompletionHandler:^(void) {      
      if (self.currentPosition == AVCaptureDevicePositionFront) {
        self.currentPosition = AVCaptureDevicePositionBack;
      } else {
        self.currentPosition = AVCaptureDevicePositionFront;
      }
      AVCaptureDevice* device = self.currentDevices[0];
      for (AVCaptureDevice* d in self.currentDevices) {
        if (d.position == self.currentPosition) {
          device = d;
          break;
        }
      }
      [rtcCapture startCaptureWithDevice:device format:self.currentFormat fps:self.currentFPS 
        completionHandler:^(NSError* error) {
          if (error) {
            NSLog(@"switch camera error: %@", [error localizedDescription]);
            [rtcCapture stopCapture];
          }
        }];
    }];
  }
}
@end
