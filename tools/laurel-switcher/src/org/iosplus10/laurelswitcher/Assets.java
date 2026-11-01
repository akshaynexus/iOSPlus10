package org.iosplus10.laurelswitcher;

import android.content.Context;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

final class Assets {
    static String text(Context c, String name) throws Exception {
        try (InputStream in = c.getAssets().open(name)) {
            ByteArrayOutputStream o = new ByteArrayOutputStream();
            in.transferTo(o);
            return o.toString(StandardCharsets.UTF_8.name());
        }
    }
    /** The random high port of this build: out/laurel/switcher/port, the same one switcher-setup.sh sets. */
    static int port(Context c) throws Exception { return Integer.parseInt(text(c, "port").trim()); }
    private Assets() {}
}
