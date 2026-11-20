package io.tablecircle.prototype;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/** Reads only the signal and crashing thread's backtrace from Android's tombstone protobuf. */
final class NativeCrashSummary {
    private NativeCrashSummary() {}

    static String format(byte[] bytes) {
        try {
            var fields = new Proto(bytes, 0, bytes.length).fields();
            long threadId = number(fields, 6);
            var signal = nested(bytes, first(fields, 10));
            var summary = new StringBuilder("Signal ").append(number(signal, 1))
                .append(" · code ").append(number(signal, 3)).append(" · thread ").append(threadId);
            for (var entry : fields) {
                if (entry.id != 16) continue;
                var threadEntry = nested(bytes, entry);
                if (number(threadEntry, 1) != threadId) continue;
                var thread = nested(bytes, first(threadEntry, 2));
                int count = 0;
                for (var field : thread) {
                    if (field.id != 4 || count >= 24) continue;
                    count++;
                    var frame = nested(bytes, field);
                    String module = text(bytes, first(frame, 6), 256);
                    module = module.substring(module.lastIndexOf('/') + 1);
                    if (!module.matches("[A-Za-z0-9._$!-]+")) module = "native module";
                    String symbol = text(bytes, first(frame, 4), 144)
                        .replaceAll("[^a-zA-Z0-9_.$:<>()~*& ,+-]", "");
                    summary.append("\n  ").append(module).append(" +0x")
                        .append(Long.toHexString(number(frame, 1)));
                    if (!symbol.isEmpty()) summary.append(' ').append(symbol);
                }
                break;
            }
            return summary.toString();
        } catch (IllegalArgumentException malformed) {
            return "Android native backtrace unavailable.";
        }
    }

    private record Field(int id, long value, int start, int end) {}

    private static Field first(List<Field> fields, int id) {
        for (var field : fields) if (field.id == id) return field;
        return null;
    }

    private static long number(List<Field> fields, int id) {
        var field = first(fields, id);
        return field == null ? 0 : field.value;
    }

    private static String text(byte[] bytes, Field field, int limit) {
        if (field == null) return "";
        return new String(bytes, field.start, Math.min(limit, field.end - field.start), StandardCharsets.UTF_8);
    }

    private static List<Field> nested(byte[] bytes, Field field) {
        return field == null ? List.of() : new Proto(bytes, field.start, field.end).fields();
    }

    private static final class Proto {
        final byte[] data;
        final int end;
        int offset;

        Proto(byte[] data, int start, int end) {
            this.data = data;
            this.offset = start;
            this.end = end;
        }

        long varint() {
            long value = 0;
            for (int shift = 0; shift < 64 && offset < end; shift += 7) {
                int next = data[offset++] & 255;
                value |= (long) (next & 127) << shift;
                if ((next & 128) == 0) return value;
            }
            throw new IllegalArgumentException("Invalid varint");
        }

        List<Field> fields() {
            var result = new ArrayList<Field>();
            while (offset < end) {
                long tag = varint();
                int id = (int) (tag >>> 3);
                if (id <= 0 || result.size() >= 50_000) throw new IllegalArgumentException("Invalid field");
                switch ((int) (tag & 7)) {
                    case 0 -> result.add(new Field(id, varint(), 0, 0));
                    case 1 -> skip(8);
                    case 2 -> {
                        long length = varint();
                        int start = offset;
                        skip(length);
                        result.add(new Field(id, 0, start, offset));
                    }
                    case 5 -> skip(4);
                    default -> throw new IllegalArgumentException("Invalid field type");
                }
            }
            return result;
        }

        private void skip(long count) {
            if (count < 0 || count > end - offset) throw new IllegalArgumentException("Invalid field length");
            offset += (int) count;
        }
    }
}
