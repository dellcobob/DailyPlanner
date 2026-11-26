package com.morningmissions.tracker;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.view.View;
import android.widget.RemoteViews;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.ZoneId;

/**
 * Today's tasks on the home screen. The planner sends a small snapshot every time it saves (today
 * and the next two days), so the widget keeps working after midnight even if the app stays closed.
 * Tapping it opens the app.
 */
public class WidgetProvider extends AppWidgetProvider {
    static final String REFRESH = "com.morningmissions.tracker.WIDGET_REFRESH";
    private static final int ACCENT = 0xFFFFAC32, INK = 0xFFFFFFFF, DIM = 0xFF7F8EA3;

    @Override
    public void onUpdate(Context c, AppWidgetManager m, int[] ids) {
        for (int id : ids) render(c, m, id);
        scheduleMidnight(c);
    }

    @Override
    public void onAppWidgetOptionsChanged(Context c, AppWidgetManager m, int id, Bundle options) {
        render(c, m, id);
    }

    @Override
    public void onReceive(Context c, Intent i) {
        super.onReceive(c, i);
        if (i != null && REFRESH.equals(i.getAction())) refresh(c);
    }

    @Override
    public void onDisabled(Context c) {
        AlarmManager am = c.getSystemService(AlarmManager.class);
        if (am != null) am.cancel(refreshIntent(c));
    }

    static void save(Context c, String json) {
        if (json == null || json.length() > WidgetData.MAX_JSON) return;
        Prefs.widget(c).edit().putString("data", json).apply();
        refresh(c);
    }

    static void refresh(Context c) {
        AppWidgetManager m = AppWidgetManager.getInstance(c);
        if (m == null) return;
        int[] ids = m.getAppWidgetIds(new ComponentName(c, WidgetProvider.class));
        if (ids == null || ids.length == 0) return;
        for (int id : ids) render(c, m, id);
        scheduleMidnight(c);
    }

    private static void render(Context c, AppWidgetManager m, int id) {
        Bundle o = m.getAppWidgetOptions(id);
        int h = o == null ? 0 : o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0);
        int rows = h <= 0 ? 4 : Math.max(1, Math.min(8, (h - 64) / 28));
        LocalTime now = LocalTime.now();
        WidgetData.Screen s = WidgetData.build(Prefs.widget(c).getString("data", null), LocalDate.now(),
                now.getHour() * 60 + now.getMinute(), rows);

        RemoteViews v = new RemoteViews(c.getPackageName(), R.layout.widget);
        v.setTextViewText(R.id.w_title, s.title);
        v.setTextViewText(R.id.w_progress, s.progress);
        v.setViewVisibility(R.id.w_bar, s.total > 0 ? View.VISIBLE : View.GONE);
        v.setProgressBar(R.id.w_bar, Math.max(1, s.total), s.done, false);
        v.removeAllViews(R.id.w_rows);
        for (WidgetData.Row r : s.rows) {
            RemoteViews row = new RemoteViews(c.getPackageName(), R.layout.widget_row);
            row.setTextViewText(R.id.r_mark, r.done ? "✓" : r.now ? "▶" : "○");
            row.setTextColor(R.id.r_mark, r.done || r.now ? ACCENT : DIM);
            row.setTextViewText(R.id.r_time, r.time);
            row.setTextViewText(R.id.r_title, r.title);
            row.setTextColor(R.id.r_title, r.done ? DIM : r.now ? ACCENT : INK);
            v.addView(R.id.w_rows, row);
        }
        v.setTextViewText(R.id.w_msg, s.message);
        v.setViewVisibility(R.id.w_msg, s.message.isEmpty() ? View.GONE : View.VISIBLE);
        Intent open = new Intent(c, MainActivity.class)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        v.setOnClickPendingIntent(R.id.w_root, PendingIntent.getActivity(c, 3, open,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        m.updateAppWidget(id, v);
    }

    /** Redraws just after midnight so the widget moves on to the new day. Inexact, and never wakes the phone. */
    private static void scheduleMidnight(Context c) {
        AlarmManager am = c.getSystemService(AlarmManager.class);
        if (am == null) return;
        ZoneId z = ZoneId.systemDefault();
        long when = LocalDate.now(z).plusDays(1).atStartOfDay(z).plusMinutes(1).toInstant().toEpochMilli();
        am.set(AlarmManager.RTC, when, refreshIntent(c));
    }

    private static PendingIntent refreshIntent(Context c) {
        Intent i = new Intent(c, WidgetProvider.class).setAction(REFRESH);
        return PendingIntent.getBroadcast(c, 2, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }
}
