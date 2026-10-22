# AgroVision – câmera do robô no tablet

```
Câmera do robô ─USB─> PC (YOLO + servidor) ─USB (adb reverse)─> Tablet (app Flutter)
```

O PC continua fazendo todo o reconhecimento. O servidor só **transmite o vídeo já
com as caixas desenhadas**; o app só **mostra**. Nada aqui aciona lasers/ESP32.

## 1) No PC – servidor

1. Copie `server/agrovision_server.py` para a pasta do seu projeto (ao lado de `runs/`).
2. Feche o `camera_agrovision_USB_baixa_latencia.py` (a câmera só abre em um programa por vez).
3. Rode (com a .venv ativada):
   ```
   python agrovision_server.py
   ```
4. Abra `http://localhost:8000` no navegador do PC – deve aparecer a câmera com as detecções.

Opções úteis: `--camera 1` (outra câmera), `--imgsz 416` (mais preciso, mais lento),
`--conf 0.5`, `--camera video.mp4` (testar sem o robô).

## 2) Tablet ↔ PC por USB

1. No tablet: Opções do desenvolvedor → **Depuração USB** ligada.
2. Instale o [Android platform-tools](https://developer.android.com/tools/releases/platform-tools) no PC.
3. Com o tablet plugado: 
   ```
   adb devices
   adb reverse tcp:8000 tcp:8000
   ```
   (repita o `adb reverse` sempre que replugar o cabo). Pronto: o tablet enxerga o servidor em `http://127.0.0.1:8000`, sem Wi-Fi.

## 3) App Flutter

```
flutter create --org br.agrovision --project-name agrovision_app agrovision_app
```
Copie para dentro de `agrovision_app/`, substituindo o que existir: `lib/main.dart`, `pubspec.yaml`,
a pasta `assets/` (logo) e `patch_android.py`. Depois:

```
cd agrovision_app
del test\widget_test.dart        (apaga o teste de exemplo)
flutter pub get
python patch_android.py          (libera INTERNET e http no Android)
flutter run                      (com o tablet plugado)
```

Se a conexão cair, o app mostra “SEM SINAL” e reconecta sozinho. A engrenagem muda o endereço
(útil para Wi-Fi: `http://IP-DO-PC:8000`, o IP aparece no terminal do servidor).

## 4) Fase 2 – tablet direto no robô

Isso depende de **onde o YOLO vai rodar**, e não é só trocar o cabo:

- **O robô tem Raspberry Pi** (o seu script já fala em Raspberry Pi/V4L2): rode este mesmo servidor
  nele e conecte o tablet na rede da Pi (hotspot do robô ou do tablet). No app, só troque o endereço.
  É o caminho mais curto – o app não muda.
- **Câmera plugada direto no tablet (USB OTG)**: o app teria de abrir a câmera UVC e rodar o modelo
  no próprio tablet (exportar para NCNN/TFLite). É outro projeto, bem maior.
