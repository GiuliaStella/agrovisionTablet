"""
Ajusta o AndroidManifest.xml gerado pelo 'flutter create':
  - permissao de INTERNET (necessaria no app instalado/release)
  - HTTP sem criptografia liberado (o servidor usa http://, nao https://)
  - nome do app: AgroVision

Uso (dentro da pasta do projeto Flutter):
    python patch_android.py
"""
import pathlib
import re
import sys

caminho = pathlib.Path(
    sys.argv[1] if len(sys.argv) > 1 else "android/app/src/main/AndroidManifest.xml"
)
if not caminho.exists():
    sys.exit(f"Nao achei {caminho}. Rode dentro da pasta do projeto Flutter.")

s = caminho.read_text(encoding="utf-8")

if "android.permission.INTERNET" not in s:
    s = s.replace(
        "<application",
        '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
        1,
    )
if "usesCleartextTraffic" not in s:
    s = s.replace("<application", '<application\n        android:usesCleartextTraffic="true"', 1)
s = re.sub(r'android:label="[^"]*"', 'android:label="AgroVision"', s, count=1)

caminho.write_text(s, encoding="utf-8")
print("AndroidManifest.xml ajustado.")
