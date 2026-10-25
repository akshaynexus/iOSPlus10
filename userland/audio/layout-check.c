/*
 * Layout check of AudioServerPlugIn.h (ours) against the macOS SDK's CoreAudio/AudioServerPlugIn.h.
 * userland/audio/build.sh compiles this file twice (-DREAL_SDK = Apple's header, without = ours)
 * and compares the two outputs: every size and offset the HAL and the plug-in share must match.
 * The iOS 16 drivers use the same table: 20H392 BasebandVoice.driver has a NULL _reserved slot and
 * 22 function pointers after it (__DATA,__data 0x14008..0x140b8).
 */
#include <stddef.h>
#include <stdio.h>

#ifdef REAL_SDK
#include <CoreAudio/AudioServerPlugIn.h>
#define MAIN_TICKS mMainHostTicksPerFrame
#else
#include "AudioServerPlugIn.h"
#define MAIN_TICKS mMasterHostTicksPerFrame
#endif

#define S(t)            printf("sizeof %s %zu\n", #t, sizeof(t))
#define O(t, f)         printf("offsetof %s.%s %zu\n", #t, #f, offsetof(t, f))

int
main(void)
{
	S(AudioObjectPropertyAddress);
	S(AudioStreamRangedDescription);
	S(AudioServerPlugInClientInfo);
	O(AudioServerPlugInClientInfo, mBundleID);
	S(AudioServerPlugInIOCycleInfo);
	O(AudioServerPlugInIOCycleInfo, mCurrentTime);
	O(AudioServerPlugInIOCycleInfo, mInputTime);
	O(AudioServerPlugInIOCycleInfo, mOutputTime);
	O(AudioServerPlugInIOCycleInfo, MAIN_TICKS);
	O(AudioServerPlugInIOCycleInfo, mDeviceHostTicksPerFrame);
	S(AudioServerPlugInHostInterface);
	O(AudioServerPlugInHostInterface, RequestDeviceConfigurationChange);
	S(AudioServerPlugInDriverInterface);
	O(AudioServerPlugInDriverInterface, QueryInterface);
	O(AudioServerPlugInDriverInterface, Initialize);
	O(AudioServerPlugInDriverInterface, HasProperty);
	O(AudioServerPlugInDriverInterface, GetPropertyData);
	O(AudioServerPlugInDriverInterface, StartIO);
	O(AudioServerPlugInDriverInterface, GetZeroTimeStamp);
	O(AudioServerPlugInDriverInterface, DoIOOperation);
	O(AudioServerPlugInDriverInterface, EndIOOperation);
	/* selector and error values the plug-in answers (a typo here = a property the HAL never finds) */
	printf("sel %u %u %u %u %u %u %u %u %u %u\n", (unsigned)kAudioPlugInPropertyTranslateUIDToDevice,
	    (unsigned)kAudioDevicePropertyZeroTimeStampPeriod, (unsigned)kAudioDevicePropertyPreferredChannelsForStereo,
	    (unsigned)kAudioStreamPropertyAvailableVirtualFormats, (unsigned)kAudioLevelControlPropertyConvertDecibelsToScalar,
	    (unsigned)kAudioSelectorControlPropertyItemName, (unsigned)kAudioServerPlugInIOOperationWriteMix,
	    (unsigned)kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, (unsigned)kAudioHardwareBadPropertySizeError,
	    (unsigned)kAudioDeviceUnsupportedFormatError);
	printf("sel2 %u %u %u %u %u %u %u %u\n", (unsigned)kAudioObjectPropertyOwnedObjects,
	    (unsigned)kAudioDevicePropertyStreams, (unsigned)kAudioObjectPropertyControlList,
	    (unsigned)kAudioStreamPropertyPhysicalFormat, (unsigned)kAudioStreamPropertyAvailablePhysicalFormats,
	    (unsigned)kAudioDevicePropertyClockDomain, (unsigned)kAudioDevicePropertyRelatedDevices,
	    (unsigned)kAudioPlugInPropertyResourceBundle);
	return 0;
}
