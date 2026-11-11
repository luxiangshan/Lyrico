# Remote storage mod — work split
Branch: remote-storage. Shared interface: lyrico-app/src/main/java/com/lonx/lyrico/remote/RemoteStorage.kt (do not change its signatures without noting it here).
Packages (each owner only touches its own package + its own tests):
- remote/webdav/   WebDavStorage + OpenListStorage (OkHttp, already a dependency)
- remote/smb/      SmbStorage (smbj)
- remote/cloud115/ Cloud115Storage + Cloud115QrLogin
- integration owner: everything else (gradle deps, applicationId com.lonx.lyrico.mod "Lyrico Mod", DB, folder manager UI, scan, edit flow, CI workflow)
Each provider owner appends required Gradle deps under "## Deps needed" below; integration owner adds them.
## Deps needed

### SMB (remote/smb) — owner: smb
Gradle (app module):
```kotlin
implementation("com.hierynomus:smbj:0.14.0")            // pulls bcprov-jdk18on:1.79, slf4j-api:2.0.9, mbassador:1.3.0, asn-one:0.6.0
implementation("org.slf4j:slf4j-nop:2.0.9")              // silences "No SLF4J providers" (or use any Android slf4j binding)
implementation("com.rapid7.client:dcerpc:0.12.13")       // OPTIONAL, only for SmbStorage.listShares (SmbShareLister.kt).
                                                        //  Pulls guava 33.4.0-jre, commons-io 2.7, commons-lang3 3.4.
                                                        //  Built against smbj 0.12.2; verified working with 0.14.0 (Samba 4.22).
                                                        //  If you don't want it: delete remote/smb/SmbShareLister.kt (+ SmbShareFilterTest.kt
                                                        //  and the listShares test in SmbStorageIntegrationTest.kt); nothing else references it.
```
Android packaging notes:
- BouncyCastle is required: Android's JCE has no MD4 (NTLM). SmbStorage sets `BCSecurityProvider` explicitly (BC lightweight API, no `Security.addProvider` needed, no clash with Android's repackaged `com.android.org.bouncycastle`). Don't let anything pull `bcprov-jdk15on` too (duplicate classes) — exclude it if it appears.
- bcprov 1.7x is a multi-release jar; AGP may fail with duplicate resources. Add:
  `packaging { resources { excludes += setOf("META-INF/versions/9/OSGI-INF/MANIFEST.MF", "META-INF/DEPENDENCIES", "META-INF/INDEX.LIST", "META-INF/LICENSE*", "META-INF/NOTICE*") } }`
- Auth is NTLM only (`withAuthenticators(NtlmAuthenticator.Factory())`), so the Kerberos/GSS path (javax.security.auth.kerberos, org.ietf.jgss — absent on Android) is never used; R8 still needs dontwarns.
- R8/proguard (release minify): mbassador dispatches via reflection on `@Handler` methods.
  ```
  -keep class com.hierynomus.** { *; }
  -keep class net.engio.mbassy.** { *; }
  -keep class com.rapid7.client.dcerpc.** { *; }
  -dontwarn javax.el.**
  -dontwarn org.ietf.jgss.**
  -dontwarn javax.security.auth.kerberos.**
  -dontwarn sun.security.**
  -dontwarn com.sun.**
  -dontwarn org.slf4j.impl.**
  -dontwarn com.google.errorprone.annotations.**
  -dontwarn com.google.j2objc.annotations.**
  ```
- Needs `android.permission.INTERNET`. All calls are blocking — call on Dispatchers.IO.
- Guava `-jre` works on Android but is big; R8 shrinks it. Optionally force `com.google.guava:guava:33.4.0-android`.
- remote/webdav (test-only; runtime needs nothing beyond okhttp + platform org.json):
  testImplementation("com.squareup.okhttp3:mockwebserver3:5.5.1")
  testImplementation("org.json:json:20240303")   // real org.json for local JVM tests (android.jar stubs throw)

### 115 (remote/cloud115) — owner: cloud115
- Runtime: nothing new. Uses okhttp 5.5.1 (already a dep) + platform org.json + JCA (AES/CBC, HmacSHA1, SHA-1/MD5).
  No BouncyCastle: P-224 ECDH for the upload-init cipher and the LZ4 block decoder are implemented in pure Kotlin.
- Tests (local JVM):
  testImplementation("com.squareup.okhttp3:mockwebserver3:5.5.1")
  testImplementation("org.json:json:20240303")   // same as webdav; android.jar's org.json stubs throw
- Needs android.permission.INTERNET. All Cloud115Storage / Cloud115QrLogin calls block — use Dispatchers.IO.
  Cloud115QrLogin.poll() long-polls (default client readTimeout 60 s).
- Factory: Cloud115Storage(config, credentialStore) (credentialStore currently unused); QR: Cloud115QrLogin(app = "alipaymini").
