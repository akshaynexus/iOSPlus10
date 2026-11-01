import java.io.*;
import java.math.BigInteger;
import java.net.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.spec.RSAPublicKeySpec;
import java.util.*;

/**
 * adbd's side of the protocol, for the app's host test. It checks what real adbd checks: header magic and checksum, RSA_verify(NID_sha1) of a fresh token against the
 * stored keys, android_pubkey_decode of the offered key (size, n0inv, rr). Service "shell:CMD" runs CMD in /bin/sh with the test's environment. "root:" closes the
 * connection and comes back as root, like adbd's restart.
 */
final class FakeAdbd implements AutoCloseable {
    static final int CNXN = 0x4e584e43, AUTH = 0x48545541, OPEN = 0x4e45504f, OKAY = 0x59414b4f, CLSE = 0x45534c43, WRTE = 0x45545257;

    final ServerSocket server = new ServerSocket(0, 10, InetAddress.getLoopbackAddress());
    final Map<String, String> env;
    final List<java.security.interfaces.RSAPublicKey> trusted = new ArrayList<>();
    volatile boolean root = false, rootAllowed = true, acceptNewKeys = true;
    volatile int connections = 0, keysOffered = 0;
    final List<String> errors = Collections.synchronizedList(new ArrayList<>());
    final List<String> services = Collections.synchronizedList(new ArrayList<>());

    FakeAdbd(Map<String, String> env) throws IOException {
        this.env = env;
        Thread t = new Thread(this::acceptLoop);
        t.setDaemon(true);
        t.start();
    }
    int port() { return server.getLocalPort(); }
    @Override public void close() throws IOException { server.close(); }

    private void acceptLoop() {
        while (!server.isClosed()) {
            try {
                Socket s = server.accept();
                connections++;
                Thread t = new Thread(() -> serve(s));
                t.setDaemon(true);
                t.start();
            } catch (IOException e) { return; }
        }
    }

    private void send(OutputStream o, int cmd, int a0, int a1, byte[] d) throws IOException {
        ByteBuffer b = ByteBuffer.allocate(24 + d.length).order(ByteOrder.LITTLE_ENDIAN);
        int sum = 0;
        for (byte x : d) sum += x & 0xff;
        b.putInt(cmd).putInt(a0).putInt(a1).putInt(d.length).putInt(sum).putInt(~cmd).put(d);
        synchronized (o) { o.write(b.array()); o.flush(); }
    }

    private void serve(Socket s) {
        try (Socket x = s) {
            DataInputStream in = new DataInputStream(x.getInputStream());
            OutputStream o = x.getOutputStream();
            boolean authed = false;
            byte[] token = null;
            while (true) {
                byte[] h = new byte[24];
                in.readFully(h);
                ByteBuffer b = ByteBuffer.wrap(h).order(ByteOrder.LITTLE_ENDIAN);
                int cmd = b.getInt(), a0 = b.getInt(), a1 = b.getInt(), len = b.getInt(), sum = b.getInt(), magic = b.getInt();
                if (magic != ~cmd) { errors.add("bad magic"); return; }
                byte[] d = new byte[len];
                in.readFully(d);
                int mysum = 0;
                for (byte v : d) mysum += v & 0xff;
                if (mysum != sum) { errors.add("bad checksum"); return; }
                if (cmd == CNXN) {
                    if (a0 != 0x01000001) errors.add("version " + Integer.toHexString(a0));
                    if (!new String(d, StandardCharsets.UTF_8).startsWith("host::")) errors.add("banner");
                    token = new byte[20];
                    new SecureRandom().nextBytes(token);
                    send(o, AUTH, 1, 0, token);
                } else if (cmd == AUTH && a0 == 2) {
                    boolean ok = false;
                    for (java.security.interfaces.RSAPublicKey k : trusted) {
                        // real adbd treats the token as the digest
                        ok |= verifyDigest(k, token, d);
                    }
                    if (ok) {
                        authed = true;
                        send(o, CNXN, 0x01000001, 1 << 20, "device::ro.product.name=laurel_sprout;\0".getBytes(StandardCharsets.UTF_8));
                    } else {
                        token = new byte[20];
                        new SecureRandom().nextBytes(token);
                        send(o, AUTH, 1, 0, token);
                    }
                } else if (cmd == AUTH && a0 == 3) {
                    keysOffered++;
                    java.security.interfaces.RSAPublicKey k = decode(d);
                    if (k == null) { errors.add("public key did not decode"); return; }
                    if (!acceptNewKeys) return;
                    trusted.add(k);
                    authed = true;
                    send(o, CNXN, 0x01000001, 1 << 20, "device::ro.product.name=laurel_sprout;\0".getBytes(StandardCharsets.UTF_8));
                } else if (cmd == OPEN) {
                    if (!authed) { errors.add("OPEN before auth"); return; }
                    String svc = new String(d, 0, d.length - 1, StandardCharsets.UTF_8);
                    services.add(svc);
                    if (d[d.length - 1] != 0) errors.add("service not NUL terminated");
                    int remote = 7;
                    send(o, OKAY, remote, a0, new byte[0]);
                    if (svc.equals("root:")) {
                        if (!rootAllowed) {
                            send(o, WRTE, remote, a0, "ADB Root access is disabled by system setting - enable in Settings -> System -> Developer options\n".getBytes(StandardCharsets.UTF_8));
                            send(o, CLSE, remote, a0, new byte[0]);
                        } else {
                            send(o, WRTE, remote, a0, "restarting adbd as root\n".getBytes(StandardCharsets.UTF_8));
                            root = true;
                            return; // adbd dies; the socket closes
                        }
                    } else if (svc.startsWith("shell:")) {
                        String c = svc.substring(6);
                        ProcessBuilder pb = new ProcessBuilder("/bin/sh", "-c", c).redirectErrorStream(true);
                        pb.environment().putAll(env);
                        pb.environment().put("FAKE_UID", root ? "0" : "2000");
                        Process p = pb.start();
                        p.getOutputStream().close();
                        byte[] out = p.getInputStream().readAllBytes();
                        p.waitFor();
                        if (out.length > 0) {
                            send(o, WRTE, remote, a0, out);
                        }
                        send(o, CLSE, remote, a0, new byte[0]);
                    } else {
                        send(o, CLSE, remote, a0, new byte[0]);
                    }
                } else if (cmd != OKAY && cmd != CLSE) {
                    errors.add("packet " + Integer.toHexString(cmd));
                }
            }
        } catch (EOFException | SocketException e) {
            // client went away
        } catch (Exception e) {
            errors.add(e.toString());
        }
    }

    /** RSA_verify(NID_sha1, token, 20, sig, ...): PKCS#1 v1.5 with the SHA-1 DigestInfo around the token, token as the hash. */
    private static boolean verifyDigest(java.security.interfaces.RSAPublicKey k, byte[] token, byte[] sig) {
        BigInteger m = new BigInteger(1, sig).modPow(k.getPublicExponent(), k.getModulus());
        byte[] em = new byte[256];
        byte[] mb = m.toByteArray();
        int skip = mb.length > 256 ? mb.length - 256 : 0;
        System.arraycopy(mb, skip, em, 256 - (mb.length - skip), mb.length - skip);
        byte[] prefix = { 0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14 };
        int ps = 256 - 3 - prefix.length - 20;
        if (em[0] != 0 || em[1] != 1 || em[2 + ps] != 0) return false;
        for (int i = 0; i < ps; i++) if (em[2 + i] != (byte) 0xff) return false;
        for (int i = 0; i < prefix.length; i++) if (em[3 + ps + i] != prefix[i]) return false;
        for (int i = 0; i < 20; i++) if (em[3 + ps + prefix.length + i] != token[i]) return false;
        return true;
    }

    /** android_pubkey_decode + the checks on n0inv and rr. */
    private java.security.interfaces.RSAPublicKey decode(byte[] d) throws Exception {
        String line = new String(d, StandardCharsets.US_ASCII);
        if (d[d.length - 1] != 0) { errors.add("key not NUL terminated"); return null; }
        byte[] raw = Base64.getDecoder().decode(line.substring(0, line.indexOf(' ')));
        if (raw.length != 524) { errors.add("key size " + raw.length); return null; }
        ByteBuffer b = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        int words = b.getInt(), n0inv = b.getInt();
        if (words != 64) { errors.add("modulus words " + words); return null; }
        byte[] ng = new byte[256], rr = new byte[256];
        for (int i = 255; i >= 0; i--) ng[i] = b.get();
        for (int i = 255; i >= 0; i--) rr[i] = b.get();
        int e = b.getInt();
        BigInteger n = new BigInteger(1, ng);
        BigInteger want = BigInteger.ONE.shiftLeft(4096).mod(n);
        if (!want.equals(new BigInteger(1, rr))) errors.add("rr wrong");
        if ((n.intValue() * n0inv) != -1) errors.add("n0inv wrong");
        return (java.security.interfaces.RSAPublicKey) KeyFactory.getInstance("RSA").generatePublic(new RSAPublicKeySpec(n, BigInteger.valueOf(e & 0xffffffffL)));
    }
}
