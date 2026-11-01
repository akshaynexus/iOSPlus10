/*
 * Scenarios of laurel 2943 (test-cell.sh): why the network refuses. Included by cell_test.c. The phone's pattern of boot 23:41:57 (online, both USIMs illegal, denied)
 * with the facts the client now reads. The IMEIs here are examples, one is the public example number of the check digit. This does not prove the firmware's answers.
 */
#define IMEI_OK "490154203237518"

static int
count_of(const char *hay, const char *needle)
{
	int n = 0;

	for (const char *p = hay; (p = strstr(p, needle)) != NULL; p += strlen(needle)) {
		n++;
	}
	return n;
}

static void
two_sims(void)
{
	test_ipa_on = true;
	M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
	M.sim[1].card = 1; M.sim[1].type = 2; M.sim[1].state = 7;
}

static void
card_ind(void)
{
	uint8_t tl[400];
	uint32_t tn = card_status_tlv(tl);

	answer(0x4010, 4, 0, 0x0032, 0, tl, tn);
}

static void
scenario4(char s)
{
	switch (s) {
	case 'X':       /* the phone's pattern: denied + illegal, cause in system info and in the indication; no IMEI digit anywhere; a repeat is no new line */
		scen = "X both denied, cause";
		two_sims();
		M.imei = IMEI_OK; M.svn = "01";
		M.reg_state = 3;
		M.rej_cause[0] = 6; M.rej_dom[0] = 2;
		M.rej_cause[1] = 6; M.rej_dom[1] = 2;
		services(true);
		run_ms(60000, true);
		CHECK(M.set_online == 1);
		CHECK(M.reg_ind[0] == 1 && M.reg_ind[1] == 1 && M.sel_reads[0] == 1 && M.sel_reads[1] == 1);
		CHECK(M.ids_reads == 1);
		CHECK(strstr(logbuf, "LaurelCell: IMEI: present, check digit valid; software version present") != NULL);
		CHECK(strstr(logbuf, "SIM1 selection: modes 0x1c (bit 2 GSM, 3 UMTS, 4 LTE), network automatic, domain CS+PS, usage data, emergency mode 0, restriction 0, LTE bands 0x80800c5") != NULL);
		CHECK(strstr(logbuf, "LaurelCell: SIM1 reject: LTE, domain PS, cause 6 (illegal ME), network 404-45") != NULL);
		CHECK(strstr(logbuf, "LaurelCell: SIM2 reject: LTE, domain PS, cause 6 (illegal ME), network 404-45") != NULL);
		CHECK(strstr(logbuf, "SIM1 LTE: service limited (true none), domain none, capability none, forbidden 0, network 404-45") != NULL);
		CHECK(strstr(logbuf, "SIM1 SIM reject state: CS and PS invalid") != NULL);
		run_ms(70000, true);
		CHECK(M.sys_reads[0] >= 10);
		CHECK(count_of(logbuf, " reject: ") == 2 && count_of(logbuf, " LTE: service") == 2);
		CHECK(strstr(last(), "SIM1 registration denied (last reject LTE PS cause 6 illegal ME, network 404-45)") != NULL);
		CHECK(strstr(last(), "SIM2 registration denied (last reject LTE PS cause 6 illegal ME, network 404-45)") != NULL);
		CHECK(strstr(state_now(), "imei=valid\n") != NULL && strstr(state_now(), "sub0.reject=LTE,PS,6,404-45\n") != NULL && strstr(state_now(), "sub1.reject=LTE,PS,6,404-45\n") != NULL);
		/* the modem sets the USIM illegal: one line, and the next NAS read comes at once */
		M.sim[1].state = 6;
		card_ind();
		{
			int reads = M.sys_reads[1];
			run_ms(200, true);
			CHECK(strstr(logbuf, "SIM2: the modem set the USIM illegal, ") != NULL);
			CHECK(M.sys_reads[1] == reads + 1);
		}
		/* the indication: another radio's reject */
		{
			uint8_t ind[64], rat = 5, dom = 1, cause = 3, plmn[5] = { 0x94, 0x01, 45, 0, 0 };
			uint32_t n = 0;
			put_tlv(ind, &n, 0x01, &rat, 1);
			put_tlv(ind, &n, 0x02, &dom, 1);
			put_tlv(ind, &n, 0x03, &cause, 1);
			put_tlv(ind, &n, 0x10, plmn, 5);
			answer(0x4011, 4, 0, 0x0068, 0, ind, n);
			run_ms(100, true);
			CHECK(strstr(logbuf, "LaurelCell: SIM1 reject (indication): UMTS, domain CS, cause 3 (illegal UE), network 404-45") != NULL);
			/* the same again: no new line */
			answer(0x4011, 4, 0, 0x0068, 0, ind, n);
			run_ms(100, true);
			CHECK(count_of(logbuf, "reject (indication)") == 1);
			/* a cut one: ignored */
			answer(0x4011, 4, 0, 0x0068, 0, ind, 4);
			run_ms(100, true);
			CHECK(count_of(logbuf, "reject (indication)") == 1);
		}
		run_ms(15000, true);
		CHECK(strstr(last(), "SIM2 present (USIM illegal)") != NULL);
		CHECK(strstr(logbuf, IMEI_OK) == NULL && strstr(logbuf, "4901") == NULL && strstr(state_now(), "4901") == NULL && strstr(status_text, "4901") == NULL);
		break;
	case 'Y':       /* the verdicts; retries are bounded; a late IMEI is seen; two radios with a reject do not take turns; a cut system info is ignored */
		scen = "Y IMEI verdicts, cuts";
		CHECK(imei_verdict((const uint8_t *)IMEI_OK, 15) == IMEI_VALID);
		CHECK(imei_verdict((const uint8_t *)"490154203237519", 15) == IMEI_BAD);
		CHECK(imei_verdict((const uint8_t *)"000000000000000", 15) == IMEI_ZERO);
		CHECK(imei_verdict((const uint8_t *)"49015420323751", 14) == IMEI_FORMAT);
		CHECK(imei_verdict((const uint8_t *)"49015420323751X", 15) == IMEI_FORMAT);
		CHECK(imei_verdict((const uint8_t *)"490154203237518 \0", 17) == IMEI_VALID);
		CHECK(imei_verdict((const uint8_t *)"   ", 3) == IMEI_ABSENT);
		CHECK(imei_verdict(NULL, 0) == IMEI_ABSENT);
		two_sims();
		M.reg_state = 3;
		M.rej_cause[0] = 7; M.rej_dom[0] = 2;
		M.rej_umts_too = true;
		M.sys_cut = true;
		services(true);
		run_ms(40000, true);
		CHECK(strstr(logbuf, "LaurelCell: IMEI: absent; software version absent") != NULL);
		CHECK(count_of(logbuf, " reject: ") == 0);                  /* cut TLV: no reject read from it */
		CHECK(strstr(status_text, "SIM1 registration denied (no reject cause reported)") != NULL);
		M.sys_cut = false;
		M.imei = "000000000000000";
		run_ms(40000, true);
		CHECK(strstr(logbuf, "LaurelCell: IMEI: present, all zeros") != NULL && strstr(state_now(), "imei=zero\n") != NULL);
		{
			int lines = count_of(logbuf, " reject: ");
			CHECK(lines == 3);                                  /* SIM1 LTE, SIM1 UMTS, SIM2 UMTS */
			run_ms(120000, true);
			CHECK(count_of(logbuf, " reject: ") == lines);
		}
		M.imei = IMEI_OK;
		M.ids_err = 0;
		ids_tries = 0;                                          /* the 6 tries of this boot are used up by now */
		ids_next = 0;
		run_ms(2000, true);
		CHECK(strstr(logbuf, "LaurelCell: IMEI: present, check digit valid") != NULL && strstr(state_now(), "imei=valid\n") != NULL);
		{
			int reads = M.ids_reads;
			run_ms(120000, true);
			CHECK(M.ids_reads == reads);
		}
		break;
	case 'Z':       /* a modem that knows none of the new messages: the rest works as before, 6 IMEI tries at most */
		scen = "Z facts refused";
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		test_ipa_on = true;
		M.why_err = 0x47;
		M.ids_err = 0x47;
		services(true);
		run_ms(400000, true);
		CHECK(M.set_online == 1 && M.ids_reads == 6);
		CHECK(strstr(logbuf, "LaurelCell: IMEI: unknown (GET_DEVICE_SERIAL_NUMBERS error 0x47)") != NULL);
		CHECK(strstr(logbuf, "REGISTER_INDICATIONS (network reject): error 0x47") != NULL);
		CHECK(strstr(logbuf, "SIM1 selection: GET_SYSTEM_SELECTION_PREFERENCE error 0x47") != NULL);
		CHECK(strstr(logbuf, "nas1: GET_SYSTEM_INFO error 0x47") != NULL);
		CHECK(strstr(last(), "modem online; SIM1 registered 404-45 Airtel LTE") != NULL);
		CHECK(strstr(state_now(), "imei=unknown\n") != NULL);
		break;
	default:
		break;
	}
}
