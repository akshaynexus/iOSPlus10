package org.iosplus10.laurelswitcher;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

/**
 * One step of the app: adbd as root, then to-ios.sh through "shell:". Result = the script's last LAUREL SWITCH line. No marker line = not done, also when adbd
 * drops the connection after a line "ok": the reboot does that.
 */
public final class Switcher {
    public static final String HOST = "127.0.0.1";
    public static final int PORT = 5555;
    static final String MARK = "LAUREL SWITCH: ";

    public static final class Result {
        public final boolean ok;
        public final String text;
        Result(boolean ok, String text) { this.ok = ok; this.text = text; }
    }

    /** The app never tries a second way: adbd off, port off, key refused or root off all end here with the reason. */
    public static Result run(String script, String command, int port, AdbClient.Auth auth, int rootWaitMs) {
        try {
            String whoami;
            try (AdbClient c = AdbClient.connect(HOST, port, auth)) {
                whoami = c.run("shell:id -u").trim();
            }
            if (!"0".equals(whoami)) {
                String r;
                try (AdbClient c = AdbClient.connect(HOST, port, auth)) {
                    r = c.run("root:").trim();
                }
                if (r.isEmpty() || r.toLowerCase().contains("disabled") || r.contains("cannot run as root")) {
                    return new Result(false, "adbd gives no root: " + (r.isEmpty() ? "no answer" : r) + ". Developer options -> Rooted debugging");
                }
                long end = System.currentTimeMillis() + rootWaitMs;
                while (true) {
                    Thread.sleep(300);
                    try (AdbClient c = AdbClient.connect(HOST, port, auth)) {
                        whoami = c.run("shell:id -u").trim();
                        if ("0".equals(whoami)) break;
                    } catch (java.io.IOException e) {
                        // adbd is restarting
                    }
                    if (System.currentTimeMillis() > end) return new Result(false, "adbd did not come back as root");
                }
            }
            String b64 = Base64.getEncoder().encodeToString(script.getBytes(StandardCharsets.UTF_8));
            String out;
            try (AdbClient c = AdbClient.connect(HOST, port, auth)) {
                out = c.run("shell:echo " + b64 + " | base64 -d | sh -s -- " + command + " 2>&1");
            }
            String last = null;
            for (String l : out.split("\n")) {
                if (l.startsWith(MARK)) last = l.substring(MARK.length()).trim();
            }
            if (last == null) return new Result(false, "no result from the phone: " + out.trim());
            return new Result(last.startsWith("ok"), last);
        } catch (java.net.ConnectException e) {
            return new Result(false, "adbd does not listen on port " + port + ": run scripts/laurel/switcher-setup.sh once from the computer");
        } catch (Exception e) {
            return new Result(false, e.toString());
        }
    }
}
