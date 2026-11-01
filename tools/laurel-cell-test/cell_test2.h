/*
 * Scenarios of laurel 2786 (test-cell.sh): the DMS mode is read again until online, the NAS binding is asked again, the state for the
 * SpringBoard bridge says bars only when registered. Included by cell_test.c. The bridge's parser (userland/laurel/cell/cellbar_state.h)
 * reads the kernel's own text here, so the two ends are tested against each other.
 */
static const char *
state_now(void)
{
	static char out[sizeof(state_text)];
	struct sysctl_req r = { out, sizeof(out), NULL, 0 };

	CHECK(cell_state_sysctl(NULL, NULL, 0, &r) == 0);
	return out;
}

static int
digit_run(const char *t)
{
	int best = 0, n = 0;

	for (; *t != 0; t++) {
		n = *t >= '0' && *t <= '9' ? n + 1 : 0;
		best = n > best ? n : best;
	}
	return best;
}

static void
scenario2(char s)
{
	struct cellbar_state cs;

	switch (s) {
	case 'I':       /* boot 20:02: the first read says 5, "shutting down"; the modem goes to low power later; IPA on: online */
		scen = "I mode 5, then low power, then online";
		test_ipa_on = true;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.opmode = 5; M.opmode_later = 1; M.opmode_after = 2;
		services(true);
		run_ms(3000, true);
		CHECK(M.set_online == 0);
		CHECK(nsaid == 0);                          /* no first line with mode 5 */
		run_ms(45000, true);
		CHECK(M.set_online == 1);
		CHECK(strstr(logbuf, "operating mode shutting down") != NULL && strstr(logbuf, "operating mode low power") != NULL);
		CHECK(strstr(last(), "LAUREL CELL: on: SIM1 present (USIM ready), SIM2 absent; modem online; SIM1 registered 404-45 Airtel LTE") != NULL);
		cellbar_parse(state_now(), &cs);
		CHECK(cs.state == CB_ON && cs.radio_online && cs.sub[0].reg == 2 && cs.sub[0].bars == 2 && strcmp(cs.sub[0].op, "Airtel") == 0);
		break;
	case 'J':       /* first reads answer error 0x4a (boot 07:45), later low power: read again every 10 s, 3 log lines at most */
		scen = "J mode error, then low power";
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.opmode_err_left = 5;
		services(true);
		run_ms(70000, true);
		CHECK(M.opmode_reads >= 6);
		CHECK(strstr(last(), "part: SIM1 present (USIM ready), SIM2 absent; modem low power") != NULL);
		break;
	case 'K':       /* boot 22:50: the modem says 5 and takes every request without a change: 6 rounds, bounded, then the line says so */
		scen = "K mode stays 5";
		test_ipa_on = true;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.opmode = 5; M.mode_sticky = true;
		services(true);
		run_ms(19000, true);
		CHECK(M.set_online == 0 && M.set_lpm == 0);         /* grace time */
		run_ms(4000, true);
		CHECK(M.set_lpm == 1 && M.set_online == 1);         /* low power, then online despite 5 */
		run_ms(400000, true);
		CHECK(M.set_lpm == 6 && M.set_online == 6);
		CHECK(strstr(logbuf, "DMS SET_OPERATING_MODE online: ok (reported shutting down, round 6 of 6)") != NULL);
		CHECK(strstr(last(), "part: SIM1 present (USIM ready), SIM2 absent; modem shutting down; radio off: modem answered ONLINE ok 6 times") != NULL);
		cellbar_parse(state_now(), &cs);
		CHECK(!cs.radio_online && cs.sub[0].bars == 0 && cs.sub[0].reg == 0 && strcmp(cs.sub[0].sim, "ready") == 0);
		CHECK(strstr(state_now(), "mode=shutting down\n") != NULL && strstr(state_now(), "caps=GSM,UMTS,LTE\n") != NULL);
		break;
	case 'P':       /* 5, low power refused (invalid transition, scion), online works: the refusal does not stop the round */
		scen = "P low power refused, online ok";
		test_ipa_on = true;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.opmode = 5; M.lpm_refuse = 0x3C;
		services(true);
		run_ms(60000, true);
		CHECK(M.set_lpm == 1 && M.set_online == 1);
		CHECK(strstr(logbuf, "DMS SET_OPERATING_MODE low power: error 0x3c") != NULL);
		CHECK(strstr(logbuf, "operating mode online (raw 0") != NULL);
		CHECK(strstr(last(), "on: SIM1 present (USIM ready), SIM2 absent; modem online; SIM1 registered") != NULL);
		cellbar_parse(state_now(), &cs);
		CHECK(cs.radio_online && cs.sub[0].reg == 2);
		CHECK(strstr(state_now(), "sub0.plmn=404-45\nsub0.ps=1\n") != NULL && strstr(state_now(), "sub0.rsrp=-98\n") != NULL);
		break;
	case 'Q':       /* 5, everything refused: 6 rounds and the line has the error; no IPA: nothing asked at all */
		scen = "Q all refused, then no IPA";
		test_ipa_on = true;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.opmode = 5; M.lpm_refuse = 0x34; M.set_refuse_left = 100;
		services(true);
		run_ms(200000, true);
		CHECK(M.set_online == 6 && M.set_lpm == 6);
		CHECK(strstr(last(), "modem shutting down; radio off: modem refused ONLINE 6 times, error 0x34") != NULL);
		break;
	case 'R':       /* the mode indication: low power comes by itself: ONLINE without our low power; no IPA first: no SET */
		scen = "R mode indication";
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.opmode = 5;
		services(true);
		run_ms(30000, true);
		CHECK(M.set_lpm == 0 && M.set_online == 0 && M.event_reports == 1);
		CHECK(strstr(logbuf, "modem radio technologies: GSM,UMTS,LTE") != NULL);
		{
			uint8_t mode = 1, ind[8];
			uint32_t n = 0;
			put_tlv(ind, &n, 0x14, &mode, 1);
			answer(0x4013, 4, 0, 0x0001, 0, ind, n);
		}
		test_ipa_on = true;
		run_ms(5000, true);
		CHECK(strstr(logbuf, "operating mode low power (raw 1, indication") != NULL);
		CHECK(M.set_lpm == 0 && M.set_online == 1);
		break;
	case 'L':       /* the modem refuses ONLINE 2 times, then takes it; then a run where it always refuses: the line says so */
		scen = "L ONLINE refused";
		test_ipa_on = true;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.set_refuse_left = 2;
		services(true);
		run_ms(60000, true);
		CHECK(M.set_online == 3);
		CHECK(strstr(last(), "modem online; SIM1 registered") != NULL);
		break;
	case 'M':
		scen = "M ONLINE always refused";
		test_ipa_on = true;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.set_refuse_left = 100;
		services(true);
		run_ms(120000, true);
		CHECK(M.set_online == 6);
		CHECK(strstr(last(), "part: SIM1 present (USIM ready), SIM2 absent; modem low power; radio off: modem refused ONLINE 6 times, error 0x34") != NULL);
		CHECK(M.set_lpm == 0);
		break;
	case 'N':       /* boot 20:02: BIND error 3 while UIM starts: asked again; nas2 never binds: no registration claimed for SIM2 */
		scen = "N NAS bind retries";
		test_ipa_on = true;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.sim[1].card = 1; M.sim[1].type = 2; M.sim[1].state = 7;
		M.bind_err_left[0] = 2; M.bind_err_left[1] = 100;
		services(true);
		run_ms(100000, true);
		CHECK(M.binds[0] == 1 && M.binds[1] == 0);
		CHECK(strstr(last(), "SIM1 registered 404-45 Airtel LTE") != NULL);
		CHECK(strstr(last(), "SIM2: NAS not bound to this SIM") != NULL);
		cellbar_parse(state_now(), &cs);
		CHECK(cs.sub[0].reg == 2 && cs.sub[1].reg == 0 && cs.sub[1].bars == 0 && strcmp(cs.sub[1].sim, "ready") == 0 && cs.sub[1].slot == 2);
		break;
	case 'O':       /* no fake bars: searching = 0 bars; registered without a reading = 0 bars; thresholds; off; privacy */
		scen = "O bars";
		test_ipa_on = true;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.register_ok = false;
		services(true);
		run_ms(40000, true);
		cellbar_parse(state_now(), &cs);
		CHECK(cs.state == CB_STARTING && cs.radio_online && cs.sub[0].reg == 1 && cs.sub[0].bars == 0 && cs.sub[0].op[0] == 0);
		M.register_ok = true; M.no_signal = true;
		run_ms(25000, true);
		cellbar_parse(state_now(), &cs);
		CHECK(cs.sub[0].reg == 2 && cs.sub[0].bars == 0 && strcmp(cs.sub[0].op, "Airtel") == 0);
		M.no_signal = false; M.rsrp = -84;
		run_ms(25000, true);
		cellbar_parse(state_now(), &cs);
		CHECK(cs.sub[0].bars == 4);
		M.rsrp = -116;
		run_ms(25000, true);
		cellbar_parse(state_now(), &cs);
		CHECK(cs.sub[0].bars == 0 && cs.sub[0].reg == 2);
		/* laurel 2943: the key imei= has a verdict; no identity: no run of digits as long as one */
		CHECK(strstr(state_now(), "imsi") == NULL && strstr(state_now(), "iccid") == NULL && digit_run(state_now()) < 14);
		laurel_cell_off("modem crashed: x");
		cellbar_parse(state_now(), &cs);
		CHECK(cs.state == CB_OFF && cs.sub[0].bars == 0 && cs.sub[0].reg == 0 && !cs.radio_online);
		{
			char line[] = "on: test\nline";
			struct sysctl_req r = { NULL, 0, line, sizeof(line) - 1 };
			CHECK(cell_ui_sysctl(NULL, NULL, 0, &r) == 0);
			CHECK(strstr(logbuf, "LAUREL CELLBAR: on: test.line") != NULL);
		}
		break;
	default:
		break;
	}
}
