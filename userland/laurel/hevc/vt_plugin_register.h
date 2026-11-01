/* Part of vt_plugin.c: the session start, the vtable and the registration. Included once. */

static CFDataRef
copy_hvcc(CMVideoFormatDescriptionRef format)
{
	CFDictionaryRef atoms = CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
	CFTypeRef h;

	if (atoms == NULL || CFGetTypeID(atoms) != CFDictionaryGetTypeID()) {
		return NULL;
	}
	h = CFDictionaryGetValue(atoms, CFSTR("hvcC"));
	if (h != NULL && CFGetTypeID(h) == CFArrayGetTypeID() && CFArrayGetCount(h) > 0) {
		h = CFArrayGetValueAtIndex(h, 0);
	}
	return h != NULL && CFGetTypeID(h) == CFDataGetTypeID() ? CFRetain(h) : NULL;
}

/* The colour keys of a format description, as pixel buffer attachments. */
static CFDictionaryRef
copy_colours(CMVideoFormatDescriptionRef format)
{
	CFStringRef keys[] = { kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionExtension_ColorPrimaries,
		kCMFormatDescriptionExtension_TransferFunction };
	CFStringRef out[] = { kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey };
	CFMutableDictionaryRef d = NULL;

	for (int i = 0; i < 3; i++) {
		CFTypeRef v = CMFormatDescriptionGetExtension(format, keys[i]);

		if (v != NULL) {
			if (d == NULL) {
				d = CFDictionaryCreateMutable(NULL, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
			}
			CFDictionarySetValue(d, out[i], v);
		}
	}
	return d;
}

static OSStatus
start_session(VTVideoDecoderRef self, VTVideoDecoderSession session, CMVideoFormatDescriptionRef format)
{
	decoder *d = vt.storage(self);

	d->session = session;
	d->hvcc = copy_hvcc(format);
	if (d->hvcc == NULL || hv_parse_hvcc(CFDataGetBytePtr(d->hvcc), (size_t)CFDataGetLength(d->hvcc), &d->info) != 0) {
		say("LAUREL HEVC: session refused: the format description has no readable hvcC\n");
		return ERR_UNSUPPORTED;
	}
	if (d->info.bits > 12 || d->info.chroma_bits > 12) {
		say("LAUREL HEVC: session refused: %d-bit stream\n", d->info.bits);
		return ERR_UNSUPPORTED;
	}
	d->colours = copy_colours(format);
	return 0;
}

static Boolean
can_accept_format(VTVideoDecoderRef self, CMVideoFormatDescriptionRef format)
{
	decoder *d = vt.storage(self);
	CFDataRef h = copy_hvcc(format);
	Boolean same = h != NULL && d->hvcc != NULL && CFEqual(h, d->hvcc);

	if (h != NULL) {
		CFRelease(h);
	}
	return same;                    /* a new hvcC gets a new decoder from VideoToolbox: the simple, correct answer */
}

static OSStatus
copy_supported_properties(VTVideoDecoderRef self, CFDictionaryRef *out)
{
	(void)self;
	*out = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	return *out != NULL ? 0 : ERR_ALLOC;
}

static OSStatus
base_invalidate(void *self)
{
	decoder *d = vt.storage(self);

	if (d->core != NULL) {
		hv_flush(d->core);
	}
	/* no emit here: the session is going away, and VideoToolbox finished delayed frames first if it wanted them */
	memset(d->pending, 0, sizeof(d->pending));
	d->session = NULL;
	return 0;
}

static void
base_finalize(void *self)
{
	decoder *d = vt.storage(self);

	hv_close(d->core);
	d->core = NULL;
	if (d->hvcc != NULL) {
		CFRelease(d->hvcc);
		d->hvcc = NULL;
	}
	if (d->colours != NULL) {
		CFRelease(d->colours);
		d->colours = NULL;
	}
}

static CFStringRef
base_copy_debug_description(void *self)
{
	return CFStringCreateWithFormat(NULL, NULL, CFSTR("<LaurelHEVC %p>"), self);
}

static OSStatus
base_copy_property(void *self, CFStringRef key, CFAllocatorRef alloc, void *out)
{
	(void)self; (void)key; (void)alloc; (void)out;
	return ERR_VALUE_NOT_AVAILABLE;
}

static OSStatus
base_set_property(void *self, CFStringRef key, CFTypeRef value)
{
	(void)self; (void)key; (void)value;
	return ERR_PROPERTY_NOT_SUPPORTED;
}

static const base_class laurel_base = {
	.version = 1,
	.derived_storage_size = sizeof(decoder),
	.invalidate = base_invalidate,
	.finalize = base_finalize,
	.copy_debug_description = base_copy_debug_description,
	.copy_property = base_copy_property,
	.set_property = base_set_property,
};

static const decoder_class laurel_decoder = {
	.version = 3,
	.start_session = start_session,
	.decode_frame = decode_frame,
	.copy_supported_properties = copy_supported_properties,
	.can_accept_format = can_accept_format,
	.finish_delayed_frames = finish_delayed_frames,
};

static const decoder_vtable laurel_vtable = { NULL, &laurel_base, &laurel_decoder };

/* VTVideoDecoderCreateInstance [V VCPHEVC: x1 = allocator, x2 = out]. Refusing here makes VideoToolbox take its next decoder. */
static OSStatus
create_instance(FourCharCode codec, CFAllocatorRef allocator, VTVideoDecoderRef *out)
{
	int strikes = strikes_read();

	(void)codec;
	if (strikes >= STRIKE_LIMIT) {
		static bool said;

		if (!said) {
			said = true;
			say("LAUREL HEVC: off: %d starts ended before a first frame (%s): Apple's decoder takes over; delete the file to try again\n",
			    strikes, strike_path);
		}
		return ERR_MALFUNCTION;
	}
	return vt.derived_create(allocator, &laurel_vtable, vt.class_id(), out);
}

static bool
kill_switch(void)
{
	char args[1024] = "";
	size_t size = sizeof(args) - 1;

	return sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "laurel_hevc=0") != NULL;
}

__attribute__((visibility("default"))) void
HEVCH8Register(void)
{
	static bool done;
	const char *missing = NULL;
	const char *name = getprogname();
	bool chatty = name != NULL && strcmp(name, "mediaserverd") == 0;   /* other processes only load this file: one line a boot is enough */

	if (done) {
		return;
	}
	done = true;
	if (kill_switch()) {
		if (chatty) say("LAUREL HEVC: off: laurel_hevc=0: Apple's decoder stays\n");
		return;
	}
#define GET(field, symbol) do { *(void **)&vt.field = dlsym(RTLD_DEFAULT, symbol); if (vt.field == NULL && missing == NULL) missing = symbol; } while (0)
	GET(class_id, "VTVideoDecoderGetClassID");
	GET(derived_create, "CMDerivedObjectCreate");
	GET(storage, "CMBaseObjectGetDerivedStorage");
	GET(set_attributes, "VTDecoderSessionSetPixelBufferAttributes");
	GET(pool, "VTDecoderSessionGetPixelBufferPool");
	GET(emit, "VTDecoderSessionEmitDecodedFrame");
	GET(destination_attributes, "VTDecoderSessionGetDestinationPixelBufferAttributes");
	GET(register_with_info, "VTRegisterVideoDecoderWithInfo");
	GET(hw_key, "kVTVideoDecoder_IsHardwareAccelerated");
	GET(rating_key, "kVTVideoDecoderInfo_Rating");
#undef GET
	if (missing != NULL) {
		if (chatty) say("LAUREL HEVC: off: this system has no %s: Apple's decoder stays\n", missing);
		return;
	}
	SInt32 rating = RATING;
	CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &rating);
	const void *keys[] = { *vt.hw_key, *vt.rating_key };
	const void *values[] = { kCFBooleanFalse, number };
	CFDictionaryRef info = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	OSStatus s = vt.register_with_info('hvc1', info, (void *)create_instance);

	CFRelease(info);
	CFRelease(number);
	if (chatty) {
		int strikes = strikes_read();

		if (s != 0) {
			say("LAUREL HEVC: off: VTRegisterVideoDecoderWithInfo: %d: Apple's decoder stays\n", (int)s);
		} else if (strikes >= STRIKE_LIMIT) {
			say("LAUREL HEVC: off: %d starts ended before a first frame (%s): Apple's decoder takes over\n", strikes, strike_path);
		} else {
			say("LAUREL HEVC: on: FFmpeg %s software decoder for 'hvc1', rating %d, ahead of VCPHEVC; dead-man %s, %d strikes\n",
			    hv_decoder_version(), RATING, strike_path[0] == '-' ? "off: no writable folder" : strike_path, strikes);
		}
	}
}
