# Target TLS material (demo)

This folder contains demo TLS certificate material used by the target service
for HTTPS/QUIC test traffic in this repository (based on [godash](https://github.com/uccmisl/godash)).

Why it exists:
- `target/entrypoint.sh` starts HTTP + QUIC test endpoints.
- The QUIC endpoint requires cert/key files present at runtime.

Scope:
- Intended for local demo and reproducible hackathon testing only.
- Not suitable for production use.

Production note:
- Replace with environment-specific certificates and private key handling
  before any non-demo deployment.
