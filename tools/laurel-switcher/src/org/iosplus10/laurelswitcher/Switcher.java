package org.iosplus10.laurelswitcher;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

/**
 * One step of the app: adbd as root only as long as needed, then to-ios.sh through "shell:". Result = the script's last LAUREL SWITCH line. No marker line = not done, also when adbd
 * drops the connection after a line "ok": the reboot does that. adbd stays root until the next reboot once it is root, so what this class made root it also makes shell again.
 */
public final class Switcher {
    public static final String HOST = "127.0.0.1";
    static final String MARK = "LAUREL SWITCH: ";

    public static final class Result {
        public final boolean ok;
        public final String text;
        Result(boolean ok, String text) { this.ok = ok; this.text = text; }
    }

    private static String shell(String script, String command, int port, AdbClient.Auth auth) throws Exception {
        String b64 = Base64.getEncoder().encodeToString(script.getBytes(StandardCharsets.UTF_8));
        try (AdbClient c = AdbClient.connect(HOST, port, auth)) {
            return c.run("shell:echo " + b64 + " | base64 -d | sh -s -- " + command + " 2>&1");
        }
    }

    private static Result parse(String out) {
        String last = null;
        for (String l : out.split("\n")) {
            if (l.startsWith(MARK)) last = l.substring(MARK.length()).trim();
        }
        if (last == null) return new Result(false, "no result from the phone: " + out.trim());
        return new Result(last.startsWith("ok"), last);
    }

    private static String whoami(int port, AdbClient.Auth auth) throws Exception {
        try (AdbClient c = AdbClient.connect(HOST, port, auth)) {
            return c.run("shell:id -u").trim();
        }
    }

    /** Returns null when adbd is root now; else the reason. */
    private static String becomeRoot(int port, AdbClient.Auth auth, int waitMs) throws Exception {
        String r;
        try (AdbClient c = AdbClient.connect(HOST, port, auth)) {
            r = c.run("root:").trim();
        }
        if (r.isEmpty() || r.toLowerCase().contains("disabled") || r.contains("cannot run as root")) {
            return "adbd gives no root: " + (r.isEmpty() ? "no answer" : r) + ". Developer options -> Rooted debugging";
        }
        return waitFor("0", port, auth, waitMs) ? null : "adbd did not come back as root";
    }

    private static boolean waitFor(String uid, int port, AdbClient.Auth auth, int waitMs) throws Exception {
        long end = System.currentTimeMillis() + waitMs;
        while (true) {
            Thread.sleep(300);
            try {
                if (uid.equals(whoami(port, auth))) return true;
            } catch (java.io.IOException e) {
                // adbd is restarting
            }
            if (System.currentTimeMillis() > end) return false;
        }
    }

    /** adbd back to shell: "unroot:" restarts it. A failure is reported in the result text, it does not change the outcome of the step. */
    private static String restoreShell(int port, AdbClient.Auth auth, int waitMs) {
        try {
            try (AdbClient c = AdbClient.connect(HOST, port, auth)) {
                c.run("unroot:");
            }
            return waitFor("2000", port, auth, waitMs) ? "" : " (adbd is still root until the next reboot)";
        } catch (Exception e) {
            return " (adbd is still root until the next reboot)";
        }
    }

    /** "check" or "switch". The app never tries a second way: adbd off, port off, key refused or root off all end here with the reason. */
    public static Result run(String script, String command, int port, AdbClient.Auth auth, int rootWaitMs) {
        boolean elevated = false;
        try {
            if (!"0".equals(whoami(port, auth))) {
                String why = becomeRoot(port, auth, rootWaitMs);
                if (why != null) return new Result(false, why);
                elevated = true;
            }
            Result r = parse(shell(script, command, port, auth));
            boolean rebooting = r.ok && "switch".equals(command);
            if (elevated && !rebooting) {
                return new Result(r.ok, r.text + restoreShell(port, auth, rootWaitMs));
            }
            return r;
        } catch (java.net.ConnectException e) {
            return new Result(false, "adbd does not listen on port " + port + ": run scripts/laurel/switcher-setup.sh once from the computer");
        } catch (Exception e) {
            String t = e.toString();
            if (elevated) t += restoreShell(port, auth, rootWaitMs);
            return new Result(false, t);
        }
    }

    /**
     * At boot: adbd listens on all interfaces (persist.adb.tcp.port). Move it to loopback, as shell. Already on loopback: nothing, no root. The result text is the one log line.
     * Retries while adbd is not up yet.
     */
    public static Result lockPort(String script, int port, AdbClient.Auth auth, int waitMs) {
        long end = System.currentTimeMillis() + waitMs;
        while (true) {
            try {
                Result p = parse(shell(script, "port", port, auth));
                if (p.text.endsWith("loopback")) return new Result(true, "on: adbd on 127.0.0.1:" + port + " only");
                if (!"0".equals(whoami(port, auth))) {
                    String why = becomeRoot(port, auth, waitMs);
                    if (why != null) return new Result(false, "off: " + why + "; adbd stays on all interfaces");
                }
                shell(script, "lock", port, auth);       // adbd restarts, as shell, on loopback
                if (!waitFor("2000", port, auth, waitMs)) return new Result(false, "off: adbd did not come back as shell");
                p = parse(shell(script, "port", port, auth));
                return p.text.endsWith("loopback")
                        ? new Result(true, "on: adbd on 127.0.0.1:" + port + " only")
                        : new Result(false, "off: adbd listens on: " + p.text);
            } catch (java.net.ConnectException e) {
                if (System.currentTimeMillis() > end) return new Result(false, "off: adbd does not listen on port " + port);
                try { Thread.sleep(1000); } catch (InterruptedException i) { return new Result(false, "off: stopped"); }
            } catch (Exception e) {
                return new Result(false, "off: " + e + "; adbd stays on all interfaces");
            }
        }
    }
}
