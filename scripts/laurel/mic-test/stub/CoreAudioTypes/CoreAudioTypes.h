/* Host test only: the CoreAudio types audio_plugin.c uses. */
#ifndef MIC_TEST_CA_H
#define MIC_TEST_CA_H
#include <CoreFoundation/CoreFoundation.h>
typedef struct { Float64 mMinimum, mMaximum; } AudioValueRange;
typedef struct {
	Float64 mSampleRate;
	UInt32 mFormatID, mFormatFlags, mBytesPerPacket, mFramesPerPacket, mBytesPerFrame, mChannelsPerFrame, mBitsPerChannel, mReserved;
} AudioStreamBasicDescription;
typedef struct { Float64 mSampleTime; UInt64 mHostTime; } AudioTimeStamp;
#define kAudioFormatLinearPCM 0x6C70636Du       /* 'lpcm' */
#define kAudioFormatFlagIsSignedInteger (1u << 2)
#define kAudioFormatFlagIsPacked (1u << 3)
#endif
