#!/usr/bin/env python3
"""Decode bounded synthetic NV12 output and compare luma with its exact source phases.

This checks dimensions, decodability and synthetic luma error only. It is not a
display, chroma, text-legibility, motion-quality or streaming acceptance test.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import threading


def source_frame(width, height, phase):
    x = phase * (width - 128) // 7
    rows = [bytes([value]) * x + bytes([220]) * 128 + bytes([value]) * (width - x - 128)
            for value in [48, 96]]
    return b"".join(rows[(y // 32) % 2] for y in range(height))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture_dir", type=Path)
    args = parser.parse_args()
    folder = args.capture_dir.resolve()
    metadata = json.loads((folder / "capture.json").read_text())
    if metadata["failure"] is not None or metadata["inputPixelFormat"] != "nv12":
        raise SystemExit("Requires a successful synthetic NV12 capture")
    width, height, fps = (metadata[k] for k in ["width", "height", "sourceFPS"])
    frames = metadata["frames"]
    if not (1 <= len(frames) <= 32 and metadata["frameCount"] == len(frames)):
        raise SystemExit("Invalid capture count")
    if width not in [1920, 2560, 3840, 5120] or height not in [1080, 1440, 2160, 2880] or fps not in [30, 60, 120]:
        raise SystemExit("Invalid fixture dimensions/rate")
    if any(not isinstance(f["patternPhase"], int) or not 0 <= f["patternPhase"] < 8 for f in frames):
        raise SystemExit("Invalid fixture phase")
    if metadata["pattern"] != "eight_phase_moving_luma_bar_on_static_stripes":
        raise SystemExit("Reference generator does not match this pattern")
    encoded = folder / "encoded.annexb"
    if encoded.stat().st_size > 32 * 1024 * 1024 or encoded.stat().st_size != metadata["encodedBytes"]:
        raise SystemExit("Invalid encoded length")
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise SystemExit("ffmpeg and ffprobe are required")
    probe = subprocess.run([ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=codec_name,width,height,pix_fmt,color_range,color_space", "-of", "json", str(encoded)],
        capture_output=True, text=True, check=True, timeout=30)
    streams = json.loads(probe.stdout)["streams"]
    if len(streams) != 1 or any(streams[0].get(k) != v for k, v in
        [("codec_name", metadata["codec"]), ("width", width), ("height", height), ("color_range", "pc")]):
        raise SystemExit("Bitstream metadata differs from the full-range NV12 fixture; inspect rather than silently normalize")
    if (folder / "luma-quality-v2.json").exists() or (folder / "luma-psnr-v2.log").exists():
        raise SystemExit("Quality results already exist; preserve the original receipt")
    filters = (f"[0:v]extractplanes=y,setpts=N/({fps}*TB)[actual];"
               f"[1:v]setpts=N/({fps}*TB)[reference];"
               "[actual][reference]psnr=stats_file=luma-psnr-v2.log:shortest=1:repeatlast=0")
    command = [ffmpeg, "-hide_banner", "-loglevel", "warning", "-xerror", "-err_detect", "explode",
        "-threads", "2", "-f", metadata["codec"], "-framerate", str(fps), "-i", str(encoded),
        "-f", "rawvideo", "-pixel_format", "gray", "-video_size", f"{width}x{height}",
        "-framerate", str(fps), "-color_range", "pc", "-i", "pipe:0", "-filter_complex_threads", "2",
        "-lavfi", filters, "-frames:v", str(len(frames)), "-f", "null", "-"]
    with (folder / "luma-decode-v2.log").open("wb") as log:
        process = subprocess.Popen(command, cwd=folder, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=log)
        watchdog = threading.Timer(90, process.kill)
        watchdog.start()
        try:
            for frame in frames:
                process.stdin.write(source_frame(width, height, frame["patternPhase"]))
            process.stdin.close()
            status = process.wait(timeout=90)
        except BaseException:
            process.kill(); process.wait()
            raise
        finally:
            watchdog.cancel()
    if status != 0:
        raise SystemExit(f"Decode/compare failed ({status}); inspect luma-decode-v2.log")
    scores = []
    for line in (folder / "luma-psnr-v2.log").read_text().splitlines():
        fields = dict(re.findall(r"(\w+):([^\s]+)", line))
        mse = float(fields["mse_avg"])
        if not math.isfinite(mse) or mse < 0:
            raise SystemExit("Invalid luma error measurement")
        psnr = float(fields["psnr_avg"])
        if math.isnan(psnr) or psnr < 0:
            raise SystemExit("Invalid luma PSNR measurement")
        # FFmpeg rounds MSE to two decimals: a tiny nonzero error can appear as
        # 0.00. Derive error from its more precise PSNR so that is never called
        # lossless. Positive infinity is permitted only when FFmpeg reports it.
        scores.append(0.0 if math.isinf(psnr) else 255 * 255 * 10 ** (-psnr / 10))
    if len(scores) != len(frames):
        raise SystemExit("Decoded/compared count does not match captured source phases")
    average_mse = sum(scores) / len(scores)
    result = {
        "scope": "software_decode_and_synthetic_luma_only", "decodeIntegrityPass": True,
        "streamingAcceptance": False, "professionalImageQualityAcceptance": None,
        "comparedFrames": len(scores), "stream": streams[0],
        "approximateMeanSquaredLumaError": average_mse, "approximateMaximumFrameMeanSquaredLumaError": max(scores),
        "approximateAggregateLumaPSNRdB": 10 * math.log10(255 * 255 / average_mse) if average_mse else "infinite",
        "statisticsPrecision": "Reconstructed from FFmpeg per-frame PSNR rounded to0.01dB",
        "encodedSHA256": hashlib.sha256(encoded.read_bytes()).hexdigest(),
        "captureMetadataSHA256": hashlib.sha256((folder / "capture.json").read_bytes()).hexdigest(),
        "checkerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "ffmpegVersion": subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0],
        "command": command,
        "limitations": ["Easy cached monochrome pattern; chroma and desktop text are not evaluated.",
            "Software decoding does not measure the Apple client hardware decoder or display.",
            "No capture, network, input, client clock or end-to-end latency is measured."]
    }
    (folder / "checker-v2-source.py").write_bytes(Path(__file__).read_bytes())
    (folder / "luma-quality-v2.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ["decodeIntegrityPass", "comparedFrames", "approximateMeanSquaredLumaError", "approximateAggregateLumaPSNRdB"]}))


if __name__ == "__main__":
    main()
