# Chimera Runtime rules

- **Strict Dependency Lock:** Never comment out, remove, or alter dependencies in `mix.exs` without explicit user approval. Use `Wasmex` (with WASI disabled) as the WebAssembly runtime.
