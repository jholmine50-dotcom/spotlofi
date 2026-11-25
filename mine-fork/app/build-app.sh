#!/bin/bash
# Monta o ListenUp.app (antigo SpotLo-fi) a partir desta pasta e instala em Aplicativos.
# Uso:  bash build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

# Quando roda pela atualização automática (de dentro do app), avisa o app em vez de perguntar nada
UPD_DIR="$HOME/Library/Application Support/SpotLo-fi/update"
UPDATE_MODE=0
case "$(pwd)" in "$UPD_DIR"*) UPDATE_MODE=1 ;; esac
if [ "$UPDATE_MODE" = 1 ]; then
  rm -f "$UPD_DIR/READY" "$UPD_DIR/FAILED"
  trap 'rc=$?; if [ $rc -ne 0 ] && [ ! -f "$UPD_DIR/FAILED" ]; then { echo "o instalador parou (código $rc)"; tail -n 20 /tmp/spotlofi-update.log 2>/dev/null; } > "$UPD_DIR/FAILED"; fi' EXIT
fi

APP_NAME="ListenCraft"
OLD_NAME="SpotLo-fi"
BUNDLE_ID="com.spotlofi.app"
VERSION="1.3.0"
OUT="build/$APP_NAME.app"

for f in main.swift extras.swift app112.swift SpotLo-fi.html; do
  [ -f "$f" ] || { echo "Falta o arquivo $f nesta pasta."; exit 1; }
done

if ! xcode-select -p >/dev/null 2>&1; then
  if [ "$UPDATE_MODE" = 1 ]; then echo "Falta o compilador da Apple (Command Line Tools)." > "$UPD_DIR/FAILED"; xcode-select --install || true; exit 1; fi
  echo "Falta o compilador da Apple (Command Line Tools). Vou abrir o instalador."
  echo "Quando ele terminar, rode este script de novo."
  xcode-select --install || true
  exit 0
fi

echo "▸ Preparando o app…"
rm -rf build
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "▸ Compilando (leva uns segundos)…"
ARCH="${ARCH:-$(uname -m)}"
SDK="$(xcrun --show-sdk-path)"
FM_FLAGS=()
if [ -d "$SDK/System/Library/Frameworks/FoundationModels.framework" ]; then
  FM_FLAGS=(-D HAS_FM -Xlinker -weak_framework -Xlinker FoundationModels)
  echo "  (com Apple Intelligence)"
else
  echo "  (aviso: este compilador não tem o Apple Intelligence; atualize as Command Line Tools para usar a IA)"
fi
compile() {
  xcrun swiftc -O -swift-version 5 \
    -target "$ARCH-apple-macos13.0" \
    -framework Cocoa -framework WebKit -framework CoreAudio -framework Network \
    -framework MediaPlayer -framework ServiceManagement -framework UniformTypeIdentifiers \
    -framework Carbon -framework Speech -framework AVFoundation \
    "$@" \
    main.swift extras.swift app112.swift -o "$OUT/Contents/MacOS/$APP_NAME"
}
if [ ${#FM_FLAGS[@]} -gt 0 ]; then
  if ! compile "${FM_FLAGS[@]}" 2> build/compile-ai.log; then
    echo "  (aviso: a parte do Apple Intelligence não compilou; montando sem ela. Detalhes: $(pwd)/build/compile-ai.log)"
    compile
  fi
else
  compile
fi

cp SpotLo-fi.html "$OUT/Contents/Resources/index.html"
[ -f StatusIcon.png ] && cp StatusIcon.png "$OUT/Contents/Resources/StatusIcon.png"
[ -f widget.html ] && cp widget.html "$OUT/Contents/Resources/widget.html" && chmod 644 "$OUT/Contents/Resources/widget.html"
chmod 644 "$OUT/Contents/Resources/index.html"

if [ -f icon.png ]; then
  echo "▸ Criando o ícone…"
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
fi

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>ListenCraft</string>
  <key>NSMicrophoneUsageDescription</key><string>O ListenCraft usa o microfone para ouvir seus comandos de voz e para as chamadas do Estudar junto.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>O ListenCraft transforma sua voz em comandos para a IA do app.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>ListenCraft</string>
      <key>CFBundleURLSchemes</key><array><string>spotlofi</string></array>
    </dict>
  </array>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
  </dict>
</dict>
</plist>
EOF

echo "▸ Assinando (assinatura local)…"
codesign --force --deep --sign - "$OUT" >/dev/null 2>&1 || echo "  (aviso: não consegui assinar, mas o app deve abrir mesmo assim)"

# Mine fork: no GitHub Actions só monta o app (não instala nada)
if [ "${BUILD_ONLY:-0}" = 1 ]; then echo "✓ App montado em $OUT"; exit 0; fi

# Para de rodar a versão antiga, se estiver aberta
if [ "$UPDATE_MODE" = 1 ]; then
  touch "$UPD_DIR/READY"            # o app (1.1.7 ou mais novo) fecha sozinho ao ver este aviso
else
  osascript -e "tell application \"$OLD_NAME\" to quit" >/dev/null 2>&1 || true
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
fi
running() { pgrep -x "$OLD_NAME" >/dev/null 2>&1 || pgrep -x "$APP_NAME" >/dev/null 2>&1; }
for _ in $(seq 1 24); do
  running || break
  sleep 0.5
done
# versões antigas não sabem fechar sozinhas: pede para fechar e, se precisar, fecha à força
if running; then
  pkill -TERM -x "$OLD_NAME" 2>/dev/null || true; pkill -TERM -x "$APP_NAME" 2>/dev/null || true
  for _ in $(seq 1 10); do running || break; sleep 0.5; done
  pkill -KILL -x "$OLD_NAME" 2>/dev/null || true; pkill -KILL -x "$APP_NAME" 2>/dev/null || true
  sleep 1
fi

# As playlists ficam fora do app (não são apagadas ao reinstalar), mas guardo uma cópia por garantia
DATA="$HOME/Library/WebKit/com.spotlofi.app"
if [ -d "$DATA" ]; then
  BK="$HOME/Library/Application Support/SpotLo-fi/backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BK" && cp -R "$DATA" "$BK/" 2>/dev/null && echo "▸ Backup das suas playlists salvo em: $BK"
fi

DEST="/Applications"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
rm -rf "$DEST/$APP_NAME.app"
cp -R "$OUT" "$DEST/"
# o app mudou de nome (SpotLo-fi → ListenUp): tira a cópia antiga para não ficar duplicado
rm -rf "/Applications/$OLD_NAME.app" "$HOME/Applications/$OLD_NAME.app" 2>/dev/null || true

# O app já faz o trabalho do ajudante antigo; se ele estiver instalado, desliga
OLD="$HOME/Library/LaunchAgents/com.spotlofi.ducker.plist"
if [ -f "$OLD" ]; then
  launchctl bootout "gui/$(id -u)" "$OLD" 2>/dev/null || true
  rm -f "$OLD" "$HOME/Library/Application Support/SpotLo-fi/spotlofi-ducker"
  echo "▸ Removi o ajudante antigo (o app já faz isso sozinho)."
fi

echo ""
echo "✓ Pronto! ListenUp instalado em $DEST. Abrindo…"
open "$DEST/$APP_NAME.app" || open -a "$DEST/$APP_NAME.app" || true
