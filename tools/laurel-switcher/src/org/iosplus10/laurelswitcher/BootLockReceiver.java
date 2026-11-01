package org.iosplus10.laurelswitcher;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * At each boot, as early as the system lets an app run: adbd moves from all interfaces to loopback (to-ios.sh lock). Until this runs, adbd listens on all interfaces: docs/laurel_sprout/boot-menu.md section 6.2.
 * One log line: LAUREL PORT: on|off: reason. A failure changes nothing else.
 */
public final class BootLockReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent i) {
        final PendingResult done = goAsync();
        final Context dc = c.createDeviceProtectedStorageContext();
        new Thread(() -> {
            try {
                Switcher.Result r = Switcher.lockPort(Assets.text(dc, "to-ios.sh"), Assets.port(dc), new KeyStoreAuth(), 25000);
                Log.i("LaurelSwitcher", "LAUREL PORT: " + r.text);
            } catch (Exception e) {
                Log.i("LaurelSwitcher", "LAUREL PORT: off: " + e);
            } finally {
                done.finish();
            }
        }).start();
    }
}
