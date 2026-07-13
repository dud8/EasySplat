# Third-party notices

EasySplat is MIT-licensed. Redistributed components remain under their own licenses.

The beta release build draws from:

- MetalSplatter, MIT, based on upstream commit `c0f066fb7146d46d9b68e5c76d7d0a6154facc5e` with reviewed EasySplat compatibility changes
- Depth Anything 3 source, DA3-BASE weights, and DA3-SMALL weights, Apache-2.0
- msplat native trainer, Apache-2.0
- COLMAP, Ceres Solver, SuiteSparse, and their pinned compiled dependencies
- OpenImageIO 2.5.19.1 with only JPEG, PNG, TIFF, and OpenEXR format support
- a pinned Python runtime and the hashed packages in `Tools/Da3Sfm/requirements.txt`
- the exact native-library closure required by the packaged executables

This list is a guide. The generated `supply-chain/components.json` inventory is the authoritative file-to-component record for a release. The SPDX SBOM and license archive are derived from that exact signed closure. Release verification rejects any file without a version, provenance record, owner, and license text.

Vendored source licenses remain beside their source, including `ThirdParty/MetalSplatter/LICENSE`.
