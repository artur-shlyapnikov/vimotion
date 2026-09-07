# Third-party notices

Vimotion is distributed under the MIT License; the complete text is in
[`LICENSE`](LICENSE). Dependencies keep the license terms and copyright notices
provided by their authors.

## Model Context Protocol Swift SDK

Vimotion uses [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk),
pinned to `0.12.1` in [`Package.resolved`](Package.resolved). The SDK's
[license](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/LICENSE)
documents its transition from MIT to Apache-2.0: new contributions are Apache-2.0,
while contributions that have not been relicensed remain under their original
MIT terms. Documentation contributions (except specifications) are CC-BY-4.0.

The SDK brings in additional Swift packages, including Swift System, Swift Log,
Swift NIO, EventSource, and their transitive dependencies. Their exact revisions
are recorded in `Package.resolved`; each package's upstream license and notice
remain authoritative when redistributing source or binaries.

The Cua driver is an optional external executable discovered at runtime. It is
not copied into or redistributed by this repository; follow its upstream license
and distribution terms separately.
