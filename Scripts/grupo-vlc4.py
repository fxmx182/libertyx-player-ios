#!/usr/bin/env python3
"""Põe um build no grupo interno "Eu (VLC 4)", o do dono.

O grupo interno antigo ("Eu") recebia todo build sozinho, e a Apple não deixa
desligar isso pela API. Desde 15/11/2026 o dono testa o motor VLC 4 (main)
num grupo que só recebe os builds escolhidos, e os testadores de fora ficam no
VLC 3 (ramo vlc3). O CI da main chama este script depois do envio.

    grupo-vlc4.py 69

Mesmas variáveis do asc.py. Espera o build sair do processamento (VALID).
"""
import sys
import time

from asc import chamar

APP = "6826934911"
GRUPO = "701b6eb0-fd30-40f8-aa5e-6bfdc6d3bf8c"  # Eu (VLC 4)


def main() -> None:
    numero = sys.argv[1]
    for _ in range(50):
        r = chamar("GET", f"/v1/builds?filter[app]={APP}&filter[version]={numero}"
                          "&fields[builds]=processingState")
        if r["data"]:
            build = r["data"][0]
            estado = build["attributes"]["processingState"]
            if estado == "VALID":
                chamar("POST", f"/v1/betaGroups/{GRUPO}/relationships/builds",
                       {"data": [{"type": "builds", "id": build["id"]}]})
                print(f"build {numero} no grupo Eu (VLC 4)")
                return
            if estado in ("FAILED", "INVALID"):
                raise SystemExit(f"build {numero}: {estado}")
        time.sleep(30)
    raise SystemExit(f"build {numero} não ficou pronto em 25 minutos")


if __name__ == "__main__":
    main()
