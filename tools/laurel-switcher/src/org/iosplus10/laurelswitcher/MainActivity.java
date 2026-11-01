package org.iosplus10.laurelswitcher;

import android.app.Activity;
import android.app.AlertDialog;
import android.os.Bundle;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * The launcher entry: any app can start it, so it does nothing by itself: each step needs a tap by the owner, on a screen no other app covers (filterTouchesWhenObscured), and "Restart" asks
 * again. A step asks adbd for root; adbd goes back to shell after it. The tile starts GoActivity, which no other app can start.
 */
public class MainActivity extends Activity {
    /** true: switch at once. */
    boolean goAtStart() { return false; }

    private TextView status;
    private Button check;
    private Button go;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setPadding(48, 96, 48, 48);
        status = new TextView(this);
        status.setTextSize(18);
        status.setText("Tap Check. Check and Restart use root through adbd for a moment.");
        check = new Button(this);
        check.setText("Check");
        check.setFilterTouchesWhenObscured(true);
        check.setOnClickListener(v -> start("check"));
        go = new Button(this);
        go.setText("Restart into iOS");
        go.setFilterTouchesWhenObscured(true);
        go.setOnClickListener(v -> new AlertDialog.Builder(this)
                .setMessage("Android restarts into iOS.")
                .setPositiveButton("Restart", (d, w) -> start("switch"))
                .setNegativeButton("Cancel", null)
                .show());
        l.addView(status);
        l.addView(check);
        l.addView(go);
        setContentView(l);
        if (goAtStart()) start("switch");
    }

    private void start(String command) {
        check.setEnabled(false);
        go.setEnabled(false);
        status.setText("switch".equals(command) ? "Switching to iOS..." : "Checking...");
        new Thread(() -> {
            Switcher.Result r;
            try {
                r = Switcher.run(Assets.text(this, "to-ios.sh"), command, Assets.port(this), new KeyStoreAuth(), 15000);
            } catch (Exception e) {
                r = new Switcher.Result(false, e.toString());
            }
            final Switcher.Result fr = r;
            runOnUiThread(() -> {
                status.setText(fr.text);
                check.setEnabled(true);
                go.setEnabled(true);
            });
        }).start();
    }
}
