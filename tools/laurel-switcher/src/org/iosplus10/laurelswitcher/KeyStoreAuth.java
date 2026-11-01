package org.iosplus10.laurelswitcher;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.interfaces.RSAPublicKey;

/** The app's adb key: RSA 2048 in Android Keystore, no file holds the private part. adbd asks the owner once ("Always allow"). */
final class KeyStoreAuth implements AdbClient.Auth {
    private static final String ALIAS = "laurel-adb";

    private KeyStore store() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (!ks.containsAlias(ALIAS)) {
            KeyPairGenerator g = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore");
            g.initialize(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setKeySize(2048)
                    .setDigests(KeyProperties.DIGEST_NONE)
                    .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
                    .build());
            g.generateKeyPair();
        }
        return ks;
    }

    @Override public byte[] sign(byte[] token) throws Exception {
        Signature s = Signature.getInstance("NONEwithRSA");
        s.initSign((PrivateKey) store().getKey(ALIAS, null));
        s.update(AdbClient.sha1DigestInfo(token));
        return s.sign();
    }

    @Override public byte[] publicKey() throws Exception {
        return AdbClient.publicKeyPayload((RSAPublicKey) store().getCertificate(ALIAS).getPublicKey(), "laurel-switcher@phone");
    }
}
