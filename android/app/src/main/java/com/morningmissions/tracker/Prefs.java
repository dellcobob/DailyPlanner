package com.morningmissions.tracker;

import android.content.Context;
import android.content.SharedPreferences;

/** Small app-private settings that the native side needs before the planner page loads. */
final class Prefs {
    private Prefs() {}

    static SharedPreferences app(Context c) {
        return c.getSharedPreferences("app", Context.MODE_PRIVATE);
    }

    static SharedPreferences reminders(Context c) {
        return c.getSharedPreferences("reminders", Context.MODE_PRIVATE);
    }

    /** The snapshot of today's tasks that the home-screen widget shows. */
    static SharedPreferences widget(Context c) {
        return c.getSharedPreferences("widget", Context.MODE_PRIVATE);
    }
}
