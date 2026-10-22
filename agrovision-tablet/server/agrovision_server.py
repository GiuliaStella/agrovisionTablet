#!/usr/bin/env python3
"""
AGROVISION - servidor de video (SOMENTE VISUALIZACAO)

Abre a camera do robo, roda o YOLO e transmite a imagem ja com as
deteccoes desenhadas (MJPEG) para o app Flutter no tablet.

  - NAO abre porta serial, NAO fala com o ESP32, NAO aciona lasers.
  - Uma camera so pode ser aberta por um programa por vez: feche o
    camera_agrovision_USB_baixa_latencia.py antes de rodar este.

Coloque este arquivo na MESMA pasta do projeto (ao lado de "runs/").

Uso:
    python agrovision_server.py
    python agrovision_server.py --camera 1 --imgsz 416
    python agrovision_server.py --camera video_teste.mp4     (testar sem robo)

Teste no navegador do PC:  http://localhost:8000
"""
import argparse
import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2
from ultralytics import YOLO

CLASS_ERVA = 0
CLASS_PLANTA = 1
ROTULOS = {CLASS_ERVA: "ERVA", CLASS_PLANTA: "PLANTA"}
CORES = {CLASS_ERVA: (0, 255, 0), CLASS_PLANTA: (0, 0, 255)}  # BGR

AQUI = os.path.dirname(os.path.abspath(__file__))


# ------------------------------------------------------------------
# Camera (captura em thread propria, guarda so o quadro mais recente)
# ------------------------------------------------------------------
class Camera:
    def __init__(self, source, width, height, fps):
        self.eh_arquivo = isinstance(source, str)
        if self.eh_arquivo:
            self.cap = cv2.VideoCapture(source)
        else:
            backend = cv2.CAP_V4L2 if sys.platform.startswith("linux") else cv2.CAP_ANY
            self.cap = cv2.VideoCapture(source, backend)
        if not self.cap.isOpened():
            raise RuntimeError(
                "Nao foi possivel abrir a camera/video. Ela esta em uso por "
                "outro programa? Tente --camera 1."
            )
        if not self.eh_arquivo:
            self.cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
            self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
            self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
            self.cap.set(cv2.CAP_PROP_FPS, fps)
            self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        self.lock = threading.Lock()
        self.frame = None
        self.seq = 0
        self.running = True
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _loop(self):
        while self.running:
            ok, frame = self.cap.read()
            if not ok:
                if self.eh_arquivo:  # video de teste: recomeca
                    self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                    continue
                time.sleep(0.01)
                continue
            if self.eh_arquivo:
                time.sleep(1 / 30)
            with self.lock:
                self.frame = frame
                self.seq += 1

    def latest(self):
        with self.lock:
            if self.frame is None:
                return None, self.seq
            return self.frame, self.seq

    def close(self):
        self.running = False
        self.thread.join(timeout=2)
        self.cap.release()


# ------------------------------------------------------------------
# Estado compartilhado entre a inferencia e os clientes HTTP
# ------------------------------------------------------------------
class Estado:
    def __init__(self):
        self.cond = threading.Condition()
        self.jpeg = None
        self.seq = 0
        self.running = True
        self.reconhecendo = True  # POST /start e /stop mudam isto
        self.stats = {"fps": 0.0, "ervas": 0, "plantas": 0, "camera": False}

    def status(self):
        s = dict(self.stats)
        if not s["camera"]:
            s["status"] = "Iniciando"
        else:
            s["status"] = "Conectado" if self.reconhecendo else "Parado"
        return s

    def publicar(self, jpeg, stats):
        with self.cond:
            self.jpeg = jpeg
            self.seq += 1
            self.stats = stats
            self.cond.notify_all()

    def esperar_novo(self, ultimo, timeout=2.0):
        with self.cond:
            self.cond.wait_for(lambda: self.seq != ultimo or not self.running, timeout)
            return self.jpeg, self.seq


ESTADO = Estado()


# ------------------------------------------------------------------
# Inferencia
# ------------------------------------------------------------------
def desenhar(img, deteccoes, escala):
    for cls, conf, (x1, y1, x2, y2) in deteccoes:
        x1, y1, x2, y2 = int(x1 * escala), int(y1 * escala), int(x2 * escala), int(y2 * escala)
        cor = CORES.get(cls, (255, 255, 0))
        cv2.rectangle(img, (x1, y1), (x2, y2), cor, 3)
        cx, cy = (x1 + x2) // 2, (y1 + y2) // 2
        cv2.circle(img, (cx, cy), 5, cor, -1)
        texto = f"{ROTULOS.get(cls, str(cls))} {conf:.2f}"
        cv2.putText(img, texto, (x1, max(22, y1 - 8)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, cor, 2)


def loop_inferencia(cam, model, args):
    ultimo_seq = -1
    contador, t0, fps = 0, time.monotonic(), 0.0
    while ESTADO.running:
        frame, seq = cam.latest()
        if frame is None or seq == ultimo_seq:
            time.sleep(0.002)
            continue
        ultimo_seq = seq

        deteccoes, ervas, plantas = [], 0, 0
        # Parado: continua mandando o video, so sem rodar o YOLO
        res = model(frame, conf=args.conf, imgsz=args.imgsz, verbose=False)[0] if ESTADO.reconhecendo else None
        if res is not None and res.boxes is not None:
            for box in res.boxes:
                cls = int(box.cls[0])
                conf = float(box.conf[0])
                xyxy = tuple(map(float, box.xyxy[0]))
                deteccoes.append((cls, conf, xyxy))
                if cls == CLASS_ERVA:
                    ervas += 1
                elif cls == CLASS_PLANTA:
                    plantas += 1

        # Reduz a imagem ANTES de enviar (1080p inteiro pesa demais p/ o tablet)
        h, w = frame.shape[:2]
        escala = 1.0
        saida = frame.copy()
        if args.stream_width and w > args.stream_width:
            escala = args.stream_width / w
            saida = cv2.resize(saida, (args.stream_width, int(h * escala)),
                               interpolation=cv2.INTER_AREA)
        desenhar(saida, deteccoes, escala)

        ok, buf = cv2.imencode(".jpg", saida, [cv2.IMWRITE_JPEG_QUALITY, args.quality])
        if not ok:
            continue

        contador += 1
        agora = time.monotonic()
        if agora - t0 >= 1.0:
            fps = contador / (agora - t0)
            contador, t0 = 0, agora

        ESTADO.publicar(buf.tobytes(), {
            "fps": round(fps, 1),
            "ervas": ervas,
            "plantas": plantas,
            "camera": True,
        })


# ------------------------------------------------------------------
# HTTP
# ------------------------------------------------------------------
PAGINA = b"""<!doctype html><meta charset="utf-8">
<title>AgroVision</title>
<body style="margin:0;background:#000;display:flex;align-items:center;justify-content:center;height:100vh">
<img src="/video" style="max-width:100%;max-height:100%"></body>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # silencia o log de cada requisicao

    def do_GET(self):
        caminho = self.path.split("?")[0]
        if caminho == "/video":
            self._video()
        elif caminho == "/status":
            self._json(200, ESTADO.status())
        elif caminho == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(PAGINA)))
            self.end_headers()
            self.wfile.write(PAGINA)
        else:
            self.send_error(404)

    def do_POST(self):
        caminho = self.path.split("?")[0]
        if caminho == "/start":
            ESTADO.reconhecendo = True
            self._json(200, ESTADO.status())
        elif caminho == "/stop":
            ESTADO.reconhecendo = False
            self._json(200, ESTADO.status())
        elif caminho.startswith("/laser/"):
            # Este servidor e so de visualizacao: nao fala com o ESP32
            self._json(501, {"erro": "laser nao implementado neste servidor"})
        else:
            self.send_error(404)

    def _json(self, codigo, dados):
        corpo = json.dumps(dados).encode()
        self.send_response(codigo)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corpo)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(corpo)

    def _video(self):
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        ultimo = -1
        try:
            while ESTADO.running:
                jpeg, seq = ESTADO.esperar_novo(ultimo)
                if jpeg is None or seq == ultimo:
                    continue
                ultimo = seq
                self.wfile.write(
                    b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(jpeg)
                )
                self.wfile.write(jpeg)
                self.wfile.write(b"\r\n")
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            pass  # tablet desconectou


def ips_locais():
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except OSError:
        pass
    return sorted(ip for ip in ips if not ip.startswith("127."))


# ------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="AgroVision - servidor de video para o tablet")
    ap.add_argument("--model", default=os.path.join(AQUI, "runs/detect/agrovision-2/weights/best.pt"))
    ap.add_argument("--camera", default="0", help="indice da camera (0, 1...) ou caminho de um video")
    ap.add_argument("--conf", type=float, default=0.70)
    ap.add_argument("--imgsz", type=int, default=320, help="menor = mais rapido (320/416/640)")
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--fps", type=int, default=90)
    # Padroes pensados para Bluetooth PAN (~1-2 Mbps); aumente se estiver em Wi-Fi
    ap.add_argument("--stream-width", type=int, default=480, help="largura da imagem enviada ao tablet")
    ap.add_argument("--quality", type=int, default=50, help="qualidade JPEG (1-100)")
    ap.add_argument("--port", type=int, default=8000)
    args = ap.parse_args()

    source = int(args.camera) if args.camera.isdigit() else args.camera

    print("Carregando modelo:", args.model)
    model = YOLO(args.model)
    cam = Camera(source, args.width, args.height, args.fps)

    t = threading.Thread(target=loop_inferencia, args=(cam, model, args), daemon=True)
    t.start()

    servidor = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print()
    print("=" * 52)
    print(" AGROVISION - servidor de video (so visualizacao)")
    print("=" * 52)
    print(f" No PC:                http://localhost:{args.port}")
    print(f" Tablet via USB (adb): http://127.0.0.1:{args.port}   (apos 'adb reverse')")
    for ip in ips_locais():
        print(f" Tablet via rede/BT:   http://{ip}:{args.port}")
    print(" Ctrl+C para sair")
    print("=" * 52)
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        ESTADO.running = False
        with ESTADO.cond:
            ESTADO.cond.notify_all()
        servidor.server_close()
        cam.close()
        print("Encerrado.")


if __name__ == "__main__":
    main()
