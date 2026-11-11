# Remote storage mod — work split
Branch: remote-storage. Shared interface: lyrico-app/src/main/java/com/lonx/lyrico/remote/RemoteStorage.kt (do not change its signatures without noting it here).
Packages (each owner only touches its own package + its own tests):
- remote/webdav/   WebDavStorage + OpenListStorage (OkHttp, already a dependency)
- remote/smb/      SmbStorage (smbj)
- remote/cloud115/ Cloud115Storage + Cloud115QrLogin
- integration owner: everything else (gradle deps, applicationId com.lonx.lyrico.mod "Lyrico Mod", DB, folder manager UI, scan, edit flow, CI workflow)
Each provider owner appends required Gradle deps under "## Deps needed" below; integration owner adds them.
## Deps needed
