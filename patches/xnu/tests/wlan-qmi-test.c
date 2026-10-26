/*
 * Host test for the QMI TLV coder (patch 0266, bsd/dev/negroni_wlan_qmi.c + negroni_wlfw_tables.h)
 * and the QRTR packet decoder (patch 0265, bsd/dev/negroni_wlan_qrtr.c). Run it with
 *   scripts/wifi/qmi-host-test.sh TREE          (TREE = a patched tree, scripts/kernel/patched-tree.sh)
 * The script cuts the coder and the parser out of the kernel files (no kernel headers needed).
 * Checks: exact bytes of HOST_CAP / RESPOND_MEM / IND_REGISTER / CAP requests, a full BDF segment
 * is the v01 maximum (6182 bytes, v01.h:648), decode of REQUEST_MEM_IND and CAP responses with
 * nested strings and an unknown TLV, refusal of truncated / over-count / mandatory-missing input,
 * then random and mutated input under ASan/UBSan.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include "negroni_wlfw_tables.h"
struct qrtr_pkt { uint32_t version, type, src_node, src_port, dst_node, dst_port, size; bool confirm_rx; const uint8_t *payload; };
int negroni_qrtr_parse(const uint8_t *buf, uint32_t len, struct qrtr_pkt *out);
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(1);} } while (0)
static uint8_t buf[16384];
static void hex(const uint8_t *b, uint32_t n){for(uint32_t i=0;i<n;i++)printf("%02x%s",b[i],i%16==15?"\n":" ");printf("\n");}
int main(void){
 uint32_t len;
 struct wlfw_host_cap_req hc; memset(&hc,0,sizeof hc);
 hc.num_clients_valid=1; hc.num_clients=1; hc.bdf_support_valid=hc.bdf_support=1; hc.m3_support_valid=hc.m3_support=1;
 hc.m3_cache_support_valid=hc.m3_cache_support=1; hc.cal_done_valid=1; hc.host_build_type_valid=1; hc.host_build_type=2;
 hc.feature_list_valid=1; hc.feature_list=5;
 CHECK(!negroni_qmi_encode(&wlfw_host_cap_req_d, QMI_REQUEST, 7, &hc, buf, sizeof buf, &len));
 printf("HOST_CAP %u bytes:\n", len); hex(buf,len);
 static const uint8_t exp_hc[] = {0,7,0,0x34,0,0x29,0, 0x10,4,0,1,0,0,0, 0x14,1,0,1, 0x16,1,0,1, 0x17,1,0,1, 0x1a,1,0,0, 0x20,4,0,2,0,0,0, 0x27,8,0,5,0,0,0,0,0,0,0};
 CHECK(len==sizeof exp_hc && !memcmp(buf,exp_hc,len));
 /* REQUEST_MEM_IND: 2 segs */
 uint8_t im[] = {4,1,0,0x35,0,0,0, 0x01,0,0, 2, 0x00,0x00,0x40,0x00, 1,0,0,0, 1, 0x10,0,0,0,0,0,0,0, 0x00,0x10,0,0, 1,  0x00,0x80,0,0, 4,0,0,0, 0};
 uint16_t tl = sizeof im - 10; im[8]=tl&0xff; im[9]=tl>>8; uint16_t ml=sizeof im-7; im[5]=ml; im[6]=ml>>8;
 static struct wlfw_request_mem_ind m;
 CHECK(!negroni_qmi_decode(&wlfw_request_mem_ind_d, im, sizeof im, &m));
 CHECK(m.mem_seg_len==2 && m.mem_seg[0].size==0x400000 && m.mem_seg[0].type==1 && m.mem_seg[0].mem_cfg_len==1 && m.mem_seg[0].mem_cfg[0].offset==0x10 && m.mem_seg[0].mem_cfg[0].size==0x1000 && m.mem_seg[0].mem_cfg[0].secure_flag==1 && m.mem_seg[1].size==0x8000 && m.mem_seg[1].type==4 && m.mem_seg[1].mem_cfg_len==0);
 /* truncated by one: must fail */
 im[8]--; im[5]--; CHECK(negroni_qmi_decode(&wlfw_request_mem_ind_d, im, sizeof im - 1, &m)==EBADMSG); im[8]++; im[5]++;
 /* count above max */
 im[10]=53; CHECK(negroni_qmi_decode(&wlfw_request_mem_ind_d, im, sizeof im, &m)==EBADMSG); im[10]=2;
 /* CAP response with strings and an unknown TLV */
 uint8_t cr[512]; uint32_t p=7;
 #define PUT(...) do { uint8_t t_[]={__VA_ARGS__}; memcpy(cr+p,t_,sizeof t_); p+=sizeof t_; } while(0)
 PUT(0x02,4,0,0,0,0,0); PUT(0x10,8,0,0x02,0,0,0,0x04,0x40,0,0); PUT(0x11,4,0,0xff,0,0,0); PUT(0x99,2,0,0xaa,0xbb);
 PUT(0x13,4+1+5,0,0x11,0x22,0x33,0x44,5,'1','2',':','3','4'); PUT(0x14,6,0,'W','L','A','N','.','1'); PUT(0x23,1,0,1);
 cr[0]=2; cr[1]=3; cr[2]=0; cr[3]=0x24; cr[4]=0; cr[5]=(p-7)&0xff; cr[6]=(p-7)>>8;
 static struct wlfw_cap_resp c;
 CHECK(!negroni_qmi_decode(&wlfw_cap_resp_d, cr, p, &c));
 CHECK(c.resp.result==0 && c.chip_info_valid && c.chip_info.chip_id==2 && c.chip_info.chip_family==0x4004 && c.board_info.v==0xff && c.fw_version_info.fw_version==0x44332211 && !strcmp(c.fw_version_info.fw_build_timestamp,"12:34") && !strcmp(c.fw_build_id,"WLAN.1") && c.regdb_mandatory_valid && c.regdb_mandatory==1 && !c.soc_info_valid);
 printf("CAP decode OK: build %s ts %s\n", c.fw_build_id, c.fw_version_info.fw_build_timestamp);
 /* missing mandatory 0x02 */
 uint8_t nr[]={2,1,0,0x34,0,0,0}; static struct wlfw_resp_only ro; CHECK(negroni_qmi_decode(&wlfw_host_cap_resp_d,nr,sizeof nr,&ro)==EBADMSG);
 uint8_t okr[]={2,1,0,0x34,0,7,0,2,4,0,1,0,0x2a,0}; CHECK(!negroni_qmi_decode(&wlfw_host_cap_resp_d,okr,sizeof okr,&ro) && ro.resp.result==1 && ro.resp.error==0x2a);
 /* BDF full segment */
 static struct wlfw_bdf_download_req b; memset(&b,0,sizeof b); b.valid=1; b.file_id_valid=1; b.file_id=0xff; b.total_size_valid=1; b.total_size=59932; b.seg_id_valid=1; b.data_valid=1; b.data_len=6144; for(int i=0;i<6144;i++) b.data[i]=i; b.end_valid=1; b.bdf_type_valid=1; b.bdf_type=1;
 CHECK(!negroni_qmi_encode(&wlfw_bdf_download_req_d, 0, 9, &b, buf, 8192-32, &len));
 printf("BDF segment %u bytes (msg_len %u, v01 max 6182)\n", len, len-7); CHECK(len-7==6182);
 b.data_len=6145; CHECK(negroni_qmi_encode(&wlfw_bdf_download_req_d, 0, 9, &b, buf, 8192, &len)==EINVAL);
 /* RESPOND_MEM / M3 / IND_REGISTER encodes */
 static struct wlfw_respond_mem_req rm; rm.mem_seg_len=1; rm.mem_seg[0].addr=0x812340000ull; rm.mem_seg[0].size=0x400000; rm.mem_seg[0].type=1;
 CHECK(!negroni_qmi_encode(&wlfw_respond_mem_req_d,0,3,&rm,buf,sizeof buf,&len)); hex(buf,len);
 static const uint8_t exp_rm[]={0,3,0,0x36,0,21,0,1,18,0,1, 0,0,0x34,0x12,8,0,0,0, 0,0,0x40,0, 1,0,0,0, 0};
 CHECK(len==sizeof exp_rm && !memcmp(buf,exp_rm,len));
 struct wlfw_m3_info_req m3={.addr=0x80610000ull,.size=266684}; CHECK(!negroni_qmi_encode(&wlfw_m3_info_req_d,0,4,&m3,buf,sizeof buf,&len)); CHECK(len==7+11+7);
 struct wlfw_ind_register_req ir; memset(&ir,0,sizeof ir); ir.fw_ready_enable_valid=ir.fw_ready_enable=1; ir.client_id_valid=1; ir.client_id=0x4b4e454c; ir.request_mem_enable_valid=ir.request_mem_enable=1; ir.fw_mem_ready_enable_valid=ir.fw_mem_ready_enable=1; ir.fw_init_done_enable_valid=ir.fw_init_done_enable=1; ir.cal_done_enable_valid=ir.cal_done_enable=1;
 CHECK(!negroni_qmi_encode(&wlfw_ind_register_req_d,0,1,&ir,buf,sizeof buf,&len)); hex(buf,len);
 struct wlfw_empty e={0}; CHECK(!negroni_qmi_encode(&wlfw_cap_req_d,0,5,&e,buf,sizeof buf,&len)); CHECK(len==7 && buf[3]==0x24 && buf[5]==0);
 /* fuzz every decoder */
 const struct qmi_msg_desc *ds[]={&wlfw_ind_register_resp_d,&wlfw_host_cap_resp_d,&wlfw_request_mem_ind_d,&wlfw_cap_resp_d,&wlfw_bdf_download_resp_d,&wlfw_fw_init_done_ind_d,&wlfw_cal_done_ind_d,&wlfw_respond_mem_req_d,&wlfw_bdf_download_req_d};
 static uint8_t fz[4096]; srand(1);
 for(int it=0;it<300000;it++){ uint32_t n=rand()%600; for(uint32_t i=0;i<n;i++) fz[i]=rand()%(it&1?256:8); if(n>=7){uint16_t mlen=rand()%(n); fz[5]=mlen; fz[6]=mlen>>8;}
  const struct qmi_msg_desc *d=ds[it%9]; uint8_t *cp=malloc(d->csize); uint8_t *in=malloc(n?n:1); memcpy(in,fz,n); (void)negroni_qmi_decode(d,in,n,cp); free(cp); free(in);}
 /* mutate the valid REQUEST_MEM_IND */
 for(int it=0;it<200000;it++){ uint8_t t[sizeof im]; memcpy(t,im,sizeof im); t[rand()%sizeof im]=rand(); uint32_t n=rand()%(sizeof im+1); uint8_t *in=malloc(n?n:1); memcpy(in,t,n); (void)negroni_qmi_decode(&wlfw_request_mem_ind_d,in,n,&m); free(in);}
 /* QRTR parse */
 uint8_t q[64]={1,0,0,0, 2,0,0,0, 7,0,0,0, 0xfe,0xff,0xff,0xff, 0,0,0,0, 20,0,0,0, 1,0,0,0, 0xfe,0xff,0xff,0xff, 2};
 struct qrtr_pkt k; CHECK(!negroni_qrtr_parse(q,52,&k) && k.type==2 && k.src_node==7 && k.size==20 && k.dst_port==0xfffffffe);
 CHECK(negroni_qrtr_parse(q,56,&k)==EBADMSG); /* len != hdr + ALIGN(size) */
 q[20]=19; CHECK(negroni_qrtr_parse(q,52,&k)==0); q[4]=4; CHECK(negroni_qrtr_parse(q,52,&k)==EBADMSG); /* NEW_SERVER < 20 */
 q[20]=0xff; q[21]=0xff; q[22]=0xff; q[23]=0xff; CHECK(negroni_qrtr_parse(q,52,&k)==EBADMSG);
 for(int it=0;it<500000;it++){ uint32_t n=rand()%80; uint8_t *in=malloc(n?n:1); for(uint32_t i=0;i<n;i++) in[i]=rand()%(it%3?4:256); if(n) in[0]=it&1?1:3; (void)negroni_qrtr_parse(in,n,&k); if(!negroni_qrtr_parse(in,n,&k)) CHECK(k.payload+k.size<=in+n); free(in);}
 printf("ALL PASS\n"); return 0;}
