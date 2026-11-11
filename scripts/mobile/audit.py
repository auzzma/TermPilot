"""Checks the binaries actually shipped, independent of readelf output formats."""
import struct
import zipfile


def audit_android(path, abi):
    machine = {"arm64-v8a": 183, "x86_64": 62}[abi]
    results = []
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if not name.startswith("lib/") or not name.endswith(".so"):
                continue
            assert name.startswith(f"lib/{abi}/"), "APK contains another ABI"
            data = archive.read(name)
            assert data[:6] == b"\x7fELF\x02\x01", f"Not a little-endian ELF64 library: {name}"
            assert struct.unpack_from("<H", data, 18)[0] == machine, f"Wrong ELF architecture: {name}"
            offset = struct.unpack_from("<Q", data, 32)[0]
            size, count = struct.unpack_from("<HH", data, 54)
            assert size >= 56 and offset + count * size <= len(data), "Invalid ELF program headers"
            loads = []
            for index in range(count):
                kind, flags, file_offset, address, _, file_size, _, alignment = struct.unpack_from(
                    "<IIQQQQQQ", data, offset + index * size
                )
                if kind == 1:
                    assert alignment >= 16384, f"Library is not 16 KiB aligned: {name}"
                    assert file_offset % 16384 == address % 16384, f"Unaligned ELF load offset: {name}"
                    assert file_offset + file_size <= len(data), "Truncated ELF segment"
                    loads.append(alignment)
            assert loads, f"Library has no loadable segments: {name}"
            results.append({"name": name, "bytes": len(data), "loadAlignments": loads})
    assert results, "APK has no native libraries"
    return results
