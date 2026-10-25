/*
 * NegroniAudio.driver: the CoreAudio HAL output device of iOS 16 on the OnePlus 10 Pro
 * (NE2211, SM8450). Stage 0 and stage d of docs/audio-plan.md.
 *
 * Adapted from HackiOS userland/src/audio_plugin.c (external/hackios-xnu-userland, commit
 * a79ff07), which plays iOS 16.5 sound with the same iPhone X (D22) identity. That code is
 * under the MIT licence:
 *
 *   Copyright (c) 2026 OOSEX GANG
 *
 *   Permission is hereby granted, free of charge, to any person obtaining a copy of this
 *   software and associated documentation files (the "Software"), to deal in the Software
 *   without restriction, including without limitation the rights to use, copy, modify, merge,
 *   publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
 *   to whom the Software is furnished to do so, subject to the following conditions:
 *
 *   The above copyright notice and this permission notice shall be included in all copies or
 *   substantial portions of the Software.
 *
 *   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 *   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
 *   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
 *   FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 *   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 *   DEALINGS IN THE SOFTWARE.
 *
 * Why it exists (docs/audio-plan.md stage 0): without an audio device, mediaserverd aborts
 * (std::terminate from a dispatch block: an uncaught C++ exception, logs/usblog-20261024-195455.txt,
 * scripts/debug/symbolicate.sh). The slop root tweaks remove VirtualAudio.plugin; then the HAL has
 * only CoreAudio's Null_Device and the routing layer has no route. VirtualAudio knows the iPhone
 * devices by UID and builds the speaker route only when these exist (HackiOS, verified on D22):
 *
 *   "Speaker"   stereo output -> /dev/negroni-audio (dropped while the node does not exist),
 *               plus a silent stereo input (on an iPhone: the amplifier sense data)
 *   "Hawking"   one silent input: the 'vhaw' companion of the default virtual device
 *   "Actuator"  one mono output (Taptic Engine haptics): dropped, no motor driver yet
 *   "Codec"     one mono input (built-in mic, data source 'imic'): silence
 *
 * Clock: the system clock. The device says it plays NEGRONI_AUDIO_RATE frames per second of
 * mach_absolute_time(); the HAL I/O thread paces itself by that, with or without hardware.
 *
 * Volume: the Speaker output has a volume control (48 dB, linear in dB). Its value goes to the
 * kernel (NEGRONI_AUDIO_SET_VOLUME); the kernel adds it to its own safe maximum. HackiOS
 * observation: VirtualAudio sets it once to 0 dB and keeps the D22 speaker in software volume
 * mode, so iOS scales the samples itself.
 *
 * Log lines start "NegroniAudio:" (stderr, as HackiOS does).
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "negroni_audio.h"

#include "AudioServerPlugIn.h"

/* ---- the objects ---- */

enum {
	OBJECT_PLUGIN = 1,
	OBJECT_SPEAKER, OBJECT_SPEAKER_OUTPUT, OBJECT_SPEAKER_INPUT,
	OBJECT_HAWKING, OBJECT_HAWKING_INPUT,
	OBJECT_ACTUATOR, OBJECT_ACTUATOR_OUTPUT,
	OBJECT_CODEC, OBJECT_CODEC_INPUT,
	OBJECT_SPEAKER_VOLUME,          /* volume control of the Speaker output */
	OBJECT_CODEC_SOURCE,            /* data source control of the Codec input */
	OBJECT_LAST = OBJECT_CODEC_SOURCE
};

#define VOLUME_RANGE_DB         48.0
#define TRANSPORT_BUILT_IN      'bltn'
#define MIC_SOURCE              'imic'  /* VirtualAudio keeps only data sources it knows (HackiOS) */
#define MANUFACTURER            CFSTR("iOSPlus10")
#define TIMESTAMP_PERIOD        16384   /* frames between zero time stamps; the largest HAL buffer */
#define REOPEN_NS               2000000000ull   /* try /dev/negroni-audio again at most every 2 s */

struct device {
	AudioObjectID object;
	CFStringRef uid;
	AudioObjectID output, input;
	UInt32 output_channels, input_channels;
	unsigned running;
	UInt64 anchor;                  /* mach_absolute_time() at the first StartIO (0: never started) */
};

static struct device devices[] = {
	{ .object = OBJECT_SPEAKER, .uid = CFSTR("Speaker"), .output = OBJECT_SPEAKER_OUTPUT, .input = OBJECT_SPEAKER_INPUT,
	  .output_channels = NEGRONI_AUDIO_CHANNELS, .input_channels = 2 },
	{ .object = OBJECT_HAWKING, .uid = CFSTR("Hawking"), .input = OBJECT_HAWKING_INPUT, .input_channels = 1 },
	{ .object = OBJECT_ACTUATOR, .uid = CFSTR("Actuator"), .output = OBJECT_ACTUATOR_OUTPUT, .output_channels = 1 },
	{ .object = OBJECT_CODEC, .uid = CFSTR("Codec"), .input = OBJECT_CODEC_INPUT, .input_channels = 1 },
};
#define DEVICES                 (sizeof(devices) / sizeof(devices[0]))

static AudioServerPlugInHostRef host;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int sink = -1;                   /* /dev/negroni-audio, -1 = not open */
static UInt64 sink_tried;               /* mach_absolute_time() of the last open() */
static Float64 ticks_per_frame;
static UInt64 ns_numer = 1, ns_denom = 1;
static UInt64 written, refused;         /* frames since the Speaker started */
static Boolean inactive[OBJECT_LAST + 1];
static Float32 volume = 1.0f;

static void
say(const char *format, ...)
{
	char line[256];
	va_list ap;
	int n;

	memcpy(line, "NegroniAudio: ", 14);
	va_start(ap, format);
	n = vsnprintf(line + 14, sizeof(line) - 15, format, ap);
	va_end(ap);
	if (n < 0) {
		return;
	}
	n = n + 14 > (int)sizeof(line) - 2 ? (int)sizeof(line) - 2 : n + 14;
	line[n++] = '\n';
	(void)write(2, line, (size_t)n);
}

static Float32
scalar_to_db(Float32 scalar)
{
	scalar = scalar < 0 ? 0 : scalar > 1 ? 1 : scalar;
	return (Float32)(-VOLUME_RANGE_DB * (1.0 - scalar));
}

static Float32
db_to_scalar(Float32 db)
{
	Float32 scalar = (Float32)(1.0 + db / VOLUME_RANGE_DB);

	return scalar < 0 ? 0 : scalar > 1 ? 1 : scalar;
}

/* With the lock held. */
static void
volume_to_kernel(void)
{
	struct negroni_audio_volume v = { (uint32_t)lround(-scalar_to_db(volume) * 8), volume <= 0 };

	if (sink < 0) {
		return;
	}
	if (ioctl(sink, NEGRONI_AUDIO_SET_VOLUME, &v) < 0) {
		say("volume %.3f not given to the kernel (%s)", volume, strerror(errno));
		return;
	}
	say("volume %.3f: %s%.1f dB below the kernel maximum", volume, v.muted ? "muted, " : "", v.below / 8.0);
}

/*
 * Open /dev/negroni-audio if it is not open. The node exists only with the kernel boot-arg
 * negroniaudio=1; without it the samples are dropped (stage 0). With the lock held; not
 * called from the I/O thread (StartIO only), so open() may take its time.
 */
static void
sink_open(void)
{
	UInt64 now = mach_absolute_time();

	if (sink >= 0 || (sink_tried != 0 && (now - sink_tried) * ns_numer / ns_denom < REOPEN_NS)) {
		return;
	}
	sink_tried = now;
	sink = open(NEGRONI_AUDIO_DEVICE, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (sink >= 0) {
		say("%s open: the Speaker output goes to the kernel", NEGRONI_AUDIO_DEVICE);
		volume_to_kernel();
	} else {
		say("%s: %s: the Speaker output is dropped", NEGRONI_AUDIO_DEVICE, strerror(errno));
	}
}

static struct device *
device_of(AudioObjectID object)
{
	for (unsigned i = 0; i < DEVICES; i++) {
		if (object == devices[i].object || (object != 0 && (object == devices[i].output || object == devices[i].input))) {
			return &devices[i];
		}
	}
	return NULL;
}

static AudioStreamBasicDescription
format_of(AudioObjectID stream)
{
	const struct device *d = device_of(stream);
	UInt32 channels = d == NULL ? 2 : stream == d->output ? d->output_channels : d->input_channels;

	return (AudioStreamBasicDescription) {
		       .mSampleRate = NEGRONI_AUDIO_RATE, .mFormatID = kAudioFormatLinearPCM,
		       .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
		       .mBytesPerPacket = 2 * channels, .mFramesPerPacket = 1, .mBytesPerFrame = 2 * channels,
		       .mChannelsPerFrame = channels, .mBitsPerChannel = 16,
	};
}

static HRESULT
query_interface(void *driver, REFIID uuid, LPVOID *interface)
{
	CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
	Boolean ours = requested != NULL && (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID));

	if (requested != NULL) {
		CFRelease(requested);
	}
	if (interface == NULL || !ours) {
		return E_NOINTERFACE;
	}
	*interface = driver;            /* one static driver: no reference counts */
	return S_OK;
}

static ULONG
add_ref(__unused void *driver)
{
	return 1;
}

static ULONG
release(__unused void *driver)
{
	return 1;
}

static OSStatus
initialize(__unused AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef the_host)
{
	mach_timebase_info_data_t timebase;

	host = the_host;
	mach_timebase_info(&timebase);
	ns_numer = timebase.numer;
	ns_denom = timebase.denom ? timebase.denom : 1;
	ticks_per_frame = 1e9 * timebase.denom / timebase.numer / NEGRONI_AUDIO_RATE;
	pthread_mutex_lock(&lock);
	sink_open();
	pthread_mutex_unlock(&lock);
	say("initialized: Speaker, Hawking, Actuator, Codec (timebase %u/%u)", timebase.numer, timebase.denom);
	return 0;
}

static OSStatus
create_device(__unused AudioServerPlugInDriverRef driver, __unused CFDictionaryRef description,
    __unused const AudioServerPlugInClientInfo *client, __unused AudioObjectID *object)
{
	return kAudioHardwareUnsupportedOperationError;
}

static OSStatus
destroy_device(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object)
{
	return kAudioHardwareUnsupportedOperationError;
}

static OSStatus
device_client(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object,
    __unused const AudioServerPlugInClientInfo *client)
{
	return 0;
}

static OSStatus
configuration_change(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object, __unused UInt64 action,
    __unused void *info)
{
	return 0;
}

/* A property value: size bytes, or an empty list, or (neither) no such property. */
struct value {
	UInt32 size;
	bool empty;
	bool string;                    /* a CFString: the caller gets its own reference */
	union {
		UInt32 words[4];
		Float64 number;
		Float32 decimal;
		CFStringRef string;
		AudioValueRange range;
		AudioStreamBasicDescription format;
		AudioStreamRangedDescription ranged;
	} u;
};

static struct value
control_property(AudioObjectID object, UInt32 selector, UInt32 qualifier_size, const void *qualifier)
{
	struct value v;

	memset(&v, 0, sizeof(v));
#define WORD(x)         (v.u.words[0] = (x), v.size = sizeof(UInt32))
#define STRING(x)       (v.u.string = (x), v.string = true, v.size = sizeof(CFStringRef))
#define FLOAT(x)        (v.u.decimal = (x), v.size = sizeof(Float32))
	bool vol = object == OBJECT_SPEAKER_VOLUME;

	switch (selector) {
	case kAudioObjectPropertyBaseClass:
		WORD(vol ? kAudioLevelControlClassID : kAudioSelectorControlClassID);
		break;
	case kAudioObjectPropertyClass:
		WORD(vol ? kAudioVolumeControlClassID : kAudioDataSourceControlClassID);
		break;
	case kAudioObjectPropertyOwner:
		WORD(vol ? OBJECT_SPEAKER : OBJECT_CODEC);
		break;
	case kAudioObjectPropertyOwnedObjects:
		v.empty = true;
		break;
	case kAudioControlPropertyScope:
		WORD(vol ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput);
		break;
	case kAudioControlPropertyElement:
		WORD(0);
		break;
	}
	if (vol) {
		switch (selector) {
		case kAudioLevelControlPropertyScalarValue:
			FLOAT(volume);
			break;
		case kAudioLevelControlPropertyDecibelValue:
			FLOAT(scalar_to_db(volume));
			break;
		case kAudioLevelControlPropertyDecibelRange:
			v.u.range.mMinimum = -VOLUME_RANGE_DB;
			v.u.range.mMaximum = 0;
			v.size = sizeof(AudioValueRange);
			break;
		case kAudioLevelControlPropertyConvertScalarToDecibels:
		case kAudioLevelControlPropertyConvertDecibelsToScalar:
			FLOAT(0);       /* converted in place in get_property_data() */
			break;
		}
	} else {
		switch (selector) {
		case kAudioSelectorControlPropertyCurrentItem:
		case kAudioSelectorControlPropertyAvailableItems:
			WORD(MIC_SOURCE);
			break;
		case kAudioSelectorControlPropertyItemName:
			if (qualifier_size == sizeof(UInt32) && qualifier != NULL && *(const UInt32 *)qualifier == MIC_SOURCE) {
				STRING(CFSTR("Bottom"));
			} else {
				STRING(CFSTR(""));
			}
			break;
		}
	}
#undef WORD
#undef STRING
#undef FLOAT
	return v;
}

static struct value
property(AudioObjectID object, const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier)
{
	UInt32 selector = address->mSelector, scope = address->mScope;
	const struct device *d = device_of(object);
	struct value v;

	if (object == OBJECT_SPEAKER_VOLUME || object == OBJECT_CODEC_SOURCE) {
		return control_property(object, selector, qualifier_size, qualifier);
	}
	memset(&v, 0, sizeof(v));
	if (object != OBJECT_PLUGIN && d == NULL) {
		return v;
	}
#define WORD(x)         (v.u.words[0] = (x), v.size = sizeof(UInt32))
#define LIST(x)         (v.u.words[v.size / sizeof(UInt32)] = (x), v.size += sizeof(UInt32))
#define STRING(x)       (v.u.string = (x), v.string = true, v.size = sizeof(CFStringRef))
	switch (selector) {
	case kAudioObjectPropertyBaseClass:
		WORD(kAudioObjectClassID);
		return v;
	case kAudioObjectPropertyClass:
		WORD(object == OBJECT_PLUGIN ? kAudioPlugInClassID : object == d->object ? kAudioDeviceClassID : kAudioStreamClassID);
		return v;
	case kAudioObjectPropertyOwner:
		WORD(object == OBJECT_PLUGIN ? 0 : object == d->object ? OBJECT_PLUGIN : d->object);
		return v;
	}
	if (object == OBJECT_PLUGIN) {
		switch (selector) {
		case kAudioObjectPropertyManufacturer:
			STRING(MANUFACTURER);
			break;
		case kAudioObjectPropertyOwnedObjects:
		case kAudioPlugInPropertyDeviceList:
			for (unsigned i = 0; i < DEVICES; i++) {
				LIST(devices[i].object);
			}
			break;
		case kAudioPlugInPropertyBoxList:
			v.empty = true;
			break;
		case kAudioPlugInPropertyTranslateUIDToBox:
			WORD(0);
			break;
		case kAudioPlugInPropertyTranslateUIDToDevice:
			WORD(0);
			for (unsigned i = 0; i < DEVICES; i++) {
				if (qualifier_size == sizeof(CFStringRef) && qualifier != NULL && *(const CFStringRef *)qualifier != NULL &&
				    CFEqual(*(const CFStringRef *)qualifier, devices[i].uid)) {
					WORD(devices[i].object);
				}
			}
			break;
		case kAudioPlugInPropertyResourceBundle:
			STRING(CFSTR(""));
			break;
		}
	} else if (object == d->object) {
		switch (selector) {
		case kAudioObjectPropertyManufacturer:
			STRING(MANUFACTURER);
			break;
		case kAudioObjectPropertyName:
		case kAudioDevicePropertyDeviceUID:
		case kAudioDevicePropertyModelUID:
			STRING(d->uid);
			break;
		case kAudioDevicePropertyTransportType:
			WORD(TRANSPORT_BUILT_IN);
			break;
		case kAudioDevicePropertyRelatedDevices:
			WORD(d->object);
			break;
		case kAudioDevicePropertyClockDomain:
		case kAudioDevicePropertyLatency:
		case kAudioDevicePropertySafetyOffset:
		case kAudioDevicePropertyIsHidden:
			WORD(0);
			break;
		case kAudioDevicePropertyDeviceIsAlive:
			WORD(1);
			break;
		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
			WORD(d->output != 0);
			break;
		case kAudioDevicePropertyDeviceIsRunning:
			WORD(d->running != 0);
			break;
		case kAudioObjectPropertyOwnedObjects:
		case kAudioDevicePropertyStreams:
			if (scope != kAudioObjectPropertyScopeInput && d->output != 0) {
				LIST(d->output);
			}
			if (scope != kAudioObjectPropertyScopeOutput && d->input != 0) {
				LIST(d->input);
			}
			if (selector == kAudioObjectPropertyOwnedObjects && d->object == OBJECT_SPEAKER) {
				LIST(OBJECT_SPEAKER_VOLUME);
			}
			if (selector == kAudioObjectPropertyOwnedObjects && d->object == OBJECT_CODEC && scope != kAudioObjectPropertyScopeOutput) {
				LIST(OBJECT_CODEC_SOURCE);
			}
			v.empty = v.size == 0;
			break;
		case kAudioObjectPropertyControlList:
			if (d->object == OBJECT_SPEAKER) {
				LIST(OBJECT_SPEAKER_VOLUME);
			}
			if (d->object == OBJECT_CODEC) {
				LIST(OBJECT_CODEC_SOURCE);
			}
			v.empty = v.size == 0;
			break;
		case kAudioDevicePropertyNominalSampleRate:
			v.u.number = NEGRONI_AUDIO_RATE;
			v.size = sizeof(Float64);
			break;
		case kAudioDevicePropertyAvailableNominalSampleRates:
			v.u.range.mMinimum = v.u.range.mMaximum = NEGRONI_AUDIO_RATE;
			v.size = sizeof(AudioValueRange);
			break;
		case kAudioDevicePropertyPreferredChannelsForStereo:
			v.u.words[0] = 1;
			v.u.words[1] = 2;
			v.size = 2 * sizeof(UInt32);
			break;
		case kAudioDevicePropertyZeroTimeStampPeriod:
			WORD(TIMESTAMP_PERIOD);
			break;
		}
	} else {
		switch (selector) {
		case kAudioStreamPropertyIsActive:
			WORD(!inactive[object]);
			break;
		case kAudioStreamPropertyDirection:
			WORD(object == d->input);
			break;
		case kAudioStreamPropertyTerminalType:
			WORD(object == d->input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
			break;
		case kAudioStreamPropertyStartingChannel:
			WORD(1);
			break;
		case kAudioStreamPropertyLatency:
			WORD(0);
			break;
		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
			v.u.format = format_of(object);
			v.size = sizeof(AudioStreamBasicDescription);
			break;
		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			v.u.ranged.mFormat = format_of(object);
			v.u.ranged.mSampleRateRange.mMinimum = v.u.ranged.mSampleRateRange.mMaximum = NEGRONI_AUDIO_RATE;
			v.size = sizeof(AudioStreamRangedDescription);
			break;
		}
	}
#undef WORD
#undef LIST
#undef STRING
	return v;
}

/* Properties asked for that we do not have: the first 64 (object, selector, scope), once each. */
#define UNKNOWN_TOLD            64
static UInt32 unknown_told[UNKNOWN_TOLD][3];
static unsigned unknown_count;

static void
unknown(AudioObjectID object, const AudioObjectPropertyAddress *address)
{
	UInt32 s = address->mSelector, c = address->mScope;
	const struct device *d = device_of(object);
	char uid[32] = "-";

	for (unsigned i = 0; i < unknown_count; i++) {
		if (unknown_told[i][0] == object && unknown_told[i][1] == s && unknown_told[i][2] == c) {
			return;
		}
	}
	if (unknown_count >= UNKNOWN_TOLD) {
		return;
	}
	unknown_told[unknown_count][0] = object;
	unknown_told[unknown_count][1] = s;
	unknown_told[unknown_count][2] = c;
	unknown_count++;
	if (d != NULL) {
		(void)CFStringGetCString(d->uid, uid, sizeof(uid), kCFStringEncodingUTF8);
	}
	say("object %u (%s) has no '%c%c%c%c' (%#x), scope '%c%c%c%c', element %u", (unsigned)object, uid,
	    (int)(s >> 24 & 0xff), (int)(s >> 16 & 0xff), (int)(s >> 8 & 0xff), (int)(s & 0xff), (unsigned)s,
	    (int)(c >> 24 & 0xff), (int)(c >> 16 & 0xff), (int)(c >> 8 & 0xff), (int)(c & 0xff), (unsigned)address->mElement);
}

static Boolean
has_property(__unused AudioServerPlugInDriverRef driver, AudioObjectID object, __unused pid_t client,
    const AudioObjectPropertyAddress *address)
{
	struct value v;

	if (address == NULL) {
		return false;
	}
	v = property(object, address, 0, NULL);
	if (v.size == 0 && !v.empty) {
		unknown(object, address);
	}
	return v.size != 0 || v.empty;
}

static OSStatus
is_property_settable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
    const AudioObjectPropertyAddress *address, Boolean *settable)
{
	const struct device *d = device_of(object);

	if (address == NULL || settable == NULL || !has_property(driver, object, client, address)) {
		return kAudioHardwareUnknownPropertyError;
	}
	if (object == OBJECT_SPEAKER_VOLUME) {
		*settable = address->mSelector == kAudioLevelControlPropertyScalarValue ||
		    address->mSelector == kAudioLevelControlPropertyDecibelValue;
	} else if (object == OBJECT_CODEC_SOURCE) {
		*settable = address->mSelector == kAudioSelectorControlPropertyCurrentItem;
	} else if (object == OBJECT_PLUGIN || d == NULL) {
		*settable = false;
	} else if (object == d->object) {
		*settable = address->mSelector == kAudioDevicePropertyNominalSampleRate;
	} else {
		*settable = address->mSelector == kAudioStreamPropertyIsActive ||
		    address->mSelector == kAudioStreamPropertyVirtualFormat || address->mSelector == kAudioStreamPropertyPhysicalFormat;
	}
	return 0;
}

static OSStatus
get_property_data_size(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
    const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier, UInt32 *size)
{
	if (address == NULL || size == NULL || !has_property(driver, object, client, address)) {
		return object < OBJECT_PLUGIN || object > OBJECT_LAST ? kAudioHardwareBadObjectError : kAudioHardwareUnknownPropertyError;
	}
	*size = property(object, address, qualifier_size, qualifier).size;
	return 0;
}

static OSStatus
get_property_data(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
    const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier, UInt32 room, UInt32 *size,
    void *data)
{
	struct value v;

	if (address == NULL || size == NULL || data == NULL || !has_property(driver, object, client, address)) {
		return object < OBJECT_PLUGIN || object > OBJECT_LAST ? kAudioHardwareBadObjectError : kAudioHardwareUnknownPropertyError;
	}
	if (object == OBJECT_SPEAKER_VOLUME && (address->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels ||
	    address->mSelector == kAudioLevelControlPropertyConvertDecibelsToScalar)) {
		if (room < sizeof(Float32)) {
			return kAudioHardwareBadPropertySizeError;
		}
		*(Float32 *)data = address->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels ?
		    scalar_to_db(*(Float32 *)data) : db_to_scalar(*(Float32 *)data);
		*size = sizeof(Float32);
		return 0;
	}
	pthread_mutex_lock(&lock);
	v = property(object, address, qualifier_size, qualifier);
	pthread_mutex_unlock(&lock);
	if (v.size > room) {
		/* lists may be read in part; anything else must fit */
		if (address->mSelector != kAudioObjectPropertyOwnedObjects && address->mSelector != kAudioDevicePropertyStreams &&
		    address->mSelector != kAudioPlugInPropertyDeviceList && address->mSelector != kAudioObjectPropertyControlList) {
			return kAudioHardwareBadPropertySizeError;
		}
		v.size = room - room % sizeof(UInt32);
	}
	memcpy(data, &v.u, v.size);
	if (v.string && v.size == sizeof(CFStringRef)) {
		CFRetain(v.u.string);
	}
	*size = v.size;
	return 0;
}

static OSStatus
set_property_data(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
    const AudioObjectPropertyAddress *address, __unused UInt32 qualifier_size, __unused const void *qualifier, UInt32 size,
    const void *data)
{
	Boolean settable = false;

	if (address == NULL || data == NULL || is_property_settable(driver, object, client, address, &settable) != 0) {
		return kAudioHardwareUnknownPropertyError;
	}
	if (!settable) {
		return kAudioHardwareIllegalOperationError;
	}
	if (object == OBJECT_SPEAKER_VOLUME) {
		AudioObjectPropertyAddress changed[2] = {
			{ kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, 0 },
			{ kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, 0 },
		};
		Float32 wanted;

		if (size != sizeof(Float32)) {
			return kAudioHardwareBadPropertySizeError;
		}
		wanted = *(const Float32 *)data;
		if (wanted != wanted) {         /* NaN */
			return kAudioHardwareIllegalOperationError;
		}
		wanted = address->mSelector == kAudioLevelControlPropertyDecibelValue ? db_to_scalar(wanted) :
		    wanted < 0 ? 0 : wanted > 1 ? 1 : wanted;
		pthread_mutex_lock(&lock);
		volume = wanted;
		volume_to_kernel();
		pthread_mutex_unlock(&lock);
		if (host != NULL) {
			host->PropertiesChanged(host, OBJECT_SPEAKER_VOLUME, 2, changed);
		}
		return 0;
	}
	if (object == OBJECT_CODEC_SOURCE) {
		return size == sizeof(UInt32) ? (*(const UInt32 *)data == MIC_SOURCE ? 0 : kAudioHardwareIllegalOperationError) :
		       kAudioHardwareBadPropertySizeError;
	}
	if (address->mSelector == kAudioStreamPropertyIsActive) {
		if (size != sizeof(UInt32)) {
			return kAudioHardwareBadPropertySizeError;
		}
		pthread_mutex_lock(&lock);
		inactive[object] = *(const UInt32 *)data == 0;
		pthread_mutex_unlock(&lock);
		return 0;
	}
	if (address->mSelector == kAudioDevicePropertyNominalSampleRate) {
		return size == sizeof(Float64) && *(const Float64 *)data == NEGRONI_AUDIO_RATE ? 0 : kAudioDeviceUnsupportedFormatError;
	}
	/* a stream format: only the one there is */
	if (size != sizeof(AudioStreamBasicDescription)) {
		return kAudioHardwareBadPropertySizeError;
	} else {
		const AudioStreamBasicDescription *wanted = data, format = format_of(object);

		return wanted->mSampleRate == format.mSampleRate && wanted->mFormatID == format.mFormatID &&
		       wanted->mChannelsPerFrame == format.mChannelsPerFrame && wanted->mBitsPerChannel == format.mBitsPerChannel &&
		       (wanted->mFormatFlags & kAudioFormatFlagIsSignedInteger) ? 0 : kAudioDeviceUnsupportedFormatError;
	}
}

static OSStatus
start_io(__unused AudioServerPlugInDriverRef driver, AudioObjectID object, __unused UInt32 client)
{
	struct device *d = device_of(object);

	if (d == NULL || object != d->object) {
		return kAudioHardwareBadObjectError;
	}
	pthread_mutex_lock(&lock);
	if (d->running++ == 0) {
		__atomic_store_n(&d->anchor, mach_absolute_time(), __ATOMIC_RELEASE);
		if (d->object == OBJECT_SPEAKER) {
			written = refused = 0;
			sink_open();
			say("Speaker starts (%s)", sink >= 0 ? "to the kernel" : "dropped");
		}
	}
	pthread_mutex_unlock(&lock);
	return 0;
}

static OSStatus
stop_io(__unused AudioServerPlugInDriverRef driver, AudioObjectID object, __unused UInt32 client)
{
	struct device *d = device_of(object);

	if (d == NULL || object != d->object) {
		return kAudioHardwareBadObjectError;
	}
	pthread_mutex_lock(&lock);
	if (d->running != 0 && --d->running == 0 && d->object == OBJECT_SPEAKER) {
		say("Speaker stops after %llu.%02llu s (%llu frames not taken)", written / NEGRONI_AUDIO_RATE,
		    written % NEGRONI_AUDIO_RATE * 100 / NEGRONI_AUDIO_RATE, refused);
	}
	pthread_mutex_unlock(&lock);
	return 0;
}

/*
 * The last device time at a multiple of TIMESTAMP_PERIOD frames, and its host time. Called on
 * the HAL real-time I/O thread: no lock (start_io holds it during open()), no loop. anchor is
 * one aligned 64-bit word, written by start_io only.
 */
static OSStatus
get_zero_time_stamp(__unused AudioServerPlugInDriverRef driver, AudioObjectID object, __unused UInt32 client,
    Float64 *sample_time, UInt64 *host_time, UInt64 *seed)
{
	Float64 ticks_per_period = ticks_per_frame * TIMESTAMP_PERIOD;
	UInt64 now = mach_absolute_time();
	struct device *d = device_of(object);
	UInt64 anchor, periods;

	if (d == NULL || sample_time == NULL || host_time == NULL || seed == NULL) {
		return kAudioHardwareBadObjectError;
	}
	anchor = __atomic_load_n(&d->anchor, __ATOMIC_ACQUIRE);
	if (anchor == 0 || now < anchor) {      /* not started yet: the clock stands at 0 */
		anchor = now;
	}
	periods = (UInt64)((Float64)(now - anchor) / ticks_per_period);
	*sample_time = (Float64)periods * TIMESTAMP_PERIOD;
	*host_time = anchor + (UInt64)((Float64)periods * ticks_per_period);
	*seed = 1;
	return 0;
}

static OSStatus
will_do_io_operation(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object, __unused UInt32 client,
    UInt32 operation, Boolean *will_do, Boolean *in_place)
{
	if (will_do == NULL || in_place == NULL) {
		return kAudioHardwareIllegalOperationError;
	}
	*will_do = operation == kAudioServerPlugInIOOperationReadInput || operation == kAudioServerPlugInIOOperationWriteMix;
	*in_place = true;
	return 0;
}

static OSStatus
begin_end_io_operation(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object, __unused UInt32 client,
    __unused UInt32 operation, __unused UInt32 frames, __unused const AudioServerPlugInIOCycleInfo *cycle)
{
	return 0;
}

/* The HAL I/O thread: no locks, no waits. */
static OSStatus
do_io_operation(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object, AudioObjectID stream,
    __unused UInt32 client, UInt32 operation, UInt32 frames, __unused const AudioServerPlugInIOCycleInfo *cycle, void *buffer,
    __unused void *secondary)
{
	const struct device *d = device_of(stream);

	if (d == NULL || buffer == NULL) {
		return kAudioHardwareBadObjectError;
	}
	if (operation == kAudioServerPlugInIOOperationReadInput) {
		/* every input is silent: Speaker sense, Hawking, Codec (no microphone driver) */
		memset(buffer, 0, (size_t)frames * 2 * (stream == d->input ? d->input_channels : 1));
	} else if (operation == kAudioServerPlugInIOOperationWriteMix && stream == OBJECT_SPEAKER_OUTPUT) {
		int fd = sink;
		ssize_t n = fd >= 0 ? write(fd, buffer, (size_t)frames * NEGRONI_AUDIO_FRAME) : -1;
		UInt32 took = n > 0 ? (UInt32)n / NEGRONI_AUDIO_FRAME : 0;

		refused += frames - (took < frames ? took : frames);
		written += frames;
	}
	/* the Actuator output (haptics) is dropped: no motor driver yet */
	return 0;
}

static AudioServerPlugInDriverInterface interface = {
	NULL, query_interface, add_ref, release, initialize, create_device, destroy_device, device_client, device_client,
	configuration_change, configuration_change, has_property, is_property_settable, get_property_data_size,
	get_property_data, set_property_data, start_io, stop_io, get_zero_time_stamp, will_do_io_operation,
	begin_end_io_operation, do_io_operation, begin_end_io_operation,
};
static AudioServerPlugInDriverInterface *driver = &interface;

/* The factory named in Info.plist (CFPlugInFactories). */
__attribute__((visibility("default"))) void *NegroniAudio_Create(CFAllocatorRef allocator, CFUUIDRef type);

void *
NegroniAudio_Create(__unused CFAllocatorRef allocator, CFUUIDRef type)
{
	return type != NULL && CFEqual(type, kAudioServerPlugInTypeUUID) ? &driver : NULL;
}
