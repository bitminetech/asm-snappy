# asm-snappy

Snappy compression for Ethereum, in assembly.

Standard: [asm-standard@0db3e07](https://github.com/bitminetech/asm-standard/blob/0db3e07f58a9ba89c5b6a46925b179de265ee7e8/ARCHITECTURE.md)

<!-- CI generates the supported platforms panel here. -->
<table><tr><td>

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/readme/platforms-dark.svg"><img src="docs/readme/platforms-light.svg" alt="Supported platforms. Linux: x86-64, ARM64, RISC-V; Windows: x86-64, ARM64; macOS 11.0 or later: x86-64, ARM64"></picture>

</td></tr></table>
<!-- End of the supported platforms panel. -->

<!-- CI generates the verification heatmap here. -->
<table><tr><td>

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/header-dark.svg"><img src="docs/heatmap/header-light.svg" alt="asm-snappy formal verification: 0 of 11 functions proved"></picture>

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/label-block-dark.svg"><img src="docs/heatmap/label-block-light.svg" alt="block"></picture><a href="docs/reference/block.md#function-snappy_compress_size"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_compress_size" title="snappy_compress_size: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_compress"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_compress" title="snappy_compress: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_get_uncompressed_length"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_get_uncompressed_length" title="snappy_get_uncompressed_length: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_uncompress"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_uncompress" title="snappy_uncompress: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_read_length"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_read_length" title="snappy_read_length: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_uncompress_block"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_uncompress_block" title="snappy_uncompress_block: Not proved"></picture></a><a href="docs/reference/block.md#function-snappy_compress_block"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_compress_block" title="snappy_compress_block: Not proved"></picture></a><br>
<picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/label-framing-dark.svg"><img src="docs/heatmap/label-framing-light.svg" alt="framing"></picture><a href="docs/reference/framing.md#function-snappy_frame_compress_size"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_frame_compress_size" title="snappy_frame_compress_size: Not proved"></picture></a><a href="docs/reference/framing.md#function-snappy_frame_compress"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_frame_compress" title="snappy_frame_compress: Not proved"></picture></a><a href="docs/reference/framing.md#function-snappy_frame_uncompress"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_frame_uncompress" title="snappy_frame_uncompress: Not proved"></picture></a><a href="docs/reference/framing.md#function-snappy_crc32c"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/cell-0-dark.svg"><img src="docs/heatmap/cell-0-light.svg" alt="snappy_crc32c" title="snappy_crc32c: Not proved"></picture></a>

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/heatmap/legend-dark.svg"><img src="docs/heatmap/legend-light.svg" alt="Legend"></picture>

</td></tr></table>
<!-- End of the verification heatmap. -->

<!-- CI generates the CI panel here. -->
<table><tr><td>

<a href="https://github.com/bitminetech/asm-snappy/actions/runs/45810825053"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/readme/ci-dark.svg"><img src="docs/readme/ci-light.svg" alt="Latest CI run passed: 8 of 8 jobs passed"></picture></a>

</td></tr></table>
<!-- End of the CI panel. -->

<!-- CI generates the docs panel here. -->
<table><tr><td>

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/readme/docs-header-dark.svg"><img src="docs/readme/docs-header-light.svg" alt="asm-snappy docs"></picture><br>
<picture><source media="(prefers-color-scheme: dark)" srcset="docs/readme/docs-docs-dark.svg"><img src="docs/readme/docs-docs-light.svg" alt="Function docs"></picture><br>
<a href="docs/reference/block.md"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/readme/docs-doc-block-dark.svg"><img src="docs/readme/docs-doc-block-light.svg" alt="Block format: Snappy blocks, as in gossip messages"></picture></a><a href="docs/reference/framing.md"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/readme/docs-doc-framing-dark.svg"><img src="docs/readme/docs-doc-framing-light.svg" alt="Framing format: Framed streams, as in req/resp chunks"></picture></a>

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/readme/docs-footer-dark.svg"><img src="docs/readme/docs-footer-light.svg" alt="Select a card to open its doc."></picture>

</td></tr></table>
<!-- End of the docs panel. -->
