import java.nio.file.*;
import java.security.*;
import java.security.interfaces.RSAPublicKey;
import java.util.*;
import org.iosplus10.laurelswitcher.*;

/** usage: TestSwitcher SCRIPT FAKEBIN BLOCKDIR LOGFILE: the real client against FakeAdbd, the real script on a fake phone. */
public class TestSwitcher {
    static int fails = 0, checks = 0;
    static void check(boolean c, String what) { checks++; if (!c) { fails++; System.out.println("FAIL " + what); } }

    public static void main(String[] a) throws Exception {
        String script = new String(Files.readAllBytes(Paths.get(a[0])));
        Map<String, String> env = new HashMap<>();
        env.put("PATH", a[1] + ":" + System.getenv("PATH"));
        env.put("LS_BLOCK", a[2]);
        env.put("FAKE_LOG", a[3]);
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

        // first use: key unknown -> token, signature refused, key offered, accepted; adbd as shell -> root: -> restart -> check passes
        try (FakeAdbd d = new FakeAdbd(env)) {
            Switcher.Result r = Switcher.run(script, "check", d.port(), auth, 5000);
            check(r.ok && r.text.contains("ready"), "first check: " + r.text);
            check(d.keysOffered == 1, "key offered once, got " + d.keysOffered);
            check(d.root, "root service used");
            check(d.connections >= 3, "reconnected after the restart: " + d.connections);
            // second run: known key, no new offer, already root: no root: service again
            d.services.clear();
            r = Switcher.run(script, "check", d.port(), auth, 5000);
            check(r.ok, "second check: " + r.text);
            check(d.keysOffered == 1, "known key offered again");
            check(!d.services.contains("root:"), "root: asked again while already root");
            check(d.errors.isEmpty(), "protocol errors: " + d.errors);
            Files.write(Paths.get(a[3]), new byte[0]);
            r = Switcher.run(script, "switch", d.port(), auth, 5000);
            check(r.ok && r.text.contains("slot b active"), "switch: " + r.text);
            String log = new String(Files.readAllBytes(Paths.get(a[3])));
            check(log.contains("set-active-boot-slot 1"), "switch called the HAL: " + log);
            check(log.contains("svc power reboot"), "switch rebooted: " + log);
            check(d.errors.isEmpty(), "protocol errors: " + d.errors);
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
