# Zstandard dependency

Vendored decoder: upstream Zstandard **1.5.7**, BSD 3-clause license.

Source: https://github.com/facebook/zstd/releases/tag/v1.5.7
Archive: https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
Archive SHA-256: `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`.

Generated without source edits, from `build/single_file_libs`:

```sh
python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

The generated decompressor and the unmodified public headers are built as the static `CZstd` target. No compressor, subprocess, Homebrew package, downloaded runtime or network access is needed by the installed app. The upstream license is stored with Core resources and explicitly copied into the Resources directory of both the distributed app and widget; packaging verifies both copies byte for byte. Decoder history windows are capped at 128 MiB; input/output buffers and non-accounting lines are bounded. Unsupported, incomplete or damaged frames retain previous valid cached events and produce an incomplete-aggregation health warning with a 60-second retry.

## Pinned files

- `Sources/CZstd/zstddeclib.c`: `5eb38abe0a7eea13674b312a006df72002d4192f0f0b4d09e6f03fb927a1f3d0`
- `Sources/CZstd/include/zstd.h`: `9b4bc8245565c98ccfc61c07749928b57e7c0f6fddb0530c4f6aa1971893d88b`
- `Sources/CZstd/include/zstd_errors.h`: `66a8c3f71d12ea6e797e4f622f31f3f8f81c41b36f48cad4f5de7d8bfb6aac0a`
- `Sources/CodexBalanceCore/Resources/Zstandard-LICENSE.txt`: `7055266497633c9025b777c78eb7235af13922117480ed5c674677adc381c9d8`
