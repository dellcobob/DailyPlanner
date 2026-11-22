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
}
