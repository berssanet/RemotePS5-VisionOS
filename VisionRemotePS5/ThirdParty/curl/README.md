# curl public headers

These unmodified public headers allow `ChiakiCore.c` to compile without the
ignored `chiaki-ng` checkout. The app still links the existing curl implementation
inside `Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a`; no curl source
or replacement binary is built here.

- Upstream: https://github.com/curl/curl
- Source revision: `b1ef0e1a01c0bb6ee5367bd9c186a603bde3615a`
- Source paths: `include/curl/*.h` and `COPYING`
- Header version string: `8.11.0-DEV` (preserved exactly from that revision)
- License: [COPYING](COPYING)
- Integrity: [SHA256SUMS](SHA256SUMS), paths relative to this directory

The files were exported from the revision pinned by the existing local Chiaki
curl submodule and checked byte-for-byte against the headers previously used by
this workspace. This records header provenance; it does not independently prove
the source revision of the curl objects embedded in the precompiled archive.

To verify this snapshot from this directory:

```sh
shasum -a 256 -c SHA256SUMS
```

Do not update these headers independently of native-library compatibility review.
