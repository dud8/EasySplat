# Third-Party Notices

EasySplat includes or depends on third-party components that remain under their own licenses.

## Vendored source in this repository

- `ThirdParty/MetalSplatter`
  License: MIT
  See `ThirdParty/MetalSplatter/LICENSE`
- `ThirdParty/VGGT`
  License: Meta VGGT Research License
  See `ThirdParty/VGGT/LICENSE.txt`
- `ThirdParty/FastVGGT`
  License: Meta VGGT Research License
  See `ThirdParty/FastVGGT/LICENSE.txt`

## Runtime and toolchain notes

- Depth Anything 3 source and bundled default weights (`DA3-BASE`, `DA3-SMALL`) are Apache-2.0. Optional `DA3METRIC-LARGE` experiment weights are Apache-2.0 when explicitly included. Non-commercial DA3 variants are not part of the default EasySplat toolchain.
- Downloaded toolchain artifacts may include additional third-party components, Python packages, and model assets with their own license terms.
- Review the bundled license files before shipping modified binaries or model packages.
