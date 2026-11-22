# ListenCraft + mod ListenUp Show

O ListenCraft é a versão do ListenUp com cara de Minecraft (antes chamada Mine fork), feita pra conversar com o mod do jogo. Não tem o assistente.
Ele tem a própria numeração e o próprio canal de atualização: o ListenUp normal e o ListenCraft nunca se misturam.

## Baixar
Página de download: https://github.com/jholmine50-dotcom/spotlofi/releases/tag/mine-fork

- `ListenCraft-Mac.zip`: o app pronto (já compilado, Apple Silicon e Intel).
- `ListenUpShow-<versão>-fabric-1.21.1.jar`: o mod (Fabric 1.21.1 + Fabric API).

## Instalar (só na primeira vez)
1. Descompacta o zip e arrasta o `ListenCraft.app` pra Aplicativos (se tiver o `ListenUp.app` do fork, pode apagar).
2. Na primeira vez, clica com o botão direito no app → Abrir → Abrir.
3. Coloca o `.jar` na pasta `mods` do Minecraft, junto com o Fabric API.

Depois disso o app se atualiza sozinho: quando sair versão nova do fork, aparece o aviso dentro do app.

## Mod
- A letra se espalha pelo mundo: cada linha fica presa num ponto do terreno, sempre pelo menos 1 bloco acima do chão, e as palavras aparecem uma a uma.
- No F7, o botão "Letra" alterna entre: no mundo, na tela, e mundo + tela.
- Teclas: F7 ajustes (dá pra trocar pra letra na tela) · F8 letras · F9 luzes · [ e ] sincronia · /listenup status.

## Como publicar uma versão nova do ListenCraft
Muda `mine-fork/version.json` (versão + notas), o código em `mine-fork/app` e/ou o mod em `mine-fork/mod`, e dá push.
O GitHub compila o app, sobe na página de download e só então atualiza `mine-fork/latest.json` (o que os apps do fork leem).
A pele de Minecraft fica em `mine-fork/skin` (aplicar com `python3 mine-fork/skin/apply_skin.py mine-fork/app/SpotLo-fi.html mine-fork/app/SpotLo-fi.html`).
Fonte: Monocraft (SIL OFL 1.1).
