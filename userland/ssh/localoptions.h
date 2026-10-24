/* iOSPlus10: dropbear options for the USB link (docs/usb-network.md). Read by the dropbear
 * build (copied into the build folder as localoptions.h). */

/* Public keys; passwords too, but the launchd job passes -s (no passwords) when an
 * authorized_keys file is installed. Without a key the job allows root + the stock
 * iOS password (see the doc). */
#define DROPBEAR_SVR_PUBKEY_AUTH 1
#define DROPBEAR_SVR_PASSWORD_AUTH 1
#define DROPBEAR_SVR_PAM_AUTH 0
#define DROPBEAR_CLI_PASSWORD_AUTH 1

#define DROPBEAR_ED25519 1
#define DROPBEAR_ECDSA 1

/* No forwarding of X11 or agents, no SFTP server binary, no MOTD. */
#define DROPBEAR_X11FWD 0
#define DROPBEAR_SVR_AGENTFWD 0
#define DROPBEAR_CLI_AGENTFWD 0
#define DROPBEAR_SFTPSERVER 0
#define DO_MOTD 0

/* Privilege separation needs setresgid(), which Darwin does not have. Unix-socket
 * forwarding depends on it, so it is off too. TCP forwarding stays on (ssh -L/-R). */
#define DROPBEAR_SVR_DROP_PRIVS 0
#define DROPBEAR_SVR_LOCALSTREAMFWD 0
#define DROPBEAR_SVR_REMOTESTREAMFWD 0

/* Host keys live in /private/etc/dropbear (the default /etc/dropbear is a symlink to it). */
#define DSS_PRIV_FILENAME "/private/etc/dropbear/dropbear_dss_host_key"
#define RSA_PRIV_FILENAME "/private/etc/dropbear/dropbear_rsa_host_key"
#define ECDSA_PRIV_FILENAME "/private/etc/dropbear/dropbear_ecdsa_host_key"
#define ED25519_PRIV_FILENAME "/private/etc/dropbear/dropbear_ed25519_host_key"

/* /usr/local/bin holds dropbear, toybox and our tools. */
#define DEFAULT_PATH "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
#define DEFAULT_ROOT_PATH "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
