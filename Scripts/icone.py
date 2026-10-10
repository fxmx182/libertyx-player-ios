#!/usr/bin/env python3
"""
O ícone do LibertyX Partition, gerado por geometria (mesma escola do Player e do Folder).

A regra que a família aprendeu: em ícone pequeno vale a MANCHA, não o detalhe. O Player é
escuro com um X de ouro; o Folder é uma pasta de ouro. O Partition é um DISCO de ouro —
um círculo — com uma fatia destacada, como num gráfico de pizza: é a partição. O X das
fitas da marca fica vazado na face do disco. De longe: círculo dourado com um entalhe;
de perto: a mesma marca.

Gera:
  src/LibertyX.Partition/Assets/app.ico        ícone do executável (16–256)
  src/LibertyX.Partition/Assets/Logo.axaml     a marca como geometria vetorial para a interface
  Scripts/icone-512.png                        prévia

Dependências (venv em toolchain/icon-venv): shapely resvg-py pillow
"""
import io, math, os
import resvg_py
from PIL import Image
from shapely import affinity
from shapely.geometry import Polygon, Point
from shapely.ops import unary_union

AQUI = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(AQUI, "../src/LibertyX.Partition/Assets")
OURO_P = [(0, "#FFF6D6"), (0.45, "#FBC501"), (1, "#B97A06")]
FUNDO = [(0, "#2E2010"), (0.55, "#150E07"), (1, "#070403")]
C = (54, 54)


def elipse(rx, ry, ang, n=360):
    p = Polygon([(54 + rx * math.cos(t), 54 + ry * math.sin(t)) for t in (2 * math.pi * i / n for i in range(n))])
    return affinity.rotate(p, ang, origin=C)


def fitas(rx=35, ry=13.0, irx=27.5, iry=8.8, ang=45, trama=1.3):
    A = elipse(rx, ry, -ang).difference(elipse(irx, iry, -ang))
    B = elipse(rx, ry, ang).difference(elipse(irx, iry, ang))
    cruz = A.intersection(B)
    pts = [g.centroid for g in cruz.geoms] if cruz.geom_type == "MultiPolygon" else [cruz.centroid]
    for i, p in enumerate(sorted(pts, key=lambda p: math.atan2(p.y - 54, p.x - 54))):
        zona = p.buffer(7)
        if i % 2 == 0: B = B.difference(A.intersection(zona).buffer(trama))
        else:          A = A.difference(B.intersection(zona).buffer(trama))
    return unary_union([A, B])


def fatia(r, a0, a1, n=120):
    pts = [C] + [(54 + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)), 54 + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]
    return Polygon(pts)


def marca(R=41.0, r=19.5, a0=-90.0, a1=-28.0, explode=6.5, folga=3.4):
    """Prato de disco (anel) com a fatia da partição puxada para fora; o X da marca no furo central."""
    anel = Point(C).buffer(R, 256).difference(Point(C).buffer(r, 256))
    cunha = fatia(R + 2, a0, a1)
    corpo = anel.difference(cunha.buffer(folga))
    meio = math.radians((a0 + a1) / 2)
    peca = anel.intersection(cunha).buffer(-folga / 2)
    peca = affinity.translate(peca, explode * math.cos(meio), explode * math.sin(meio))
    corpo = corpo.buffer(-1.4, join_style="round").buffer(1.4, join_style="round")
    peca = peca.buffer(-1.4, join_style="round").buffer(1.4, join_style="round")
    x = affinity.scale(fitas(), 0.44, 0.44, origin=C)
    g = unary_union([corpo, peca, x])
    bx0, by0, bx1, by1 = g.bounds
    return affinity.translate(g, 54 - (bx0 + bx1) / 2, 54 - (by0 + by1) / 2)


def para_path(g, nd=2):
    d = []
    for p in getattr(g, "geoms", [g]):
        for anel in [p.exterior, *p.interiors]:
            c = list(anel.simplify(0.02).coords)[:-1]
            d.append("M" + " ".join(f"{x:.{nd}f},{y:.{nd}f}" for x, y in c) + "Z")
    return "".join(d)


def stops(L): return "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in L)


M = marca()
PF = para_path(M)


def svg(size, fundo=True, escala=0.80):
    tx = 54 - 54 * escala
    tile = (f'<rect x="0" y="0" width="108" height="108" rx="24" fill="url(#f)"/>'
            f'<rect x="0.6" y="0.6" width="106.8" height="106.8" rx="23.5" fill="none" stroke="#FBC501" stroke-opacity="0.18" stroke-width="1.2"/>') if fundo else ""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="{size}" height="{size}">
<defs><radialGradient id="f" cx="54" cy="30" r="90" gradientUnits="userSpaceOnUse">{stops(FUNDO)}</radialGradient>
<linearGradient id="o" x1="18" y1="16" x2="92" y2="94" gradientUnits="userSpaceOnUse">{stops(OURO_P)}</linearGradient></defs>
{tile}<g transform="translate({tx} {tx}) scale({escala})"><path fill-rule="evenodd" fill="url(#o)" d="{PF}"/></g></svg>'''


def png(s, px):
    return Image.open(io.BytesIO(bytes(resvg_py.svg_to_bytes(svg_string=s, width=px, height=px)))).convert("RGBA")


png(svg(512), 512).save(os.path.join(AQUI, "icone-512.png"))
sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
imgs = [png(svg(s, escala=0.86 if s <= 24 else 0.80), s) for s in sizes]
imgs[-1].save(os.path.join(ASSETS, "app.ico"), sizes=[(s, s) for s in sizes], append_images=imgs[:-1])
png(svg(256, fundo=False, escala=1.0), 256).save(os.path.join(ASSETS, "logo-mark.png"))

xaml = f'''<!-- Gerado por Scripts/icone.py — não editar à mão. -->
<ResourceDictionary xmlns="https://github.com/avaloniaui" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <!-- A marca: disco de ouro com a fatia destacada e o X da família vazado. Caixa 108×108. -->
  <StreamGeometry x:Key="LogoMark">F0 {PF}</StreamGeometry>
</ResourceDictionary>
'''
open(os.path.join(ASSETS, "Logo.axaml"), "w").write(xaml)
print("ok", len(PF))
