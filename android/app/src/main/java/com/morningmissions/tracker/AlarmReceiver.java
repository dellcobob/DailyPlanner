package com.morningmissions.tracker;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** The scheduled alarm: show what is due and set the next one. */
public class AlarmReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !"com.morningmissions.tracker.REMIND".equals(intent.getAction())) return;
        Reminders.arm(context);
    }
}
