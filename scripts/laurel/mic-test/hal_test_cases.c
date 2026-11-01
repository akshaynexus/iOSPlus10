/* the cases of hal_test.c */
static void
what_ios_sees(void)
{
	UInt32 words[8], n = 0, w = 0;
	CFStringRef uid = NULL;
	AudioStreamBasicDescription f;
	Float32 v = 0;
	AudioValueRange r;
	int have_codec = 0;

	CHECK(get(OBJECT_PLUGIN, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, words, sizeof(words), &n) == 0, "device list");
	for (unsigned i = 0; i < n / 4; i++) {
		CHECK(get(words[i], kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &uid, sizeof(uid), NULL) == 0, "uid");
		have_codec += strcmp(uid, "Codec") == 0;
	}
	CHECK(have_codec == 1, "the plug-in has no device \"Codec\" (VirtualAudio's microphone port)");

	CHECK(get(OBJECT_CODEC, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, words, sizeof(words), &n) == 0 && n == 4 &&
	    words[0] == OBJECT_CODEC_INPUT, "input stream list");
	CHECK(get(OBJECT_CODEC, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, words, sizeof(words), &n) == 0 && n == 0,
	    "the Codec has no output");
	CHECK(get(OBJECT_CODEC_INPUT, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal, &w, 4, NULL) == 0 && w == 1, "direction: input");
	CHECK(get(OBJECT_CODEC_INPUT, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal, &w, 4, NULL) == 0 &&
	    w == kAudioStreamTerminalTypeMicrophone, "terminal type: microphone");
	CHECK(get(OBJECT_CODEC_INPUT, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, &f, sizeof(f), NULL) == 0, "format");
	CHECK(f.mSampleRate == 48000 && f.mFormatID == kAudioFormatLinearPCM && f.mChannelsPerFrame == 1 && f.mBitsPerChannel == 16 &&
	    f.mBytesPerFrame == 2 && f.mFramesPerPacket == 1 && (f.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0,
	    "format: 48 kHz S16 mono (the kernel's)");

	/* VirtualAudio does not take a codec without a data source it knows; the source + the new volume are controls */
	CHECK(get(OBJECT_CODEC, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal, words, sizeof(words), &n) == 0 && n == 8 &&
	    words[0] == OBJECT_CODEC_SOURCE && words[1] == OBJECT_CODEC_VOLUME, "control list");
	CHECK(get(OBJECT_CODEC_SOURCE, kAudioSelectorControlPropertyCurrentItem, kAudioObjectPropertyScopeGlobal, &w, 4, NULL) == 0 && w == MIC_SOURCE,
	    "data source 'imic'");
	CHECK(get(OBJECT_CODEC_VOLUME, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, &w, 4, NULL) == 0 && w == kAudioVolumeControlClassID,
	    "volume control class");
	CHECK(get(OBJECT_CODEC_VOLUME, kAudioControlPropertyScope, kAudioObjectPropertyScopeGlobal, &w, 4, NULL) == 0 && w == kAudioObjectPropertyScopeInput,
	    "volume control scope: input");
	CHECK(get(OBJECT_CODEC_VOLUME, kAudioObjectPropertyOwner, kAudioObjectPropertyScopeGlobal, &w, 4, NULL) == 0 && w == OBJECT_CODEC,
	    "volume control owner");
	CHECK(get(OBJECT_CODEC_VOLUME, kAudioLevelControlPropertyDecibelRange, kAudioObjectPropertyScopeGlobal, &r, sizeof(r), NULL) == 0 &&
	    r.mMinimum == -MIC_RANGE_DB && r.mMaximum == 0, "volume range");
	CHECK(get(OBJECT_CODEC_VOLUME, kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, &v, 4, NULL) == 0 && v == 1.0f,
	    "the capture gain starts at the top");
	CHECK(get(OBJECT_SPEAKER_VOLUME, kAudioControlPropertyScope, kAudioObjectPropertyScopeGlobal, &w, 4, NULL) == 0 && w == kAudioObjectPropertyScopeOutput,
	    "the speaker's volume is unchanged");
	CHECK(get(OBJECT_SPEAKER_VOLUME, kAudioLevelControlPropertyDecibelRange, kAudioObjectPropertyScopeGlobal, &r, sizeof(r), NULL) == 0 &&
	    r.mMinimum == -VOLUME_RANGE_DB, "the speaker's range is unchanged");
}

static void
io_read(AudioObjectID dev, AudioObjectID stream, int16_t *buf, UInt32 frames)
{
	CHECK((*D)->DoIOOperation(D, dev, stream, 1, kAudioServerPlugInIOOperationReadInput, frames, NULL, buf, NULL) == 0, "DoIO read");
}

static void
capture(void)
{
	int16_t buf[1024];
	Boolean will = 0, in_place = 0;

	for (int i = 0; i < 4096; i++) {
		mock_samples[i] = (int16_t)(i * 7 - 1000);
	}
	CHECK((*D)->WillDoIOOperation(D, OBJECT_CODEC, 1, kAudioServerPlugInIOOperationReadInput, &will, &in_place) == 0 && will, "WillDo read");

	/* the kernel's device is opened only while the input runs */
	CHECK(opens == 0 && !mic_fd_open, "open before StartIO");
	CHECK((*D)->StartIO(D, OBJECT_CODEC, 1) == 0, "StartIO");
	CHECK(opens == 1 && mic_fd_open, "StartIO must open /dev/redwood-mic");
	CHECK((*D)->StartIO(D, OBJECT_CODEC, 2) == 0 && opens == 1, "a second client must not open it again");

	/* samples pass unchanged */
	memset(buf, 0x55, sizeof(buf));
	io_read(OBJECT_CODEC, OBJECT_CODEC_INPUT, buf, 512);
	CHECK(memcmp(buf, mock_samples, 512 * 2) == 0, "samples differ");
	CHECK(mic_heard == 512 && mic_frames == 512, "counted %llu of %llu", (unsigned long long)mic_heard, (unsigned long long)mic_frames);

	/* a short read: the rest is silence */
	mock_short = 200 * 2;
	memset(buf, 0x55, sizeof(buf));
	io_read(OBJECT_CODEC, OBJECT_CODEC_INPUT, buf, 512);
	CHECK(memcmp(buf, mock_samples, 200 * 2) == 0 && buf[200] == 0 && buf[511] == 0, "short read");
	mock_short = 0;

	/* the kernel has nothing or fails: silence, no error */
	mock_err = 1;
	memset(buf, 0x55, sizeof(buf));
	io_read(OBJECT_CODEC, OBJECT_CODEC_INPUT, buf, 256);
	CHECK(buf[0] == 0 && buf[255] == 0, "read error must give silence");
	mock_err = 0;

	/* the other inputs stay silent */
	memset(buf, 0x55, sizeof(buf));
	io_read(OBJECT_HAWKING, OBJECT_HAWKING_INPUT, buf, 256);
	CHECK(buf[0] == 0 && buf[255] == 0, "Hawking must be silent");

	/* capture does not stop playback */
	(void)(*D)->StartIO(D, OBJECT_SPEAKER, 3);
	CHECK((*D)->DoIOOperation(D, OBJECT_SPEAKER, OBJECT_SPEAKER_OUTPUT, 3, kAudioServerPlugInIOOperationWriteMix, 256, NULL, buf, NULL) == 0 &&
	    sink_frames == 256, "playback must reach /dev/redwood-audio");
	(void)(*D)->StopIO(D, OBJECT_SPEAKER, 3);

	CHECK((*D)->StopIO(D, OBJECT_CODEC, 2) == 0 && closes == 0, "the first client's stop must not close");
	CHECK((*D)->StopIO(D, OBJECT_CODEC, 1) == 0 && closes == 1 && !mic_fd_open, "the last stop must close");

	/* the kernel's microphone is off (ENXIO): silence, and the speaker does not care */
	open_fails = 1;
	CHECK((*D)->StartIO(D, OBJECT_CODEC, 1) == 0, "StartIO with the mic off must still succeed");
	memset(buf, 0x55, sizeof(buf));
	io_read(OBJECT_CODEC, OBJECT_CODEC_INPUT, buf, 256);
	CHECK(buf[0] == 0 && buf[255] == 0, "mic off must give silence");
	CHECK((*D)->StopIO(D, OBJECT_CODEC, 1) == 0, "StopIO with the mic off");
	open_fails = 0;
}

static void
volume_(void)
{
	Float32 v = 0;

	/* set while the input is stopped: remembered, given at the next start */
	CHECK(set_float(OBJECT_CODEC_VOLUME, kAudioLevelControlPropertyScalarValue, 0.5f) == 0 && ioctls == 0, "set while stopped");
	CHECK(get(OBJECT_CODEC_VOLUME, kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, &v, 4, NULL) == 0 && v == -12.0f, "dB value %f", v);
	CHECK((*D)->StartIO(D, OBJECT_CODEC, 1) == 0 && ioctls == 1 && last_below == 96, "the gain at start: ioctls %d, below %u", ioctls, last_below);

	/* while running: at once; 0 is the bottom of the range, never silence */
	CHECK(set_float(OBJECT_CODEC_VOLUME, kAudioLevelControlPropertyScalarValue, 0.0f) == 0 && ioctls == 2 && last_below == 192, "scalar 0: below %u", last_below);
	CHECK(set_float(OBJECT_CODEC_VOLUME, kAudioLevelControlPropertyDecibelValue, 0.0f) == 0 && ioctls == 3 && last_below == 0, "0 dB: below %u", last_below);
	CHECK(set_float(OBJECT_CODEC_VOLUME, kAudioLevelControlPropertyScalarValue, 5.0f) == 0 && last_below == 0, "clamped");
	CHECK((*D)->StopIO(D, OBJECT_CODEC, 1) == 0, "stop");
	/* the top is the kernel's default: no ioctl at the next start */
	ioctls = 0;
	CHECK((*D)->StartIO(D, OBJECT_CODEC, 1) == 0 && ioctls == 0, "no ioctl at the top");
	CHECK((*D)->StopIO(D, OBJECT_CODEC, 1) == 0, "stop");
}

int
main(void)
{
	void *p = RedwoodAudio_Create(NULL, kAudioServerPlugInTypeUUID);

	CHECK(p != NULL, "factory");
	D = (AudioServerPlugInDriverRef)p;
	CHECK((*D)->Initialize(D, &host_if) == 0, "initialize");
	what_ios_sees();
	capture();
	volume_();
	printf("mic hal test: %s\n", fails == 0 ? "PASS" : "FAIL");
	return fails != 0;
}
