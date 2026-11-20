package io.tablecircle.prototype;

import android.content.Context;
import android.content.SharedPreferences;
import java.util.Calendar;
import java.util.Map;

final class QuietHours {
    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences("quiet_hours", Context.MODE_PRIVATE);
    }

    static Map<String, Object> read(Context context) {
        var values = prefs(context);
        var schedule = new java.util.HashMap<String, Object>();
        schedule.put("enabled", values.getBoolean("enabled", false));
        schedule.put("start", values.getInt("start", 1320));
        schedule.put("end", values.getInt("end", 480));
        schedule.put("days", values.getInt("days", 127));
        return schedule;
    }

    static boolean save(Context context, boolean enabled, int start, int end, int days) {
        if (start < 0 || start >= 1440 || end < 0 || end >= 1440
                || days < 0 || days > 127 || (enabled && (start == end || days == 0))) return false;
        return prefs(context).edit().putBoolean("enabled", enabled).putInt("start", start)
            .putInt("end", end).putInt("days", days).commit();
    }

    static boolean active(Context context) {
        var values = prefs(context);
        var now = Calendar.getInstance();
        int day = (now.get(Calendar.DAY_OF_WEEK) + 5) % 7;
        int minute = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE);
        return values.getBoolean("enabled", false) && activeAt(day, minute,
            values.getInt("start", 1320), values.getInt("end", 480), values.getInt("days", 127));
    }

    static boolean activeAt(int day, int minute, int start, int end, int days) {
        boolean overnight = start > end;
        if (overnight && minute < end) day = (day + 6) % 7;
        boolean inHours = overnight ? minute >= start || minute < end : minute >= start && minute < end;
        return inHours && (days & (1 << day)) != 0;
    }
}
