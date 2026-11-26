package com.morningmissions.tracker;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * What the home-screen widget shows, worked out from the snapshot the planner sends. No Android
 * dependencies, so it can be unit tested. Anything malformed in the snapshot is skipped, never trusted.
 */
final class WidgetData {
    static final int MAX_JSON = 200_000;
    static final int MAX_ITEMS = 60;

    static final class Row {
        final String time, title;
        final boolean done, now;

        Row(String time, String title, boolean done, boolean now) {
            this.time = time;
            this.title = title;
            this.done = done;
            this.now = now;
        }
    }

    static final class Screen {
        final String title, progress, message;
        final int done, total;
        final List<Row> rows;

        Screen(String title, String progress, String message, int done, int total, List<Row> rows) {
            this.title = title;
            this.progress = progress;
            this.message = message;
            this.done = done;
            this.total = total;
            this.rows = Collections.unmodifiableList(rows);
        }
    }

    private static final class Task {
        final String time, title;
        final int s, e;
        final boolean done;

        Task(String time, String title, int s, int e, boolean done) {
            this.time = time;
            this.title = title;
            this.s = s;
            this.e = e;
            this.done = done;
        }
    }

    private WidgetData() {}

    /**
     * The screen for {@code today} at {@code nowMin} minutes after midnight, with at most {@code maxRows}
     * tasks: starting at the one happening now or next, filling in earlier ones near the end of the day.
     */
    static Screen build(String json, LocalDate today, int nowMin, int maxRows) {
        maxRows = Math.max(1, maxRows);
        JSONObject root = null;
        if (json != null && json.length() <= MAX_JSON) {
            try {
                root = new JSONObject(json);
            } catch (JSONException e) {
                root = null;
            }
        }
        JSONArray days = root == null ? null : root.optJSONArray("days");
        JSONObject day = null;
        for (int i = 0; days != null && i < days.length(); i++) {
            JSONObject d = days.optJSONObject(i);
            if (d != null && today.toString().equals(d.optString("d"))) {
                day = d;
                break;
            }
        }
        List<Row> none = new ArrayList<>();
        if (day == null) return new Screen("Daily Missions", "", "Open Daily Missions to see today's tasks.", 0, 0, none);
        String title = clip(day.optString("title", ""), 40);
        if (title.isEmpty()) title = "Today";
        int total = clamp(day.optInt("total", 0), 0, 10_000);
        int done = clamp(day.optInt("done", 0), 0, total);
        String progress = total == 0 ? "" : done == total ? "All " + total + " done" : done + " of " + total + " done";
        if (total == 0) return new Screen(title, progress, "Nothing scheduled today. Enjoy the rest day.", 0, 0, none);
        if (!root.optBoolean("names", true)) {
            return new Screen(title, progress, "Task names are hidden. Show them in Tools > Home-screen widget.", done, total, none);
        }
        List<Task> tasks = new ArrayList<>();
        JSONArray items = day.optJSONArray("items");
        for (int i = 0; items != null && i < items.length() && tasks.size() < MAX_ITEMS; i++) {
            JSONObject o = items.optJSONObject(i);
            if (o == null) continue;
            String t = clip(o.optString("t", ""), 60);
            int s = o.optInt("s", -1), e = o.optInt("e", -1);
            if (t.isEmpty() || s < 0 || s > 1439 || e < 0 || e > 1439) continue;
            tasks.add(new Task(clip(o.optString("tm", ""), 12), t, s, e, o.optInt("c", 0) == 1));
        }
        if (tasks.isEmpty()) return new Screen(title, progress, "Open Daily Missions to see today's tasks.", done, total, none);

        int start = -1;
        for (int i = 0; i < tasks.size() && start < 0; i++) {
            Task k = tasks.get(i);
            if (!k.done && endsAfter(k.s, k.e, nowMin)) start = i;
        }
        for (int i = 0; i < tasks.size() && start < 0; i++) {
            if (!tasks.get(i).done) start = i;
        }
        if (start < 0) start = 0;
        int from = Math.max(0, Math.min(start, tasks.size() - maxRows));
        int to = Math.min(tasks.size(), from + maxRows);
        List<Row> rows = new ArrayList<>();
        for (int i = from; i < to; i++) {
            Task k = tasks.get(i);
            rows.add(new Row(k.time, k.title, k.done, !k.done && isNow(k.s, k.e, nowMin)));
        }
        int hidden = tasks.size() - rows.size();
        String message = hidden > 0 ? hidden + " more in the app" : "";
        return new Screen(title, progress, message, done, total, rows);
    }

    /** A task whose end is before its start runs overnight, ending the next day. */
    static boolean isNow(int s, int e, int now) {
        return e > s ? now >= s && now < e : now >= s;
    }

    static boolean endsAfter(int s, int e, int now) {
        return e <= s || e > now;
    }

    private static int clamp(int v, int lo, int hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    private static String clip(String s, int max) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length() && b.length() < max; i++) {
            char c = s.charAt(i);
            if (c >= 0x20 && c != 0x7f) b.append(c);
        }
        return b.toString().trim();
    }
}
