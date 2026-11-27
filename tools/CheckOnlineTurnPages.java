package io.tablecircle.prototype;

import java.util.List;

public final class CheckOnlineTurnPages {
    public static void main(String[] args) {
        var pages = new OnlineTurnPages();
        String maxToken = "x".repeat(256);
        String fullPage = (maxToken + ",").repeat(127) + maxToken;
        require(fullPage.length() == 32895);
        for (int i = 0; i < 32; i++) require(pages.stage(i, fullPage));
        require(pages.size() == 0);
        require(pages.commit(32).size() == 32);
        require(pages.stage(31, "changed"));
        require(pages.stage(33, "missing_previous_page"));
        require(pages.commit(34) == null);
        require(pages.size() == 32 && pages.get(31).equals(fullPage));
        pages.discard();
        require(pages.stage(32, maxToken));
        require(pages.commit(33).equals(List.of(32)));
        require(pages.get(32).equals(maxToken));
        require(pages.stage(34, "gap"));
        require(pages.commit(35) == null && pages.size() == 33);
        pages.discard();
        require(pages.stage(33, "past_partial_tail"));
        require(pages.commit(34) == null);
        pages.discard();
        require(pages.commit(32).isEmpty() && pages.size() == 32);
        require(!pages.stage(0, "a,,b") && !pages.stage(0, maxToken + "x"));
        System.out.println("PASS: staging isolation, incomplete delivery, 4097 turns, and rollback.");
    }

    private static void require(boolean condition) {
        if (!condition) throw new AssertionError();
    }
}
