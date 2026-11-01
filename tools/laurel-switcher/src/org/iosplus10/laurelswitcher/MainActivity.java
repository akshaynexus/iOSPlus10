package org.iosplus10.laurelswitcher;

import android.app.Activity;
import android.os.Bundle;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Shows the check result and the reason of a refusal. The launcher entry only checks: other apps can start it. The tile starts GoActivity, which no other app can start. */
public class MainActivity extends Activity {
    /** true: switch at once. */
    boolean goAtStart() { return false; }

    private TextView status;
    private Button button;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setPadding(48, 96, 48, 48);
        status = new TextView(this);
        status.setTextSize(18);
        button = new Button(this);
        button.setText("Restart into iOS");
        button.setOnClickListener(v -> start("switch"));
        l.addView(status);
        l.addView(button);
        setContentView(l);
        start(goAtStart() ? "switch" : "check");
    }

    private void start(String command) {
        button.setEnabled(false);
        status.setText("switch".equals(command) ? "Switching to iOS..." : "Checking...");
        new Thread(() -> {
            Switcher.Result r;
            try {
                r = Switcher.run(asset("to-ios.sh"), command, Switcher.PORT, new KeyStoreAuth(), 15000);
            } catch (Exception e) {
                r = new Switcher.Result(false, e.toString());
            }
            final Switcher.Result fr = r;
            runOnUiThread(() -> {
                status.setText(fr.text);
                button.setEnabled(fr.ok && "check".equals(command));
            });
        }).start();
    }

    private String asset(String name) throws Exception {
        try (InputStream in = getAssets().open(name)) {
            ByteArrayOutputStream o = new ByteArrayOutputStream();
            in.transferTo(o);
            return o.toString(StandardCharsets.UTF_8.name());
        }
    }
}
