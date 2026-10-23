"""Structural media gates; placeholders are used only in isolated unit tests."""
from pathlib import Path
from contract import require


def video(path):
    path = Path(path)
    size = path.stat().st_size
    boxes = set()
    with path.open("rb") as stream:
        while stream.tell() < size:
            start = stream.tell()
            header = stream.read(8)
            require(len(header) == 8, "Truncated video header")
            count, kind = int.from_bytes(header[:4], "big"), header[4:8]
            minimum = 8
            if count == 1:
                extended = stream.read(8)
                require(len(extended) == 8, "Truncated extended video header")
                count, minimum = int.from_bytes(extended, "big"), 16
            elif count == 0:
                count = size - start
            require(count >= minimum and start + count <= size, "Truncated video box")
            boxes.add(kind)
            stream.seek(start + count)
    require({b"ftyp", b"moov", b"mdat"} <= boxes and size > 3000, "Missing/unfinalized actual simulator video")


def screenshots(directory):
    pngs = list(Path(directory).rglob("*.png"))
    require(len(pngs) >= 6, "Actual peer journey screenshots missing")
    for path in pngs:
        with path.open("rb") as stream:
            require(stream.read(8) == b"\x89PNG\r\n\x1a\n", "Exported attachment is not PNG")
