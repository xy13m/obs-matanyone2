# Models

The compiled Core ML models are not committed. `scripts/export-models.sh`
exports them into `.build/models/<width>x<height>/MatAnyone/` and
`scripts/build-plugin.sh` copies the selected set into the plugin bundle under
`Contents/Resources/models/MatAnyone/`.

The weights are licensed under the NTU S-Lab License 1.0 (non-commercial).
See `NOTICE.md` at the repository root.
