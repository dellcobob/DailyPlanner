package com.morningmissions.tracker;

import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * The reminders the planner asked for, kept as plain data so this class has no Android
 * dependencies and can be unit tested. Times are local wall-clock times ("2026-11-22T06:15"),
 * turned into instants only when an alarm is set, so a time zone change keeps them right.
 */
final class ReminderList {
    static final int MAX_ITEMS = 500;
    static final int MAX_JSON = 400_000;
    static final Set<String> CHANNELS = Collections.unmodifiableSet(
            new HashSet<>(Arrays.asList("task", "summary", "finish", "missed", "goal", "test")));

    static final class Item {
        final String id, channel, title, body;
        final LocalDateTime at;
        final boolean hideOnLockScreen;

        Item(String id, String channel, String title, String body, LocalDateTime at, boolean hideOnLockScreen) {
            this.id = id;
            this.channel = channel;
            this.title = title;
            this.body = body;
            this.at = at;
            this.hideOnLockScreen = hideOnLockScreen;
        }

        long epochMillis(ZoneId zone) {
            return at.atZone(zone).toInstant().toEpochMilli();
        }

        JSONObject toJson() throws JSONException {
            JSONObject o = new JSONObject();
            o.put("id", id);
            o.put("ch", channel);
            o.put("title", title);
            o.put("body", body);
            o.put("at", at.toString());
            o.put("priv", hideOnLockScreen ? 1 : 0);
            return o;
        }
    }

    private ReminderList() {}

    /** Reads a JSON array from the planner. Anything malformed is skipped, never trusted. */
    static List<Item> parse(String json) {
        List<Item> out = new ArrayList<>();
        if (json == null || json.length() > MAX_JSON) return out;
        JSONArray a;
        try {
            a = new JSONArray(json);
        } catch (JSONException e) {
            return out;
        }
        for (int i = 0; i < a.length() && out.size() < MAX_ITEMS; i++) {
            Item it = parseItem(a.optJSONObject(i), null);
            if (it != null) out.add(it);
        }
        out.sort((x, y) -> x.at.compareTo(y.at));
        return out;
    }

    /** One item; when {@code fallbackAt} is given, a missing or bad time uses it instead. */
    static Item parseItem(JSONObject o, LocalDateTime fallbackAt) {
        if (o == null) return null;
        String id = clip(o.optString("id", ""), 120);
        String ch = o.optString("ch", "task");
        String title = clip(o.optString("title", ""), 100);
        String body = clip(o.optString("body", ""), 200);
        if (id.isEmpty() || title.isEmpty() || !CHANNELS.contains(ch)) return null;
        LocalDateTime at = fallbackAt;
        String when = o.optString("at", "");
        if (!when.isEmpty()) {
            try {
                at = LocalDateTime.parse(when);
            } catch (RuntimeException e) {
                if (fallbackAt == null) return null;
            }
        }
        if (at == null) return null;
        return new Item(id, ch, title, body, at, o.optInt("priv", 0) == 1);
    }

    static String toJson(List<Item> items) {
        JSONArray a = new JSONArray();
        for (Item it : items) {
            try {
                a.put(it.toJson());
            } catch (JSONException ignored) {
                // skip
            }
        }
        return a.toString();
    }

    /** Items whose time has come, allowing a grace period for ones missed while the phone was off. */
    static List<Item> due(List<Item> items, ZoneId zone, long now, long graceMillis) {
        List<Item> out = new ArrayList<>();
        for (Item it : items) {
            long t = it.epochMillis(zone);
            if (t <= now + 30_000 && t >= now - graceMillis) out.add(it);
        }
        return out;
    }

    /** Items still in the future, in time order. */
    static List<Item> upcoming(List<Item> items, ZoneId zone, long now) {
        List<Item> out = new ArrayList<>();
        for (Item it : items) {
            if (it.epochMillis(zone) > now + 30_000) out.add(it);
        }
        return out;
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
