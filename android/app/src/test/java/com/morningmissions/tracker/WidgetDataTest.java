package com.morningmissions.tracker;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.time.LocalDate;
import org.junit.Test;

public class WidgetDataTest {
    private static final LocalDate FRI = LocalDate.of(2026, 11, 20);

    private static String task(String t, String tm, int s, int e, int c) {
        return "{\"t\":\"" + t + "\",\"tm\":\"" + tm + "\",\"s\":" + s + ",\"e\":" + e + ",\"c\":" + c + "}";
    }

    private static String day(String d, int done, int total, String items) {
        return "{\"d\":\"" + d + "\",\"title\":\"Friday, Nov 20\",\"done\":" + done + ",\"total\":" + total + ",\"items\":[" + items + "]}";
    }

    private static final String SIX = task("Water", "6:00 AM", 360, 375, 1) + "," + task("Yoga", "6:15 AM", 375, 395, 1) + ","
            + task("Shower", "6:50 AM", 410, 420, 0) + "," + task("Study", "8:20 AM", 500, 560, 0) + ","
            + task("Walk", "9:20 AM", 560, 575, 0) + "," + task("Group", "10:00 AM", 600, 630, 0);

    @Test
    public void startsAtTheTaskHappeningNow() {
        String json = "{\"v\":1,\"names\":true,\"days\":[" + day("2026-11-20", 2, 6, SIX) + "]}";
        WidgetData.Screen s = WidgetData.build(json, FRI, 9 * 60 + 5, 3);
        assertEquals("Friday, Nov 20", s.title);
        assertEquals("2 of 6 done", s.progress);
        assertEquals(3, s.rows.size());
        assertEquals("Study", s.rows.get(0).title);
        assertTrue("Study is happening at 9:05", s.rows.get(0).now);
        assertFalse(s.rows.get(1).now);
        assertEquals("3 more in the app", s.message);
    }

    @Test
    public void nearTheEndOfTheDayItFillsInEarlierTasks() {
        String json = "{\"names\":true,\"days\":[" + day("2026-11-20", 2, 6, SIX) + "]}";
        WidgetData.Screen s = WidgetData.build(json, FRI, 10 * 60 + 5, 4);
        assertEquals(4, s.rows.size());
        assertEquals("open tasks from earlier fill the space", "Shower", s.rows.get(0).title);
        assertEquals("Group", s.rows.get(3).title);
        assertEquals("", s.message.replace("2 more in the app", ""));
        assertTrue(s.rows.get(3).now);
    }

    @Test
    public void missedTasksShowWhenNothingIsLeftLater() {
        String json = "{\"names\":true,\"days\":[" + day("2026-11-20", 2, 6, SIX) + "]}";
        WidgetData.Screen s = WidgetData.build(json, FRI, 23 * 60, 2);
        assertEquals("Shower", s.rows.get(0).title);
        assertFalse(s.rows.get(0).done);
        assertFalse(s.rows.get(0).now);
    }

    @Test
    public void overnightTasksAreNowUntilMidnight() {
        String json = "{\"names\":true,\"days\":[" + day("2026-11-20", 0, 1, task("Night shift", "10:00 PM", 1320, 360, 0)) + "]}";
        assertTrue(WidgetData.build(json, FRI, 23 * 60, 3).rows.get(0).now);
        assertFalse(WidgetData.build(json, FRI, 21 * 60, 3).rows.get(0).now);
        assertTrue(WidgetData.isNow(1320, 360, 1400));
        assertTrue(WidgetData.endsAfter(1320, 360, 1400));
    }

    @Test
    public void picksTodayFromTheDaysSent() {
        String json = "{\"names\":true,\"days\":[" + day("2026-11-19", 1, 1, task("Old", "6:00 AM", 360, 375, 1)) + ","
                + day("2026-11-21", 0, 0, "") + "]}";
        assertEquals("Open Daily Missions to see today's tasks.", WidgetData.build(json, FRI, 600, 3).message);
        WidgetData.Screen sat = WidgetData.build(json, FRI.plusDays(1), 600, 3);
        assertTrue(sat.rows.isEmpty());
        assertTrue(sat.message.startsWith("Nothing scheduled today"));
    }

    @Test
    public void allDoneAndHiddenNames() {
        String done = "{\"names\":true,\"days\":[" + day("2026-11-20", 1, 1, task("Yoga", "6:15 AM", 375, 395, 1)) + "]}";
        WidgetData.Screen s = WidgetData.build(done, FRI, 600, 3);
        assertEquals("All 1 done", s.progress);
        assertTrue(s.rows.get(0).done);
        String hidden = "{\"names\":false,\"days\":[{\"d\":\"2026-11-20\",\"title\":\"Friday, Nov 20\",\"done\":3,\"total\":13,\"items\":[]}]}";
        WidgetData.Screen h = WidgetData.build(hidden, FRI, 600, 3);
        assertEquals("3 of 13 done", h.progress);
        assertTrue(h.rows.isEmpty());
        assertTrue(h.message.startsWith("Task names are hidden"));
    }

    @Test
    public void ignoresBadInput() {
        assertTrue(WidgetData.build(null, FRI, 0, 3).rows.isEmpty());
        assertTrue(WidgetData.build("not json", FRI, 0, 3).rows.isEmpty());
        String bad = "{\"names\":true,\"days\":[" + day("2026-11-20", 99, 2, task("", "x", 1, 2, 0) + "," + task("Late", "x", 5000, 2, 0)
                + "," + task("Ok\\u0007", "6:00 AM", 360, 375, 0)) + "]}";
        WidgetData.Screen s = WidgetData.build(bad, FRI, 0, 5);
        assertEquals("progress is clamped", "All 2 done", s.progress);
        assertEquals(1, s.rows.size());
        assertEquals("control characters are dropped", "Ok", s.rows.get(0).title);
        StringBuilder big = new StringBuilder("{\"days\":[");
        while (big.length() <= WidgetData.MAX_JSON) big.append("x");
        assertTrue(WidgetData.build(big.toString(), FRI, 0, 3).rows.isEmpty());
    }
}
