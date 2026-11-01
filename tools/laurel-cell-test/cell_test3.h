/*
 * Scenarios of laurel 2932 (test-cell.sh): the data session's QMI steps. Included by cell_test.c. The AP pipes and the interface are stand-ins here
 * (tools/laurel-ipa-test/data_test.c tests the pipes). Layouts of the answers: libqmi, as hakios.mpss.c reads them. This does not prove the firmware's answers.
 */
static void
send_status_ind(uint32_t port, uint8_t status, uint16_t reason)
{
	uint8_t ind[32], v[2] = { status, 0 };
	uint32_t n = 0;

	put_tlv(ind, &n, 0x01, v, 2);
	put_tlv(ind, &n, 0x10, &reason, 2);
	answer(port, 4, 0, 0x0022, 0, ind, n);
}

static void
scenario3(char s)
{
	struct cellbar_state cs;

	switch (s) {
	case 'S':       /* the whole session: format before ONLINE, both families, settings to the interface, disconnect, START again */
		scen = "S data session";
		test_ipa_on = true;
		test_data_state = 1;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		services(true);
		data_services();
		run_ms(60000, true);
		CHECK(M.dpm_pipes[0] == 1 && M.dpm_pipes[1] == 9);
		CHECK(M.wda_sets == 1 && M.online_after_format);
		CHECK(M.wds_bind[0] == 1 && M.wds_bind[1] == 1 && M.wds_mux == 1);
		CHECK(M.wds_family[0] == 4 && M.wds_family[1] == 6);
		CHECK(M.wds_start[0] == 1 && M.wds_start[1] == 1 && M.start_family[0] == 4 && M.start_family[1] == 6);
		CHECK(P4.up && P4.ip == 0x0A000002 && P4.mask == 0xFFFFFFFC && P4.gw == 0x0A000001 && P4.dns1 == 0x08080808 && P4.mtu == 1430);
		CHECK(P6.up && P6.plen == 64 && P6.ip[0] == 0x24 && P6.gw[0] == 0xFE && P6.dns1[15] == 0x88 && P6.mtu == 1430);
		CHECK(strstr(logbuf, "LAUREL CELL DATA: on: pdp_ip0 IPv4") != NULL);
		CHECK(strstr(last(), "; data on: pdp_ip0 IPv4 IPv6; SMS, voice off: not built") != NULL);
		CHECK(strstr(state_now(), "data=on\n") != NULL);
		{
			/* the daemon's parser on the kernel's text */
			struct pdp_v4 a4 = { true, P4.ip, P4.mask, P4.gw, P4.dns1, P4.dns2, P4.mtu };
			struct pdp_v6 a6;
			struct celld_net cn;
			char t[640];
			memset(&a6, 0, sizeof(a6));
			a6.up = true; a6.plen = P6.plen; a6.mtu = P6.mtu;
			memcpy(a6.ip, P6.ip, 16); memcpy(a6.gw, P6.gw, 16); memcpy(a6.dns1, P6.dns1, 16);
			pdp_text(t, sizeof(t), &a4, &a6);
			celld_parse(t, &cn);
			CHECK(cn.on && strcmp(cn.ifname, "pdp_ip0") == 0 && cn.mtu == 1430);
			CHECK(strcmp(cn.v4, "10.0.0.2") == 0 && strcmp(cn.v4_mask, "255.255.255.252") == 0 && strcmp(cn.v4_gw, "10.0.0.1") == 0);
			CHECK(cn.v4_dns_n == 1 && strcmp(cn.v4_dns[0], "8.8.8.8") == 0);
			CHECK(strcmp(cn.v6, "2401:0:0:0:0:0:0:2") == 0 && cn.v6_plen == 64 && strcmp(cn.v6_gw, "fe80:0:0:0:0:0:0:1") == 0);
			CHECK(cn.v6_dns_n == 1 && strcmp(cn.v6_dns[0], "2001:0:0:0:0:0:0:88") == 0);
			a4.up = a6.up = false;
			pdp_text(t, sizeof(t), &a4, &a6);
			celld_parse(t, &cn);
			CHECK(!cn.on && cn.v4[0] == 0 && cn.v6[0] == 0);
		}
		cellbar_parse(state_now(), &cs);
		CHECK(cs.radio_online && cs.sub[0].reg == 2);
		send_status_ind(0x4019, 1, 3);
		run_ms(1000, true);
		CHECK(!P4.up && P6.up);
		CHECK(strstr(logbuf, "ipv4: disconnected, call end reason 3") != NULL);
		run_ms(15000, true);
		CHECK(M.wds_start[0] == 2 && P4.up);
		break;
	case 'T':       /* not registered: no START at all; registered: v4 up, v6 refused, retries are paced, one family is enough */
		scen = "T v6 refused";
		test_ipa_on = true;
		test_data_state = 1;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.register_ok = false;
		M.start_err[1] = 0x0E;                      /* call failed */
		services(true);
		data_services();
		run_ms(40000, true);
		CHECK(M.wds_start[0] == 0 && M.wds_start[1] == 0);
		M.register_ok = true;
		run_ms(25000, true);
		CHECK(M.wds_start[0] == 1 && P4.up && !P6.up);
		CHECK(M.wds_start[1] >= 1 && M.wds_start[1] <= 3);
		CHECK(strstr(logbuf, "ipv6: START_NETWORK: error 0xe, call end reason 12") != NULL);
		CHECK(strstr(last(), "data on: pdp_ip0 IPv4;") != NULL);
		run_ms(600000, true);
		CHECK(M.wds_start[1] <= 6 + 11);            /* 10 s gaps, then 60 s */
		break;
	case 'U':       /* WDA refuses: data off in one line, the radio still goes online, no WDS session */
		scen = "U WDA refused";
		test_ipa_on = true;
		test_data_state = 1;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.wda_err = 0x46;
		services(true);
		data_services();
		run_ms(50000, true);
		CHECK(strstr(logbuf, "LAUREL CELL DATA: off: WDA SET_DATA_FORMAT error 0x46") != NULL);
		CHECK(M.set_online == 1 && M.wds_start[0] == 0);
		CHECK(strstr(last(), "modem online; SIM1 registered") != NULL && strstr(last(), "data off: WDA SET_DATA_FORMAT error 0x46") != NULL);
		break;
	case 'V':       /* the pipes failed: same; modem crash with a session up: interface down, no START after it */
		scen = "V pipes off, crash";
		test_ipa_on = true;
		test_data_state = 1;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		services(true);
		data_services();
		run_ms(40000, true);
		CHECK(P4.up && P6.up);
		laurel_cell_off("modem crashed: x");
		CHECK(!P4.up && !P6.up);
		{
			int starts = M.wds_start[0];
			run_ms(30000, true);
			CHECK(M.wds_start[0] == starts);
		}
		break;
	case 'W':       /* boot-arg cell_data=0: no client request, the rest as before */
		scen = "W cell_data=0";
		test_ipa_on = true;
		test_data_state = 1;
		boot_cell_data = 0;
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		services(true);
		data_services();
		run_ms(50000, true);
		CHECK(strstr(logbuf, "LAUREL CELL DATA: off: boot-arg cell_data=0") != NULL);
		CHECK(M.wda_sets == 0 && M.wds_start[0] == 0 && M.set_online == 1);
		break;
	default:
		break;
	}
}
