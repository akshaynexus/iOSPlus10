package org.iosplus10.laurelswitcher;

import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.math.BigInteger;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.interfaces.RSAPublicKey;
import java.util.Base64;

/**
 * The device side of adb, from an app on the device: a minimal adb client over TCP to the phone's own adbd (127.0.0.1). No root in the app: adbd checks the
 * key like any host's, and root comes from adbd's own "root:" service (Developer options, Rooted debugging). Protocol: AOSP packages/modules/adb/protocol.txt.
 */
public final class AdbClient implements AutoCloseable {
    public interface Auth {
        /** PKCS#1 v1.5 RSA signature over the 20 byte token treated as a SHA-1 digest. */
        byte[] sign(byte[] token) throws Exception;
        /** The public key adbd stores: adb's own encoding (AdbClient.publicKeyPayload). */
        byte[] publicKey() throws Exception;
    }

    static final int CNXN = 0x4e584e43, AUTH = 0x48545541, OPEN = 0x4e45504f, OKAY = 0x59414b4f, CLSE = 0x45534c43, WRTE = 0x45545257;
    static final int VERSION = 0x01000001, MAX_DATA = 1024 * 1024;
    static final int AUTH_TOKEN = 1, AUTH_SIGNATURE = 2, AUTH_RSAPUBLICKEY = 3;
    /** The owner answers the "Allow debugging" dialog at the first connection. */
    public static final int AUTH_WAIT_MS = 60000;
    static final int READ_WAIT_MS = 60000;

    private final Socket sock;
    private final DataInputStream in;
    private final OutputStream out;
    private int nextId = 1;
    private int peerMax = 4096;

    static final class Packet {
        int cmd, arg0, arg1;
        byte[] data;
    }

    private AdbClient(Socket s) throws IOException {
        sock = s;
        in = new DataInputStream(s.getInputStream());
        out = s.getOutputStream();
    }

    /** Connect and pass the key check. Throws when adbd does not listen or the key is refused. */
    public static AdbClient connect(String host, int port, Auth auth) throws Exception {
        Socket s = new Socket();
        s.setTcpNoDelay(true);
        s.connect(new InetSocketAddress(host, port), 3000);
        s.setSoTimeout(AUTH_WAIT_MS);
        AdbClient c = new AdbClient(s);
        try {
            c.send(CNXN, VERSION, MAX_DATA, "host::laurelswitcher\0".getBytes(StandardCharsets.US_ASCII));
            int tokens = 0;
            while (true) {
                Packet p = c.read();
                if (p.cmd == CNXN) {
                    c.peerMax = Math.max(4096, p.arg1);
                    s.setSoTimeout(READ_WAIT_MS);
                    return c;
                }
                if (p.cmd != AUTH || p.arg0 != AUTH_TOKEN) throw new IOException("unexpected packet " + Integer.toHexString(p.cmd) + " during auth");
                if (++tokens == 1) c.send(AUTH, AUTH_SIGNATURE, 0, auth.sign(p.data));
                else if (tokens == 2) c.send(AUTH, AUTH_RSAPUBLICKEY, 0, auth.publicKey());
                else throw new IOException("adbd refused the key");
            }
        } catch (Exception e) {
            c.close();
            throw e;
        }
    }

    /** Run a service to its end and return what it wrote. EOF without CLSE (adbd restarting, reboot) keeps what came. */
    public String run(String service) throws IOException {
        int local = nextId++;
        send(OPEN, local, 0, (service + "\0").getBytes(StandardCharsets.UTF_8));
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        int remote = 0;
        try {
            while (true) {
                Packet p = read();
                if (p.arg1 != local && p.cmd != CNXN && p.cmd != AUTH) continue;
                if (p.cmd == OKAY) {
                    remote = p.arg0;
                } else if (p.cmd == WRTE) {
                    remote = p.arg0;
                    o.write(p.data);
                    send(OKAY, local, remote, new byte[0]);
                } else if (p.cmd == CLSE) {
                    if (remote != 0) send(CLSE, local, remote, new byte[0]);
                    break;
                }
            }
        } catch (java.io.EOFException | java.net.SocketException e) {
            // adbd went away: "root:" restarts it, a reboot stops it. The caller reads what came.
        }
        return o.toString(StandardCharsets.UTF_8.name());
    }

    int peerMaxData() { return peerMax; }

    private void send(int cmd, int a0, int a1, byte[] data) throws IOException {
        ByteBuffer b = ByteBuffer.allocate(24 + data.length).order(ByteOrder.LITTLE_ENDIAN);
        int sum = 0;
        for (byte x : data) sum += x & 0xff;
        b.putInt(cmd).putInt(a0).putInt(a1).putInt(data.length).putInt(sum).putInt(~cmd).put(data);
        out.write(b.array());
        out.flush();
    }

    private Packet read() throws IOException {
        byte[] h = new byte[24];
        in.readFully(h);
        ByteBuffer b = ByteBuffer.wrap(h).order(ByteOrder.LITTLE_ENDIAN);
        Packet p = new Packet();
        p.cmd = b.getInt();
        p.arg0 = b.getInt();
        p.arg1 = b.getInt();
        int len = b.getInt();
        b.getInt();
        if (b.getInt() != ~p.cmd || len < 0 || len > MAX_DATA) throw new IOException("bad adb packet");
        p.data = new byte[len];
        in.readFully(p.data);
        return p;
    }

    @Override public void close() {
        try { sock.close(); } catch (IOException e) { /* nothing to do */ }
    }

    /** ASN.1 prefix of a SHA-1 DigestInfo: adbd uses RSA_verify(NID_sha1, token, ...). */
    public static byte[] sha1DigestInfo(byte[] token) {
        byte[] prefix = { 0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14 };
        byte[] r = new byte[prefix.length + token.length];
        System.arraycopy(prefix, 0, r, 0, prefix.length);
        System.arraycopy(token, 0, r, prefix.length, token.length);
        return r;
    }

    /** android_pubkey_encode (AOSP system/core/libcrypto_utils) + base64 + name + NUL: 2048 bit keys only. */
    public static byte[] publicKeyPayload(RSAPublicKey key, String name) {
        BigInteger n = key.getModulus();
        if (n.bitLength() != 2048) throw new IllegalArgumentException("adb takes 2048 bit RSA keys");
        BigInteger r32 = BigInteger.ONE.shiftLeft(32);
        long n0inv = n.mod(r32).modInverse(r32).negate().mod(r32).longValue();
        BigInteger rr = BigInteger.ONE.shiftLeft(4096).mod(n);
        ByteBuffer b = ByteBuffer.allocate(524).order(ByteOrder.LITTLE_ENDIAN);
        b.putInt(64).putInt((int) n0inv);
        for (int i = 0; i < 64; i++) b.putInt(n.shiftRight(32 * i).intValue());
        for (int i = 0; i < 64; i++) b.putInt(rr.shiftRight(32 * i).intValue());
        b.putInt(key.getPublicExponent().intValueExact());
        String line = Base64.getEncoder().encodeToString(b.array()) + " " + name + "\0";
        return line.getBytes(StandardCharsets.US_ASCII);
    }
}
