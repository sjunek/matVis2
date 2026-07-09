# ScanImageTiffReader (vendored)

The `.m` files under `+ScanImageTiffReader/` are the official ScanImageTiffReader MATLAB package
(Apache-2.0, see `+ScanImageTiffReader/ScanImageTiffReader.m`'s header), vendored verbatim from
the Windows build published at:

```
https://gitlab.com/api/v4/projects/8668010/jobs/artifacts/master/download?job=build_windows
```

See https://vidriotech.gitlab.io/scanimagetiffreader-matlab/ for the project docs.

`+ScanImageTiffReader/private/*.mexw64` (the compiled reader, Windows x64 only) is **not**
committed here (gitignored) — `io/ensureScanImageTiffReader.m` downloads it automatically on first
use on Windows (with confirmation, when running interactively). There is no automated Mac/Linux
build; per the upstream docs, email support@mbfbioscience.com for one, then copy the
`+ScanImageTiffReader` folder's contents (including `private/`) into this directory yourself.

`io/scanImageTiffReader/` (this folder, the *parent* of `+ScanImageTiffReader/`) must be on the
MATLAB path — not the `+ScanImageTiffReader` folder itself — for
`import ScanImageTiffReader.ScanImageTiffReader` to resolve (MATLAB package-folder convention).
