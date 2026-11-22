package com.morningmissions.tracker;

import android.Manifest;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.print.PrintAttributes;
import android.print.PrintManager;
import android.provider.Settings;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.Toast;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Daily Missions: a WebView that shows the planner page bundled in the app and nothing else.
 * The app has no internet permission, every request other than the page itself is refused,
 * and navigation away from the page is blocked.
 */
public class MainActivity extends Activity {
    private static final String HOST = "appassets.androidplatform.net";
    private static final String PAGE = "https://" + HOST + "/index.html";
    private static final int REQ_SAVE = 100, REQ_PICK = 101, REQ_READ = 102, REQ_NOTIFY = 103;
    private static final int MAX_TEXT = 6_000_000;
    private static final int MAX_READ = 9_000_000;
    private static final int NAVY = Color.rgb(0x18, 0x23, 0x31);

    private WebView web;
    private WebView printView;
    private ValueCallback<Uri[]> pickCallback;
    private String pendingSave;
    private String opened;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        Window w = getWindow();
        if (Prefs.app(this).getBoolean("secure", false)) w.addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        w.setStatusBarColor(NAVY);
        w.setNavigationBarColor(NAVY);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(NAVY);
        web = new WebView(this);
        web.setBackgroundColor(NAVY);
        root.addView(web, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                Insets i = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime() | WindowInsets.Type.displayCutout());
                v.setPadding(i.left, i.top, i.right, i.bottom);
                return WindowInsets.CONSUMED;
            }
            v.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                    insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets.consumeSystemWindowInsets();
        });
        setContentView(root);
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController c = w.getInsetsController();
            if (c != null) {
                c.setSystemBarsAppearance(0, WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                        | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS);
            }
        }

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setSupportMultipleWindows(false);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setGeolocationEnabled(false);
        s.setSaveFormData(false);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest req) {
                return serve(req.getUrl());
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                return true; // never leave the planner page
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (pickCallback != null) pickCallback.onReceiveValue(null);
                pickCallback = callback;
                try {
                    startActivityForResult(openDocument(), REQ_PICK);
                } catch (ActivityNotFoundException e) {
                    pickCallback.onReceiveValue(null);
                    pickCallback = null;
                    toast("No file picker is available.");
                }
                return true;
            }
        });
        web.addJavascriptInterface(new FileBridge(), "NativeFiles");
        web.addJavascriptInterface(new NotifyBridge(), "NativeNotify");
        web.addJavascriptInterface(new AppBridge(), "NativeApp");
        web.loadUrl(PAGE);
    }

    private WebResourceResponse serve(Uri u) {
        if (u != null && "https".equals(u.getScheme()) && HOST.equals(u.getHost()) && "/index.html".equals(u.getPath())) {
            try {
                Map<String, String> h = new HashMap<>();
                h.put("Cache-Control", "no-store");
                h.put("X-Content-Type-Options", "nosniff");
                h.put("Referrer-Policy", "no-referrer");
                return new WebResourceResponse("text/html", "UTF-8", 200, "OK", h, getAssets().open("index.html"));
            } catch (IOException e) {
                return blocked();
            }
        }
        return blocked();
    }

    static WebResourceResponse blocked() {
        return new WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden",
                Collections.emptyMap(), new ByteArrayInputStream(new byte[0]));
    }

    private static Intent openDocument() {
        return new Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*")
                .putExtra(Intent.EXTRA_MIME_TYPES, new String[] {"application/json", "text/plain", "application/octet-stream"});
    }

    private void js(String code) {
        runOnUiThread(() -> {
            if (web != null) web.evaluateJavascript(code, null);
        });
    }

    private void toast(String msg) {
        runOnUiThread(() -> Toast.makeText(this, msg, Toast.LENGTH_LONG).show());
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        Uri uri = (res == RESULT_OK && data != null) ? data.getData() : null;
        if (req == REQ_PICK) {
            if (pickCallback != null) pickCallback.onReceiveValue(uri == null ? null : new Uri[] {uri});
            pickCallback = null;
        } else if (req == REQ_SAVE) {
            boolean ok = false;
            if (uri != null && pendingSave != null) ok = write(uri, pendingSave);
            pendingSave = null;
            js("window.onNativeFileSaved&&window.onNativeFileSaved(" + ok + ")");
        } else if (req == REQ_READ) {
            boolean ok = false;
            if (uri != null) {
                opened = read(uri);
                ok = opened != null;
            }
            js("window.onNativeFileOpened&&window.onNativeFileOpened(" + ok + ")");
        }
    }

    private boolean write(Uri uri, String text) {
        for (String mode : new String[] {"wt", "w"}) {
            try (OutputStream o = getContentResolver().openOutputStream(uri, mode)) {
                if (o == null) return false;
                o.write(text.getBytes(StandardCharsets.UTF_8));
                return true;
            } catch (IOException | IllegalArgumentException | SecurityException e) {
                // try the next mode
            }
        }
        return false;
    }

    private String read(Uri uri) {
        try (InputStream in = getContentResolver().openInputStream(uri)) {
            if (in == null) return null;
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) {
                if (b.size() + n > MAX_READ) return null;
                b.write(buf, 0, n);
            }
            return new String(b.toByteArray(), StandardCharsets.UTF_8);
        } catch (IOException | SecurityException e) {
            return null;
        }
    }

    @Override
    public void onRequestPermissionsResult(int req, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(req, permissions, results);
        if (req == REQ_NOTIFY) {
            Reminders.arm(this);
            js("window.onNativeNotifyPermission&&window.onNativeNotifyPermission()");
        }
    }

    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        web.evaluateJavascript(
                "(function(){var d=document.querySelector('dialog[open]');if(d){d.close();return true;}return false;})()",
                v -> {
                    if (!"true".equals(v)) super.onBackPressed();
                });
    }

    @Override
    protected void onDestroy() {
        if (web != null) {
            web.destroy();
            web = null;
        }
        if (printView != null) {
            printView.destroy();
            printView = null;
        }
        super.onDestroy();
    }

    /** Save and open files through Android's own file picker, and print weekly records. */
    final class FileBridge {
        @JavascriptInterface
        public void saveText(String name, String mime, String content) {
            if (name == null || content == null || content.length() > MAX_TEXT) return;
            String clean = name.replaceAll("[^a-zA-Z0-9_.-]", "_");
            final String file = clean.length() > 100 ? clean.substring(0, 100) : clean;
            final String type = "application/json".equals(mime) ? "application/json" : "text/html";
            runOnUiThread(() -> {
                pendingSave = content;
                Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT)
                        .addCategory(Intent.CATEGORY_OPENABLE)
                        .setType(type)
                        .putExtra(Intent.EXTRA_TITLE, file);
                try {
                    startActivityForResult(i, REQ_SAVE);
                } catch (ActivityNotFoundException e) {
                    pendingSave = null;
                    js("window.onNativeFileSaved&&window.onNativeFileSaved(false)");
                }
            });
        }

        /** Opens a backup with Android's picker and reads it here, then the page collects it. */
        @JavascriptInterface
        public void openText() {
            runOnUiThread(() -> {
                try {
                    startActivityForResult(openDocument(), REQ_READ);
                } catch (ActivityNotFoundException e) {
                    js("window.onNativeFileOpened&&window.onNativeFileOpened(false)");
                }
            });
        }

        @JavascriptInterface
        public String takeOpened() {
            String t = opened;
            opened = null;
            return t;
        }

        @JavascriptInterface
        public void printHtml(String html) {
            if (html == null || html.length() > MAX_TEXT) return;
            runOnUiThread(() -> {
                if (printView != null) printView.destroy();
                WebView pv = new WebView(MainActivity.this);
                WebSettings ps = pv.getSettings();
                ps.setJavaScriptEnabled(false);
                ps.setAllowFileAccess(false);
                ps.setAllowContentAccess(false);
                pv.setWebViewClient(new WebViewClient() {
                    private boolean sent;

                    @Override
                    public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest req) {
                        return blocked();
                    }

                    @Override
                    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                        return true;
                    }

                    @Override
                    public void onPageFinished(WebView view, String url) {
                        if (sent) return;
                        sent = true;
                        PrintManager pm = (PrintManager) getSystemService(Context.PRINT_SERVICE);
                        if (pm == null) {
                            toast("Printing is unavailable. Download the weekly record instead.");
                            return;
                        }
                        pm.print("Daily Missions weekly record",
                                view.createPrintDocumentAdapter("Daily Missions record"),
                                new PrintAttributes.Builder().build());
                    }
                });
                printView = pv;
                pv.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null);
            });
        }
    }

    /** Lets the planner schedule reminders. The page plans them; this side shows them on time. */
    final class NotifyBridge {
        @JavascriptInterface
        public String status() {
            JSONObject o = new JSONObject();
            try {
                String perm;
                boolean granted = Build.VERSION.SDK_INT < 33
                        || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED;
                if (granted) {
                    perm = Notifier.allowed(MainActivity.this) ? "granted" : "denied";
                } else {
                    boolean asked = Prefs.app(MainActivity.this).getBoolean("askedNotify", false);
                    perm = !asked || shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS) ? "ask" : "denied";
                }
                o.put("perm", perm);
                o.put("exact", Reminders.canExact(MainActivity.this));
                o.put("count", Reminders.count(MainActivity.this));
            } catch (JSONException ignored) {
                // return what we have
            }
            return o.toString();
        }

        @JavascriptInterface
        public void requestPermission() {
            runOnUiThread(() -> {
                if (Build.VERSION.SDK_INT >= 33
                        && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    Prefs.app(MainActivity.this).edit().putBoolean("askedNotify", true).apply();
                    requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTIFY);
                } else {
                    js("window.onNativeNotifyPermission&&window.onNativeNotifyPermission()");
                }
            });
        }

        @JavascriptInterface
        public int schedule(String json) {
            return Reminders.replace(MainActivity.this, json);
        }

        @JavascriptInterface
        public void test(String json) {
            Reminders.postNow(MainActivity.this, json);
        }

        @JavascriptInterface
        public void openSettings() {
            runOnUiThread(() -> {
                Intent i = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName());
                try {
                    startActivity(i);
                } catch (ActivityNotFoundException e) {
                    try {
                        startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName())));
                    } catch (ActivityNotFoundException ignored) {
                        toast("Open Settings > Apps > Daily Missions > Notifications.");
                    }
                }
            });
        }
    }

    /** App-level switches the page controls. */
    final class AppBridge {
        /** Hides the planner from screenshots, screen recording, and the recent-apps preview. */
        @JavascriptInterface
        public void setSecure(boolean on) {
            Prefs.app(MainActivity.this).edit().putBoolean("secure", on).apply();
            runOnUiThread(() -> {
                if (on) getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
                else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);
            });
        }
    }
}
