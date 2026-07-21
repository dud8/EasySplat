# Third-party notices

EasySplat is MIT-licensed. Redistributed components remain under their own licenses.

The `0.2.0` release set draws from:

- MetalSplatter, MIT, based on upstream commit `c0f066fb7146d46d9b68e5c76d7d0a6154facc5e` with reviewed EasySplat compatibility changes
- optional Depth Anything 3 source at commit `41736238f5bced4debf3f2a12375d2466874866d`, DA3-BASE weights, and DA3-SMALL weights, Apache-2.0; see [`Tools/Da3Sfm/NOTICE.md`](Tools/Da3Sfm/NOTICE.md)
- msplat 1.1.3 by Rayan Hatout at commit `106499b0a53f82b0c92d013b0861fbebd341b17e`, Apache-2.0, with documented EasySplat modifications; see [`Tools/MsplatNative/NOTICE.md`](Tools/MsplatNative/NOTICE.md)
- native COLMAP 4.1.1, BSD-3-Clause, built with pinned FAISS (MIT), PoseLib (BSD-3-Clause), and VLFeat (BSD-2-Clause)
- Ceres Solver 2.2.0, BSD-3-Clause, compiled into COLMAP with Eigen 3.4.0 (MPL-2.0); SuiteSparse is disabled and is not redistributed
- OpenImageIO 2.5.19.1 with only JPEG and PNG format support
- an optional pinned Python runtime and the hashed packages in `Tools/Da3Sfm/requirements.txt`
- the exact native-library closure required by the packaged executables

This list is a guide. The generated `supply-chain/components.json` inventory is the authoritative file-to-component record for a release. The SPDX SBOM and license archive are derived from that exact signed closure. Release verification rejects any file without a version, provenance record, owner, and license text.

Vendored source licenses remain beside their source, including `ThirdParty/MetalSplatter/LICENSE`.
The Apache License 2.0 text for the tracked DA3 and msplat modifications is at `ThirdParty/LICENSES/Apache-2.0.txt`.
