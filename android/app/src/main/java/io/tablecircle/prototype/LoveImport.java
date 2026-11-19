package io.tablecircle.prototype;

import android.content.ContentResolver;
import android.net.Uri;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.DigestInputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

final class LoveImport {
    private static final long MAX_PACKAGE_BYTES = 64L * 1024 * 1024;
    private static final long MAX_CONTENT_BYTES = 192L * 1024 * 1024;
    private static final int MAX_ENTRIES = 4096;

    static Map<String, Object> stage(ContentResolver resolver, Uri source, File directory)
            throws IOException {
        String title;
        try (var cursor = resolver.query(source, new String[] {OpenableColumns.DISPLAY_NAME},
                null, null, null)) {
            title = cursor != null && cursor.moveToFirst() ? cursor.getString(0) : null;
        }
        if (title == null || !title.toLowerCase(Locale.ROOT).endsWith(".love")) {
            throw new IOException("Choose a file ending in .love.");
        }
        if (!directory.isDirectory() && !directory.mkdirs()) {
            throw new IOException("Game storage is unavailable.");
        }
        File pending = File.createTempFile("import-", ".partial", directory);
        try {
            MessageDigest digest = sha256();
            try (InputStream stream = resolver.openInputStream(source)) {
                if (stream == null) throw new IOException("Couldn’t open this file.");
                try (var input = new DigestInputStream(stream, digest);
                     var output = new FileOutputStream(pending)) {
                    byte[] buffer = new byte[32768];
                    long size = 0;
                    for (int count; (count = input.read(buffer)) != -1;) {
                        size += count;
                        if (size > MAX_PACKAGE_BYTES) {
                            throw new IOException("This .love file exceeds 64 MB.");
                        }
                        output.write(buffer, 0, count);
                    }
                }
            }
            validate(pending);
            StringBuilder key = new StringBuilder(64);
            for (var value : digest.digest()) {
                key.append(Character.forDigit((value & 0xff) >> 4, 16));
                key.append(Character.forDigit(value & 0xf, 16));
            }
            String id = key.toString();
            long bytes = pending.length();
            File destination = new File(directory, id + ".love");
            if (!destination.isFile() && !pending.renameTo(destination)) {
                throw new IOException("Couldn’t save this game.");
            }
            Map<String, Object> result = new HashMap<>();
            result.put("id", id);
            result.put("title", title.length() > 120 ? title.substring(0, 120) : title);
            result.put("bytes", bytes);
            return result;
        } finally {
            if (pending.exists()) pending.delete();
        }
    }

    static void validate(File file) throws IOException {
        long expanded = 0;
        boolean hasEntry = false;
        Set<String> names = new HashSet<>();
        Set<String> directories = new HashSet<>();
        byte[] buffer = new byte[32768];
        try (var zip = new ZipFile(file)) {
            if (zip.size() > MAX_ENTRIES) throw new IOException("This game has too many files.");
            var entries = zip.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                String name = entry.getName();
                String path = entry.isDirectory() ? name.substring(0, name.length() - 1) : name;
                if (path.isEmpty() || path.length() > 512 || path.indexOf('\\') >= 0
                        || path.indexOf(':') >= 0 || path.chars().anyMatch(Character::isISOControl)) {
                    throw new IOException("This game contains an invalid file path.");
                }
                String normalized = path.toLowerCase(Locale.ROOT);
                for (String part : path.split("/", -1)) {
                    if (part.isEmpty() || part.equals(".") || part.equals("..")) {
                        throw new IOException("This game contains an invalid file path.");
                    }
                }
                if (!names.add(normalized) || (!entry.isDirectory() && directories.contains(normalized))) {
                    throw new IOException("This game contains conflicting file names.");
                }
                for (int slash = normalized.indexOf('/'); slash >= 0;
                        slash = normalized.indexOf('/', slash + 1)) {
                    String parent = normalized.substring(0, slash);
                    if (names.contains(parent) && !directories.contains(parent)) {
                        throw new IOException("This game contains conflicting file names.");
                    }
                    directories.add(parent);
                }
                if (entry.isDirectory()) {
                    directories.add(normalized);
                    continue;
                }
                if (entry.getSize() < 0 || entry.getSize() > MAX_CONTENT_BYTES - expanded) {
                    throw new IOException("This game exceeds 192 MB when unpacked.");
                }
                long size = 0;
                CRC32 crc = new CRC32();
                try (InputStream input = zip.getInputStream(entry)) {
                    for (int count; (count = input.read(buffer)) != -1;) {
                        if (count > entry.getSize() - size) {
                            throw new IOException("A game file is damaged.");
                        }
                        crc.update(buffer, 0, count);
                        size += count;
                    }
                }
                if (size != entry.getSize() || crc.getValue() != entry.getCrc()) {
                    throw new IOException("A game file is damaged.");
                }
                expanded += size;
                if (name.equals("main.lua") && size > 0) hasEntry = true;
            }
        }
        if (!hasEntry) throw new IOException("This game needs a main.lua file at the top level.");
    }

    private static MessageDigest sha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new AssertionError(e);
        }
    }
}
