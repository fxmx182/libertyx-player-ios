#!/usr/bin/env python3
"""
O ícone do iPhone, com o mesmo desenho do Android.

A geometria mora num lugar só — Android/Scripts/icone.py, as duas fitas de ouro
em X trançadas com o play recortado no meio. Daqui se carrega só a parte dela
que desenha (tudo antes do primeiro arquivo que aquele script escreve), e se
gera o que o iOS pede:

  AppIcon.appiconset/AppIcon-1024.png   quadrado cheio, sem transparência — o
                                        próprio iOS arredonda os cantos
  AppIconSymbol.imageset/simbolo.png    o símbolo sem fundo e sem margem, para
                                        a marca dentro do app

Dependências: pip install shapely resvg-py pillow
"""
import os

AQUI = os.path.dirname(os.path.abspath(__file__))
ANDROID = os.path.join(AQUI, "../Android/Scripts/icone.py")
ASSETS = os.path.join(AQUI, "../App/Resources/Assets.xcassets")

fonte = open(ANDROID).read()
corte = fonte.index('open(f"{RES}/drawable/ic_launcher_foreground.xml"')
g = {"__file__": ANDROID}
exec(compile(fonte[:corte], ANDROID, "exec"), g)
fonte_svg = fonte[fonte.index("def svg(size"):fonte.index("def recorte(")]
exec(compile(fonte_svg, ANDROID, "exec"), g)

# O ícone: a peça de 108 do Android tem 18 de margem de corte de cada lado;
# o miolo de 72 é o que o launcher mostra, e é o mesmo enquadramento aqui.
grande = g["png"](g["svg"](1), 1024 * 108 // 72)
c = int(grande.size[0] * 18 / 108)
grande.crop((c, c, grande.size[0] - c, grande.size[0] - c)) \
      .resize((1024, 1024), g["Image"].LANCZOS).convert("RGB") \
      .save(os.path.join(ASSETS, "AppIcon.appiconset/AppIcon-1024.png"), optimize=True)

# A marca: o símbolo recortado rente, num quadrado transparente. 288 px servem
# à maior aparição dela (96 pt na tela vazia, @3x).
m = g["png"](g["svg"](108, fundo=False), 1200)
m = m.crop(m.getbbox())
lado = max(m.size) + 8
q = g["Image"].new("RGBA", (lado, lado), (0, 0, 0, 0))
q.alpha_composite(m, ((lado - m.width) // 2, (lado - m.height) // 2))
q.resize((288, 288), g["Image"].LANCZOS) \
 .save(os.path.join(ASSETS, "AppIconSymbol.imageset/simbolo.png"), optimize=True)
print("ok")
