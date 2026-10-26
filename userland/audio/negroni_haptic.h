/*
 * /dev/negroni-haptic: the user/kernel ABI between NegroniAudio.driver (the CoreAudio HAL plug-in
 * in mediaserverd) and the kernel motor path (bsd/dev/negroni_haptic_ui.c, patches/xnu/0302).
 * The kernel keeps its own copy of these numbers (it has no userland headers): change both.
 *
 * Model: HackiOS /dev/redwood-haptic (external/hackios-xnu-kernel bsd/dev/redwood_haptic.c, MIT).
 *
 *   write()  S16LE mono samples at NEGRONI_HAPTIC_RATE: what iOS plays on the HAL "Actuator"
 *            device (CoreHaptics, UIFeedbackGenerator, the vibe engine, via VirtualAudio's
 *            VirtualAudioDevice_Actuator). The kernel plays them from the moment they arrive, so
 *            write them as soon as they come. Never blocks; the kernel takes every byte.
 *            Silence need not be written: no data counts as silence. The node exists only with
 *            the boot-args negronihap=1|2 negronihap_ui=1.
 */
#ifndef NEGRONI_HAPTIC_H
#define NEGRONI_HAPTIC_H

#define NEGRONI_HAPTIC_DEVICE   "/dev/negroni-haptic"
#define NEGRONI_HAPTIC_RATE     48000   /* frames/s, 1 channel, S16LE (the Actuator stream format) */
#define NEGRONI_HAPTIC_SILENT   256     /* of 32768: the kernel treats smaller peaks as silence */

#endif
