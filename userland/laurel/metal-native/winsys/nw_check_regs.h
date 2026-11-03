/* SPDX-License-Identifier: MIT */
/* The registers nw_check.c reads for a write's size. Mesa's a6xx.xml.h needs Mesa's util headers, this file does not; nmn_pm4.cc checks each number against that file at compile time. */
#ifndef NW_CHECK_REGS_H
#define NW_CHECK_REGS_H
#define NW_RB_2D_BLIT_CNTL              0x8c00u
#define NW_RB_2D_BLIT_CNTL_SOLID        0x80u
#define NW_RB_2D_DST                    0x8c18u
#define NW_RB_2D_DST_PITCH              0x8c1au
#define NW_GRAS_2D_DST_BR               0x8406u
#define NW_GRAS_2D_SRC_BR_X             0x8402u
#define NW_GRAS_2D_SRC_BR_Y             0x8404u
#define NW_SP_PS_2D_SRC                 0xb4c2u
#define NW_SP_PS_2D_SRC_PITCH           0xb4c4u
#define NW_GRAS_SC_WINDOW_SCISSOR_BR    0x80f1u
#define NW_RB_DEPTH_BUFFER_PITCH        0x8873u
#define NW_RB_DEPTH_BUFFER_BASE         0x8875u
#define NW_RB_STENCIL_BUFFER_PITCH      0x8882u
#define NW_RB_STENCIL_BUFFER_BASE       0x8884u
#define NW_RB_MRT                       0x8820u  /* 8 registers each: pitch + 3, base + 5 */
#define NW_MARKER_DIRECT_RENDER         1u
#endif
