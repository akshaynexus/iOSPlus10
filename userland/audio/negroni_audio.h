/*
 * /dev/negroni-audio: the user/kernel ABI between NegroniAudio.driver (the CoreAudio HAL
 * plug-in in mediaserverd) and the kernel sink (bsd/dev/negroni_audio.c, patches/xnu/0241+).
 * The kernel keeps its own copy of these numbers (it has no userland headers): change both.
 *
 * Model: HackiOS sys/redwood_audio.h (external/hackios-xnu-userland, MIT).
 *
 *   write()  whole frames, S16LE, 2 channels (left, right), 48000 frames/s. Never blocks (the
 *            writer is the HAL real-time I/O thread). The return value is the number of bytes
 *            the kernel took; the rest is dropped. ENODEV: no sink is running (no ADSP graph):
 *            the plug-in counts the frames as dropped and goes on.
 *   ioctl    NEGRONI_AUDIO_SET_VOLUME: the HAL volume control, in 1/8 dB below the kernel's
 *            maximum (the kernel maximum is a safe, low level: see the kernel limiter).
 *            NEGRONI_AUDIO_GET_STATS: counters for scripts/audio/phone-test.sh.
 */
#ifndef NEGRONI_AUDIO_H
#define NEGRONI_AUDIO_H

#include <stdint.h>
#include <sys/ioccom.h>

#define NEGRONI_AUDIO_DEVICE    "/dev/negroni-audio"
#define NEGRONI_AUDIO_RATE      48000
#define NEGRONI_AUDIO_CHANNELS  2
#define NEGRONI_AUDIO_FRAME     4       /* bytes per frame */

struct negroni_audio_volume {
	uint32_t below;                 /* 1/8 dB below the kernel maximum (0243: stored, not applied yet) */
	uint32_t muted;                 /* 1: iOS volume 0 */
};

struct negroni_audio_stats {
	uint64_t frames_in;             /* frames written by user space */
	uint64_t frames_dropped;        /* frames the sink did not take */
	uint64_t frames_played;         /* frames the sink gave to the DSP */
	uint32_t state;                 /* NEGRONI_AUDIO_STATE_* */
	uint32_t peak_in;               /* peak |sample| written since the last GET_STATS */
	uint32_t peak_out;              /* peak |sample| after the limiter since the last GET_STATS */
	uint32_t limiter_gain_q15;      /* limiter gain now, 32768 = 0 dB */
};

#define NEGRONI_AUDIO_STATE_NOSINK      0       /* the device exists, no sink: samples are dropped */
#define NEGRONI_AUDIO_STATE_IDLE        1       /* a sink exists, not running */
#define NEGRONI_AUDIO_STATE_RUNNING     2       /* the graph runs, samples go to the DSP */
#define NEGRONI_AUDIO_STATE_FAILED      3       /* the sink stopped after an error */

#define NEGRONI_AUDIO_SET_VOLUME        _IOW('n', 1, struct negroni_audio_volume)
#define NEGRONI_AUDIO_GET_STATS         _IOR('n', 2, struct negroni_audio_stats)
/*
 * 0246: the output route of the Speaker stream. SPEAKER: both TFA9874 amps (stereo); RECEIVER: the
 * top amp only in its "receiver" profile (the earpiece; the kernel plays (L + R) / 2). A change
 * stops the amps; the next non-silent write starts the new route. Also: sysctl kern.negroni_audio_route.
 */
#define NEGRONI_AUDIO_ROUTE_SPEAKER     1u
#define NEGRONI_AUDIO_ROUTE_RECEIVER    2u
#define NEGRONI_AUDIO_SET_ROUTE         _IOW('n', 3, uint32_t)

#endif
