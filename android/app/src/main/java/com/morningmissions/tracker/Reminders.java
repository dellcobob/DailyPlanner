package com.morningmissions.tracker;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.List;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Stores the planned reminders and keeps exactly one alarm set: the next one due.
 * When it fires, the due reminders are shown and the following alarm is set.
 */
final class Reminders {
    private static final String KEY = "list";
    private static final long GRACE = 30 * 60_000L; // show ones missed by up to 30 minutes (phone off)

    private Reminders() {}

    static int replace(Context c, String json) {
        List<ReminderList.Item> items = ReminderList.parse(json);
        List<ReminderList.Item> keep = ReminderList.upcoming(items, ZoneId.systemDefault(), System.currentTimeMillis());
        Prefs.reminders(c).edit().putString(KEY, ReminderList.toJson(keep)).apply();
        arm(c);
        return keep.size();
    }

    static int count(Context c) {
        return ReminderList.parse(Prefs.reminders(c).getString(KEY, "[]")).size();
    }

    /** Shows anything due, drops it, and sets the alarm for the next reminder. */
    static synchronized void arm(Context c) {
        ZoneId zone = ZoneId.systemDefault();
        long now = System.currentTimeMillis();
        List<ReminderList.Item> items = ReminderList.parse(Prefs.reminders(c).getString(KEY, "[]"));
        for (ReminderList.Item it : ReminderList.due(items, zone, now, GRACE)) Notifier.post(c, it);
        List<ReminderList.Item> next = ReminderList.upcoming(items, zone, now);
        Prefs.reminders(c).edit().putString(KEY, ReminderList.toJson(next)).apply();

        AlarmManager am = c.getSystemService(AlarmManager.class);
        if (am == null) return;
        PendingIntent pi = alarmIntent(c);
        if (next.isEmpty()) {
            am.cancel(pi);
            return;
        }
        long when = next.get(0).epochMillis(zone);
        try {
            if (canExact(c)) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, when, pi);
            else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, when, pi);
        } catch (SecurityException e) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, when, pi);
        }
    }

    static boolean canExact(Context c) {
        if (Build.VERSION.SDK_INT < 31) return true;
        AlarmManager am = c.getSystemService(AlarmManager.class);
        return am != null && am.canScheduleExactAlarms();
    }

    static void postNow(Context c, String json) {
        try {
            ReminderList.Item it = ReminderList.parseItem(new JSONObject(json), LocalDateTime.now());
            if (it != null) Notifier.post(c, it);
        } catch (JSONException ignored) {
            // not a reminder
        }
    }

    private static PendingIntent alarmIntent(Context c) {
        Intent i = new Intent(c, AlarmReceiver.class).setAction("com.morningmissions.tracker.REMIND");
        return PendingIntent.getBroadcast(c, 1, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }
}
