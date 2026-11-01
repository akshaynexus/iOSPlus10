package org.iosplus10.laurelswitcher;

import android.app.PendingIntent;
import android.content.Intent;
import android.service.quicksettings.TileService;

/** Quick Settings tile "Boot iOS". The work runs in the activity: the system may stop a tile service when the shade closes, and a refusal must be readable. */
public final class BootIosTile extends TileService {
    @Override public void onClick() {
        unlockAndRun(() -> {
            Intent i = new Intent(this, GoActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        });
    }
}
