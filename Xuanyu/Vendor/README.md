# Vendored speech runtime

- `sherpa-onnx.xcframework`: sherpa-onnx v1.13.3 macOS static XCFramework.
  - Source: https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.3
  - Archive SHA-256: `e1dcd71368ce7dba20622c75f8bdd1a2d2eda4265ce4a1be4a1ac3a2fc74dc9a`
  - License: Apache-2.0
- `onnxruntime.xcframework`: manually packaged from the universal static ONNX Runtime 1.24.4 archive used by sherpa-onnx v1.13.3.
  - Source: https://github.com/csukuangfj/onnxruntime-libs/releases/tag/v1.24.4
  - Archive SHA-256: `df4e20a6583ddc81fae7b1dfa776f6c06fa9c7cd32a3af44c9369c9e75731426`
  - License: MIT

Both XCFrameworks contain universal `arm64` and `x86_64` static libraries. The
module maps are local packaging metadata required by Swift Package Manager.
