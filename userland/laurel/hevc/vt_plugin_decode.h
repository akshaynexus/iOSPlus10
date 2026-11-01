/* Part of vt_plugin.c: one decode session. Included once. */

static double
ms_since(uint64_t start)
{
	static mach_timebase_info_data_t tb;

	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	return (double)(mach_absolute_time() - start) * tb.numer / tb.denom / 1e6;
}

/* Is this format among what the session's client asked for? No list means anything goes. */
static bool
destination_wants(VTVideoDecoderSession session, OSType format, bool *has_list)
{
	CFDictionaryRef a = vt.destination_attributes != NULL ? vt.destination_attributes(session) : NULL;
	CFTypeRef f = a != NULL ? CFDictionaryGetValue(a, kCVPixelBufferPixelFormatTypeKey) : NULL;
	SInt32 want;

	*has_list = f != NULL;
	if (f == NULL) {
		return false;
	}
	if (CFGetTypeID(f) == CFNumberGetTypeID()) {
		CFNumberGetValue(f, kCFNumberSInt32Type, &want);
		return (OSType)want == format;
	}
	if (CFGetTypeID(f) != CFArrayGetTypeID()) {
		return false;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(f); i++) {
		CFTypeRef e = CFArrayGetValueAtIndex(f, i);

		if (CFGetTypeID(e) == CFNumberGetTypeID() && CFNumberGetValue(e, kCFNumberSInt32Type, &want) && (OSType)want == format) {
			return true;
		}
	}
	return false;
}

/*
 * The output format of a stream: what the client asked for if we make it, else our natural format (VideoToolbox's pixel transfer does
 * the rest). Alpha and depth layers of a HEIC are monochrome: 'L008' when asked for, else 4:2:0 with neutral chroma.
 */
static OSType
choose_format(decoder *d, const hv_picture *p)
{
	const OSType full8[] = { '420f', '420v' }, video8[] = { '420v', '420f' };
	const OSType full10[] = { 'xf20', 'x420' }, video10[] = { 'x420', 'xf20' };
	const OSType *list = p->bits > 8 ? (p->full_range ? full10 : video10) : (p->full_range ? full8 : video8);
	bool listed;

	if (p->plane[1] == NULL && p->bits == 8 && destination_wants(d->session, 'L008', &listed)) {
		return 'L008';
	}
	for (int i = 0; i < 2; i++) {
		if (destination_wants(d->session, list[i], &listed)) {
			return list[i];
		}
	}
	return list[0];
}

static OSStatus
set_attributes(decoder *d, OSType format, int width, int height)
{
	SInt32 f = (SInt32)format;
	CFNumberRef nf = CFNumberCreate(NULL, kCFNumberSInt32Type, &f);
	CFNumberRef nw = CFNumberCreate(NULL, kCFNumberIntType, &width);
	CFNumberRef nh = CFNumberCreate(NULL, kCFNumberIntType, &height);
	CFDictionaryRef io = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	const void *keys[] = { kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferWidthKey, kCVPixelBufferHeightKey,
		kCVPixelBufferIOSurfacePropertiesKey };
	const void *values[] = { nf, nw, nh, io };
	CFDictionaryRef a = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	OSStatus s = vt.set_attributes(d->session, a);

	CFRelease(a);
	CFRelease(io);
	CFRelease(nh);
	CFRelease(nw);
	CFRelease(nf);
	return s;
}

/* Colour tags from the stream (H.273 numbers), when the format description had none. */
static void
tag_colours(decoder *d, CVPixelBufferRef pb, const hv_picture *p)
{
	CFStringRef m = NULL, c = NULL, t = NULL;

	if (d->colours != NULL) {
		CVBufferSetAttachments(pb, d->colours, kCVAttachmentMode_ShouldPropagate);
		return;
	}
	switch (p->matrix) {
	case 1: m = kCVImageBufferYCbCrMatrix_ITU_R_709_2; break;
	case 5: case 6: m = kCVImageBufferYCbCrMatrix_ITU_R_601_4; break;
	case 9: m = kCVImageBufferYCbCrMatrix_ITU_R_2020; break;
	}
	switch (p->primaries) {
	case 1: c = kCVImageBufferColorPrimaries_ITU_R_709_2; break;
	case 6: c = kCVImageBufferColorPrimaries_SMPTE_C; break;
	case 9: c = kCVImageBufferColorPrimaries_ITU_R_2020; break;
	case 12: c = kCVImageBufferColorPrimaries_P3_D65; break;
	}
	switch (p->transfer) {
	case 1: case 6: case 13: t = kCVImageBufferTransferFunction_ITU_R_709_2; break;
	}
	if (m != NULL) CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, m, kCVAttachmentMode_ShouldPropagate);
	if (c != NULL) CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, c, kCVAttachmentMode_ShouldPropagate);
	if (t != NULL) CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, t, kCVAttachmentMode_ShouldPropagate);
}

static VTVideoDecoderFrame
pending_take(decoder *d, uint64_t tag)
{
	for (int i = 0; i < MAX_PENDING; i++) {
		if (d->pending[i].used && d->pending[i].tag == tag) {
			d->pending[i].used = false;
			return d->pending[i].frame;
		}
	}
	return NULL;
}

/*
 * One picture into a pixel buffer. The stride check is the self-check of the IOSurface layer: before kernel patch 2001 (negroni 0390)
 * every plane of a biplanar surface had bytesPerRow 0, and all rows landed on row 0 [V docs/camera-ios-2026-10-27.md section 14].
 */
static OSStatus
picture_to_buffer(decoder *d, const hv_picture *p, CVPixelBufferRef *out)
{
	CVPixelBufferPoolRef pool;
	CVPixelBufferRef pb = NULL;
	OSStatus s;
	OSType format = d->format;

	if (format == 0 || p->width != d->width || p->height != d->height) {
		format = choose_format(d, p);
		s = set_attributes(d, format, p->width, p->height);
		if (s != 0) {
			say("LAUREL HEVC: no pixel buffer attributes for %dx%d: %d\n", p->width, p->height, (int)s);
			return s;
		}
		d->format = format;
		d->width = p->width;
		d->height = p->height;
	}
	pool = vt.pool(d->session);
	if (pool == NULL || (s = CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pb)) != 0 || pb == NULL) {
		return ERR_ALLOC;
	}
	s = CVPixelBufferLockBaseAddress(pb, 0);
	if (s != 0) {
		CVPixelBufferRelease(pb);
		return s;
	}
	if (format == 'L008') {
		uint8_t *y = CVPixelBufferGetBaseAddress(pb);
		size_t by = CVPixelBufferGetBytesPerRow(pb);

		if (y == NULL || by < (size_t)p->width) {
			s = ERR_MALFUNCTION;
		} else {
			hv_copy_l008(p, y, by);
		}
	} else {
		uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
		size_t by = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), buv = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
		size_t row = (size_t)p->width * (format == 'x420' || format == 'xf20' ? 2 : 1);

		if (y == NULL || uv == NULL || by < row || buv < ((row + 1) & ~(size_t)1)) {
			say("LAUREL HEVC: frame refused: buffer planes %p %p have bytesPerRow %zu/%zu under %zu (IOSurface plane layout, kernel 2001)\n",
			    y, uv, by, buv, row);
			s = ERR_MALFUNCTION;
		} else if (format == 'x420' || format == 'xf20') {
			hv_copy_p010(p, y, by, uv, buv);
		} else {
			hv_copy_nv12(p, y, by, uv, buv);
		}
	}
	CVPixelBufferUnlockBaseAddress(pb, 0);
	if (s != 0) {
		CVPixelBufferRelease(pb);
		return s;
	}
	tag_colours(d, pb, p);
	*out = pb;
	return 0;
}

/*
 * The dead-man's other half + one line per process for each output format, so a boot log shows that decode reached this file and which
 * paths ran (a HEIC layer: '420f' colour and 'L008' or '420f' alpha). A failed picture adds a strike instead of clearing them.
 */
static void
note_first_frame(decoder *d, const hv_picture *p, OSStatus s, uint64_t start)
{
	static uint32_t seen;
	uint32_t bit = d->format == 'L008' ? 1 : d->format == '420f' ? 2 : d->format == '420v' ? 4 : d->format == 'x420' ? 8 : 16;

	if (s != 0) {
		strikes_write(strikes_read() + 1);
	} else if ((__atomic_fetch_or(&struck, 2, __ATOMIC_RELAXED) & 2) == 0) {
		strikes_write(0);
	}
	if ((__atomic_fetch_or(&seen, bit, __ATOMIC_RELAXED) & bit) == 0) {
		say("LAUREL HEVC: first frame in %s[%d]: %dx%d %d-bit chroma_idc %d -> '%c%c%c%c' in %.1f ms: status %d\n", getprogname(), getpid(),
		    p->width, p->height, p->bits, d->info.chroma_idc, (char)(d->format >> 24), (char)(d->format >> 16), (char)(d->format >> 8),
		    (char)d->format, ms_since(start), (int)s);
	}
}

/* Hands on every picture the decoder has ready. Each frame handle goes back to VideoToolbox exactly once. */
static void
emit_ready(decoder *d, uint64_t start)
{
	hv_picture p;
	int r;

	while ((r = hv_next(d->core, &p)) > 0) {
		VTVideoDecoderFrame f = pending_take(d, p.tag);
		CVPixelBufferRef pb = NULL;
		OSStatus s;

		if (f == NULL) {
			continue;
		}
		s = picture_to_buffer(d, &p, &pb);
		vt.emit(d->session, f, s, s == 0 ? 0 : INFO_FRAME_DROPPED, pb);
		if (pb != NULL) {
			CVPixelBufferRelease(pb);
		}
		note_first_frame(d, &p, s, start);
	}
	if (r < 0) {
		char t[80];

		say("LAUREL HEVC: decode: %s\n", hv_error_text(r, t, sizeof(t)));
	}
}

/* Pictures the decoder will never give (dropped by the stream, or errors): VideoToolbox still waits for an answer per frame. */
static void
pending_drop_all(decoder *d, OSStatus status)
{
	for (int i = 0; i < MAX_PENDING; i++) {
		if (d->pending[i].used) {
			d->pending[i].used = false;
			vt.emit(d->session, d->pending[i].frame, status, INFO_FRAME_DROPPED, NULL);
		}
	}
}

static OSStatus
decode_frame(VTVideoDecoderRef self, VTVideoDecoderFrame frame, CMSampleBufferRef sample, uint32_t flags, uint32_t *info)
{
	decoder *d = vt.storage(self);
	CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
	size_t size = block != NULL ? CMBlockBufferGetDataLength(block) : 0;
	uint64_t start = mach_absolute_time();
	char *bytes = NULL, *copy = NULL;
	size_t run = 0;
	int free_slot = -1, r;

	if (info != NULL) {
		*info = 0;
	}
	if (size == 0 || d->session == NULL) {
		return ERR_BAD_DATA;
	}
	if (d->core == NULL) {
		char err[120] = "";
		/* temporal processing = a player: pictures may come out later, more threads pay. A HEIC tile wants its picture at once. */
		d->core = hv_open(CFDataGetBytePtr(d->hvcc), (size_t)CFDataGetLength(d->hvcc),
		    (flags & DECODE_TEMPORAL) != 0 ? HV_THREADS_FRAME : HV_THREADS_SLICE, err, sizeof(err));
		if (d->core == NULL) {
			say("LAUREL HEVC: session refused: %s\n", err);
			return ERR_MALFUNCTION;
		}
		if ((__atomic_fetch_or(&struck, 1, __ATOMIC_RELAXED) & 1) == 0) {
			strikes_write(strikes_read() + 1);      /* once a process: a crash before its first picture counts */
		}
	}
	for (int i = 0; i < MAX_PENDING; i++) {
		if (!d->pending[i].used) {
			free_slot = i;
			break;
		}
	}
	if (free_slot < 0) {            /* cannot happen with a legal stream: the DPB holds at most 16 pictures + the threads' */
		pending_drop_all(d, ERR_BAD_DATA);
		free_slot = 0;
	}
	if (CMBlockBufferGetDataPointer(block, 0, &run, NULL, &bytes) != 0 || run < size) {
		copy = malloc(size);
		if (copy == NULL || CMBlockBufferCopyDataBytes(block, 0, size, copy) != 0) {
			free(copy);
			return ERR_ALLOC;
		}
		bytes = copy;
	}
	d->pending[free_slot].tag = ++d->next_tag;
	d->pending[free_slot].frame = frame;
	d->pending[free_slot].used = true;
	r = hv_send(d->core, (const uint8_t *)bytes, size, d->next_tag);
	free(copy);
	if (r < 0) {
		char t[80];
		VTVideoDecoderFrame f = pending_take(d, d->next_tag);

		say("LAUREL HEVC: decode: %zu byte sample: %s\n", size, hv_error_text(r, t, sizeof(t)));
		if (f != NULL) {
			vt.emit(d->session, f, ERR_BAD_DATA, INFO_FRAME_DROPPED, NULL);
		}
		return 0;
	}
	emit_ready(d, start);
	return 0;
}

static OSStatus
finish_delayed_frames(VTVideoDecoderRef self)
{
	decoder *d = vt.storage(self);

	if (d->core != NULL) {
		hv_drain(d->core);
		emit_ready(d, mach_absolute_time());
		hv_flush(d->core);
		pending_drop_all(d, 0);
	}
	return 0;
}
