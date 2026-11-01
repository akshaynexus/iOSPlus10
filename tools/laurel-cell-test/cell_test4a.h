/* laurel 2943: the simulated modem's answers to the read-only NAS facts. Layouts: libqmi qmi-service-nas.json. Included by cell_test.c before topaz_qrtr_data. */
static void
sys_info_tlv(uint8_t *tl, uint32_t *tn, uint8_t type, uint8_t dom, uint8_t cause, const char *mnc)
{
	uint8_t v[28] = { 0 };

	v[0] = 1; v[1] = 0;                                 /* domain none */
	v[2] = 1; v[3] = 0;                                 /* capability none */
	v[16] = cause != 0;
	v[17] = dom;
	v[18] = cause;
	v[19] = 1;
	memcpy(v + 20, "404", 3);
	memcpy(v + 23, mnc, 3);
	put_tlv(tl, tn, type, v, M.sys_cut ? 10 : sizeof(v));
}

static void
why_answer(uint32_t port, uint16_t txn, uint16_t msg, int sub, const uint8_t *d)
{
	uint8_t tl[400] = { 0 };
	uint32_t tn = 0;

	if (msg == 0x0003) {
		M.reg_ind[sub]++;
		CHECK_M(d[7] == 0x21 && d[10] == 1 && d[11] == 0);
	} else if (msg == 0x0034) {
		uint16_t modes = 0x1C;
		uint64_t lte = 0x80800C5;
		uint32_t dom = 2, use = 2;
		uint8_t net = 0, emerg = 0;
		M.sel_reads[sub]++;
		put_tlv(tl, &tn, 0x10, &emerg, 1);
		put_tlv(tl, &tn, 0x11, &modes, 2);
		put_tlv(tl, &tn, 0x15, &lte, 8);
		put_tlv(tl, &tn, 0x16, &net, 1);
		put_tlv(tl, &tn, 0x18, &dom, 4);
		put_tlv(tl, &tn, 0x1F, &use, 4);
	} else {
		uint8_t st[3] = { 1, 0, 0 };                    /* limited, true none */
		uint32_t sim_rej = M.rej_cause[sub] != 0 ? 4 : 1;
		M.sys_reads[sub]++;
		put_tlv(tl, &tn, 0x14, st, 3);
		sys_info_tlv(tl, &tn, 0x19, M.rej_dom[sub], M.rej_cause[sub], "45\xFF");
		if (M.rej_umts_too) {
			put_tlv(tl, &tn, 0x13, st, 3);
			sys_info_tlv(tl, &tn, 0x18, 1, 2, "860");
		}
		put_tlv(tl, &tn, 0x27, &sim_rej, 4);
	}
	answer(port, 2, txn, msg, (uint16_t)M.why_err, tl, tn);
}
