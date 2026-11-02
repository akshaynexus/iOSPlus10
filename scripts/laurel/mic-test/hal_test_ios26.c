/*
 * Host mock test of the iOS 26 build of RedwoodAudio.driver: audio_plugin.c + mic-input.patch + ios26-devices.patch against the mocks of hal_test.c (scripts/laurel/mic-host-test.sh, IOS26 part).
 * Proves the plug-in: five devices, four microphone channels from the kernel's one, no write of Baseband Voice to the speaker. Not iOS, not audiomxd.
 */
#define main hal16_main
#include "hal_test.c"
#undef main

static void
ios26_devices(void)
{
	UInt32 words[8], n = 0;
	CFStringRef uid = NULL;
	const char *want[] = { "Speaker", "Hawking", "Actuator", "Codec", "Baseband Voice" };
	int seen = 0;

	CHECK(get(OBJECT_PLUGIN, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, words, sizeof(words), &n) == 0 && n == 20, "five devices: %u bytes", n);
	for (unsigned i = 0; i < n / 4; i++) {
		CHECK(get(words[i], kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &uid, sizeof(uid), NULL) == 0, "uid");
		for (unsigned k = 0; k < 5; k++) {
			seen += strcmp(uid, want[k]) == 0;
		}
	}
	CHECK(seen == 5, "the five names: %d", seen);
}

static void
ios26_codec(void)
{
	AudioStreamBasicDescription f;
	UInt32 w = 0, n = 0, items[8];
	UInt32 two = 'mc02', old = 'imic', bad = 'xxxx';
	AudioObjectPropertyAddress a = { kAudioSelectorControlPropertyCurrentItem, kAudioObjectPropertyScopeGlobal, 0 };
	int16_t buf[4 * 64 + 4];

	CHECK(get(OBJECT_CODEC_INPUT, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, &f, sizeof(f), NULL) == 0, "format");
	CHECK(f.mChannelsPerFrame == 4 && f.mBytesPerFrame == 8 && f.mBitsPerChannel == 16 && f.mSampleRate == 48000, "Codec: 4 channels S16 48 kHz: %u", (unsigned)f.mChannelsPerFrame);
	CHECK(get(OBJECT_CODEC_SOURCE, kAudioSelectorControlPropertyCurrentItem, kAudioObjectPropertyScopeGlobal, &w, 4, NULL) == 0 && w == 'mc01', "current source mc01");
	CHECK(get(OBJECT_CODEC_SOURCE, kAudioSelectorControlPropertyAvailableItems, kAudioObjectPropertyScopeGlobal, items, sizeof(items), &n) == 0 && n == 16 && items[3] == 'mc04', "four sources: %u bytes", n);
	CHECK((*D)->SetPropertyData(D, OBJECT_CODEC_SOURCE, 1, &a, 0, NULL, 4, &two) == 0, "mc02 accepted");
	CHECK((*D)->SetPropertyData(D, OBJECT_CODEC_SOURCE, 1, &a, 0, NULL, 4, &old) == 0, "imic accepted");
	CHECK((*D)->SetPropertyData(D, OBJECT_CODEC_SOURCE, 1, &a, 0, NULL, 4, &bad) != 0, "an unknown source refused");

	for (int i = 0; i < 64; i++) {
		mock_samples[i] = (int16_t)(i * 100 - 3000);
	}
	/* the frames past the buffer's end stay: a canary */
	for (unsigned i = 0; i < sizeof(buf) / sizeof(buf[0]); i++) {
		buf[i] = 0x5a5a;
	}
	CHECK((*D)->StartIO(D, OBJECT_CODEC, 1) == 0, "StartIO");
	CHECK((*D)->DoIOOperation(D, OBJECT_CODEC, OBJECT_CODEC_INPUT, 1, kAudioServerPlugInIOOperationReadInput, 64, NULL, buf, NULL) == 0, "read");
	for (int i = 0; i < 64; i++) {
		for (int c = 0; c < 4; c++) {
			CHECK(buf[i * 4 + c] == mock_samples[i], "frame %d channel %d: %d", i, c, buf[i * 4 + c]);
		}
	}
	CHECK(buf[4 * 64] == 0x5a5a, "nothing past the buffer");
	/* a short read: the rest is silence in all four channels */
	mock_short = 20;        /* 10 samples */
	for (unsigned i = 0; i < sizeof(buf) / sizeof(buf[0]); i++) {
		buf[i] = 0x5a5a;
	}
	CHECK((*D)->DoIOOperation(D, OBJECT_CODEC, OBJECT_CODEC_INPUT, 1, kAudioServerPlugInIOOperationReadInput, 64, NULL, buf, NULL) == 0, "short read");
	CHECK(buf[9 * 4 + 3] == mock_samples[9] && buf[10 * 4] == 0 && buf[63 * 4 + 3] == 0 && buf[4 * 64] == 0x5a5a, "short read: %d %d", buf[9 * 4 + 3], buf[10 * 4]);
	mock_short = 0;
	CHECK((*D)->StopIO(D, OBJECT_CODEC, 1) == 0, "StopIO");
}

static void
ios26_baseband(void)
{
	UInt32 words[8], n = 0;
	int16_t out[128], in[64];
	unsigned before;

	CHECK(get(OBJECT_BASEBAND_VOICE, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, words, sizeof(words), &n) == 0 && n == 4 && words[0] == OBJECT_BASEBAND_VOICE_OUTPUT, "output stream");
	CHECK(get(OBJECT_BASEBAND_VOICE, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, words, sizeof(words), &n) == 0 && n == 4 && words[0] == OBJECT_BASEBAND_VOICE_INPUT, "input stream");
	memset(out, 0x11, sizeof(out));
	memset(in, 0x22, sizeof(in));
	(void)(*D)->StartIO(D, OBJECT_BASEBAND_VOICE, 5);
	before = sink_frames;
	CHECK((*D)->DoIOOperation(D, OBJECT_BASEBAND_VOICE, OBJECT_BASEBAND_VOICE_OUTPUT, 5, kAudioServerPlugInIOOperationWriteMix, 64, NULL, out, NULL) == 0 && sink_frames == before, "a call's output must not reach the speaker");
	CHECK((*D)->DoIOOperation(D, OBJECT_BASEBAND_VOICE, OBJECT_BASEBAND_VOICE_INPUT, 5, kAudioServerPlugInIOOperationReadInput, 64, NULL, in, NULL) == 0 && in[0] == 0 && in[63] == 0, "silence in");
	(void)(*D)->StopIO(D, OBJECT_BASEBAND_VOICE, 5);
	(void)(*D)->StartIO(D, OBJECT_SPEAKER, 6);
	before = sink_frames;
	CHECK((*D)->DoIOOperation(D, OBJECT_SPEAKER, OBJECT_SPEAKER_OUTPUT, 6, kAudioServerPlugInIOOperationWriteMix, 32, NULL, out, NULL) == 0 && sink_frames == before + 32, "the speaker still plays");
	(void)(*D)->StopIO(D, OBJECT_SPEAKER, 6);
}

int
main(void)
{
	void *p = RedwoodAudio_Create(NULL, kAudioServerPlugInTypeUUID);

	CHECK(p != NULL, "factory");
	D = (AudioServerPlugInDriverRef)p;
	CHECK((*D)->Initialize(D, &host_if) == 0, "initialize");
	ios26_devices();
	ios26_codec();
	ios26_baseband();
	printf("mic hal test, iOS 26 build: %s\n", fails == 0 ? "PASS" : "FAIL");
	return fails != 0;
}
