package com.morningmissions.tracker;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.List;
import org.json.JSONObject;
import org.junit.Test;

public class ReminderListTest {
    private static final ZoneId ZONE = ZoneId.of("America/New_York");

    private static long at(String local) {
        return LocalDateTime.parse(local).atZone(ZONE).toInstant().toEpochMilli();
    }

    @Test
    public void parsesSortsAndKeepsPrivacyFlag() {
        List<ReminderList.Item> l = ReminderList.parse("["
                + "{\"id\":\"b\",\"ch\":\"task\",\"title\":\"Yoga\",\"body\":\"6:15\",\"at\":\"2026-11-23T06:15\",\"priv\":1},"
                + "{\"id\":\"a\",\"ch\":\"summary\",\"title\":\"Today\",\"body\":\"13\",\"at\":\"2026-11-23T05:45\"}]");
        assertEquals(2, l.size());
        assertEquals("a", l.get(0).id);
        assertFalse(l.get(0).hideOnLockScreen);
        assertTrue(l.get(1).hideOnLockScreen);
    }

    @Test
    public void rejectsBadInput() {
        assertTrue(ReminderList.parse("not json").isEmpty());
        assertTrue(ReminderList.parse(null).isEmpty());
        List<ReminderList.Item> l = ReminderList.parse("["
                + "{\"id\":\"x\",\"ch\":\"spam\",\"title\":\"T\",\"at\":\"2026-11-23T06:00\"},"
                + "{\"id\":\"\",\"ch\":\"task\",\"title\":\"T\",\"at\":\"2026-11-23T06:00\"},"
                + "{\"id\":\"y\",\"ch\":\"task\",\"title\":\"\",\"at\":\"2026-11-23T06:00\"},"
                + "{\"id\":\"z\",\"ch\":\"task\",\"title\":\"T\",\"at\":\"tomorrow\"},"
                + "42]");
        assertTrue(l.isEmpty());
    }

    @Test
    public void stripsControlCharactersAndClipsLength() {
        StringBuilder longTitle = new StringBuilder();
        for (int i = 0; i < 300; i++) longTitle.append('A');
        List<ReminderList.Item> l = ReminderList.parse("[{\"id\":\"a\",\"ch\":\"task\",\"title\":\"" + longTitle
                + "\",\"body\":\"line\\u0007two\",\"at\":\"2026-11-23T06:00\"}]");
        assertEquals(100, l.get(0).title.length());
        assertEquals("linetwo", l.get(0).body);
    }

    @Test
    public void capsTheNumberOfItems() {
        StringBuilder b = new StringBuilder("[");
        for (int i = 0; i < 700; i++) {
            if (i > 0) b.append(',');
            b.append("{\"id\":\"r").append(i).append("\",\"ch\":\"task\",\"title\":\"T\",\"at\":\"2026-11-23T06:00\"}");
        }
        assertEquals(ReminderList.MAX_ITEMS, ReminderList.parse(b.append(']').toString()).size());
    }

    @Test
    public void splitsDueAndUpcoming() {
        List<ReminderList.Item> l = ReminderList.parse("["
                + "{\"id\":\"old\",\"ch\":\"task\",\"title\":\"T\",\"at\":\"2026-11-23T04:00\"},"
                + "{\"id\":\"late\",\"ch\":\"task\",\"title\":\"T\",\"at\":\"2026-11-23T05:50\"},"
                + "{\"id\":\"now\",\"ch\":\"task\",\"title\":\"T\",\"at\":\"2026-11-23T06:00\"},"
                + "{\"id\":\"next\",\"ch\":\"task\",\"title\":\"T\",\"at\":\"2026-11-23T06:15\"}]");
        long now = at("2026-11-23T06:00");
        List<ReminderList.Item> due = ReminderList.due(l, ZONE, now, 30 * 60_000L);
        assertEquals(2, due.size());
        assertEquals("late", due.get(0).id);
        assertEquals("now", due.get(1).id);
        List<ReminderList.Item> up = ReminderList.upcoming(l, ZONE, now);
        assertEquals(1, up.size());
        assertEquals("next", up.get(0).id);
    }

    @Test
    public void roundTripsThroughJson() {
        List<ReminderList.Item> l = ReminderList.parse("[{\"id\":\"a\",\"ch\":\"finish\",\"title\":\"Finish your day\",\"body\":\"Tap\",\"at\":\"2026-11-23T21:00\",\"priv\":1}]");
        List<ReminderList.Item> back = ReminderList.parse(ReminderList.toJson(l));
        assertEquals(1, back.size());
        assertEquals("finish", back.get(0).channel);
        assertEquals(LocalDateTime.parse("2026-11-23T21:00"), back.get(0).at);
        assertTrue(back.get(0).hideOnLockScreen);
    }

    @Test
    public void testNotificationUsesNowWhenNoTimeIsGiven() throws Exception {
        LocalDateTime now = LocalDateTime.parse("2026-11-23T08:00");
        ReminderList.Item it = ReminderList.parseItem(new JSONObject("{\"id\":\"t\",\"ch\":\"test\",\"title\":\"Daily Missions\",\"body\":\"Working\"}"), now);
        assertNotNull(it);
        assertEquals(now, it.at);
        assertNull(ReminderList.parseItem(new JSONObject("{\"id\":\"t\",\"ch\":\"test\",\"title\":\"x\"}"), null));
    }

    @Test
    public void handlesDaylightSavingGap() {
        // 2:30 AM does not exist on March 8, 2026 in New York; it must still map to a real instant.
        List<ReminderList.Item> l = ReminderList.parse("[{\"id\":\"a\",\"ch\":\"task\",\"title\":\"T\",\"at\":\"2026-03-08T02:30\"}]");
        long t = l.get(0).epochMillis(ZONE);
        assertTrue(t > at("2026-03-08T01:59") && t <= at("2026-03-08T03:31"));
    }
}
