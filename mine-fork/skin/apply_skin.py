"""Aplica a pele Minecraft (skin.css + skin.js) no SpotLo-fi.html do Mine fork. Pode rodar de novo: troca a versão antiga."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf8').read()
s = re.sub(r'<style id="mc-skin">.*?</style>\n?', '', s, flags=re.S)
s = re.sub(r'<script id="mc-skin-js">.*?</script>\n?', '', s, flags=re.S)
css = open(os.path.join(HERE, 'skin.css'), encoding='utf8').read()
js = open(os.path.join(HERE, 'skin.js'), encoding='utf8').read()
i = s.rfind('</head>'); assert i > 0
s = s[:i] + '<style id="mc-skin">' + css + '</style>\n' + s[i:]
j = s.rfind('</body>'); assert j > 0
s = s[:j] + '<script id="mc-skin-js">' + js + '</script>\n' + s[j:]
open(dst, 'w', encoding='utf8').write(s)
print('ok', len(s))
