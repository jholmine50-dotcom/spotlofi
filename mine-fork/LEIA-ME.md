# ListenUp Mine fork + mod ListenUp Show

Versão separada do ListenUp com cara de Minecraft, feita pra conversar com o mod do jogo.
Ela tem a própria numeração e o próprio canal de atualização: o ListenUp normal e o Mine fork nunca se misturam.

## Baixar
Página de download: https://github.com/jholmine50-dotcom/spotlofi/releases/tag/mine-fork

- `ListenUp-Mine-fork-Mac.zip`: o app pronto (já compilado, Apple Silicon e Intel).
- `ListenUpShow-<versão>-fabric-1.21.1.jar`: o mod (Fabric 1.21.1 + Fabric API).

## Instalar (só na primeira vez)
1. Descompacta o zip e arrasta o `ListenUp.app` pra Aplicativos (substitui o atual).
2. Na primeira vez, clica com o botão direito no app → Abrir → Abrir.
3. Coloca o `.jar` na pasta `mods` do Minecraft, junto com o Fabric API.

Depois disso o app se atualiza sozinho: quando sair versão nova do fork, aparece o aviso dentro do app.

## Mod
- A letra se espalha pelo mundo: cada linha fica presa num ponto do terreno, as palavras aparecem uma a uma.
- Teclas: F7 ajustes (dá pra trocar pra letra na tela) · F8 letras · F9 luzes · [ e ] sincronia · /listenup status.

## Como publicar uma versão nova do fork
Muda `mine-fork/version.json` (versão + notas), o código em `mine-fork/app` e/ou o mod em `mine-fork/mod`, e dá push.
O GitHub compila o app, sobe na página de download e só então atualiza `mine-fork/latest.json` (o que os apps do fork leem).
A pele de Minecraft fica em `mine-fork/skin` (aplicar com `python3 mine-fork/skin/apply_skin.py mine-fork/app/SpotLo-fi.html mine-fork/app/SpotLo-fi.html`).
Fonte: Monocraft (SIL OFL 1.1).
