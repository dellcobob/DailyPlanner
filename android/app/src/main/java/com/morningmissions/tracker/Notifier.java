package com.morningmissions.tracker;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;

/** Shows reminders. One channel per kind, so each can be tuned in Android's own settings too. */
final class Notifier {
    private static final int ACCENT = 0xFFFFAC32;
    private static final String[][] CHANNELS = {
        {"task", "Task reminders", "A reminder when a task is about to start."},
        {"summary", "Morning summary", "Your objectives for the day, before the first one starts."},
        {"finish", "Finish-day reminder", "An evening nudge to finish your day and see your medal."},
        {"missed", "Missed-task nudges", "A nudge when a task ended and is not checked off."},
        {"test", "Test notifications", "Sent when you tap Send a test notification."},
    };

    private Notifier() {}

    static boolean allowed(Context c) {
        if (Build.VERSION.SDK_INT >= 33
                && c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            return false;
        }
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        return nm != null && nm.areNotificationsEnabled();
    }

    static void ensureChannels(Context c) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        if (nm == null) return;
        for (String[] ch : CHANNELS) {
            NotificationChannel n = new NotificationChannel(ch[0], ch[1], NotificationManager.IMPORTANCE_DEFAULT);
            n.setDescription(ch[2]);
            n.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
            nm.createNotificationChannel(n);
        }
    }

    static void post(Context c, ReminderList.Item it) {
        if (!allowed(c)) return;
        ensureChannels(c);
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        Intent open = new Intent(c, MainActivity.class)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent tap = PendingIntent.getActivity(c, 0, open,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder b = new Notification.Builder(c, it.channel)
                .setSmallIcon(R.drawable.ic_notify)
                .setColor(ACCENT)
                .setContentTitle(it.title)
                .setContentText(it.body)
                .setStyle(new Notification.BigTextStyle().bigText(it.body))
                .setCategory(Notification.CATEGORY_REMINDER)
                .setAutoCancel(true)
                .setShowWhen(true)
                .setContentIntent(tap);
        if (it.hideOnLockScreen) {
            // On a locked phone only this generic version shows; the details appear after unlocking.
            b.setVisibility(Notification.VISIBILITY_PRIVATE);
            b.setPublicVersion(new Notification.Builder(c, it.channel)
                    .setSmallIcon(R.drawable.ic_notify)
                    .setColor(ACCENT)
                    .setContentTitle("Daily Missions")
                    .setContentText("You have a reminder.")
                    .build());
        } else {
            b.setVisibility(Notification.VISIBILITY_PUBLIC);
        }
        nm.notify(it.id.hashCode(), b.build());
    }
}
