# bfmatlab (vendored)

The `.m` files in this folder (and `private/is_octave.m`) are the official Bio-Formats MATLAB
toolbox, vendored verbatim from
`https://downloads.openmicroscopy.org/bio-formats/8.5.0/artifacts/bfmatlab.zip`
(BSD-2-Clause license, see each file's header). They are no longer published in the main
[ome/bioformats](https://github.com/ome/bioformats) source tree (removed after v6.0.1) but are
still built and distributed as this zip.

`bioformats_package.jar` is **not** committed here (53 MB, gitignored) — `io/ensureBioFormats.m`
downloads it automatically on first use (with confirmation, when running interactively), or fetch
it yourself into this folder:

```
https://downloads.openmicroscopy.org/bio-formats/8.5.0/artifacts/bioformats_package.jar
```

`bfCheckJavaPath.m` auto-discovers the jar by looking in its own folder, so it must stay
co-located with these `.m` files.
