package io.tablecircle.prototype;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.regex.Pattern;

final class OnlineTurnPages {
    private static final int PAGE_SIZE = 128;
    private static final Pattern TURN_TOKEN = Pattern.compile("[A-Za-z0-9_-]{1,256}");
    private final ArrayList<String> committed = new ArrayList<>();
    private final HashMap<Integer, String> staged = new HashMap<>();

    boolean stage(int index, String page) {
        if (index < 0 || page.isEmpty() || page.length() > 32895) return false;
        String[] tokens = page.split(",", -1);
        if (tokens.length > PAGE_SIZE) return false;
        for (String token : tokens) {
            if (!TURN_TOKEN.matcher(token).matches()) return false;
        }
        staged.put(index, page);
        return true;
    }

    void discard() {
        staged.clear();
    }

    ArrayList<Integer> commit(int count) {
        // Validate every required page before replacing even a single committed page.
        if (count < 0 || count > committed.size() + staged.size()) return null;
        for (int index = committed.size(); index < count; index++) {
            if (!staged.containsKey(index)) return null;
        }
        // A partial tail is legal only while it remains the last page.
        for (var entry : staged.entrySet()) {
            if (entry.getKey() < count - 1 && !full(entry.getValue())) return null;
        }
        int previousTail = committed.size() - 1;
        if (previousTail >= 0 && previousTail < count - 1 && !staged.containsKey(previousTail)
                && !full(committed.get(previousTail))) return null;
        var changed = new ArrayList<Integer>();
        for (int index = 0; index < count; index++) {
            String page = staged.get(index);
            if (page == null) continue;
            if (index == committed.size()) committed.add(page);
            else committed.set(index, page);
            changed.add(index);
        }
        committed.subList(count, committed.size()).clear();
        discard();
        return changed;
    }

    private static boolean full(String page) {
        return page.chars().filter(c -> c == ',').count() == PAGE_SIZE - 1;
    }

    int size() {
        return committed.size();
    }

    String get(int index) {
        return committed.get(index);
    }
}
