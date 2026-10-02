# colleagues-v2.8.0

The colleagues' own variant, for comparison only: `daos-2.8.0-idmap-v2-760402672.patch` as
received. FUSE_CAP_ALLOW_IDMAP in fused v1.0.0 as bit 31, always requested by dfuse when the
kernel offers it, ioctl caller check unchanged. Apply to v2.8.0. Not for upstream.
