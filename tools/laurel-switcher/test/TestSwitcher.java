import java.nio.file.*;
import java.security.*;
import java.security.interfaces.RSAPublicKey;
import java.util.*;
import org.iosplus10.laurelswitcher.*;

/** usage: TestSwitcher SCRIPT FAKEBIN BLOCKDIR LOGFILE FAKE_STATE LS_ROOT LOCK_PORT: the real client against FakeAdbd, the real script on a fake phone. */
public class TestSwitcher {
    static int fails = 0, checks = 0;
    static void check(boolean c, String what) { checks++; if (!c) { fails++; System.out.println("FAIL " + what); } }

    public static void main(String[] a) throws Exception {
        String script = new String(Files.readAllBytes(Paths.get(a[0])));
        Map<String, String> env = new HashMap<>();
        env.put("PATH", a[1] + ":" + System.getenv("PATH"));
        env.put("LS_BLOCK", a[2]);
        env.put("FAKE_LOG", a[3]);
        env.put("FAKE_STATE", a[4]);
        env.put("LS_ROOT", a[5]);
        int lockPortNumber = Integer.parseInt(a[6]);
        KeyPairGenerator g = KeyPairGenerator.getInstance("RSA");
        g.initialize(2048);
        KeyPair kp = g.generateKeyPair();
        AdbClient.Auth auth = new AdbClient.Auth() {
            public byte[] sign(byte[] t) throws Exception {
                Signature s = Signature.getInstance("NONEwithRSA");
                s.initSign(kp.getPrivate());
                s.update(AdbClient.sha1DigestInfo(t));
                return s.sign();
            }
            public byte[] publicKey() { return AdbClient.publicKeyPayload((RSAPublicKey) kp.getPublic(), "test@host"); }
        };

        // first use: key unknown -> token, signature refused, key offered, accepted; adbd as shell -> root: -> restart -> check passes -> unroot: -> shell (P9)
        try (FakeAdbd d = new FakeAdbd(env)) {
            Switcher.Result r = Switcher.run(script, "check", d.port(), auth, 5000);
            check(r.ok && r.text.contains("ready"), "first check: " + r.text);
            check(d.keysOffered == 1, "key offered once, got " + d.keysOffered);
            check(d.services.contains("root:"), "root service used");
            check(d.connections >= 3, "reconnected after the restart: " + d.connections);
            check(d.unrootCount == 1 && !d.root, "adbd back to shell after check: unroot " + d.unrootCount + " root " + d.root);
            // already root (the owner's adb root): this class made nothing root, it leaves it so
            d.root = true;
            d.services.clear();
            int u0 = d.unrootCount;
            r = Switcher.run(script, "check", d.port(), auth, 5000);
            check(r.ok, "second check: " + r.text);
            check(d.keysOffered == 1, "known key offered again");
            check(!d.services.contains("root:"), "root: asked again while already root");
            check(d.unrootCount == u0, "unroot of a root it did not ask for");
            d.root = false;
            check(d.errors.isEmpty(), "protocol errors: " + d.errors);
            Files.write(Paths.get(a[3]), new byte[0]);
            u0 = d.unrootCount;
            r = Switcher.run(script, "switch", d.port(), auth, 5000);
            check(r.ok && r.text.contains("slot b active"), "switch: " + r.text);
            String log = new String(Files.readAllBytes(Paths.get(a[3])));
            check(log.contains("set-active-boot-slot 1"), "switch called the HAL: " + log);
            check(log.contains("svc power reboot"), "switch rebooted: " + log);
            check(d.unrootCount == u0, "unroot after a switch: the phone reboots");
            d.root = false;
            check(d.errors.isEmpty(), "protocol errors: " + d.errors);
            // a refused check also goes back to shell
            Files.write(Paths.get(a[4], "active"), "0\n".getBytes());
            Files.write(Paths.get(a[4], "b_ok"), "1\n".getBytes());
            Files.move(Paths.get(a[2], "iosroot"), Paths.get(a[2], "iosroot.x"));
            u0 = d.unrootCount;
            r = Switcher.run(script, "check", d.port(), auth, 5000);
            Files.move(Paths.get(a[2], "iosroot.x"), Paths.get(a[2], "iosroot"));
            check(!r.ok && r.text.contains("no partition iosroot"), "refused check: " + r.text);
            check(d.unrootCount == u0 + 1 && !d.root, "adbd back to shell after a refusal");
        }
        // the boot lock (P3): all interfaces -> root -> lock -> shell on loopback; a second run needs no root
        try (FakeAdbd d = new FakeAdbd(env)) {
            d.trusted.add((RSAPublicKey) kp.getPublic());
            Path tcp = Paths.get(a[5], "proc/net/tcp");
            String hex = String.format("%04X", lockPortNumber);
            Files.write(tcp, ("  sl  local_address rem_address   st\n   0: 00000000:" + hex + " 00000000:0000 0A\n").getBytes());
            Switcher.Result r = Switcher.lockPort(script, d.port(), auth, 5000);
            check(r.ok && r.text.startsWith("on:"), "lock: " + r.text);
            check(d.services.contains("root:") && !d.root, "lock used root and went back to shell: root " + d.root);
            String log = new String(Files.readAllBytes(Paths.get(a[3])));
            check(log.contains("setprop service.adb.listen_addrs tcp:localhost:" + lockPortNumber), "listen_addrs: " + log);
            check(log.contains("setprop ctl.restart adbd"), "restart: " + log);
            check(new String(Files.readAllBytes(tcp)).contains("0100007F:" + hex), "fake kernel table");
            d.services.clear();
            r = Switcher.lockPort(script, d.port(), auth, 5000);
            check(r.ok && !d.services.contains("root:"), "second lock asks no root: " + r.text);
            // listen_addrs has no effect: reported as off
            Files.write(tcp, ("  sl  local_address rem_address   st\n   0: 00000000:" + hex + " 00000000:0000 0A\n").getBytes());
            env.put("FAKE_LOCK_NO_EFFECT", "1");
            r = Switcher.lockPort(script, d.port(), auth, 5000);
            env.remove("FAKE_LOCK_NO_EFFECT");
            check(!r.ok && r.text.contains("off:"), "lock with no effect: " + r.text);
            d.root = false;
        }
        // Rooted debugging off
        try (FakeAdbd d = new FakeAdbd(env)) {
            d.rootAllowed = false;
            Switcher.Result r = Switcher.run(script, "switch", d.port(), auth, 2000);
            check(!r.ok && r.text.contains("Rooted debugging"), "root off: " + r.text);
        }
        // key refused by the owner
        try (FakeAdbd d = new FakeAdbd(env)) {
            d.acceptNewKeys = false;
            Switcher.Result r = Switcher.run(script, "check", d.port(), auth, 2000);
            check(!r.ok, "key refused: " + r.text);
        }
        // nobody listens
        int closed;
        try (java.net.ServerSocket s = new java.net.ServerSocket(0)) { closed = s.getLocalPort(); }
        Switcher.Result r = Switcher.run(script, "check", closed, auth, 1000);
        check(!r.ok && r.text.contains("does not listen"), "no adbd: " + r.text);
        System.out.println("client: " + checks + " checks, " + fails + " failures");
        System.exit(fails == 0 ? 0 : 1);
    }
}
