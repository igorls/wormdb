# Third-party components

WormDB's project license does not replace the licenses of its dependencies.
Preserve the applicable notices when redistributing source or binaries.

| Component | Use | License and source |
| --- | --- | --- |
| MeshGuard | Embedded networking library; required source submodule | MIT; [license](https://github.com/igorls/meshguard/blob/fdbfd51bdbc643bae0aff8cb7b11e9372f6a23a8/LICENSE), [upstream](https://github.com/igorls/meshguard) |
| libsodium | Optional crypto backend; vendored Linux shared and Windows static libraries | ISC; [notice](deps/lib/LICENSE.libsodium), [upstream](https://github.com/jedisct1/libsodium) |
| libwtf | Optional QUIC/WebTransport gateway | Apache-2.0; [license](https://github.com/andrewmd5/libwtf/blob/9d0a45532d7894ad47a11d6acf329c74decbab31/LICENSE), [upstream](https://github.com/andrewmd5/libwtf) |
| MsQuic | Optional QUIC transport | MIT; [license](https://github.com/microsoft/msquic/blob/adfed920c0fd2a69875ccd57870290fbebc79bd8/LICENSE), [upstream](https://github.com/microsoft/msquic) |

Git submodule entries pin the source revisions. The vendored libsodium libraries
do not currently have a checked-in reproducible build recipe or complete source
provenance record. Verify their source version, build flags, and notices before
redistributing them in a release; selecting `-Dcrypto-backend=std` avoids linking
them. A version string alone is not a provenance record.

QUIC builds may include additional components from libwtf and MsQuic, including
their TLS and compression implementations. Include their transitive notices for
the selected build. JavaScript clients and documentation tooling have their own
lockfiles and dependency licenses; this table is not a complete release SBOM.
