/*
 * /dev/negronicam: the rear main camera (IMX789) for iOS, kernel patch 0318 (negronicam=7).
 * The ABI is the one of HakiOS's /dev/hakios-camera (HakiOS userland/src/hakios.camera.h, MIT License,
 * Copyright (c) 2025-2026 the HakiOS authors; userland/camera/LICENSE.HakiOS) under our names: the same
 * 120-byte frame header and 24-byte command, magic "NCFRAME1". Kernel side: patches/xnu/0318 (struct
 * ncam_frame_hdr, ncam_command), patches/xnu/README-camera.md.
 *
 *   open()   no hardware action.
 *   read()   the first read of a session starts it (bring-up, 3-place ring); waits (1 s; 6 s for the first
 *            frame) for the newest frame not read yet: the header, then as many frame bytes as fit. A buffer
 *            of the header's size gets the header only. EAGAIN on a time-out, EIO after a fault (then for
 *            the rest of the boot). The session ends after the last close or 1 s without a read.
 *   write()  struct negronicam_command: EXPOSURE (a lines, b gain x256 linear, c frame lines or 0) and SENSOR
 *            (only 1, the rear main, exists: others give ENODEV). KEEP and FOCUS are accepted and ignored.
 */
#ifndef NEGRONICAM_H
#define NEGRONICAM_H

#include <stdint.h>

#define NEGRONICAM_DEVICE       "/dev/negronicam"
#define NEGRONICAM_MAGIC        "NCFRAME1"

struct negronicam_frame {
	char            magic[8];       /* NEGRONICAM_MAGIC */
	uint32_t        header_bytes;   /* this structure's size: the frame's bytes follow */
	uint32_t        width, height;  /* pixels (IMX789 FTM mode: 4000 x 3008; TPG: 640 x 480) */
	uint32_t        stride;         /* bytes from one line to the next */
	uint32_t        format;         /* 1: MIPI RAW10, four pixels in five bytes */
	uint32_t        bayer;          /* the order of a 2x2 cell: 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR (boot-arg negronicam_bayer) */
	uint32_t        black;          /* the black level, in 10-bit steps (64 for the IMX789 [I]; 0 for the TPG) */
	uint64_t        sequence;       /* the frame's number since the session started, from 1 */
	uint64_t        time;           /* when the frame was done, in mach_absolute_time()'s units */
	uint32_t        exposure_lines; /* the exposure it was taken with, in lines ... */
	uint32_t        line_ns;        /* ... of this many nanoseconds */
	uint32_t        gain;           /* the analog gain, gain_unity for 1x */
	uint32_t        gain_unity;     /* 256 */
	uint32_t        gain_max;       /* 16x */
	uint32_t        frame_lines;    /* the frame's length in lines */
	uint32_t        frame_lines_min; /* the mode's own length: the shortest frame */
	uint32_t        frame_lines_max; /* the longest frame it may be given */
	uint32_t        margin;         /* exposure_lines is at most frame_lines - margin */
	uint32_t        sensor;         /* 1: the rear main camera (HakiOS's numbering: the wide camera) */
	uint32_t        focus;          /* NEGRONICAM_NO_FOCUS: no lens motor driver (AK7377) yet */
	uint32_t        reserved[5];
};
_Static_assert(sizeof(struct negronicam_frame) == 120, "the frame header is 120 bytes (kernel 0318)");

#define NEGRONICAM_NO_FOCUS 0xffffffffu

enum {
	NEGRONICAM_EXPOSURE = 1,        /* a: lines, b: gain, c: frame lines (0: the shortest that holds the exposure) */
	NEGRONICAM_KEEP = 2,            /* accepted and ignored by 0318 */
	NEGRONICAM_SENSOR = 3,          /* a: which sensor; only 1 here */
	NEGRONICAM_FOCUS = 4,           /* accepted and ignored by 0318 */
};

struct negronicam_command {
	uint32_t        command;
	uint32_t        bytes;          /* of what follows this structure */
	uint32_t        a, b, c, d;
};
_Static_assert(sizeof(struct negronicam_command) == 24, "the command is 24 bytes (kernel 0318)");

#endif
