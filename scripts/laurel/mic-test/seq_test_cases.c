/* the cases of seq_test.c */
static void
pins_and_clocks(void)
{
	reset_model();
	CHECK(bring_up(), "bring-up: %s", mic_why);
	CHECK(mic_dev == 1, "the codec is device %u", mic_dev);
	/* trinket-pinctrl.dtsi: swr_tx (function 1), 10 mA, bus hold; PINGROUP(106, EAST, swr_tx, ...) */
	for (uint32_t i = 0; i < 3; i++) {
		CHECK(RD(0xD6A000 + 0x1000 * i) == 0x106, "gpio%u cfg %#x", 106 + i, RD(0xD6A000 + 0x1000 * i));
	}
	CHECK(RD(0xD8E000) == 3, "bolero slew_rate_reg1");
	CHECK(RD(0x978000) == 0x3C0 && RD(0x978004) == 2, "reset gpio120: gpio, 16 mA, output, high");
	/* va_macro_mclk_enable + tx_macro_mclk_enable + tx_macro_swrm_clock */
	CHECK(RD(0x0A4A0000) == 1 && RD(0x0A4A0004) == 1 && RD(0x0A4A0080) == 2, "VA fs-gen");
	CHECK(RD(0x0A460090) == 1 && RD(0x0A460000) == 1 && RD(0x0A460004) == 1, "TX MCLK 9.6 MHz");
	CHECK(RD(0x0A460008) == 1, "TX SWR clock on, reset released: %#x", RD(0x0A460008));
	/* swrm_master_init(): 50 rows, 2 cols, ssp 48: 9.6 MHz x 2 / (50 x 2 x 4000) */
	CHECK(RD(SWR(0x101C)) == ((1u << 3) | (47u << 16)), "frame bank 0 %#x", RD(SWR(0x101C)));
	CHECK(RD(SWR(0x500)) == 1 && RD(SWR(0x314)) == 3 && RD(SWR(0x1044)) == 2 && RD(SWR(4)) == 3, "master init");
	CHECK((RD(SWR(0x1048)) & 0x3E0000) == (0x1Fu << 17), "no pings");
	CHECK(RD(SWR(0x204)) == 0x1FDFD && RD(SWR(0x210)) == 0x1FDFD && RD(SWR(0x208)) == 0xFFFFFFFFu, "interrupt masks");
}

static void
codec_and_path(void)
{
	reset_model();
	CHECK(bring_up(), "bring-up: %s", mic_why);
	log_i = 0;
	CHECK(codec_init(), "codec_init: %s", mic_why);
	CHECK((codec[0x3022] & 0x3F) == 16 && (codec[0x3023] & 0x3F) == 16 && (codec[0x3025] & 0x3F) == 16, "micbias 1.8 V: (1800 - 1000) / 50");
	CHECK(codec[0x3103] == 0xCE && codec[0x3029] == 0x80 && codec[0x30CE] == 0x3A && codec[0x30E2] == 0xD9, "wcd937x_init_reg");
	CHECK(codec[0x306B] == 0xFA && codec[0x306E] == 0xFA && codec[0x3071] == 0xFA, "MICBn_TEST_CTL_1");
	CHECK((codec[0x3001] & 0xC0) == 0x80, "ANA_BIAS on, precharge off");
	CHECK(at(0x3103, 0x80, 0x80, 0) < at(0x3103, 0x40, 0x40, 0), "SLEEP_CTL order");

	CHECK(dec0_on(MIC_GAIN_DB), "dec0: %s", mic_why);
	CHECK(RD(0x0A46042C) == 0x0E, "TX0 SEC7 (tx_macro_init)");
	CHECK(RD(0x0A460100) == 1 && RD(0x0A460104) == 1, "TX SMIC MUX0 = ADC0, TX DEC0 MUX = SWR_MIC");
	CHECK(RD(0x0A460400) == 0x34, "TX0_PATH_CTL: 48 kHz (4), muted, on: %#x", RD(0x0A460400));
	CHECK(RD(0x0A46040C) == 18, "TX_DEC0 Volume 102 = +18 dB");
	CHECK((RD(0x0A460404) & 0x60) == 0x40, "HPF 150 Hz while it settles");

	log_i = 0;
	CHECK(codec_adc1_on(), "adc1: %s", mic_why);
	CHECK((codec[0x3022] & 0xC0) == 0x40, "MIC BIAS1 on");
	CHECK((codec[0x300E] & 0x1F) == 12 && (codec[0x300E] & 0x80), "ADC1 Volume 12, ADC1 on");
	CHECK((codec[0x3408] & 0x18) == 0x18 && (codec[0x3409] & 0xF0) == 0xF0, "clocks");
	CHECK((codec[0x3457] & 3) == 2, "REQ_CTL");
	/* wcd937x_enable_req(): the hold set, the channels' clock, ch1 on, the hold released */
	CHECK(at(0x300F, 0x40, 0x40, 0) >= 0 && at(0x300F, 0x40, 0x40, 0) < at(0x300E, 0x80, 0x80, 0), "hold before ch1 on");
	CHECK(at(0x300E, 0x80, 0x80, 0) < at(0x300F, 0x40, 0x00, 0), "ch1 on before hold off");
	CHECK(at(0x3022, 0xC0, 0x40, 0) < at(0x300E, 0x80, 0x80, 0), "bias before the ADC");

	log_i = 0;
	CHECK(swr_datapath_on(), "datapath: %s", mic_why);
	CHECK(bank_status == 1, "the bank switched from 0 to 1");
	/* tx_frame_params_superset[1]: si 3, off1 1, off2 0, lane 0; master port 2 channel mask 1 */
	for (uint32_t b = 0; b < 2; b++) {
		CHECK(RD(SWR(0x1224 + 0x40 * b)) == 0x01000103, "master port 2 bank %u ctrl %#x", b, RD(SWR(0x1224 + 0x40 * b)));
		CHECK(RD(SWR(0x1228 + 0x40 * b)) == 0, "master port 2 bank %u lane", b);
		CHECK(RD(SWR(0x1234 + 0x40 * b)) == 0xF0, "master port 2 bank %u hctrl", b);
		CHECK(codec[0x120 + 0x10 * b] == 1 && codec[0x122 + 0x10 * b] == 3 && codec[0x124 + 0x10 * b] == 1 && codec[0x125 + 0x10 * b] == 0 &&
		    codec[0x128 + 0x10 * b] == 0, "codec port 0 bank %u", b);
	}
	CHECK(RD(SWR(0x105C)) == ((1u << 3) | 7u | (5u << 16)), "frame bank 1: 50 x 16, ssp 6: %#x", RD(SWR(0x105C)));
	CHECK(swlog[0].dev == 0xF && swlog[0].reg == 0xF0 && swlog[0].val == 1, "first: the devices' clock halved in the idle bank");
	CHECK(at(0x70, 0xFF, (1u << 3) | 7u, 0) > at(0x128 + 0x10, 0xFF, 0, 0), "the idle bank's port before the switch");
	CHECK(at(0x70, 0xFF, (1u << 3) | 7u, 0) < at(0x128, 0xFF, 0, 0), "the other bank's port after the switch");

	CHECK(dec0_unmute() && RD(0x0A460400) == 0x24, "unmuted: %#x", RD(0x0A460400));
	log_i = 0;
	CHECK(dec0_settled(), "settled: %s", mic_why);
	CHECK((codec[0x300F] & 0x40) == 0 && (RD(0x0A460404) & 0x60) == 0 && (RD(0x0A460418) & 3) == 1, "the filter as at reset, the hold off");
	dec0_gain(-6);
	CHECK(RD(0x0A46040C) == 0xFA, "gain -6 dB");

	dec0_off();
	codec_adc1_off();
	CHECK((codec[0x3022] & 0xC0) == 0 && (codec[0x300E] & 0x80) == 0, "bias + ADC off");
	CHECK((RD(0x0A460400) & 0x30) == 0, "DEC0 off");
}

static void
failures(void)
{
	/* no codec on the bus: a clean "not found", no writes through SoundWire */
	reset_model();
	no_codec = 1;
	CHECK(!bring_up() && mic_dev == 0 && log_i == 0, "no codec");
	/* a codec register that reads back another value is said once, the start goes on (Android never reads them back) */
	reset_model();
	CHECK(bring_up(), "bring-up: %s", mic_why);
	codec[0x3474] = 0x55;
	stuck_reg = 0x3474;
	codec_mismatch = 0;
	CHECK(codec_init() && codec_mismatch == 1 && mic_why[0] == 0, "stuck register: %u, \"%s\"", codec_mismatch, mic_why);
	/* a dead bus stops it: the read answer never comes */
	reset_model();
	CHECK(bring_up(), "bring-up: %s", mic_why);
	dead_bus = 1;
	CHECK(!codec_init() && strstr(mic_why, "no answer") != NULL, "dead bus: \"%s\"", mic_why);
	dead_bus = 0;
}

static void
ring(void)
{
	static int16_t mem[MIC_RING_FRAMES], in[960], out[4096];
	struct mic_level l;

	mic_ring = mem;
	mic_ring_w = 0;
	mic_ring_reset();
	for (int i = 0; i < 960; i++) {
		in[i] = (int16_t)i;
	}
	mic_ring_put(in, 960);
	CHECK(mic_ring_ready(512) == 0, "nothing until 40 ms are there");
	mic_ring_put(in, 960);
	uint64_t r = mic_ring_ready(512), n;
	const int16_t *s = mic_ring_slice(r, &n);
	CHECK(r == 512 && n == 512 && s[5] == 5, "the first read");
	/* a late reader: the oldest is skipped */
	for (int i = 0; i < 10; i++) {
		mic_ring_put(in, 960);
	}
	CHECK(mic_ring_ready(512) == 512 && mic_skipped != 0, "skipped");
	/* wrap: the two pieces are contiguous and complete */
	mic_ring_w = MIC_RING_FRAMES * 3 - 100;
	mic_ring_reset();
	mic_ring_put(in, 960);
	mic_ring_put(in, 960);
	mic_ring_put(in, 960);
	mic_ring_r = mic_ring_w - 1920;
	mic_primed = true;
	r = mic_ring_ready(1920);
	uint64_t total = 0;
	while (r > 0) {
		s = mic_ring_slice(r, &n);
		memcpy(out + total, s, n * 2);
		total += n;
		r -= n;
	}
	CHECK(total == 1920 && out[0] == 0 && out[959] == 959 && out[960] == 0 && out[1919] == 959, "wrap");
	/* dry: a short read, then priming again */
	mic_ring_r = mic_ring_w - 100;
	mic_primed = true;
	CHECK(mic_ring_ready(512) == 100 && mic_dry != 0 && !mic_primed, "dry");

	memset(&l, 0, sizeof(l));
	for (int i = 0; i < 960; i++) {
		in[i] = i % 2 ? 1000 : -1000;
	}
	mic_level_add(&l, in, 960);
	CHECK(mic_level_rms(&l) == 1000 && l.peak == 1000 && l.frames == 960, "rms %u", mic_level_rms(&l));
	memset(&l, 0, sizeof(l));
	CHECK(mic_level_rms(&l) == 0, "empty level");
	in[0] = -32768;
	mic_level_add(&l, in, 1);
	CHECK(mic_level_rms(&l) == 32768 && l.peak == 32768, "full scale");
}

int
main(void)
{
	pins_and_clocks();
	codec_and_path();
	failures();
	ring();
	printf("mic sequence test: %s\n", fails == 0 ? "PASS" : "FAIL");
	return fails != 0;
}
