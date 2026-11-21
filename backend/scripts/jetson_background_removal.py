"""Serve PennyMe coin cutouts on Jetson with a prebuilt U²-Net TensorRT engine."""

import argparse
import ctypes
import io
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from time import perf_counter

import numpy as np
from PIL import Image, ImageOps, UnidentifiedImageError
import tensorrt as trt


class BackgroundRemovalModel:
    def __init__(self, engine_path):
        self.cuda = ctypes.CDLL("/usr/local/cuda/lib64/libcudart.so.10.2")
        self.logger = trt.Logger(trt.Logger.WARNING)
        self.runtime = trt.Runtime(self.logger)
        self.engine = self.runtime.deserialize_cuda_engine(engine_path.read_bytes())
        self.context = self.engine.create_execution_context()
        self.input_index = self.engine.get_binding_index("input.1")
        self.mask_index = self.engine.get_binding_index("1959")
        self.buffers = []
        self.bindings = []
        for index in range(self.engine.num_bindings):
            binding = np.empty(
                tuple(self.engine.get_binding_shape(index)),
                dtype=trt.nptype(self.engine.get_binding_dtype(index)),
            )
            device = ctypes.c_void_p()
            self.check_cuda(
                self.cuda.cudaMalloc(
                    ctypes.byref(device), ctypes.c_size_t(binding.nbytes)
                )
            )
            self.buffers.append(binding)
            self.bindings.append(device.value)

    @staticmethod
    def check_cuda(status):
        if status:
            raise RuntimeError("CUDA error {}".format(status))

    def copy(self, index, to_gpu):
        host = ctypes.c_void_p(self.buffers[index].ctypes.data)
        device = ctypes.c_void_p(self.bindings[index])
        destination, source = (device, host) if to_gpu else (host, device)
        self.check_cuda(
            self.cuda.cudaMemcpy(
                destination,
                source,
                ctypes.c_size_t(self.buffers[index].nbytes),
                1 if to_gpu else 2,
            )
        )

    def inference(self, image):
        rgb = np.asarray(image.resize((320, 320), Image.LANCZOS))
        scaled = rgb / max(rgb.max(), 1e-6)
        normalized = (scaled - (0.485, 0.456, 0.406)) / (0.229, 0.224, 0.225)
        self.buffers[self.input_index][0] = normalized.transpose(2, 0, 1)
        start = perf_counter()
        self.copy(self.input_index, to_gpu=True)
        if not self.context.execute_v2(self.bindings):
            raise RuntimeError("TensorRT execution failed")
        self.copy(self.mask_index, to_gpu=False)
        gpu_ms = (perf_counter() - start) * 1000
        prediction = self.buffers[self.mask_index][0, 0]
        low, high = prediction.min(), prediction.max()
        if not np.isfinite(prediction).all():
            raise RuntimeError("TensorRT produced a non-finite mask")
        mask = np.zeros(prediction.shape, dtype=np.uint8)
        if high > low:
            mask = ((prediction - low) / (high - low) * 255).astype(np.uint8)
        return Image.fromarray(mask, "L"), gpu_ms


class Handler(BaseHTTPRequestHandler):
    # one request at a time shares one GPU context for coin uploads.
    def do_POST(self):
        if self.client_address[0] != self.server.allowed_client:
            self.send_error(403)
            return
        if self.path != "/cutout":
            self.send_error(404)
            return
        length = self.headers.get("Content-Length", "")
        if not length.isdigit() or not 0 < int(length) <= 20 * 1024 * 1024:
            self.send_error(400, "Expected image body up to 20 MiB")
            return
        self.connection.settimeout(20)
        start = perf_counter()
        try:
            with Image.open(io.BytesIO(self.rfile.read(int(length)))) as source:
                if source.width * source.height > 50_000_000:
                    self.send_error(413, "Image exceeds 50 megapixels")
                    return
                image = ImageOps.exif_transpose(source).convert("RGB")
                image.thumbnail((1000, 1000), Image.LANCZOS)
        except (UnidentifiedImageError, Image.DecompressionBombError, OSError):
            self.send_error(400, "Unreadable image")
            return

        mask, gpu_ms = self.server.model.inference(image)
        mask = mask.resize(image.size, Image.LANCZOS)
        cutout = Image.composite(
            image.convert("RGBA"), Image.new("RGBA", image.size), mask
        )
        output = io.BytesIO()
        cutout.save(output, "PNG")
        payload = output.getvalue()
        service_ms = (perf_counter() - start) * 1000
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-GPU-Inference-Ms", "{:.2f}".format(gpu_ms))
        self.send_header("X-Jetson-Processing-Ms", "{:.2f}".format(service_ms))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "engine", type=Path, help="Path to the prebuilt TensorRT engine"
    )
    parser.add_argument("--bind", required=True, help="Jetson private IPv4 address")
    parser.add_argument(
        "--allow-client", required=True, help="PennyMe private IPv4 address"
    )
    args = parser.parse_args()

    with HTTPServer((args.bind, 18765), Handler) as server:
        server.allowed_client = args.allow_client
        server.model = BackgroundRemovalModel(args.engine)
        mask, _ = server.model.inference(Image.new("RGB", (320, 320), "white"))
        assert mask.size == (320, 320)
        print("Ready {}".format(args.engine.name), flush=True)
        server.serve_forever()
