package io.tablecircle.prototype;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.PBEKeySpec;
import javax.crypto.spec.SecretKeySpec;

// Encrypt the whole Chatmail archive, including attachments. Each authenticated
// record has a unique nonce. An authenticated empty record checks for truncation.
final class BackupCipher {
    private static final byte[] MAGIC = {0x5a, 0x4f, 0x4d, 0x50, 0x42, 1};
    private static final int SALT = 16;
    private static final int NONCE_PREFIX = 8;
    private static final int HEADER = MAGIC.length + SALT + NONCE_PREFIX;
    private static final int CHUNK = 64 * 1024;
    private static final int TAG = 16;

    private BackupCipher() {}

    static void transfer(File source, File destination, char[] password, boolean encrypt)
            throws IOException, GeneralSecurityException {
        if (password.length < 12 || password.length > 1024) throw new IOException("Invalid password length");
        try (var input = new DataInputStream(new BufferedInputStream(new FileInputStream(source)));
             var output = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(destination)))) {
            byte[] header = new byte[HEADER];
            if (encrypt) {
                new SecureRandom().nextBytes(header);
                System.arraycopy(MAGIC, 0, header, 0, MAGIC.length);
                output.write(header);
            } else {
                input.readFully(header);
                if (!Arrays.equals(MAGIC, Arrays.copyOf(header, MAGIC.length))) throw new IOException("Invalid backup header");
            }
            var spec = new PBEKeySpec(password, Arrays.copyOfRange(header, MAGIC.length, MAGIC.length + SALT), 600000, 256);
            byte[] key;
            try {
                key = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).getEncoded();
            } finally {
                spec.clearPassword();
            }
            var buffer = new byte[CHUNK + TAG];
            try {
                var cipher = Cipher.getInstance("AES/GCM/NoPadding");
                for (int index = 0; ; index = Math.addExact(index, 1)) {
                    int count = encrypt ? fill(input, buffer) : input.readInt();
                    if (count < 0 || count > CHUNK) throw new IOException("Invalid backup record length");
                    if (encrypt) output.writeInt(count);
                    else input.readFully(buffer, 0, count + TAG);
                    var nonce = ByteBuffer.allocate(12).put(header, HEADER - NONCE_PREFIX, NONCE_PREFIX).putInt(index);
                    cipher.init(encrypt ? Cipher.ENCRYPT_MODE : Cipher.DECRYPT_MODE,
                        new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce.array()));
                    cipher.updateAAD(header);
                    cipher.updateAAD(ByteBuffer.allocate(4).putInt(count).array());
                    output.write(cipher.doFinal(buffer, 0, encrypt ? count : count + TAG));
                    if (count == 0) {
                        if (!encrypt && input.read() != -1) throw new IOException("Unexpected backup bytes");
                        break;
                    }
                }
            } finally {
                Arrays.fill(buffer, (byte) 0);
                Arrays.fill(key, (byte) 0);
            }
        }
    }

    private static int fill(DataInputStream stream, byte[] buffer) throws IOException {
        int count = 0;
        while (count < CHUNK) {
            int read = stream.read(buffer, count, CHUNK - count);
            if (read < 0) break;
            count += read;
        }
        return count;
    }
}
